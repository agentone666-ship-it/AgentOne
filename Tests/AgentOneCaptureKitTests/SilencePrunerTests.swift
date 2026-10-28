@testable import AgentOneCaptureKit
import AVFoundation
import CoreMedia
import Foundation
import Testing

struct SilencePrunerTests {
    private func recording(_ db: MemoryDatabase, amplitude: Float = 0, discardSilence: Bool = false) throws -> String {
        let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let writer = AudioTrackWriter(database: db, source: "mixed", sessionID: UUID().uuidString, wallAnchor: Date(), hostAnchor: host, discardSilence: discardSilence)
        for second in 0..<3 {
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)); pcm.frameLength = 48000
            for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0, count: 48000) }
            // A brief quiet sound on only one channel, surrounded by silence.
            if second == 1 { for frame in 12000..<21600 { pcm.floatChannelData![1][frame] = amplitude * sin(Float(frame) * 2 * .pi * 440 / 48000) } }
            try writer.append(pcm, presentationSeconds: host + Double(second))
        }
        let id = try #require(db.rows("SELECT id FROM segments ORDER BY created_ms DESC LIMIT 1").first?["id"])
        try writer.finish(); return id
    }
    @Test func actualSilentAACIsRemovedWithJobsAndRecoveryFilesButTimingIsRetained() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try MemoryDatabase(root: root), id = try recording(db)
        let url = try db.verifiedAudioURL(id)
        #expect(try SilencePruner.inspect(url) != nil)
        let preview = try SilencePruner.scan(database: db, apply: false)
        #expect(preview.silent == 1 && preview.deleted == 0 && FileManager.default.fileExists(atPath: url.path))
        let result = try SilencePruner.scan(database: db, apply: true)
        #expect(result.deleted == 1 && result.bytesReclaimed > 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try db.rows("SELECT id FROM jobs WHERE state IN ('pending','leased')").isEmpty)
        #expect(try db.rows("SELECT id FROM coverage WHERE reason='silent_audio_discarded'").count == 1)
        try db.recoverInterruptedSegments()
        #expect(try db.rows("SELECT id FROM segments WHERE state='sealed'").isEmpty)
        #expect(try SilencePruner.scan(database: db, apply: true).deleted == 0)
    }
    @Test func faintSingleChannelSoundAndItsSurroundingSilenceSurviveEvenWithNoSpeechASR() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try MemoryDatabase(root: root), id = try recording(db, amplitude: 0.001)
        try db.execute("INSERT INTO transcripts VALUES (?,1,'','[]','no_speech','fixture',?)", [id, MemoryDatabase.now])
        try db.execute("UPDATE segments SET context_json=json_set(context_json,'$.audio_activity.peak_rms_dbfs',-160) WHERE id=?", [id]) // A wrong legacy summary must not delete real sound.
        #expect(try SilencePruner.inspect(db.verifiedAudioURL(id)) == nil)
        let result = try SilencePruner.scan(database: db, apply: true)
        #expect(result.deleted == 0)
        let file = try AVAudioFile(forReading: db.verifiedAudioURL(id))
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 3) < 0.06)
    }
    @Test func transcriptLeasesAndChangedHashesProtectSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try MemoryDatabase(root: root), id = try recording(db)
        try db.execute("UPDATE jobs SET state='leased' WHERE segment_id=?", [id])
        #expect(try SilencePruner.scan(database: db, apply: true).protected == 1)
        try db.execute("UPDATE jobs SET state='pending' WHERE segment_id=?", [id])
        try db.execute("INSERT INTO transcripts VALUES (?,1,'保留的低声对话','[]','ok','fixture',?)", [id, MemoryDatabase.now])
        #expect(try SilencePruner.scan(database: db, apply: true).protected == 1)
        try db.execute("DELETE FROM transcripts WHERE segment_id=?", [id])
        try db.execute("INSERT INTO analyses VALUES (?,1,1,'{}',?)", [id, MemoryDatabase.now])
        #expect(try SilencePruner.scan(database: db, apply: true).protected == 1)
        try db.execute("DELETE FROM analyses WHERE segment_id=?", [id])
        let url = try db.verifiedAudioURL(id)
        try Data("not an audio file".utf8).write(to: url)
        let result = try SilencePruner.scan(database: db, apply: true)
        #expect(result.failed == 1 && result.deleted == 0)
        #expect(try db.rows("SELECT id FROM segments WHERE id=? AND state='sealed'", [id]).count == 1)
    }
    @Test func asyncSealingCleanupDoesNotRequireRestartingCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try MemoryDatabase(root: root), id = try recording(db, discardSilence: true)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, try db.rows("SELECT id FROM segments WHERE id=? AND state='deleted' AND json_extract(context_json,'$.cleanup_pending')=0", [id]).isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try db.rows("SELECT state FROM segments WHERE id=?", [id]).first?["state"] == "deleted")
        try db.resumeSilenceCleanup()
        #expect(try db.rows("SELECT context_json FROM segments WHERE id=?", [id]).first?["context_json"]?.contains("\"cleanup_pending\":false") == true)
    }
    @Test func cleanupAfterCommittedTombstoneRemovesResidualFilesWithoutRecoveringThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try MemoryDatabase(root: root), id = try recording(db)
        let url = try db.verifiedAudioURL(id)
        // State at a process exit between the durable tombstone and file removal.
        try db.execute("UPDATE segments SET state='deleted',context_json='{\"silence_discarded\":true,\"cleanup_pending\":true}' WHERE id=?", [id])
        for suffix in [".pcm", ".pcm.json", ".partial.m4a"] { try Data([0]).write(to: url.deletingLastPathComponent().appendingPathComponent(id + suffix)) }
        try db.recoverInterruptedSegments()
        #expect(try db.rows("SELECT id FROM segments WHERE state='sealed'").isEmpty)
        try db.resumeSilenceCleanup(); try db.resumeSilenceCleanup()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).isEmpty)
    }
}
