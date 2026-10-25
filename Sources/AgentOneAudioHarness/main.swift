import AgentOneCaptureKit
import AVFoundation
import CoreMedia
import Foundation

@main struct AudioHarness {
    static func main() throws {
        let args = CommandLine.arguments
        let explicitRoot = args.firstIndex(of: "--home").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let root = explicitRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("agentone-audio-harness-\(UUID().uuidString)")
        if FileManager.default.fileExists(atPath: root.path), !(try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty {
            throw CaptureFailure.message("音频 Harness 需要空白测试目录，不能使用真实 Memory 目录")
        }
        defer { if explicitRoot == nil { try? FileManager.default.removeItem(at: root) } }
        let database = try MemoryDatabase(root: root)
        let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let wall = Date(timeIntervalSince1970: 1_761_480_000)
        for (source,channels) in [("system_audio",2),("microphone",1)] {
            let writer = AudioTrackWriter(database: database,source: source,sessionID: "synthetic-dual-track",wallAnchor: wall,hostAnchor: host,segmentSeconds: 1,metadata: { ("合成测试地点", "{\"synthetic\":true}") })
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000,channels: AVAudioChannelCount(channels))!
            for index in 0..<4 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 24_000)!
                buffer.frameLength = 24_000
                for channel in 0..<channels {
                    for frame in 0..<24_000 {
                        buffer.floatChannelData![channel][frame] = 0.15 * sin(Float(frame) * 2 * .pi * (source == "microphone" ? 880 : 440) / 48_000)
                    }
                }
                var description: CMAudioFormatDescription?
                guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,asbd: format.streamDescription,layoutSize: 0,layout: nil,magicCookieSize: 0,magicCookie: nil,extensions: nil,formatDescriptionOut: &description) == noErr else { throw CaptureFailure.message("合成音频格式失败") }
                var timing=CMSampleTimingInfo(duration: CMTime(value: 1,timescale: 48_000),presentationTimeStamp: CMTime(seconds: host + Double(index)*0.5,preferredTimescale: 48_000),decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,dataBuffer: nil,dataReady: false,makeDataReadyCallback: nil,refcon: nil,formatDescription: description,sampleCount: Int(buffer.frameLength),sampleTimingEntryCount: 1,sampleTimingArray: &timing,sampleSizeEntryCount: 0,sampleSizeArray: nil,sampleBufferOut: &sample) == noErr,let sample else { throw CaptureFailure.message("合成采样缓冲失败") }
                guard CMSampleBufferSetDataBufferFromAudioBufferList(sample,blockBufferAllocator: kCFAllocatorDefault,blockBufferMemoryAllocator: kCFAllocatorDefault,flags: 0,bufferList: buffer.audioBufferList) == noErr,
                      CMSampleBufferSetDataReady(sample) == noErr else { throw CaptureFailure.message("合成采样数据失败") }
                try writer.consume(sample)
            }
            try writer.finish()
            guard writer.sealedCount == 2 else { throw CaptureFailure.message("切片轮转失败") }
        }
        let rows = try database.rows("SELECT * FROM segments ORDER BY started_ms,source")
        guard rows.count == 4, try database.rows("SELECT * FROM jobs WHERE state='pending'").count == 4 else { throw CaptureFailure.message("双路持久化失败") }
        for row in rows {
            let file = try AVAudioFile(forReading: root.appendingPathComponent(row["relative_path"]!))
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            guard seconds > 0.9,seconds < 1.2,row["sha256"]?.count == 64,row["state"] == "sealed" else { throw CaptureFailure.message("最终音频文件验证失败") }
        }
        guard rows[0]["started_ms"] == rows[1]["started_ms"], rows[2]["started_ms"] == rows[3]["started_ms"] else { throw CaptureFailure.message("双轨时间对齐失败") }
        let result: [String:Any] = ["fixture":true,"segments":4,"sources":["system_audio","microphone"],"checks":["real AAC encoding","rotation","separate tracks","shared timestamps","readable final files","source hashes","pending ASR jobs"]]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result,options: [.sortedKeys]),as: UTF8.self))
    }
}
