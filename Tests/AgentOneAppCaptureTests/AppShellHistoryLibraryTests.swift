import AgentOneCore
import Foundation
import Testing
@testable import AgentOneApp

@Suite
@MainActor
struct AppShellHistoryLibraryTests {
    @Test
    func completeHistoryKeepsEveryDayAndDoesNotTruncateBusyDays() {
        let oldDay = makeReplay(day: "2026-07-21", contextCount: 240, journalCount: 125)
        let middleDay = makeReplay(day: "2026-08-13", contextCount: 402, journalCount: 226)
        let recentDay = makeReplay(day: "2026-09-22", contextCount: 34, journalCount: 1)
        let model = AgentOneShellViewModel()

        model.consumePersistedLibrary([recentDay, oldDay, middleDay])

        #expect(model.replayDays.map(\.day) == ["2026-09-22", "2026-08-13", "2026-07-21"])
        #expect(model.totalRecordedDays == 3)
        #expect(model.totalRecordedContextCount == 676)

        model.selectReplayDay("2026-08-13")
        #expect(model.replayMoments.count == 402)
        #expect(model.agentJournalEntries.count == 226)

        model.selectReplayDay("2026-07-21")
        #expect(model.replayMoments.count == 240)
        #expect(model.agentJournalEntries.count == 125)
    }

    @Test
    func liveTodayUpdatesDoNotReplaceTheHistoricalDayBeingViewed() {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let oldDay = formatter.string(
            from: calendar.date(byAdding: .day, value: -10, to: Date())!
        )
        let historical = makeReplay(day: oldDay, contextCount: 240, journalCount: 125)
        let initialToday = makeReplay(day: today, contextCount: 34, journalCount: 1)
        let updatedToday = makeReplay(day: today, contextCount: 99, journalCount: 2)
        let model = AgentOneShellViewModel()
        model.consumePersistedLibrary([historical, initialToday])
        model.selectReplayDay(oldDay)

        let event = ActivityEvent(
            signal: .contentChanged,
            context: ActivityContext(applicationName: "Test")
        )
        let output = ContextEngineOutput(
            eventID: event.id,
            activeIntent: nil,
            relevance: nil
        )
        model.consumeRuntime(event: event, output: output, replay: updatedToday)

        #expect(model.selectedReplayDay == oldDay)
        #expect(model.replayMoments.count == 240)
        #expect(model.agentJournalEntries.count == 125)
        #expect(model.replayDays.first(where: { $0.day == today })?.contextCount == 99)

        model.selectReplayDay(today)
        #expect(model.replayMoments.count == 99)
        #expect(model.agentJournalEntries.count == 2)
    }

    private func makeReplay(
        day: String,
        contextCount: Int,
        journalCount: Int
    ) -> SemanticReplay {
        let calendar = Calendar(identifier: .gregorian)
        let base = ISO8601DateFormatter().date(from: "\(day)T00:00:00Z")!
        var moments: [AgentOneCore.ReplayMoment] = (0 ..< contextCount).map { index in
            let id = UUID()
            return AgentOneCore.ReplayMoment(
                id: id,
                timestamp: calendar.date(byAdding: .second, value: index, to: base)!,
                lane: .userActivity,
                kind: .activity,
                title: "Context \(index)",
                sourceEntryID: id
            )
        }
        moments.append(contentsOf: (0 ..< journalCount).map { index in
            let id = UUID()
            return AgentOneCore.ReplayMoment(
                id: id,
                timestamp: calendar.date(byAdding: .minute, value: index, to: base)!,
                lane: .agentMind,
                kind: .thought,
                title: "Thought \(index)",
                sourceEntryID: id,
                thoughtDisposition: .heldBack,
                thoughtUncertainty: 0.2
            )
        })
        return SemanticReplay(day: day, moments: moments, evidence: [])
    }
}
