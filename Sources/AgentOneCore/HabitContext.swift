import Foundation

public enum HabitContextKind: String, Codable, Hashable, Sendable {
    case readingRhythm
    case activityRhythm
}

/// A user-visible projection over immutable diary evidence. It is intentionally
/// derived rather than silently rewriting a profile: new sessions can strengthen
/// or contradict the pattern while the original observations remain intact.
public struct HabitContext: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var kind: HabitContextKind
    public var title: String
    public var summary: String
    public var supportingSessionCount: Int
    public var confidence: Double
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var typicalDuration: TimeInterval
    public var typicalApplications: [String]
    public var evidenceEntryIDs: [UUID]

    public init(
        id: String,
        kind: HabitContextKind,
        title: String,
        summary: String,
        supportingSessionCount: Int,
        confidence: Double,
        firstObservedAt: Date,
        lastObservedAt: Date,
        typicalDuration: TimeInterval,
        typicalApplications: [String],
        evidenceEntryIDs: [UUID]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.supportingSessionCount = supportingSessionCount
        self.confidence = min(max(confidence, 0), 1)
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.typicalDuration = max(0, typicalDuration)
        self.typicalApplications = typicalApplications
        self.evidenceEntryIDs = evidenceEntryIDs
    }
}

public struct HabitContextExtractor: Sendable {
    public init() {}

    public func extract(from entries: [DiaryEntry]) -> [HabitContext] {
        var sessions: [(entryID: UUID, session: ActivitySessionSummary)] = entries.compactMap { entry in
            guard case .activity(let record) = entry.payload,
                  let session = record.session,
                  session.isDiaryWorthy,
                  !session.context.isSensitive,
                  !session.context.isAgentOneInternalContext,
                  !session.context.isSystemNoiseContext else {
                return nil
            }
            return (entry.id, session)
        }
        let legacy = LegacySemanticActivityProjection.build(from: entries)
        sessions.append(contentsOf: legacy.sessionsByFirstEntryID.values.map {
            (entryID: $0.sourceEntryID, session: $0.session)
        })
        sessions.sort { $0.session.startedAt < $1.session.startedAt }
        guard !sessions.isEmpty else { return [] }

        var contexts: [HabitContext] = []
        let readings = sessions.filter { $0.session.kind == .reading }
        if !readings.isEmpty {
            contexts.append(makeReadingRhythm(from: readings))
        }

        for kind in [ContinuousActivityKind.composing, .researching, .communicating, .watching] {
            let matching = sessions.filter { $0.session.kind == kind }
            guard !matching.isEmpty else { continue }
            contexts.append(makeActivityRhythm(kind: kind, sessions: matching))
        }
        return contexts
    }

    private func makeReadingRhythm(
        from readings: [(entryID: UUID, session: ActivitySessionSummary)]
    ) -> HabitContext {
        let durations = readings.map { $0.session.duration }.sorted()
        let median = durations[durations.count / 2]
        let applications = Dictionary(grouping: readings.compactMap { $0.session.context.applicationName }, by: { $0 })
            .sorted { lhs, rhs in
                if lhs.value.count == rhs.value.count { return lhs.key < rhs.key }
                return lhs.value.count > rhs.value.count
            }
            .map(\.key)
        let count = readings.count
        let confidence = min(0.95, 0.28 + Double(count) * 0.14)
        let appText = applications.prefix(2).joined(separator: "、")
        let durationText = Self.durationText(median)
        let evidenceText = count == 1 ? "我刚开始学习这个节奏，还不会把一次经历当成定论。" : "这个模式已在 \(count) 段独立阅读中重复出现。"
        let locationText = appText.isEmpty ? "阅读页面" : appText

        return HabitContext(
            id: "reading-rhythm",
            kind: .readingRhythm,
            title: "连续滚动通常代表你正在阅读",
            summary: "在 \(locationText) 中，零散滚轮信号会组成持续阅读段，典型时长约 \(durationText)。\(evidenceText)",
            supportingSessionCount: count,
            confidence: confidence,
            firstObservedAt: readings.map { $0.session.startedAt }.min() ?? Date(),
            lastObservedAt: readings.map { $0.session.lastObservedAt }.max() ?? Date(),
            typicalDuration: median,
            typicalApplications: applications,
            evidenceEntryIDs: readings.map(\.entryID)
        )
    }

    private func makeActivityRhythm(
        kind: ContinuousActivityKind,
        sessions: [(entryID: UUID, session: ActivitySessionSummary)]
    ) -> HabitContext {
        let durations = sessions.map { $0.session.duration }.sorted()
        let median = durations[durations.count / 2]
        let applications = Dictionary(grouping: sessions.compactMap { $0.session.context.applicationName }, by: { $0 })
            .sorted { lhs, rhs in
                if lhs.value.count == rhs.value.count { return lhs.key < rhs.key }
                return lhs.value.count > rhs.value.count
            }
            .map(\.key)
        let count = sessions.count
        let confidence = min(0.95, 0.24 + Double(count) * 0.12)
        let appText = applications.prefix(2).joined(separator: "、")
        let place = appText.isEmpty ? "这些场景" : appText
        let labels: (title: String, verb: String)
        switch kind {
        case .composing:
            labels = ("你的连续写作节奏", "写作")
        case .researching:
            labels = ("你查资料时的探索节奏", "查资料")
        case .communicating:
            labels = ("你的沟通节奏", "沟通")
        case .watching:
            labels = ("你的观看节奏", "观看")
        case .reading, .navigating, .idle:
            labels = ("你的活动节奏", "活动")
        }
        let evidenceText = count == 1
            ? "这是我第一次观察到，还会继续校准。"
            : "这个模式已在 \(count) 个独立活动段中出现。"
        return HabitContext(
            id: "activity-rhythm-\(kind.rawValue)",
            kind: .activityRhythm,
            title: labels.title,
            summary: "你通常会在 \(place) 连续\(labels.verb)约 \(Self.durationText(median))。\(evidenceText)",
            supportingSessionCount: count,
            confidence: confidence,
            firstObservedAt: sessions.map { $0.session.startedAt }.min() ?? Date(),
            lastObservedAt: sessions.map { $0.session.lastObservedAt }.max() ?? Date(),
            typicalDuration: median,
            typicalApplications: applications,
            evidenceEntryIDs: sessions.map(\.entryID)
        )
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        if duration < 60 { return "不到 1 分钟" }
        return "\(max(1, Int((duration / 60).rounded()))) 分钟"
    }
}
