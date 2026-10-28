import Foundation
import CryptoKit

/// A discussion is a logical, source-backed interval, independent of AAC rotation.
public final class ConversationMemory: @unchecked Sendable {
    public static let pauseMilliseconds: Int64 = 180_000
    private let database: MemoryDatabase
    private var lastScan: Int64 = 0
    private var signature = ""
    public init(database: MemoryDatabase) { self.database = database }

    public func refresh(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000), force: Bool = false) throws {
        let fingerprint = try database.rows("""
          SELECT (SELECT COUNT(*) FROM segments WHERE state='sealed') n,
          (SELECT COALESCE(MAX(ended_ms),0) FROM segments WHERE state='sealed') latest,
          (SELECT COUNT(*) FROM transcripts) transcripts,
          (SELECT COALESCE(SUM(revision),0) FROM transcripts) revisions,
          (SELECT COALESCE(MAX(created_ms),0) FROM transcripts) changed,
          (SELECT COALESCE(MAX(updated_ms),0) FROM jobs WHERE stage='transcribe') queue_changed
          """).first ?? [:]
        let nextSignature = fingerprint.keys.sorted().map { $0 + ":" + (fingerprint[$0] ?? "") }.joined(separator: ";")
        guard force || signature != nextSignature || now-lastScan >= 15_000 else { return }
        try database.transaction {
            let rows = try database.rows("""
              SELECT s.id,s.started_ms,s.ended_ms,s.sha256,t.revision,t.text,t.utterances_json,t.status,
              EXISTS(SELECT 1 FROM jobs j WHERE j.segment_id=s.id AND j.stage='transcribe' AND j.state IN ('pending','leased') AND j.input_revision=COALESCE(t.revision,0)) retry_pending
              FROM segments s LEFT JOIN transcripts t ON t.segment_id=s.id
              AND t.revision=(SELECT MAX(revision) FROM transcripts WHERE segment_id=s.id)
              WHERE s.state='sealed' ORDER BY s.started_ms,s.id
              """)
            let chunks = rows.compactMap(Chunk.init)
            let spoken = chunks.filter { $0.speech != nil }
            var groups = [[Chunk]]()
            for chunk in spoken {
                if let last = groups.last, let previous = last.map({ $0.speech!.1 }).max(), chunk.speech!.0 - previous <= Self.pauseMilliseconds {
                    groups[groups.count-1].append(chunk)
                } else { groups.append([chunk]) }
            }
            var activeIDs = Set<String>()
            for group in groups {
                guard group.reduce(0, { $0 + $1.text.filter { !$0.isWhitespace }.count }) >= 8,
                      let first = group.first else { continue }
                let speechStart = group.map { $0.speech!.0 }.min()!, speechEnd = group.map { $0.speech!.1 }.max()!
                // Include the complete boundary chunks. Legacy ASR may have
                // retained only their final words; its timestamps must not
                // trim away the beginning of the source recording.
                let start = max(chunks.first?.start ?? speechStart, min(first.start, speechStart - 5_000))
                let end = min(chunks.last?.end ?? speechEnd, max(group.map(\.end).max()!, speechEnd + 15_000))
                let members = chunks.filter { $0.end > start && $0.start < end }
                let pending = chunks.filter { $0.end > start && $0.start < speechEnd + Self.pauseMilliseconds && $0.pending }.count
                let state = now-speechEnd < Self.pauseMilliseconds ? "open" : pending > 0 ? "processing" : "ended"
                let id = "conversation-" + first.id
                activeIDs.insert(id)
                let text = members.filter { !$0.text.isEmpty }.map { chunk in
                    let elapsed = max(0, chunk.start-start)/1000
                    return "[\(elapsed/60):\(String(format: "%02lld",elapsed%60))] " + chunk.text
                }.joined(separator: "\n")
                let preview = group.prefix(3).map { String($0.text.prefix(100)) }.joined(separator: " … ")
                let input = [String(start),String(end),state] + members.map { [$0.id,$0.hash,String($0.revision)].joined(separator: ":") }
                let digest = SHA256.hash(data: Data(input.joined(separator: "\n").utf8)).map { String(format: "%02x",$0) }.joined()
                let old = try database.rows("SELECT input_digest,pending_count FROM conversations WHERE id=?",[id]).first
                guard old?["input_digest"] != digest || old?["pending_count"] != String(pending) else { continue }
                var merged = [(Int64,Int64)]()
                for member in members {
                    let lo = max(start,member.start), hi = min(end,member.end)
                    if let tail = merged.last, lo <= tail.1 { merged[merged.count-1].1 = max(tail.1,hi) }
                    else { merged.append((lo,hi)) }
                }
                let missing = max(0,end-start-merged.reduce(0) { $0 + $1.1-$1.0 })
                try database.execute("""
                  INSERT INTO conversations VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                  ON CONFLICT(id) DO UPDATE SET started_ms=excluded.started_ms,ended_ms=excluded.ended_ms,
                  last_speech_ms=excluded.last_speech_ms,state=excluded.state,input_digest=excluded.input_digest,
                  preview_text=excluded.preview_text,transcript_text=excluded.transcript_text,segment_count=excluded.segment_count,
                  pending_count=excluded.pending_count,missing_ms=excluded.missing_ms,updated_ms=excluded.updated_ms
                  """,[id,String(start),String(end),String(speechEnd),state,digest,preview,text,String(members.count),String(pending),String(missing),String(now)])
                try database.execute("DELETE FROM conversation_segments WHERE conversation_id=?",[id])
                for (ordinal,member) in members.enumerated() {
                    try database.execute("INSERT INTO conversation_segments VALUES (?,?,?,?,?)",[id,member.id,member.hash,String(member.revision),String(ordinal)])
                }
            }
            for row in try database.rows("SELECT id FROM conversations WHERE state<>'superseded'") {
                guard let id = row["id"], !activeIDs.contains(id) else { continue }
                try database.execute("UPDATE conversations SET state='superseded',preview_text='',transcript_text='' WHERE id=?",[id])
            }
        }
        signature = nextSignature; lastScan = now
    }

    public func recent(query: String = "", limit: Int = 30) throws -> [[String:String]] {
        let rows = try database.rows("""
          SELECT c.* FROM conversations c
          WHERE c.state<>'superseded'
          AND NOT EXISTS(SELECT 1 FROM conversation_segments m JOIN segments s ON s.id=m.segment_id
                         WHERE m.conversation_id=c.id AND s.state<>'sealed')
          ORDER BY c.started_ms DESC
          """)
        let key=query.filter {!$0.isWhitespace}.lowercased()
        return Array(rows.filter {key.isEmpty || ($0["transcript_text"] ?? "").filter {!$0.isWhitespace}.lowercased().contains(key)}.prefix(min(max(1,limit),100)))
    }

    @discardableResult public func retranscribe(id: String) throws -> Int {
        try database.transaction {
            let rows=try database.rows("""
              SELECT s.id,s.sha256,t.revision FROM conversation_segments m JOIN segments s ON s.id=m.segment_id
              JOIN transcripts t ON t.segment_id=s.id AND t.revision=(SELECT MAX(revision) FROM transcripts WHERE segment_id=s.id)
              WHERE m.conversation_id=? AND s.state='sealed' AND t.engine NOT LIKE 'apple-on-device-windowed-v2:%'
              """,[id])
            guard rows.count<=240 else {throw CaptureFailure.message("本场超过四小时，请分批补全转写")}
            var count=0
            for row in rows {
                count += try database.execute("INSERT OR IGNORE INTO jobs (id,segment_id,stage,source_hash,input_revision,state,created_ms,updated_ms) VALUES (?,?,'transcribe',?,?,'pending',?,?)",[UUID().uuidString,row["id"],row["sha256"],row["revision"],MemoryDatabase.now,MemoryDatabase.now])
            }
            return count
        }
    }

    private struct Chunk {
        let id: String, hash: String, text: String
        let start: Int64, end: Int64, revision: Int
        let pending: Bool
        let speech: (Int64,Int64)?
        init?(_ row: [String:String]) {
            guard let id=row["id"],let hash=row["sha256"],let start=Int64(row["started_ms"] ?? ""),let end=Int64(row["ended_ms"] ?? ""),end>start else { return nil }
            self.id=id;self.hash=hash;self.start=start;self.end=end
            revision=Int(row["revision"] ?? "") ?? 0;pending=revision == 0 || row["retry_pending"]=="1";text=row["text"]?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            let utterances = row["utterances_json"].flatMap { $0.data(using:.utf8) }.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [[String:Any]] } ?? []
            let ranges = utterances.compactMap { u -> (Int64,Int64)? in
                guard let a=u["start_ms"] as? Int64,let b=u["end_ms"] as? Int64,b>a,let t=u["text"] as? String,!t.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return nil }
                let lo=max(start,start+a),hi=min(end,start+b);return hi>lo ? (lo,hi):nil
            }
            if !text.isEmpty,row["status"] != "no_speech" { speech = ranges.isEmpty ? (start,end):(ranges.map(\.0).min()!,ranges.map(\.1).max()!) }
            else { speech=nil }
        }
    }
}
