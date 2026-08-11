import XCTest
@testable import AgentOneCore

final class ReplayProjectionTests: XCTestCase {
    func testContextLogAndAgentJournalAreDisjointProjections() {
        let timestamp = Date(timeIntervalSince1970: 1_722_787_200)
        let digest = DailyContextDigest(
            day: "2026-08-10",
            generatedAt: timestamp,
            headline: "把今天串成一条线",
            overview: "今天围绕 Context 日志和 Agent 日记完成了清晰分工。",
            highlights: ["回放保留事实", "日记负责提炼"],
            agentNote: "原始经历和我的理解，应该各自待在合适的位置。",
            mood: "thoughtful",
            sourceContextCount: 3,
            evidenceCount: 1,
            personalizedMemoryCount: 2
        )

        let activity = makeMoment(kind: .activity, lane: .userActivity, timestamp: timestamp)
        let evidence = makeMoment(kind: .evidence, lane: .userActivity, timestamp: timestamp.addingTimeInterval(1))
        let thought = makeMoment(kind: .thought, lane: .agentMind, timestamp: timestamp.addingTimeInterval(2))
        let skill = makeMoment(kind: .learnedSkill, lane: .agentMind, timestamp: timestamp.addingTimeInterval(3))
        let summary = ReplayMoment(
            timestamp: timestamp.addingTimeInterval(4),
            lane: .relationship,
            kind: .summary,
            title: digest.headline,
            sourceEntryID: UUID(),
            dailyDigest: digest
        )
        let replay = SemanticReplay(
            day: digest.day,
            moments: [activity, evidence, thought, skill, summary],
            evidence: []
        )

        XCTAssertEqual(replay.contextLogMoments.map(\.id), [activity.id, evidence.id])
        XCTAssertEqual(replay.agentJournalMoments.map(\.id), [thought.id])
        XCTAssertEqual(replay.latestDailyContextDigest, digest)
        XCTAssertTrue(Set(replay.contextLogMoments.map(\.id)).isDisjoint(
            with: Set(replay.agentJournalMoments.map(\.id))
        ))
        XCTAssertFalse(replay.contextLogMoments.contains { $0.kind == .summary || $0.kind == .thought })
        XCTAssertFalse(replay.agentJournalMoments.contains { $0.kind != .thought })
    }

    func testAllFactualContextKindsRemainInReplay() {
        let timestamp = Date(timeIntervalSince1970: 1_722_787_200)
        let kinds: [ReplayMomentKind] = [
            .activity, .intent, .drift, .reminder, .returned, .correction, .evidence
        ]
        let moments = kinds.enumerated().map { index, kind in
            makeMoment(
                kind: kind,
                lane: kind == .reminder ? .relationship : .userActivity,
                timestamp: timestamp.addingTimeInterval(Double(index))
            )
        }
        let replay = SemanticReplay(day: "2026-08-10", moments: moments, evidence: [])

        XCTAssertEqual(replay.contextLogMoments.map(\.kind), kinds)
        XCTAssertTrue(replay.agentJournalMoments.isEmpty)
    }

    private func makeMoment(
        kind: ReplayMomentKind,
        lane: ReplayLane,
        timestamp: Date
    ) -> ReplayMoment {
        ReplayMoment(
            timestamp: timestamp,
            lane: lane,
            kind: kind,
            title: kind.rawValue,
            sourceEntryID: UUID()
        )
    }
}
