@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

/// One writer per source; both receive the same wall/host-clock anchor.
/// This keeps independent tracks and original presentation timestamps instead
/// of mixing system output with microphone echo or guessing speaker identity.
public final class AudioTrackWriter: @unchecked Sendable {
    private let database: MemoryDatabase
    private let source: String
    private let sessionID: String
    private let wallAnchor: Date
    private let hostAnchor: Double
    private let segmentSeconds: Double
    private let metadata: @Sendable () -> (String?, String)
    private var file: AVAudioFile?
    private var segmentID: String?
    private var url: URL?
    private var firstPTS: Double = 0
    private var endPTS: Double = 0
    private var format: AVAudioFormat?
    private var mapping = "host_clock"
    private var offset: Double = 0
    public private(set) var sealedCount = 0

    public init(database: MemoryDatabase, source: String, sessionID: String, wallAnchor: Date, hostAnchor: Double,
                segmentSeconds: Double = 60, metadata: @escaping @Sendable () -> (String?, String) = { (nil, "{}") }) {
        self.database = database; self.source = source; self.sessionID = sessionID
        self.wallAnchor = wallAnchor; self.hostAnchor = hostAnchor; self.segmentSeconds = segmentSeconds; self.metadata = metadata
    }

    public func consume(_ sample: CMSampleBuffer) throws {
        guard CMSampleBufferDataIsReady(sample), let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= Int(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
            throw CaptureFailure.message("无法读取音频采样")
        }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard pts.isFinite else { throw CaptureFailure.message("音频缺少有效时间戳") }
        try append(buffer, presentationSeconds: pts)
    }

    /// Also used by the synthetic-audio harness; exercises the real encoder,
    /// rotation, persistence and file finalization without recording a device.
    public func append(_ buffer: AVAudioPCMBuffer, presentationSeconds pts: Double) throws {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard pts.isFinite, duration > 0 else { throw CaptureFailure.message("无效音频区间") }
        if file != nil, (pts < endPTS - 0.05 || pts - endPTS > 0.1 || pts - firstPTS >= segmentSeconds || format != buffer.format) {
            let previousEnd = endPTS
            try finish()
            if pts > previousEnd + 0.1 {
                try database.addGap(started: date(for: previousEnd), ended: date(for: pts), source: source, reason: "no_samples")
            }
        }
        if file == nil {
            // ScreenCaptureKit normally uses the host clock. Retain a labeled
            // arrival-based fallback when a device supplies another clock.
            let nowHost = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            if abs(nowHost - pts) > 30 {
                mapping = "arrival_estimate"
                offset = nowHost - pts
            } else { mapping = "host_clock"; offset = 0 }
            firstPTS = pts; endPTS = pts; format = buffer.format
            let id = UUID().uuidString
            segmentID = id
            let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = .current
            let relative = "Audio/\(day.string(from: date(for: pts)))/\(id).partial.m4a"
            let url = database.root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: buffer.format.channelCount, AVEncoderBitRateKey: source == "microphone" ? 48_000 : 96_000]
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
            self.url = url
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let (place, context) = metadata()
            try database.execute("INSERT INTO segments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [id,sessionID,source,
                MemoryDatabase.ms(date(for: pts)),MemoryDatabase.ms(date(for: pts)),TimeZone.current.identifier,
                String(pts),String(hostAnchor),mapping,String(buffer.format.sampleRate),String(buffer.format.channelCount),relative,nil,
                "recording",place,context,MemoryDatabase.now])
        }
        try file?.write(from: buffer)
        endPTS = max(endPTS, pts + duration)
    }

    public func finish() throws {
        guard let id = segmentID, let url else { return }
        file = nil // Flush the container before exposing it to another process.
        let finalURL = url.deletingLastPathComponent().appendingPathComponent("\(id).m4a")
        try FileManager.default.moveItem(at: url, to: finalURL)
        let hash = SHA256.hash(data: try Data(contentsOf: finalURL)).map { String(format: "%02x", $0) }.joined()
        let relative = String(finalURL.path.dropFirst(database.root.path.count + 1))
        try database.transaction {
            try database.execute("UPDATE segments SET ended_ms=?,relative_path=?,sha256=?,state='sealed' WHERE id=?",
                [MemoryDatabase.ms(date(for: endPTS)),relative,hash,id])
            try database.execute("INSERT OR IGNORE INTO jobs (id,segment_id,stage,source_hash,state,created_ms,updated_ms) VALUES (?,?,'transcribe',?,'pending',?,?)",
                [UUID().uuidString,id,hash,MemoryDatabase.now,MemoryDatabase.now])
        }
        segmentID = nil; self.url = nil; format = nil; sealedCount += 1
    }

    private func date(for pts: Double) -> Date { wallAnchor.addingTimeInterval(pts + offset - hostAnchor) }
}
