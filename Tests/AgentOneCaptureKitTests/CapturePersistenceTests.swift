import AgentOneCaptureKit
import Foundation
import Testing

struct CapturePersistenceTests {
    @Test func sharedSchemaIsIdenticalAndCreatesNoFakeRecordings() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let swiftSchema = try String(contentsOf: repo.appendingPathComponent("Sources/AgentOneCaptureKit/Resources/schema.sql"),encoding: .utf8)
        let mcpSchema = try String(contentsOf: repo.appendingPathComponent("plugins/agentone-memory/schema.sql"),encoding: .utf8)
        #expect(swiftSchema == mcpSchema)
        #expect(try String(contentsOf:repo.appendingPathComponent("Sources/AgentOneCaptureKit/Resources/migrate-v2.sql"),encoding:.utf8) == String(contentsOf:repo.appendingPathComponent("plugins/agentone-memory/migrate-v2.sql"),encoding:.utf8))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MemoryDatabase(root: root)
        #expect(try database.rows("SELECT * FROM segments").isEmpty)
        #expect(try database.rows("SELECT * FROM jobs").isEmpty)
    }

    @Test func transactionRollsBackAndInterruptedTailIsNotAnalyzed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MemoryDatabase(root: root)
        try database.execute("INSERT INTO segments VALUES ('tail','session','microphone',1,1,'UTC',1,1,'host_clock',48000,1,'Audio/tail.partial.m4a',NULL,'recording',NULL,'{}',1)")
        enum Rollback: Error { case intentional }
        #expect(throws: Rollback.self) {
            try database.transaction {
                try database.execute("UPDATE segments SET place='should not commit' WHERE id='tail'")
                throw Rollback.intentional
            }
        }
        #expect(try database.rows("SELECT place FROM segments WHERE id='tail'").first?["place"] == nil)
        try database.recoverInterruptedSegments()
        #expect(try database.rows("SELECT state FROM segments WHERE id='tail'").first?["state"] == "incomplete")
        #expect(try database.rows("SELECT * FROM jobs").isEmpty)
        #expect(try database.rows("SELECT reason FROM coverage").first?["reason"] == "interrupted_tail")
    }

    @Test func databaseSymlinkIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("memory.sqlite"),withDestinationURL: root.appendingPathComponent("elsewhere.sqlite"))
        #expect(throws: CaptureFailure.self) { try MemoryDatabase(root: root) }
    }

    @Test func deletingSourceInvalidatesConsolidationsWithoutResurrectingOldFacts() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database=try MemoryDatabase(root: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Audio"),withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: root.appendingPathComponent("Audio/source.m4a"))
        try database.execute("INSERT INTO segments VALUES ('source','session','microphone',1,1000,'UTC',1,1,'host_clock',48000,1,'Audio/source.m4a','hash','sealed',NULL,'{}',1)")
        try database.execute("INSERT INTO memories VALUES ('old','decision','old','old','[]','supported_summary',1,NULL,'[]','superseded','old-digest',1)")
        try database.execute("INSERT INTO memories VALUES ('new','decision','private title','private fact','[\"private entity\"]','supported_summary',2,NULL,'[\"old\"]','active','new-digest',2)")
        try database.execute("INSERT INTO memory_evidence VALUES ('new','source','hash',1,0,1000,'private quote')")
        try database.deleteSegment("source")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Audio/source.m4a").path))
        #expect(try database.rows("SELECT state FROM segments WHERE id='source'").first?["state"] == "deleted")
        #expect(try database.rows("SELECT status FROM memories WHERE id='old'").first?["status"] == "superseded")
        let new=try database.rows("SELECT * FROM memories WHERE id='new'").first!
        #expect(new["status"] == "invalidated")
        #expect(new["text"] == "")
        #expect(new["entities_json"] == "[]")
        #expect(try database.rows("SELECT * FROM memory_evidence").isEmpty)
    }
}
