import Foundation
import CryptoKit
import SQLite3

public enum CaptureFailure: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(value) = self { value } else { nil } }
}

/// Shared on-disk contract with the generic MCP server. No model or Agent loop.
public final class MemoryDatabase: @unchecked Sendable {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static func resource(_ name:String) -> URL? {
        let packaged=Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AgentOne_AgentOneCaptureKit.bundle")
        if let bundle=Bundle(url:packaged),let url=bundle.url(forResource:name,withExtension:"sql") {return url}
        // SwiftPM's generated CLI accessor points at the build machine when an
        // executable is relocated. Never use that fallback in a packaged app.
        if Bundle.main.bundleURL.pathExtension=="app" || ProcessInfo.processInfo.environment["AGENTONE_PACKAGED_RESOURCES_ONLY"]=="1" {return nil}
        return Bundle.module.url(forResource:name,withExtension:"sql")
    }

    public static var defaultRoot: URL {
        if let path = ProcessInfo.processInfo.environment["AGENTONE_MEMORY_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        let home = (UserDefaults.standard.string(forKey: "agentOne.home.rootPath") ?? UserDefaults(suiteName: "life.agentone.desktop")?.string(forKey: "agentOne.home.rootPath"))
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/AgentOne Home")
        return home.appendingPathComponent("Memory")
    }

    public init(root: URL = MemoryDatabase.defaultRoot) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = self.root.appendingPathComponent("memory.sqlite").path
        guard (try? self.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw CaptureFailure.message("Memory 路径不能是符号链接")
        }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CaptureFailure.message("无法打开 Memory 数据库")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        guard let schema = Self.resource("schema") else {
            throw CaptureFailure.message("缺少 Memory schema")
        }
        try executeScript(String(contentsOf: schema, encoding: .utf8))
        if try rows("SELECT value FROM meta WHERE key='schema_version'").first?["value"] == "1" {
            guard let migration=Self.resource("migrate-v2") else {throw CaptureFailure.message("缺少混音数据升级脚本")}
            do {try executeScript(String(contentsOf:migration,encoding:.utf8))}
            catch {try? executeScript("ROLLBACK");try? executeScript("PRAGMA foreign_keys=ON");throw error}
            guard try rows("PRAGMA foreign_key_check").isEmpty else {throw CaptureFailure.message("混音数据升级关系校验失败")}
        }
        guard try rows("SELECT value FROM meta WHERE key='schema_version'").first?["value"] == "2" else {
            throw CaptureFailure.message("Memory schema 版本不兼容")
        }
    }

    deinit { sqlite3_close(db) }

    public func executeScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CaptureFailure.message("Memory 数据库操作失败") }
    }

    @discardableResult public func execute(_ sql: String, _ values: [String?] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CaptureFailure.message("Memory 查询无效") }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in values.enumerated() {
            if let value { sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient) }
            else { sqlite3_bind_null(stmt, Int32(index + 1)) }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CaptureFailure.message("Memory 写入失败") }
        return Int(sqlite3_changes(db))
    }

    public func rows(_ sql: String, _ values: [String?] = []) throws -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CaptureFailure.message("Memory 查询无效") }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in values.enumerated() {
            if let value { sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient) }
            else { sqlite3_bind_null(stmt, Int32(index + 1)) }
        }
        var result: [[String: String]] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw CaptureFailure.message("Memory 读取失败") }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(stmt) {
                if let value = sqlite3_column_text(stmt, index) {
                    row[String(cString: sqlite3_column_name(stmt, index))] = String(cString: value)
                }
            }
            result.append(row)
        }
        return result
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try executeScript("BEGIN IMMEDIATE")
        do { let result = try body(); try executeScript("COMMIT"); return result }
        catch { try? executeScript("ROLLBACK"); throw error }
    }

    public func setCaptureState(_ state: String, detail: String = "") throws {
        try execute("INSERT INTO capture_state VALUES (1,?,?,?) ON CONFLICT(singleton) DO UPDATE SET state=excluded.state,detail=excluded.detail,heartbeat_ms=excluded.heartbeat_ms",
                    [state, detail, Self.now])
    }

    /// Model audit is optional. Use its own non-waiting connection so a busy
    /// preview row cannot hold the recorder's database lock or stop PCM writes.
    func tryRecordDecisionAudit(_ json:String) -> Bool {
        var connection:OpaquePointer?,statement:OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("memory.sqlite").path,&connection,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {sqlite3_close(connection);return false}
        defer {sqlite3_finalize(statement);sqlite3_close(connection)}
        sqlite3_busy_timeout(connection,0)
        let sql="INSERT INTO meta VALUES ('capture_decision',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE COALESCE(CAST(json_extract(meta.value,'$.observed_ms') AS REAL),0)<=COALESCE(CAST(json_extract(excluded.value,'$.observed_ms') AS REAL),0)"
        guard sqlite3_prepare_v2(connection,sql,-1,&statement,nil)==SQLITE_OK else{return false}
        sqlite3_bind_text(statement,1,json,-1,transient)
        return sqlite3_step(statement)==SQLITE_DONE && sqlite3_changes(connection)>0
    }

    public func addGap(started: Date, ended: Date?, source: String = "all", reason: String) throws {
        try execute("INSERT INTO coverage VALUES (?,?,?,?,?)", [UUID().uuidString, Self.ms(started), ended.map(Self.ms), source, reason])
    }

    public func recoverInterruptedSegments() throws {
        try PCMRecoveryJournal.recover(database:self)
        try transaction {
            for row in try rows("SELECT id,started_ms,source FROM segments WHERE state='recording'") {
                try execute("UPDATE segments SET state='incomplete',ended_ms=? WHERE id=?", [Self.now, row["id"]])
                try execute("INSERT INTO coverage VALUES (?,?,?,?,?)", [UUID().uuidString, row["started_ms"], Self.now, row["source"], "interrupted_tail"])
            }
        }
    }

    /// Invalidate every consolidation derived from this source before deleting
    /// its audio. Old superseded memories stay superseded, never resurrected.
    public func deleteSegment(_ id: String) throws {
        guard let row = try rows("SELECT relative_path,state FROM segments WHERE id=?",[id]).first,
              row["state"] != "recording",let relative=row["relative_path"] else { throw CaptureFailure.message("该片段仍在写入或不存在") }
        let url=root.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/Audio/") else { throw CaptureFailure.message("音频路径无效") }
        let discussions=try rows("SELECT conversation_id FROM conversation_segments WHERE segment_id=?",[id]).compactMap {$0["conversation_id"]}
        try transaction {
            for discussion in discussions {
                try execute("UPDATE conversations SET state='superseded',preview_text='',transcript_text='' WHERE id=?",[discussion])
            }
            try execute("UPDATE segments SET state='deleted',place=NULL,context_json='{}' WHERE id=?",[id])
            try execute("UPDATE jobs SET state='cancelled',lease_token=NULL,lease_until_ms=NULL WHERE segment_id=?",[id])
            try execute("UPDATE memories SET status='invalidated',title='',text='',entities_json='[]',input_digest=id WHERE id IN (SELECT memory_id FROM memory_evidence WHERE segment_id=?)",[id])
            try execute("DELETE FROM memory_evidence WHERE memory_id IN (SELECT id FROM memories WHERE status='invalidated')")
            try execute("DELETE FROM meta WHERE instr(key,?)=1",["local_label:"+id+":"])
            for table in ["transcripts","analyses","corrections","voice_matches"] { try execute("DELETE FROM \(table) WHERE segment_id=?",[id]) }
        }
        for discussion in discussions where discussion.hasPrefix("conversation-") && discussion.allSatisfy({$0.isLetter || $0.isNumber || $0 == "-"}) {
            let playback=root.appendingPathComponent("ConversationPlayback").appendingPathComponent(discussion)
            if FileManager.default.fileExists(atPath:playback.path) {try FileManager.default.removeItem(at:playback)}
        }
        try removeAudioFiles(id: id, url: url)
    }

    /// Commit the intentional silence interval before removing files. Protect
    /// any existing user/model evidence and re-check state/hash under the write lock.
    func discardVerifiedSilence(_ id: String, expectedHash: String, audit: String) throws -> Bool {
        guard UUID(uuidString: id) != nil,
              let row = try rows("SELECT relative_path,started_ms,ended_ms,source FROM segments WHERE id=? AND state='sealed' AND sha256=?", [id, expectedHash]).first,
              let relative = row["relative_path"] else { return false }
        let url = root.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/Audio/") else { return false }
        let context = "{\"silence_discarded\":true,\"cleanup_pending\":true,\"silence_evidence\":" + audit + "}"
        let accepted = try transaction {
            guard try !rows("SELECT id FROM segments WHERE id=? AND state='sealed' AND sha256=?", [id, expectedHash]).isEmpty else { return false }
            for query in ["SELECT segment_id FROM transcripts WHERE segment_id=? AND trim(text)!=''", "SELECT segment_id FROM analyses WHERE segment_id=?", "SELECT segment_id FROM corrections WHERE segment_id=?", "SELECT segment_id FROM memory_evidence WHERE segment_id=?", "SELECT segment_id FROM conversation_segments WHERE segment_id=?", "SELECT id FROM jobs WHERE segment_id=? AND state='leased'"] {
                if try !rows(query, [id]).isEmpty { return false }
            }
            try execute("UPDATE segments SET state='deleted',place=NULL,context_json=? WHERE id=?", [context, id])
            try execute("UPDATE jobs SET state='cancelled',lease_token=NULL,lease_until_ms=NULL WHERE segment_id=?", [id])
            try execute("INSERT INTO coverage VALUES (?,?,?,?,?)", [UUID().uuidString, row["started_ms"], row["ended_ms"], row["source"], "silent_audio_discarded"])
            return true
        }
        guard accepted else { return false }
        try removeAudioFiles(id: id, url: url)
        try execute("UPDATE segments SET context_json=json_set(context_json,'$.cleanup_pending',json('false')) WHERE id=? AND state='deleted'", [id])
        return true
    }

    /// A process exit or filesystem error after the tombstone cannot resurrect
    /// silence from its PCM journal; retry physical cleanup on the next scan.
    func resumeSilenceCleanup() throws {
        for row in try rows("SELECT id,relative_path FROM segments WHERE state='deleted' AND json_extract(context_json,'$.silence_discarded')=1 AND json_extract(context_json,'$.cleanup_pending')=1") {
            guard let id = row["id"], UUID(uuidString: id) != nil, let relative = row["relative_path"] else { continue }
            let url = root.appendingPathComponent(relative).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/Audio/") else { continue }
            try removeAudioFiles(id: id, url: url)
            try execute("UPDATE segments SET context_json=json_set(context_json,'$.cleanup_pending',json('false')) WHERE id=? AND state='deleted'", [id])
        }
    }

    private func removeAudioFiles(id: String, url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        if !id.contains("/") {
            for suffix in [".pcm",".pcm.json",".partial.m4a"] {
                let temporary=url.deletingLastPathComponent().appendingPathComponent(id+suffix)
                if FileManager.default.fileExists(atPath:temporary.path) {try FileManager.default.removeItem(at:temporary)}
            }
        }
    }

    public func verifiedAudioURL(_ id: String) throws -> URL {
        guard let row=try rows("SELECT relative_path,sha256 FROM segments WHERE id=? AND state='sealed'",[id]).first,
              let relative=row["relative_path"],let expected=row["sha256"] else { throw CaptureFailure.message("音频尚未封口或已删除") }
        let url=root.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/Audio/") else { throw CaptureFailure.message("音频路径无效") }
        let hash=SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x",$0) }.joined()
        guard hash == expected else { throw CaptureFailure.message("原音内容已改变，拒绝使用陈旧证据") }
        return url
    }

    public static func ms(_ date: Date) -> String { String(Int64((date.timeIntervalSince1970 * 1000).rounded())) }
    public static var now: String { ms(Date()) }
}
