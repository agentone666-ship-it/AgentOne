import Foundation

public enum ReplayLane: String, Codable, Hashable, Sendable {
    case userActivity
    case agentMind
    case relationship
}

public enum ReplayMomentKind: String, Codable, Hashable, Sendable {
    case activity
    case intent
    case drift
    case reminder
    case returned
    case thought
    case correction
    case evidence
    case learnedSkill
    case summary
}

public struct ReplayMoment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public var lane: ReplayLane
    public var kind: ReplayMomentKind
    public var title: String
    public var detail: String?
    public var sourceEntryID: UUID
    public var evidenceIDs: [UUID]
    public var isHidden: Bool
    public var thoughtDisposition: AgentThoughtDisposition?
    public var thoughtHypothesis: String?
    public var thoughtConsideredAction: String?
    public var thoughtWhy: String?
    public var thoughtUncertainty: Double?
    /// Exact text exposed by the focused editor immediately before a
    /// submit-like Return. This is linked into Agent thoughts through
    /// `AgentReflection.relatedEventIDs`, rather than inferred from the
    /// reflection prose.
    public var submittedText: String?
    public var dailyDigest: DailyContextDigest?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        lane: ReplayLane,
        kind: ReplayMomentKind,
        title: String,
        detail: String? = nil,
        sourceEntryID: UUID,
        evidenceIDs: [UUID] = [],
        isHidden: Bool = false,
        thoughtDisposition: AgentThoughtDisposition? = nil,
        thoughtHypothesis: String? = nil,
        thoughtConsideredAction: String? = nil,
        thoughtWhy: String? = nil,
        thoughtUncertainty: Double? = nil,
        submittedText: String? = nil,
        dailyDigest: DailyContextDigest? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.lane = lane
        self.kind = kind
        self.title = title
        self.detail = detail
        self.sourceEntryID = sourceEntryID
        self.evidenceIDs = evidenceIDs
        self.isHidden = isHidden
        self.thoughtDisposition = thoughtDisposition
        self.thoughtHypothesis = thoughtHypothesis
        self.thoughtConsideredAction = thoughtConsideredAction
        self.thoughtWhy = thoughtWhy
        self.thoughtUncertainty = thoughtUncertainty
        self.submittedText = submittedText
        self.dailyDigest = dailyDigest
    }
}

public struct SemanticReplay: Codable, Hashable, Sendable {
    public var day: String
    public var moments: [ReplayMoment]
    public var evidence: [KeyEvidence]

    public init(day: String, moments: [ReplayMoment], evidence: [KeyEvidence]) {
        self.day = day
        self.moments = moments
        self.evidence = evidence
    }
}

public extension ReplayMoment {
    /// A replay is the factual, inspectable Context log. Agent reflections,
    /// distilled summaries and learned skills have their own library views and
    /// must not be copied into the activity timeline.
    var belongsToContextLog: Bool {
        switch kind {
        case .activity, .intent, .drift, .reminder, .returned, .correction, .evidence:
            true
        case .thought, .learnedSkill, .summary:
            false
        }
    }

    /// The Agent journal contains LUMA's subjective reflections only. The
    /// daily Context digest is projected separately as the journal's summary.
    var belongsToAgentJournal: Bool {
        kind == .thought && lane == .agentMind
    }
}

public extension SemanticReplay {
    /// Chronological, evidence-backed events suitable for the Replay screen.
    var contextLogMoments: [ReplayMoment] {
        moments.filter(\.belongsToContextLog)
    }

    /// Subjective LUMA reflections suitable for the Agent Journal screen.
    var agentJournalMoments: [ReplayMoment] {
        moments.filter(\.belongsToAgentJournal)
    }

    /// The latest distilled summary is the journal entry for the day, not a
    /// Replay timeline event.
    var latestDailyContextDigest: DailyContextDigest? {
        moments.compactMap(\.dailyDigest).last
    }
}

public struct SemanticReplayBuilder: Sendable {
    public init() {}

    public func build(
        day: String,
        entries: [DiaryEntry],
        contextEntries: [DiaryEntry]? = nil,
        includeHidden: Bool = false
    ) -> SemanticReplay {
        let projection = DiaryProjection(entries: entries)
        let source = includeHidden ? entries : projection.visibleEntries
        let intentCatalogEntries = contextEntries ?? entries
        var moments: [ReplayMoment] = []
        var evidence: [KeyEvidence] = []
        var seenSkillSignatures: Set<String> = []
        let legacyActivity = LegacySemanticActivityProjection.build(from: source)
        let contextEnrichments = ContextEnrichmentProjection.build(from: source)
        let focusEpisodes = FocusEpisodeProjection.build(
            from: source,
            intentCatalogEntries: intentCatalogEntries,
            hiddenEntryIDs: projection.hiddenEntryIDs
        )
        let embeddedEvidenceIDs = Set(source.flatMap { entry -> [UUID] in
            guard case .activity(let record) = entry.payload else { return [] }
            return record.evidenceIDs
        })
        let activityLinksByEventID = Self.makeActivityLinksByEventID(from: source)

        for entry in source.sorted(by: { $0.timestamp < $1.timestamp }) {
            let hidden = projection.hiddenEntryIDs.contains(entry.id)
            if let projectedFocusMoment = focusEpisodes.momentsByEntryID[entry.id] {
                moments.append(projectedFocusMoment)
                continue
            }
            if focusEpisodes.suppressedEntryIDs.contains(entry.id) {
                continue
            }
            switch entry.payload {
            case .activity(let record):
                // Pre-fix builds captured AgentOne's own Replay/Diary UI. Those
                // entries are immutable historical artifacts, not user context,
                // so omit them from the read model without rewriting the diary.
                if record.event.context.isAgentOneInternalContext || record.event.context.isSystemNoiseContext {
                    continue
                }
                if record.event.context.isSensitive {
                    continue
                }
                if let session = record.session, !session.isDiaryWorthy {
                    continue
                }
                if legacyActivity.suppressedEntryIDs.contains(entry.id) {
                    continue
                }
                let projected = legacyActivity.sessionsByFirstEntryID[entry.id]
                var replayRecord = projected?.representativeRecord ?? record
                if let enrichment = contextEnrichments.enrichment(
                    forEntryID: entry.id,
                    record: replayRecord
                ) {
                    replayRecord.event.context = replayRecord.event.context
                        .mergingRicherValues(from: enrichment.context)
                    replayRecord.event.context.contentSummary = enrichment.summary
                    if !enrichment.activityTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        replayRecord.narrative = enrichment.activityTitle
                    }
                    if var session = replayRecord.session {
                        session.context = session.context.mergingRicherValues(from: enrichment.context)
                        session.context.contentSummary = enrichment.summary
                        replayRecord.session = session
                    }
                }
                let replayTimestamp = replayRecord.session?.startedAt ?? entry.timestamp
                let replayDetail: String?
                if let session = replayRecord.session {
                    let concreteSummary = session.context.contentSummary?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let duration = max(0, Int(session.duration.rounded()))
                    let durationText = duration < 60
                        ? "一个连续活动段"
                        : "约 \(max(1, Int((session.duration / 60).rounded()))) 分钟"
                    let detailParts: [String?] = [
                        concreteSummary,
                        session.context.selectedText,
                        session.context.windowTitle,
                        session.context.url?.absoluteString,
                        session.context.documentPath,
                        session.context.applicationName,
                        durationText
                    ]
                    replayDetail = detailParts
                        .compactMap { value -> String? in
                            guard let value, !value.isEmpty else { return nil }
                            return value
                        }
                        .reduce(into: [String]()) { result, value in
                            if !result.contains(value) { result.append(value) }
                        }
                        .joined(separator: " · ")
                } else {
                    let context = replayRecord.event.context
                    replayDetail = [
                        context.contentSummary,
                        context.selectedText,
                        context.windowTitle,
                        context.url?.absoluteString,
                        context.documentPath,
                        context.applicationName
                    ]
                    .compactMap { value -> String? in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    }
                    .reduce(into: [String]()) { result, value in
                        if !result.contains(value) { result.append(value) }
                    }
                    .joined(separator: " · ")
                }
                moments.append(ReplayMoment(
                    timestamp: replayTimestamp,
                    lane: .userActivity,
                    kind: .activity,
                    title: replayRecord.narrative,
                    detail: replayDetail,
                    sourceEntryID: entry.id,
                    evidenceIDs: replayRecord.evidenceIDs,
                    isHidden: hidden,
                    submittedText: Self.nonEmpty(
                        replayRecord.event.context.submittedText
                            ?? replayRecord.session?.context.submittedText
                    )
                ))
            case .contextEnrichment:
                // This is an audit fact, not a second user activity. It is
                // projected onto its target activity above.
                continue
            case .intentStarted(let intent):
                moments.append(ReplayMoment(timestamp: entry.timestamp, lane: .userActivity, kind: .intent, title: "Started: \(intent.title)", detail: intent.summary, sourceEntryID: entry.id, isHidden: hidden))
            case .intentConfirmed:
                moments.append(ReplayMoment(timestamp: entry.timestamp, lane: .relationship, kind: .intent, title: "You and AgentOne agreed on the current intent", sourceEntryID: entry.id, isHidden: hidden))
            case .driftStarted:
                moments.append(ReplayMoment(timestamp: entry.timestamp, lane: .userActivity, kind: .drift, title: "Attention began to drift", sourceEntryID: entry.id, isHidden: hidden))
            case .reminder(let prompt):
                moments.append(ReplayMoment(timestamp: entry.timestamp, lane: .relationship, kind: .reminder, title: prompt.replayTitle, sourceEntryID: entry.id, isHidden: hidden))
            case .returnedToIntent:
                moments.append(ReplayMoment(timestamp: entry.timestamp, lane: .relationship, kind: .returned, title: "Returned to the earlier intention", sourceEntryID: entry.id, isHidden: hidden))
            case .feedback:
                continue
            case .correction(let correction):
                moments.append(ReplayMoment(timestamp: entry.timestamp, lane: .relationship, kind: .correction, title: "You corrected AgentOne", detail: correction.correction, sourceEntryID: entry.id, isHidden: hidden))
            case .visibilityChanged:
                continue
            case .agentReflection(let reflection):
                if reflection.isMechanicalWakeNoise {
                    continue
                }
                let detail = [reflection.hypothesis, reflection.consideredAction, reflection.why].compactMap { $0 }.joined(separator: " · ")
                let linkedActivity = reflection.relatedEventIDs.reduce(
                    into: ReflectionActivityLink()
                ) { result, eventID in
                    guard let link = activityLinksByEventID[eventID] else { return }
                    if result.submittedText == nil {
                        result.submittedText = link.submittedText
                    }
                    for evidenceID in link.evidenceIDs where !result.evidenceIDs.contains(evidenceID) {
                        result.evidenceIDs.append(evidenceID)
                    }
                }
                moments.append(ReplayMoment(
                    timestamp: entry.timestamp,
                    lane: .agentMind,
                    kind: .thought,
                    title: reflection.observation,
                    detail: detail.isEmpty ? nil : detail,
                    sourceEntryID: entry.id,
                    evidenceIDs: linkedActivity.evidenceIDs,
                    isHidden: hidden,
                    thoughtDisposition: reflection.disposition,
                    thoughtHypothesis: reflection.hypothesis,
                    thoughtConsideredAction: reflection.consideredAction,
                    thoughtWhy: reflection.why,
                    thoughtUncertainty: reflection.uncertainty,
                    submittedText: linkedActivity.submittedText
                ))
            case .evidence(let item):
                evidence.append(item)
                if !embeddedEvidenceIDs.contains(item.id) {
                    moments.append(ReplayMoment(timestamp: entry.timestamp, lane: .userActivity, kind: .evidence, title: item.title, detail: item.summary, sourceEntryID: entry.id, evidenceIDs: [item.id], isHidden: hidden))
                }
            case .skillLearned(let skill):
                let signature = "\(skill.domain.rawValue)|\(skill.name.lowercased())|\(skill.guidance.lowercased())"
                guard seenSkillSignatures.insert(signature).inserted else { continue }
                moments.append(ReplayMoment(timestamp: entry.timestamp, lane: .agentMind, kind: .learnedSkill, title: "Learned: \(skill.name)", detail: skill.guidance, sourceEntryID: entry.id, isHidden: hidden))
            case .daySummary(let summary):
                moments.append(ReplayMoment(timestamp: entry.timestamp, lane: .relationship, kind: .summary, title: "Day in review", detail: summary, sourceEntryID: entry.id, isHidden: hidden))
            case .dailyContextDigest(let digest):
                moments.append(ReplayMoment(
                    timestamp: entry.timestamp,
                    lane: .relationship,
                    kind: .summary,
                    title: digest.headline,
                    detail: digest.overview,
                    sourceEntryID: entry.id,
                    isHidden: hidden,
                    dailyDigest: digest
                ))
            }
        }

        moments.sort { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.sourceEntryID.uuidString < rhs.sourceEntryID.uuidString
            }
            return lhs.timestamp < rhs.timestamp
        }
        return SemanticReplay(day: day, moments: moments, evidence: evidence)
    }

    private static func makeActivityLinksByEventID(
        from entries: [DiaryEntry]
    ) -> [UUID: ReflectionActivityLink] {
        var result: [UUID: ReflectionActivityLink] = [:]

        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard case .activity(let record) = entry.payload else { continue }
            guard !record.event.context.isSensitive,
                  record.session?.context.isSensitive != true else {
                continue
            }

            let submittedText = nonEmpty(
                record.event.context.submittedText
                    ?? record.session?.context.submittedText
            )
            let eventIDs = Set(
                [record.event.id] + (record.session?.eventIDs ?? [])
            )

            for eventID in eventIDs {
                var link = result[eventID] ?? ReflectionActivityLink()
                if link.submittedText == nil {
                    link.submittedText = submittedText
                }
                for evidenceID in record.evidenceIDs where !link.evidenceIDs.contains(evidenceID) {
                    link.evidenceIDs.append(evidenceID)
                }
                result[eventID] = link
            }
        }

        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct ReflectionActivityLink {
    var submittedText: String?
    var evidenceIDs: [UUID] = []
}

private struct ContextEnrichmentProjection: Sendable {
    var latestByActivityEntryID: [UUID: ActivityContextEnrichment]
    var latestByEventID: [UUID: ActivityContextEnrichment]

    static func build(from entries: [DiaryEntry]) -> Self {
        var byActivity: [UUID: ActivityContextEnrichment] = [:]
        var byEvent: [UUID: ActivityContextEnrichment] = [:]
        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard case .contextEnrichment(let enrichment) = entry.payload else { continue }
            if let targetActivityEntryID = enrichment.targetActivityEntryID {
                byActivity[targetActivityEntryID] = enrichment
            }
            byEvent[enrichment.targetEventID] = enrichment
        }
        return Self(latestByActivityEntryID: byActivity, latestByEventID: byEvent)
    }

    func enrichment(forEntryID entryID: UUID, record: ActivityDiaryRecord) -> ActivityContextEnrichment? {
        if let direct = latestByActivityEntryID[entryID] { return direct }
        if let directEvent = latestByEventID[record.event.id] { return directEvent }
        guard let session = record.session else { return nil }
        return session.eventIDs.reversed().compactMap { latestByEventID[$0] }.first
    }
}

/// Projects intent/drift classifier state into human-scale focus episodes.
/// Old Markdown remains append-only: inferred intent guesses, auto-confirmation
/// rows, and brief relevance flicker are hidden only in the Replay read model.
private struct FocusEpisodeProjection: Sendable {
    struct PendingDrift: Sendable {
        var entry: DiaryEntry
        var drift: DriftEpisode
        var hadReminder: Bool
        var isPlaceholderIntent: Bool
    }

    struct Episode: Sendable {
        var intentSessionID: UUID
        var firstEntry: DiaryEntry
        var beganAt: Date
        var returnedEntry: DiaryEntry?
        var endedAt: Date?
        var observedUntil: Date
        var hadReminder: Bool
        var isPlaceholderIntent: Bool
    }

    var momentsByEntryID: [UUID: ReplayMoment]
    var suppressedEntryIDs: Set<UUID>

    static func build(
        from entries: [DiaryEntry],
        intentCatalogEntries: [DiaryEntry],
        hiddenEntryIDs: Set<UUID>,
        minimumDuration: TimeInterval = 30,
        reentryDebounceInterval: TimeInterval = 30
    ) -> Self {
        let ordered = entries.sorted { $0.timestamp < $1.timestamp }
        let inferredIntentIDs = Set(intentCatalogEntries.compactMap { entry -> UUID? in
            guard case .intentStarted(let intent) = entry.payload,
                  intent.origin == .inferred else { return nil }
            return intent.id
        })
        let placeholderIntentIDs = Set(intentCatalogEntries.compactMap { entry -> UUID? in
            guard case .intentStarted(let intent) = entry.payload,
                  intent.isInferredPlaceholder else { return nil }
            return intent.id
        })
        var momentsByEntryID: [UUID: ReplayMoment] = [:]
        var suppressedEntryIDs: Set<UUID> = []
        var pendingByIntentID: [UUID: PendingDrift] = [:]
        var episodes: [Episode] = []

        func durationText(_ duration: TimeInterval) -> String {
            let seconds = max(0, Int(duration.rounded()))
            if seconds < 60 { return "约 \(seconds) 秒" }
            return "约 \(max(1, Int((duration / 60).rounded()))) 分钟"
        }

        for entry in ordered {
            switch entry.payload {
            case .intentStarted(let intent) where intent.origin == .inferred:
                suppressedEntryIDs.insert(entry.id)

            case .intentConfirmed(let intentSessionID) where inferredIntentIDs.contains(intentSessionID):
                suppressedEntryIDs.insert(entry.id)

            case .driftStarted(let drift):
                // Some older builds appended the same classifier transition
                // repeatedly while an episode was already open. Preserve the
                // rows in Markdown, but keep the earliest semantic boundary.
                if var pending = pendingByIntentID[drift.intentSessionID] {
                    pending.drift.lastObservedAt = max(
                        pending.drift.lastObservedAt,
                        drift.lastObservedAt
                    )
                    pending.drift.minimumRelevance = min(
                        pending.drift.minimumRelevance,
                        drift.minimumRelevance
                    )
                    pendingByIntentID[drift.intentSessionID] = pending
                } else {
                    pendingByIntentID[drift.intentSessionID] = PendingDrift(
                        entry: entry,
                        drift: drift,
                        hadReminder: false,
                        isPlaceholderIntent: placeholderIntentIDs.contains(drift.intentSessionID)
                    )
                }
                suppressedEntryIDs.insert(entry.id)

            case .reminder(let prompt):
                // A prompt is an intervention delivery detail, not a separate
                // thing the user did. Keep it in the immutable diary for audit
                // and use it to decide whether a drift episode was meaningful,
                // but never render another Replay row for the delivery itself.
                // This also covers orphaned legacy prompts whose intent began
                // before the selected day and therefore cannot be joined by ID.
                suppressedEntryIDs.insert(entry.id)
                guard case .reminder = prompt,
                      let activeID = pendingByIntentID.values.max(by: {
                          $0.drift.beganAt < $1.drift.beganAt
                      })?.drift.intentSessionID else { continue }
                if prompt.referencesPlaceholderIntent {
                    pendingByIntentID[activeID]?.isPlaceholderIntent = true
                }
                pendingByIntentID[activeID]?.hadReminder = true

            case .returnedToIntent(let intentSessionID):
                suppressedEntryIDs.insert(entry.id)
                guard let pending = pendingByIntentID.removeValue(forKey: intentSessionID) else {
                    continue
                }
                episodes.append(Episode(
                    intentSessionID: intentSessionID,
                    firstEntry: pending.entry,
                    beganAt: pending.drift.beganAt,
                    returnedEntry: entry,
                    endedAt: entry.timestamp,
                    observedUntil: entry.timestamp,
                    hadReminder: pending.hadReminder,
                    isPlaceholderIntent: pending.isPlaceholderIntent
                ))

            default:
                continue
            }
        }

        if let lastTimestamp = ordered.last?.timestamp {
            for pending in pendingByIntentID.values {
                episodes.append(Episode(
                    intentSessionID: pending.drift.intentSessionID,
                    firstEntry: pending.entry,
                    beganAt: pending.drift.beganAt,
                    returnedEntry: nil,
                    endedAt: nil,
                    observedUntil: max(lastTimestamp, pending.drift.lastObservedAt),
                    hadReminder: pending.hadReminder,
                    isPlaceholderIntent: pending.isPlaceholderIntent
                ))
            }
        }

        // A few seconds back on the task between two low-relevance runs is
        // classifier jitter, not two separate stories in a day review. Merge
        // adjacent episodes for the same intent without touching source rows.
        var coalesced: [Episode] = []
        var lastIndexByIntentID: [UUID: Int] = [:]
        for episode in episodes.sorted(by: { $0.beganAt < $1.beganAt }) {
            if let index = lastIndexByIntentID[episode.intentSessionID],
               let priorEnd = coalesced[index].endedAt,
               episode.beganAt.timeIntervalSince(priorEnd) >= 0,
               episode.beganAt.timeIntervalSince(priorEnd) <= reentryDebounceInterval {
                coalesced[index].returnedEntry = episode.returnedEntry
                coalesced[index].endedAt = episode.endedAt
                coalesced[index].observedUntil = max(
                    coalesced[index].observedUntil,
                    episode.observedUntil
                )
                coalesced[index].hadReminder = coalesced[index].hadReminder || episode.hadReminder
                coalesced[index].isPlaceholderIntent = coalesced[index].isPlaceholderIntent
                    || episode.isPlaceholderIntent
            } else {
                lastIndexByIntentID[episode.intentSessionID] = coalesced.count
                coalesced.append(episode)
            }
        }

        for episode in coalesced where !episode.isPlaceholderIntent {
            let endpoint = episode.endedAt ?? episode.observedUntil
            let duration = max(0, endpoint.timeIntervalSince(episode.beganAt))
            guard duration >= minimumDuration || episode.hadReminder else { continue }

            if let returnedEntry = episode.returnedEntry, episode.endedAt != nil {
                momentsByEntryID[returnedEntry.id] = ReplayMoment(
                    timestamp: returnedEntry.timestamp,
                    lane: .relationship,
                    kind: .returned,
                    title: "Returned after a sustained detour",
                    detail: "离开原任务\(durationText(duration))后回来",
                    sourceEntryID: returnedEntry.id,
                    isHidden: hiddenEntryIDs.contains(returnedEntry.id)
                        || hiddenEntryIDs.contains(episode.firstEntry.id)
                )
            } else {
                momentsByEntryID[episode.firstEntry.id] = ReplayMoment(
                    timestamp: episode.beganAt,
                    lane: .userActivity,
                    kind: .drift,
                    title: "Attention stayed elsewhere",
                    detail: "这次离开当前任务已经持续\(durationText(duration))",
                    sourceEntryID: episode.firstEntry.id,
                    isHidden: hiddenEntryIDs.contains(episode.firstEntry.id)
                )
            }
        }

        return FocusEpisodeProjection(
            momentsByEntryID: momentsByEntryID,
            suppressedEntryIDs: suppressedEntryIDs
        )
    }
}

private extension AgentReflection {
    var isMechanicalWakeNoise: Bool {
        let text = [observation, hypothesis, consideredAction, finalAction, why]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let isDriftWake = text.contains("drift_reminder_level_")
        let hasPlaceholderIntent = text.contains("current activity") || text.contains("当前活动")
        let hasSystemContext = ["windowmanager", "loginwindow", "control center", "控制中心"]
            .contains { text.contains($0) }
        let hasTemplateHypothesis = text.contains("还需要用户行为继续验证")
            || text.contains("needs more user behavior to verify")
        let lacksDeliberation = consideredAction == nil && finalAction == nil && why == nil
        return isDriftWake
            && (hasPlaceholderIntent || hasSystemContext || hasTemplateHypothesis || lacksDeliberation)
    }
}

private extension AgentPrompt {
    var referencesPlaceholderIntent: Bool {
        let text: String
        switch self {
        case .curiousQuestion(let value):
            text = value
        case .reminder(_, let value, _):
            text = value
        case .returnedToIntent:
            return false
        }
        let normalized = text.lowercased()
        return normalized.contains("current activity") || normalized.contains("当前活动")
    }

    var replayTitle: String {
        switch self {
        case .curiousQuestion(let text):
            return text
        case .reminder(_, let text, _):
            return text
        case .returnedToIntent:
            return "AgentOne noticed the return"
        }
    }
}
