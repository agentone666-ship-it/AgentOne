import AgentOneCore
import Foundation
import Testing
@testable import AgentOneCaptureKit

struct ContextEventTests {
    @Test func legacyImportFoldsEnrichmentCorrectionsAndHideWithoutRewritingSource() async throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:home)}
        let database=try MemoryDatabase(root:home.appendingPathComponent("Memory"))
        let diary=try AppendOnlyDiary(homeURL:home.appendingPathComponent("Diary"))
        let timestamp=Date(timeIntervalSince1970:1_760_000_000)
        let event=ActivityEvent(timestamp:timestamp,signal:.applicationActivated(bundleIdentifier:"test.browser"),context:ActivityContext(applicationName:"浏览器",windowTitle:"压测方案",url:URL(string:"https://example.test/benchmark"),contentSummary:"原始页面"))
        let entry=try await diary.append(.activity(ActivityDiaryRecord(event:event,narrative:"阅读青禾项目")),at:timestamp)
        let enrichment=ActivityContextEnrichment(targetEventID:event.id,targetActivityEntryID:entry.id,activityTitle:"青禾压测",summary:"性能指标",context:event.context,tags:[])
        _=try await diary.append(.contextEnrichment(enrichment),at:timestamp.addingTimeInterval(1))
        _=try await diary.appendCorrection(to:entry.id,text:"不是北区，是南区",at:timestamp.addingTimeInterval(2))
        let daily=home.appendingPathComponent("Diary/Daily")
        let file=try #require(FileManager.default.contentsOfDirectory(at:daily,includingPropertiesForKeys:nil).first)
        let original=try Data(contentsOf:file)
        let importer=LegacyEventImporter(database:database)
        #expect(try importer.sync(diaryRoot:home.appendingPathComponent("Diary")).imported==1)
        let row=try #require(database.rows("SELECT * FROM context_events WHERE hidden=0").first)
        #expect(row["title"]=="青禾压测")
        #expect(row["text"]?.contains("南区")==true)
        #expect(row["started_ms"]==MemoryDatabase.ms(timestamp))
        #expect(row["source_sha256"]?.count==64)
        #expect(try Data(contentsOf:file)==original)
        _=try await diary.setHidden(true,entryID:entry.id,at:timestamp.addingTimeInterval(3))
        #expect(try importer.sync(diaryRoot:home.appendingPathComponent("Diary")).imported==0)
        #expect(try database.rows("SELECT * FROM context_events WHERE hidden=0").isEmpty)
        #expect(try database.rows("SELECT text FROM context_events").first?["text"]=="")
    }
    @Test func sensitiveLegacyAndCredentialShapedEventsStayOutOfSharedIndex() async throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:home)}
        let database=try MemoryDatabase(root:home.appendingPathComponent("Memory"))
        let diary=try AppendOnlyDiary(homeURL:home.appendingPathComponent("Diary"))
        let event=ActivityEvent(signal:.contentChanged,context:ActivityContext(windowTitle:"秘密",isSensitive:true))
        _=try await diary.append(.activity(ActivityDiaryRecord(event:event,narrative:"不应导出")))
        #expect(try LegacyEventImporter(database:database).sync(diaryRoot:home.appendingPathComponent("Diary")).imported==0)
        try database.saveEvent(ContextEventRecord(started:Date(),kind:"window",title:"Password Manager",text:"test"))
        try database.saveEvent(ContextEventRecord(started:Date(),kind:"window",text:"api_key="+String(repeating:"A",count:20)))
        #expect(try database.rows("SELECT * FROM context_events").isEmpty)
    }
    @Test func eventContentHashTracksChangesAndUpsertIsIdempotent() throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:home)}
        let database=try MemoryDatabase(root:home)
        var record=ContextEventRecord(started:Date(),kind:"window_context",application:"浏览器",title:"文档",text:"页面内容",place:"工位")
        try database.saveEvent(record);try database.saveEvent(record)
        let first=try #require(database.rows("SELECT * FROM context_events").first)
        #expect(try database.rows("SELECT * FROM context_events").count==1)
        record.ended=record.started.addingTimeInterval(10);try database.saveEvent(record)
        #expect(try database.rows("SELECT source_sha256 FROM context_events").first?["source_sha256"] != first["source_sha256"])
    }
}
