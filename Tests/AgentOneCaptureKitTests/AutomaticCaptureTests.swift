@testable import AgentOneCaptureKit
import AVFoundation
import CoreMedia
import Foundation
import Testing

struct AutomaticCaptureTests {
    @Test func automaticStartupOnlyPromptsOnceAndHonorsManualPause() {
        #expect(AutomaticCapturePolicy.startup(enabled: true,desired: nil,setupAttempted: false,demo: false) == .start(allowPermissionPrompts: true))
        #expect(AutomaticCapturePolicy.startup(enabled: true,desired: true,setupAttempted: true,demo: false) == .start(allowPermissionPrompts: false))
        #expect(AutomaticCapturePolicy.startup(enabled: true,desired: false,setupAttempted: false,demo: false) == .paused)
        #expect(AutomaticCapturePolicy.startup(enabled: false,desired: true,setupAttempted: true,demo: false) == .inactive)
        #expect(AutomaticCapturePolicy.startup(enabled: true,desired: true,setupAttempted: false,demo: true) == .inactive)
    }

    @Test func measuresRealPCMFormatsAndBothChannelLayouts() throws {
        for common in [AVAudioCommonFormat.pcmFormatFloat32,.pcmFormatFloat64,.pcmFormatInt16,.pcmFormatInt32] {
            for interleaved in [true,false] {
                let format = try #require(AVAudioFormat(commonFormat: common,sampleRate: 48000,channels: 2,interleaved: interleaved))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 100))
                buffer.frameLength = 100
                let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for lane in list.indices {
                    let count = 100 * (interleaved ? 2 : 1)
                    let data = try #require(list[lane].mData)
                    switch common {
                    case .pcmFormatFloat32: data.assumingMemoryBound(to: Float.self).update(repeating: 0.25,count: count)
                    case .pcmFormatFloat64: data.assumingMemoryBound(to: Double.self).update(repeating: 0.25,count: count)
                    case .pcmFormatInt16: data.assumingMemoryBound(to: Int16.self).update(repeating: 8192,count: count)
                    case .pcmFormatInt32: data.assumingMemoryBound(to: Int32.self).update(repeating: 536870912,count: count)
                    default: break
                    }
                }
                let reading = try #require(AudioActivityReading.measure(buffer))
                #expect(abs(reading.rmsDBFS - (-12.0412)) < 0.001)
                #expect(reading.hasSound)
            }
        }
    }

    @Test func realSilenceDoesNotTriggerSoundAndMeterExpiresPerSource() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000,channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 100))
        buffer.frameLength = 100
        buffer.floatChannelData![0].update(repeating: 0,count: 100)
        let quiet = try #require(AudioActivityReading.measure(buffer))
        #expect(!quiet.hasSound)
        let meter = CaptureActivityMeter()
        meter.observe(quiet,source: "microphone",now: 0)
        #expect(!meter.hasSound(source: "microphone",now: 1))
        #expect(meter.hasSamples(source: "microphone",now: 1))
        #expect(!meter.hasSamples(source: "microphone",now: 11))
        buffer.floatChannelData![0].update(repeating: 0.1,count: 100)
        meter.observe(AudioActivityReading.measure(buffer),source: "system_audio",now: 2)
        #expect(meter.hasSound(source: "system_audio",now: 3))
        #expect(!meter.hasSound(source: "microphone",now: 3))
        #expect(!meter.hasSound(source: "system_audio",now: 6))
        meter.reset()
        #expect(!meter.hasSound(source: "system_audio",now: 3))
    }

    @Test func encoderPreservesQuietLeadInAndTailAndRetainsActivityEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MemoryDatabase(root: root)
        let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let writer = AudioTrackWriter(database: database,source: "microphone",sessionID: "automatic-test",wallAnchor: Date(),hostAnchor: host,metadata: { ("test","{\"application\":\"fixture\"}") })
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000,channels: 1))
        for (index,amplitude) in [Float(0),0.1,0].enumerated() {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 9600))
            buffer.frameLength = 9600
            for frame in 0..<9600 { buffer.floatChannelData![0][frame] = amplitude * sin(Float(frame)*2 * .pi*440/48000) }
            try writer.append(buffer,presentationSeconds: host + Double(index)*0.2)
        }
        try writer.finish()
        let row = try #require(database.rows("SELECT * FROM segments").first)
        let audio = try AVAudioFile(forReading: root.appendingPathComponent(try #require(row["relative_path"])))
        #expect(Double(audio.length)/audio.fileFormat.sampleRate >= 0.59)
        let contextJSON = try #require(row["context_json"])
        let context = try #require(JSONSerialization.jsonObject(with: Data(contextJSON.utf8)) as? [String: Any])
        #expect(context["application"] as? String == "fixture")
        let activity = try #require(context["audio_activity"] as? [String: Any])
        #expect(activity["windows"] as? Int == 3)
        #expect(activity["active_windows"] as? Int == 1)
        #expect(activity["silence_discarded"] as? Bool == false)
        #expect(activity["semantic_classification"] as? Bool == false)
        #expect(try database.rows("SELECT * FROM jobs WHERE state='pending'").count == 1)
    }
}

private struct TapPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let hostSeconds: Double
}
private struct TapInvocation: @unchecked Sendable {
    let block: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer
    let time: AVAudioTime
    func invoke() { block(buffer,time) }
}

@MainActor struct MicrophoneTapTests {
    @Test func coreAudioCallbackRunsOffUIActorAndCopiesReusableBuffer() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000,channels: 1))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 100))
        input.frameLength = 100
        input.floatChannelData![0].update(repeating: 0.25,count: 100)
        let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let result: TapPacket = try await withCheckedThrowingContinuation { continuation in
            let tap = makeMicrophoneTap(deliver: { buffer,pts in
                continuation.resume(returning: TapPacket(buffer: buffer,hostSeconds: pts))
            },fail: { message in continuation.resume(throwing: CaptureFailure.message(message)) })
            let invocation = TapInvocation(block: tap,buffer: input,time: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: host)))
            DispatchQueue.global(qos: .userInitiated).async { invocation.invoke() }
        }
        input.floatChannelData![0].update(repeating: 0,count: 100)
        #expect(result.buffer !== input)
        #expect(result.buffer.frameLength == 100)
        #expect(result.buffer.floatChannelData![0][0] == 0.25)
        #expect(abs(result.hostSeconds-host) < 0.001)
    }
}
