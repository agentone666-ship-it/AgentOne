@preconcurrency import AVFoundation
import Foundation

public struct SpeechAudioWindow: Sendable {
    public let url: URL
    public let offsetMilliseconds: Int
}

/// Bound each recognition request so a provider's rolling transcript cannot
/// replace the first half of a minute with only its final recognition window.
public enum BoundedTranscription {
    public static func windows(for source: URL, directory: URL) throws -> [SpeechAudioWindow] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let file = try AVAudioFile(forReading: source), format = file.processingFormat
        let window = AVAudioFramePosition((24 * format.sampleRate).rounded())
        let stride = AVAudioFramePosition((22 * format.sampleRate).rounded())
        guard window > 0, stride > 0 else { throw CaptureFailure.message("转写采样率无效") }
        // Decode once, then slice PCM. Repeated compressed-file seeks can drop
        // converter priming frames and shift the timestamp mapping at each cut.
        guard file.length>0,Double(file.length)<=format.sampleRate*125,
              let decoded=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(file.length)) else {throw CaptureFailure.message("原音块过长或为空，无法在本机分窗")}
        let bytesPerFrame=Int(format.streamDescription.pointee.mBytesPerFrame)
        let decodedBuffers=UnsafeMutableAudioBufferListPointer(decoded.mutableAudioBufferList)
        var decodedCount:AVAudioFrameCount=0
        while decodedCount<decoded.frameCapacity {
            let requested=min(65_536,decoded.frameCapacity-decodedCount)
            guard let packet=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:requested) else {throw CaptureFailure.message("转写解码缓冲无法分配")}
            try file.read(into:packet,frameCount:requested)
            if packet.frameLength==0 {break}
            let packetBuffers=UnsafeMutableAudioBufferListPointer(packet.mutableAudioBufferList)
            for lane in decodedBuffers.indices {
                guard let source=packetBuffers[lane].mData,let destination=decodedBuffers[lane].mData else {throw CaptureFailure.message("转写采样数据缺失")}
                destination.advanced(by:Int(decodedCount)*bytesPerFrame).copyMemory(from:source,byteCount:Int(packet.frameLength)*bytesPerFrame)
            }
            decodedCount += packet.frameLength
        }
        decoded.frameLength=decodedCount
        let length=AVAudioFramePosition(decoded.frameLength)
        let input=UnsafeMutableAudioBufferListPointer(decoded.mutableAudioBufferList)
        var start: AVAudioFramePosition = 0, result = [SpeechAudioWindow]()
        while start < length {
            let frames = AVAudioFrameCount(min(window,length-start))
            guard let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames) else { throw CaptureFailure.message("转写窗口无法分配") }
            buffer.frameLength=frames
            let outputBuffers=UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for lane in input.indices {
                guard let source=input[lane].mData,let destination=outputBuffers[lane].mData else {throw CaptureFailure.message("转写采样数据缺失")}
                destination.copyMemory(from:source.advanced(by:Int(start)*bytesPerFrame),byteCount:Int(frames)*bytesPerFrame)
            }
            let url=directory.appendingPathComponent("window-\(result.count).caf")
            do {
                let output=try AVAudioFile(forWriting:url,settings:format.settings,commonFormat:format.commonFormat,interleaved:format.isInterleaved)
                try output.write(from:buffer)
            }
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            result.append(SpeechAudioWindow(url:url,offsetMilliseconds:Int((Double(start)/format.sampleRate*1000).rounded())))
            if start+window >= length { break };start += stride
        }
        return result
    }

    public static func merge(_ windows: [(offset: Int, utterances: [AudioUtterance])], durationMilliseconds: Int) -> [AudioUtterance] {
        var result=[AudioUtterance]()
        for window in windows {
            for word in window.utterances {
                let start=max(0,word.start_ms+window.offset),end=min(durationMilliseconds,word.end_ms+window.offset)
                guard end>start,!word.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
                let duplicate=result.contains { old in
                    guard old.text.trimmingCharacters(in:.whitespacesAndNewlines)==word.text.trimmingCharacters(in:.whitespacesAndNewlines) else { return false }
                    let overlap=min(old.end_ms,end)-max(old.start_ms,start)
                    return overlap>0 && Double(overlap)/Double(min(old.end_ms-old.start_ms,end-start))>=0.35
                }
                if !duplicate { result.append(AudioUtterance(start_ms:start,end_ms:end,text:word.text,speaker_local_id:nil)) }
            }
        }
        return result.sorted { $0.start_ms == $1.start_ms ? $0.end_ms < $1.end_ms : $0.start_ms < $1.start_ms }
    }
}

/// Partial snapshots can be revised from time zero, or roll forward. Replace
/// the revised suffix while retaining earlier timed words absent from the suffix.
struct SpeechTranscriptAccumulator {
    private(set) var utterances=[AudioUtterance]()
    mutating func ingest(_ snapshot: [AudioUtterance]) {
        guard let first=snapshot.map(\.start_ms).min() else { return }
        utterances.removeAll { $0.end_ms > first }
        utterances.append(contentsOf:snapshot)
    }
}
