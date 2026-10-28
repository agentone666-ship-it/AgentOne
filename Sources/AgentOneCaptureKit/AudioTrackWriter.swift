@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

/// Persists one timestamped stream (mixed by default; legacy source tracks remain readable).
public final class AudioTrackWriter: @unchecked Sendable {
    private let database: MemoryDatabase
    private let source: String
    private let sessionID: String
    private let wallAnchor: Date
    private let hostAnchor: Double
    private let segmentSeconds: Double
    private let discardSilence: Bool
    private let metadata: @Sendable () -> (String?, String)
    private let finishingContext: @Sendable () -> String
    private var file: AVAudioFile?
    private var journal:PCMRecoveryJournal?
    private var segmentID: String?
    private var url: URL?
    private var firstPTS: Double = 0
    private var endPTS: Double = 0
    private var format: AVAudioFormat?
    private var mapping = "host_clock"
    private var offset: Double = 0
    private var activity = AudioActivitySummary()
    private var segmentContext = "{}"
    private let onActivity: @Sendable (AudioActivityReading?) -> Void
    public private(set) var sealedCount = 0

    public init(database: MemoryDatabase, source: String, sessionID: String, wallAnchor: Date, hostAnchor: Double,
                segmentSeconds: Double = 60, discardSilence: Bool = false, onActivity: @escaping @Sendable (AudioActivityReading?) -> Void = { _ in }, finishingContext: @escaping @Sendable () -> String = { "{}" }, metadata: @escaping @Sendable () -> (String?, String) = { (nil, "{}") }) {
        self.database = database; self.source = source; self.sessionID = sessionID
        self.onActivity = onActivity; self.finishingContext=finishingContext
        self.wallAnchor = wallAnchor; self.hostAnchor = hostAnchor; self.segmentSeconds = segmentSeconds; self.metadata = metadata
        self.discardSilence = discardSilence
    }

    public func consume(_ sample: CMSampleBuffer) throws {
        if let packet=try Self.decodePCM(sample) {try append(packet.buffer,presentationSeconds:packet.presentationSeconds)}
    }
    public static func decodePCM(_ sample: CMSampleBuffer) throws -> (buffer:AVAudioPCMBuffer,presentationSeconds:Double)? {
        guard CMSampleBufferDataIsReady(sample), let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= Int(Int32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
            throw CaptureFailure.message("无法读取音频采样")
        }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard pts.isFinite else { throw CaptureFailure.message("音频缺少有效时间戳") }
        return (buffer,pts)
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
            // Mixed PCM is explicitly mapped to this session's host anchor. Queue
            // latency must never remap later segments to their arrival time.
            if source != "mixed", abs(nowHost - pts) > 30 {
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
            activity = AudioActivitySummary()
            let (place, context) = metadata()
            segmentContext = context
            try database.execute("INSERT INTO segments VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [id,sessionID,source,
                MemoryDatabase.ms(date(for: pts)),MemoryDatabase.ms(date(for: pts)),TimeZone.current.identifier,
                String(pts),String(hostAnchor),mapping,String(buffer.format.sampleRate),String(buffer.format.channelCount),relative,nil,
                "recording",place,context,MemoryDatabase.now])
            if source=="mixed" {journal=try PCMRecoveryJournal(id:id,directory:url.deletingLastPathComponent(),startedMS:Double(MemoryDatabase.ms(date(for:pts)))!,sampleRate:buffer.format.sampleRate,channels:Int(buffer.format.channelCount),context:context,pulseURL:RecorderFiles.audioPulse(database.root))}
        }
        let reading = AudioActivityReading.measure(buffer)
        activity.observe(reading)
        onActivity(reading)
        var currentContext=(segmentContext.data(using:.utf8).flatMap{try? JSONSerialization.jsonObject(with:$0)} as? [String:Any]) ?? [:]
        currentContext["audio_activity"]=activity.json
        if let extra=finishingContext().data(using:.utf8).flatMap({try? JSONSerialization.jsonObject(with:$0)}) as? [String:Any] {currentContext.merge(extra){_,new in new}}
        let checkpoint=String(decoding:try JSONSerialization.data(withJSONObject:currentContext),as:UTF8.self)
        try journal?.append(buffer,context:checkpoint)
        try file?.write(from: buffer)
        endPTS = max(endPTS, pts + duration)
    }

    public func finish() throws {
        guard let id = segmentID, let url else { return }
        file = nil // Flush the container before exposing it to another process.
        if let journal,let url=self.url {
            let check=try AVAudioFile(forReading:url)
            guard abs(Int64(check.length)-journal.frames)<4096 else {throw CaptureFailure.message("AAC 封口长度与恢复日志不一致")}
        }
        let finalURL = url.deletingLastPathComponent().appendingPathComponent("\(id).m4a")
        try FileManager.default.moveItem(at: url, to: finalURL)
        let hash = SHA256.hash(data: try Data(contentsOf: finalURL)).map { String(format: "%02x", $0) }.joined()
        let relative = String(finalURL.path.dropFirst(database.root.path.count + 1))
        var context = (segmentContext.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let (lastPlace,lastContext)=metadata()
        var discoveredPlace:String?
        // A first fix can arrive after the segment opens. Retain its real sample time;
        // never project a later location backwards onto a finished recording.
        let locationFormatter=ISO8601DateFormatter();locationFormatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        if let data=lastContext.data(using:.utf8),let last=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
           let point=last["location"] as? [String:Any],let stamp=point["observed_at"] as? String,
           let sampled=locationFormatter.date(from:stamp) ?? ISO8601DateFormatter().date(from:stamp),sampled>=date(for:firstPTS).addingTimeInterval(-1),sampled<=date(for:endPTS) {
            var observations=(context["location"] as? [String:Any]).map {[$0]} ?? []
            if !observations.contains(where:{$0["observed_at"] as? String==stamp}) {observations.append(point)}
            context["location_observations"]=observations
            if context["location"]==nil && context["place_source"] as? String != "user_annotation" {
                context["location"]=point;context["place_source"]="core_location";context["place_temporal_scope"]="sampled_during_segment";discoveredPlace=lastPlace
            } else if (context["location"] as? [String:Any])?["observed_at"] as? String == stamp {
                // Address resolution refines the same fix; it is not a newer position.
                context["location"]=point;discoveredPlace=lastPlace
            }
        }
        context["audio_activity"] = activity.json
        if let data=finishingContext().data(using:.utf8),let extra=try JSONSerialization.jsonObject(with:data) as? [String:Any] {context.merge(extra) {_,new in new}}
        let contextJSON = String(decoding: try JSONSerialization.data(withJSONObject: context),as: UTF8.self)
        try database.transaction {
            try database.execute("UPDATE segments SET ended_ms=?,relative_path=?,sha256=?,context_json=?,place=COALESCE(?,place),state='sealed' WHERE id=?",
                [MemoryDatabase.ms(date(for: endPTS)),relative,hash,contextJSON,discoveredPlace,id])
            try database.execute("INSERT OR IGNORE INTO jobs (id,segment_id,stage,source_hash,state,created_ms,updated_ms) VALUES (?,?,'transcribe',?,'pending',?,?)",
                [UUID().uuidString,id,hash,MemoryDatabase.now,MemoryDatabase.now])
        }
        try journal?.removeAfterSeal();journal=nil
        segmentID = nil; self.url = nil; format = nil; sealedCount += 1
        if discardSilence { SilencePruner.enqueue(root: database.root, id: id) }
    }

    private func date(for pts: Double) -> Date { wallAnchor.addingTimeInterval(pts + offset - hostAnchor) }
}
