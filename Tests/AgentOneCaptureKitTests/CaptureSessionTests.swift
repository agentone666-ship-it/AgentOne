@testable import AgentOneCaptureKit
import AVFoundation
import CoreMedia
import Foundation
import Testing

@MainActor struct CaptureSessionTests {
    @Test func manualToIntelligentSealsOldAudioAndWaitsWithoutWriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try MemoryDatabase(root: root)
        let sessions = CaptureSessionCoordinator()
        let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        silence.frameLength = 48000
        silence.floatChannelData![0].update(repeating: 0, count: 48000)
        var writer: MixedAudioWriter?
        var status: RecordingDecisionStatus?
        var stops = [String]()
        let stop: @MainActor (String) async throws -> Void = { reason in
            stops.append(reason)
            try writer?.finish()
            writer = nil
        }
        func start(_ mode: CaptureSessionCoordinator.Mode, offset: Double) async throws {
            try await sessions.start(mode: mode, start: {
                let next = RecordingDecisionStatus(manual: mode == .manual, preserveAllAudio: mode == .preserve)
                status = next
                writer = MixedAudioWriter(database: db, sessionID: UUID().uuidString,
                    wallAnchor: Date().addingTimeInterval(offset), hostAnchor: host + offset, decisionStatus: next)
            }, stop: stop)
        }
        try await start(.manual, offset: 0)
        #expect(status?.manual == true)
        #expect(status?.snapshot.saving == true)
        try writer?.append(silence, source: "microphone", presentationSeconds: host)
        try writer?.flush(throughHostSeconds: host + 1)
        try await start(.intelligent, offset: 1)
        #expect(stops == ["capture_mode_changed"])
        #expect(sessions.mode == .intelligent)
        #expect(status?.manual == false)
        #expect(status?.snapshot.saving == false)
        let sealed = try db.rows("SELECT id FROM segments WHERE state='sealed'")
        #expect(sealed.count == 1)
        _ = try db.verifiedAudioURL(try #require(sealed.first?["id"]))
        for second in 1..<5 {
            try writer?.append(silence, source: "microphone", presentationSeconds: host + Double(second))
            try writer?.flush(throughHostSeconds: host + Double(second + 1))
            try writer?.applyDecision(RecordingDecision(choice: "wait", confidence: 0.95), quietSeconds: 20, inputsReady: true, soundConfirmed: false)
        }
        try await sessions.stop(reason: "user_paused", operation: stop)
        #expect(try db.rows("SELECT * FROM segments").count == 1)
        #expect(try db.rows("SELECT * FROM jobs").count == 1)
        #expect(try db.rows("SELECT * FROM coverage WHERE reason='automatic_wait'").count == 1)
        #expect(sessions.mode == nil)
    }

    @Test func transitionsWaitForStartingSessionAndPauseWins() async throws {
        let sessions = CaptureSessionCoordinator()
        var releaseStart: CheckedContinuation<Void, Never>?
        var events = [String]()
        let stop: @MainActor (String) async throws -> Void = { events.append("stop:" + $0) }
        let first = Task { @MainActor in
            try await sessions.start(mode: .manual, start: {
                events.append("manual:starting")
                await withCheckedContinuation { releaseStart = $0 }
                events.append("manual:started")
            }, stop: stop)
        }
        while releaseStart == nil { await Task.yield() }
        let second = Task { @MainActor in
            try await sessions.start(mode: .preserve, start: { events.append("preserve:started") }, stop: stop)
        }
        await Task.yield()
        let pause = Task { @MainActor in try await sessions.stop(reason: "user_paused", operation: stop) }
        await Task.yield()
        #expect(events == ["manual:starting"])
        releaseStart?.resume()
        try await first.value; try await second.value; try await pause.value
        #expect(events == ["manual:starting", "manual:started", "stop:capture_mode_changed", "preserve:started", "stop:user_paused"])
        #expect(sessions.mode == nil)
    }

    @Test func failedStartCanBeRetriedAndSameModeDoesNotRestart() async throws {
        let sessions = CaptureSessionCoordinator()
        var starts = 0
        let stop: @MainActor (String) async throws -> Void = { _ in }
        do {
            try await sessions.start(mode: .intelligent, start: { throw CaptureFailure.message("test device unavailable") }, stop: stop)
            Issue.record("A failed device start must propagate")
        } catch {}
        #expect(sessions.mode == nil)
        for _ in 0..<2 {
            try await sessions.start(mode: .intelligent, start: { starts += 1 }, stop: stop)
        }
        #expect(starts == 1)
        #expect(sessions.mode == .intelligent)
    }
}
