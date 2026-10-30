import Foundation

public final class VoiceprintStore: @unchecked Sendable {
    let database:MemoryDatabase
    public init(database:MemoryDatabase) {self.database=database}
    public var profileID:String? {try? database.rows("SELECT value FROM meta WHERE key='voiceprint_profile'").first?["value"]}
    public func decorate(_ rows:[[String:String]]) throws -> [[String:String]] {
        try rows.map { row in
            var r=row;guard let id=row["id"] else {return row}
            let matches=try database.rows("""
              SELECT v.status FROM conversation_segments m JOIN segments s ON s.id=m.segment_id
              LEFT JOIN voice_matches v ON v.segment_id=s.id AND v.source_hash=s.sha256 AND v.profile_id=?
              WHERE m.conversation_id=? AND s.state='sealed'
              """,[profileID ?? "",id])
            r["voice_presence"]=Self.presence(profile:profileID != nil,statuses:matches.map {$0["status"] ?? "pending"},missing:(Int(row["missing_ms"] ?? "") ?? 0)>0)
            r["retention_choice"]=try database.rows("SELECT choice FROM conversation_choices WHERE conversation_id=?",[id]).first?["choice"] ?? "undecided"
            return r
        }
    }
    public static func presence(profile:Bool,statuses:[String],missing:Bool) -> String {
        guard profile else {return "not_enrolled"}
        if statuses.contains("detected") {return "detected"}
        if statuses.isEmpty || statuses.contains("pending") {return "pending"}
        return !missing && statuses.allSatisfy {$0=="not_detected"} ? "not_detected":"uncertain"
    }
    public func keep(_ id:String) throws {
        guard try !database.rows("SELECT id FROM conversations WHERE id=? AND state<>'superseded'",[id]).isEmpty else {throw CaptureFailure.message("本场已更新，请重新打开")}
        try database.execute("INSERT INTO conversation_choices VALUES (?,'keep',?) ON CONFLICT(conversation_id) DO UPDATE SET choice='keep',updated_ms=excluded.updated_ms",[id,MemoryDatabase.now])
    }
    public func delete(_ id:String,expectedDigest:String?=nil) throws {
        guard let scene=try database.rows("SELECT input_digest FROM conversations WHERE id=? AND state<>'superseded'",[id]).first,expectedDigest==nil || scene["input_digest"]==expectedDigest else {throw CaptureFailure.message("本场已更新，请重新确认删除范围")}

        let sources=try database.rows("SELECT segment_id FROM conversation_segments WHERE conversation_id=?",[id])
        guard !sources.isEmpty else {throw CaptureFailure.message("没有可删除来源")}
        for row in sources {if let source=row["segment_id"] {try database.deleteSegment(source)}}
    }
}
