@preconcurrency import AVFoundation
import Foundation
import Darwin

/// Conservative whole-file silence check. Never uses ASR or a model's guess.
/// Each channel and every decoded frame must pass; quiet speech is retained.
public enum SilencePruner {
    public struct Evidence: Encodable, Sendable {
        public let seconds: Double
        public let peakDBFS: Double
        public let maxWindowRMSDBFS: Double
        public let detector = "decoded_pcm_whole_file_v1"
        public let peakLimitDBFS = -55.0
        public let windowLimitDBFS = -65.0
    }
    public struct Report: Codable, Sendable {
        public var checked = 0, silent = 0, deleted = 0, protected = 0, failed = 0
        public var bytesReclaimed: Int64 = 0
        public var dryRun = true
        public var skippedBusy = false
    }
    private static let queue = DispatchQueue(label: "life.agentone.silence-pruning", qos: .utility)

    public static func inspect(_ url: URL) throws -> Evidence? {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat, length = file.length
        let seconds = Double(length) / format.sampleRate
        guard seconds.isFinite, seconds >= 1, seconds <= 3600, format.channelCount > 0 else { return nil }
        let capacity = AVAudioFrameCount(max(1, Int(format.sampleRate * 0.02)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var frames: AVAudioFramePosition = 0, peak = 0.0, maxPower = 0.0
        while frames < length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), length - frames)))
            guard buffer.frameLength > 0, let lanes = buffer.floatChannelData else { return nil }
            for channel in 0..<Int(format.channelCount) {
                var power = 0.0
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(lanes[channel][frame])
                    guard value.isFinite else { return nil }
                    peak = max(peak, abs(value)); power += value * value
                }
                maxPower = max(maxPower, power / Double(buffer.frameLength))
            }
            // Abort early on any audible window, including one quiet channel's speech.
            guard peak < pow(10, -55.0 / 20), maxPower < pow(10, -65.0 / 10) else { return nil }
            frames += Int64(buffer.frameLength)
        }
        guard frames == length else { return nil }
        return Evidence(seconds: seconds, peakDBFS: 20 * log10(max(peak, 1e-8)), maxWindowRMSDBFS: 10 * log10(max(maxPower, 1e-16)))
    }

    /// Separate connection/queue: decoding, hashing and deletion cannot block PCM writing.
    static func enqueue(root: URL, id: String) {
        queue.async { _ = try? prune(database: MemoryDatabase(root: root), ids: [id], apply: true) }
    }
    static func enqueueExisting(root: URL) {
        queue.async { _ = try? scan(database: MemoryDatabase(root: root), apply: true) }
    }
    public static func scan(database: MemoryDatabase, apply: Bool) throws -> Report {
        // Old summary is only a cheap candidate filter. Always decode actual audio.
        let ids = try database.rows("SELECT id FROM segments WHERE state='sealed' AND ended_ms-started_ms>=1000 AND json_valid(context_json) AND CAST(json_extract(context_json,'$.audio_activity.peak_rms_dbfs') AS REAL)<-65 ORDER BY started_ms").compactMap { $0["id"] }
        return try prune(database: database, ids: ids, apply: apply)
    }
    static func prune(database: MemoryDatabase, ids: [String], apply: Bool) throws -> Report {
        var report = Report(); report.dryRun = !apply
        let fd = Darwin.open(database.root.appendingPathComponent("silence-cleanup.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CaptureFailure.message("无法取得静音清理锁") }
        defer { Darwin.close(fd) }
        guard Darwin.lockf(fd, F_TLOCK, 0) == 0 else { report.skippedBusy = true; return report }
        if apply { try database.resumeSilenceCleanup() }
        for id in ids {
            report.checked += 1
            do {
                guard let row = try database.rows("SELECT sha256 FROM segments WHERE id=? AND state='sealed'", [id]).first,
                      let hash = row["sha256"] else { continue }
                let url = try database.verifiedAudioURL(id)
                guard let evidence = try inspect(url) else { continue }
                report.silent += 1
                let audit = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
                let bytes = Int64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                if !apply { continue }
                if try database.discardVerifiedSilence(id, expectedHash: hash, audit: audit) {
                    report.deleted += 1; report.bytesReclaimed += bytes
                } else { report.protected += 1 }
            } catch { report.failed += 1 } // Unknown/unreadable means retain, never delete.
        }
        return report
    }
}
