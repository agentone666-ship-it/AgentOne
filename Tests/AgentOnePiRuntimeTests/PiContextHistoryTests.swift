import Foundation
import Testing
import AgentOneCore
import AgentOnePiRuntime

struct PiContextHistoryTests {
    private func activity(_ text: String = "阅读帖子") -> DiaryEntry {
        DiaryEntry(timestamp: Date(timeIntervalSince1970: 200), payload: .activity(ActivityDiaryRecord(
            event: ActivityEvent(timestamp: Date(timeIntervalSince1970: 100), signal: .contentChanged,
                context: ActivityContext(applicationName: "Chrome", url: URL(string: "https://example.com/post/1"),
                    contentSummary: text, screenshotResourcePath: "/private/screenshot.png")), narrative: "浏览帖子")))
    }

    @Test func originalTimeAndEvidenceSurviveRestart() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let diary = try AppendOnlyDiary(homeURL: home)
        let value = activity()
        _ = try await diary.append(value.payload, at: value.timestamp)
        let restored = try AppendOnlyDiary(homeURL: home)
        let records = PiContextHistory.records(from: await restored.allEntries())
        #expect(records.count == 1)
        #expect(records.first?.timestamp == "1970-01-01T00:01:40Z")
        #expect(records.first?.context.url == "https://example.com/post/1")
        let json = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        #expect(!json.contains("screenshot.png"))
    }

    @Test func restoresMultipleMonthsWithoutRecentHistoryLimit() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let diary = try AppendOnlyDiary(homeURL: home)
        let dates = ["2026-07-21T01:00:00Z", "2026-08-13T01:00:00Z", "2026-09-09T01:00:00Z"]
            + Array(repeating: "2026-09-29T01:00:00Z", count: 50)
        for date in dates {
            let time = ISO8601DateFormatter().date(from: date)!
            _ = try await diary.append(.activity(.init(event: .init(timestamp: time,
                signal: .contentChanged, context: .init(applicationName: "Chrome")), narrative: "浏览网页")), at: time)
        }
        let restored = try AppendOnlyDiary(homeURL: home)
        let records = PiContextHistory.records(from: await restored.allEntries())
        #expect(records.count == 53)
        #expect(Set(records.map { String($0.timestamp.prefix(7)) }) == ["2026-07", "2026-08", "2026-09"])
    }

    @Test func hiddenActivityDoesNotLeakThroughEnrichment() {
        let entry = activity()
        guard case .activity(let record) = entry.payload else { return }
        let enriched = DiaryEntry(timestamp: Date(timeIntervalSince1970: 210), payload: .contextEnrichment(.init(
            targetEventID: record.event.id, targetActivityEntryID: entry.id, activityTitle: "标题",
            summary: "补充解释", context: record.event.context)))
        let hidden = DiaryEntry(timestamp: Date(timeIntervalSince1970: 220), payload: .visibilityChanged(.init(targetEntryID: entry.id, isHidden: true)))
        #expect(PiContextHistory.records(from: [entry, enriched, hidden]).isEmpty)
    }

    @Test func correctionsAndLatestVisibleEnrichmentAreSearchable() {
        let entry = activity()
        guard case .activity(let record) = entry.payload else { return }
        var context = record.event.context
        context.contentSummary = "解释注意力"
        let enriched = DiaryEntry(timestamp: Date(timeIntervalSince1970: 210), payload: .contextEnrichment(.init(
            targetEventID: record.event.id, targetActivityEntryID: entry.id, activityTitle: "标题",
            summary: "补充解释", context: context, tags: ["研究"])))
        let correction = DiaryEntry(timestamp: Date(timeIntervalSince1970: 220), payload: .correction(.init(targetEntryID: entry.id, correction: "实际在做调研")))
        let result = PiContextHistory.records(from: [entry, enriched, correction])
        #expect(result.count == 1)
        #expect(result[0].context.contentSummary?.contains("实际在做调研") == true)
        #expect(result[0].context.semanticTags.contains("研究"))
        #expect(result[0].eventID == record.event.id.uuidString)
    }

    @Test func secretsAreExcludedBeforeSerialization() {
        #expect(PiContextHistory.records(from: [activity("password: example-secret")]).isEmpty)
    }
}
