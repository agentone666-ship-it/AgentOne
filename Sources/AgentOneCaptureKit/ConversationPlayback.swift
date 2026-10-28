@preconcurrency import AVFoundation
import Foundation

/// A derived, time-aligned single playback file. Originals remain immutable.
public enum ConversationPlayback {
    @MainActor public static func export(id: String, database: MemoryDatabase) async throws -> URL {
        guard id.hasPrefix("conversation-"),id.allSatisfy({$0.isLetter || $0.isNumber || $0 == "-"}),
              let conversation=try database.rows("SELECT * FROM conversations WHERE id=? AND state<>'superseded'",[id]).first,
              let started=Int64(conversation["started_ms"] ?? ""),let ended=Int64(conversation["ended_ms"] ?? ""),ended>started,
              let digest=conversation["input_digest"] else { throw CaptureFailure.message("讨论已更新或不可用") }
        let sources=try database.rows("""
          SELECT s.*,m.source_hash FROM conversation_segments m JOIN segments s ON s.id=m.segment_id
          WHERE m.conversation_id=? ORDER BY m.ordinal
          """,[id])
        guard !sources.isEmpty else { throw CaptureFailure.message("讨论没有可回放原音") }
        let composition=AVMutableComposition()
        let mix=AVMutableAudioMix()
        var parameters=[AVAudioMixInputParameters]()
        for source in sources {
            guard source["state"]=="sealed",source["sha256"]==source["source_hash"],let sourceID=source["id"],
                  let start=Int64(source["started_ms"] ?? ""),let end=Int64(source["ended_ms"] ?? "") else { throw CaptureFailure.message("原音已改变，拒绝旧回放") }
            let url=try database.verifiedAudioURL(sourceID)
            let asset=AVURLAsset(url:url)
            guard let audio=try await asset.loadTracks(withMediaType:.audio).first,
                  let track=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw CaptureFailure.message("原音无法解码") }
            let duration=try await asset.load(.duration)
            let lo=max(started,start),hi=min(ended,end)
            let offset=Double(lo-start)/1000
            let seconds=min(Double(hi-lo)/1000,CMTimeGetSeconds(duration)-offset)
            guard seconds>0 else { throw CaptureFailure.message("原音时长与时间映射不符") }
            try track.insertTimeRange(CMTimeRange(start:CMTime(seconds:offset,preferredTimescale:48000),duration:CMTime(seconds:seconds,preferredTimescale:48000)),of:audio,at:CMTime(seconds:Double(lo-started)/1000,preferredTimescale:48000))
            let level=AVMutableAudioMixInputParameters(track:track)
            level.setVolume(source["source"]=="mixed" ? 1:0.5,at:.zero);parameters.append(level)
        }
        mix.inputParameters=parameters
        let directory=database.root.appendingPathComponent("ConversationPlayback").appendingPathComponent(id)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url=directory.appendingPathComponent(UUID().uuidString+".m4a")
        guard let export=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetAppleM4A) else { throw CaptureFailure.message("整场回放无法创建") }
        export.audioMix=mix
        export.timeRange=CMTimeRange(start:.zero,duration:CMTime(seconds:Double(ended-started)/1000,preferredTimescale:48000))
        do {
            guard #available(macOS 15,*) else {throw CaptureFailure.message("整场回放需要 macOS 15 或更新版本")}
            try await export.export(to:url,as:.m4a)
            guard try database.rows("SELECT id FROM conversations WHERE id=? AND input_digest=? AND state<>'superseded'",[id,digest]).count==1,
                  try database.rows("SELECT s.id FROM conversation_segments m JOIN segments s ON s.id=m.segment_id WHERE m.conversation_id=? AND (s.state<>'sealed' OR s.sha256<>m.source_hash)",[id]).isEmpty else {throw CaptureFailure.message("讨论已更新，请重新回放")}
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            // Validate the completed media before discarding any older export.
            let readable = try AVAudioFile(forReading: url)
            guard readable.length > 0 else { throw CaptureFailure.message("整场回放没有有效音频") }
            // Keep only this generated playback; no unbounded duplicate archive.
            // Foundation can canonicalize /var to /private/var when listing.
            for old in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) where old.lastPathComponent != url.lastPathComponent {try? FileManager.default.removeItem(at:old)}
            return url
        } catch {try? FileManager.default.removeItem(at:url);throw error}
    }
}
