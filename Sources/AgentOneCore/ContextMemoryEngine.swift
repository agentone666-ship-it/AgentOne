import Foundation

public struct ContextEngineConfiguration: Codable, Hashable, Sendable {
    public var drift: DriftConfiguration
    public var curiousQuestionCooldown: TimeInterval
    public var automaticallyConfirmInferredIntent: Bool

    public init(
        drift: DriftConfiguration = DriftConfiguration(),
        curiousQuestionCooldown: TimeInterval = 120,
        automaticallyConfirmInferredIntent: Bool = true
    ) {
        self.drift = drift
        self.curiousQuestionCooldown = max(0, curiousQuestionCooldown)
        self.automaticallyConfirmInferredIntent = automaticallyConfirmInferredIntent
    }
}

public struct ContextEngineOutput: Codable, Hashable, Sendable {
    public var eventID: UUID
    public var activeIntent: IntentSession?
    public var relevance: Double?
    /// Exact wall-clock duration of the currently active drift episode. This
    /// comes from the Core state machine so UI/model layers never have to infer
    /// it from reminder thresholds or unrelated event timestamps.
    public var activeDriftDurationSeconds: TimeInterval?
    public var prompts: [AgentPrompt]
    public var appendedDiaryEntryIDs: [UUID]
    public var learnedSkills: [AgentSkill]

    public init(
        eventID: UUID,
        activeIntent: IntentSession?,
        relevance: Double?,
        activeDriftDurationSeconds: TimeInterval? = nil,
        prompts: [AgentPrompt] = [],
        appendedDiaryEntryIDs: [UUID] = [],
        learnedSkills: [AgentSkill] = []
    ) {
        self.eventID = eventID
        self.activeIntent = activeIntent
        self.relevance = relevance
        self.activeDriftDurationSeconds = activeDriftDurationSeconds
        self.prompts = prompts
        self.appendedDiaryEntryIDs = appendedDiaryEntryIDs
        self.learnedSkills = learnedSkills
    }
}

public actor ContextMemoryEngine {
    public let diary: AppendOnlyDiary

    private var configuration: ContextEngineConfiguration
    private var activeIntent: IntentSession?
    private var activeDrift: DriftEpisode?
    private var relevanceProfile = LearnedRelevanceProfile()
    private var eventByID: [UUID: ActivityEvent] = [:]
    private var diaryEntryIDByEventID: [UUID: UUID] = [:]
    private var learnedSkills: [AgentSkill] = []
    private var lastCuriousQuestionAt: Date?
    private var lastSelectedEvidenceFingerprint: String?
    private var lastSelectedEvidenceAt: Date?
    private var pendingActivitySession: PendingActivitySession?
    private var persistedDriftEpisodeIDs: Set<UUID> = []
    private var driftReturnCandidateSince: Date?
    private let skillExtractor = SkillExtractor()
    private let habitExtractor = HabitContextExtractor()
    private let activitySessionInactivityTimeout: TimeInterval = 180
    private let driftDiaryMinimumDuration: TimeInterval = 30
    private let driftReturnStabilityDuration: TimeInterval = 10

    public init(configuration: ContextEngineConfiguration = ContextEngineConfiguration(), diary: AppendOnlyDiary) {
        self.configuration = configuration
        self.diary = diary
    }

    @discardableResult
    public func beginIntent(
        title: String,
        summary: String,
        context: ActivityContext = ActivityContext(),
        origin: IntentOrigin = .userProvided,
        confidence: Double = 1,
        at timestamp: Date = Date()
    ) async throws -> IntentSession {
        _ = try await finalizePendingActivity(reason: .activityChanged)
        if var prior = activeIntent {
            prior.endedAt = timestamp
            prior.state = .completed
        }
        let terms = TextSemantics.tokens(in: "\(title) \(summary) \(context.searchableText)")
        let session = IntentSession(
            startedAt: timestamp,
            title: title,
            summary: summary,
            origin: origin,
            confidence: confidence,
            state: origin == .inferred ? .proposed : .active,
            contextTerms: terms
        )
        activeIntent = session
        activeDrift = nil
        driftReturnCandidateSince = nil
        persistedDriftEpisodeIDs.removeAll()
        _ = try await diary.append(.intentStarted(session), at: timestamp)
        return session
    }

    public func confirmCurrentIntent(at timestamp: Date = Date()) async throws {
        guard var intent = activeIntent else { return }
        intent.state = .active
        intent.origin = .userConfirmed
        intent.confidence = max(intent.confidence, 0.95)
        activeIntent = intent
        _ = try await diary.append(.intentConfirmed(intentSessionID: intent.id), at: timestamp)
    }

    public func record(_ event: ActivityEvent) async throws -> ContextEngineOutput {
        var appended: [UUID] = []
        var prompts: [AgentPrompt] = []

        appended.append(contentsOf: try await closePendingActivityIfNeeded(before: event))

        // These contexts may delimit the activity immediately before them, but
        // must never become the user's intent or advance the drift classifier.
        // In particular, loginwindow used to win the race to inferred intent
        // before the later activity-session filter had a chance to reject it.
        guard !event.context.isSensitive,
              !event.context.isAgentOneInternalContext,
              !event.context.isSystemNoiseContext else {
            let observedDriftDuration = activeDrift.map {
                max(0, $0.lastObservedAt.timeIntervalSince($0.beganAt))
            }
            return ContextEngineOutput(
                eventID: event.id,
                activeIntent: activeIntent,
                relevance: nil,
                activeDriftDurationSeconds: observedDriftDuration,
                prompts: [],
                appendedDiaryEntryIDs: appended
            )
        }

        eventByID[event.id] = event

        if activeIntent == nil, !event.context.searchableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let inferred = try await inferIntent(from: event)
            activeIntent = inferred
            let intentEntry = try await diary.append(.intentStarted(inferred), at: event.timestamp)
            appended.append(intentEntry.id)
        } else if configuration.automaticallyConfirmInferredIntent,
                  var intent = activeIntent,
                  intent.state == .proposed {
            let score = relevance(of: event, to: intent)
            if score >= configuration.drift.uncertaintyBand.upperBound {
                intent.state = .active
                intent.confidence = min(1, intent.confidence + 0.12)
                activeIntent = intent
                // Continued behavior can raise the live confidence, but it is
                // not an explicit agreement by the user and should not become
                // a relationship moment in the diary.
            }
        }

        let relevance = activeIntent.map { self.relevance(of: event, to: $0) }
        let evidence = makeEvidenceIfUseful(for: event)
        var evidenceIDs: [UUID] = []
        if let evidence {
            let evidenceEntry = try await diary.append(.evidence(evidence), at: event.timestamp)
            appended.append(evidenceEntry.id)
            evidenceIDs.append(evidence.id)
        }

        appended.append(contentsOf: try await observeSemanticActivity(
            event,
            relevance: relevance,
            evidenceIDs: evidenceIDs
        ))

        if let intent = activeIntent, let relevance, intent.canAnchorDriftEvaluation {
            let driftResult = try await updateDrift(event: event, intent: intent, relevance: relevance)
            prompts.append(contentsOf: driftResult.prompts)
            appended.append(contentsOf: driftResult.entryIDs)
        }

        return ContextEngineOutput(
            eventID: event.id,
            activeIntent: activeIntent,
            relevance: relevance,
            activeDriftDurationSeconds: activeDrift.map {
                max(0, event.timestamp.timeIntervalSince($0.beganAt))
            },
            prompts: prompts,
            appendedDiaryEntryIDs: appended
        )
    }

    /// Finalizes the current semantic activity as one append-only diary fact.
    /// Runtime shutdown and tests use this instead of persisting every raw hook.
    @discardableResult
    public func flushPendingActivity(
        at timestamp: Date = Date(),
        reason: ActivitySessionEndReason = .explicitFlush
    ) async throws -> [UUID] {
        _ = timestamp // The last observed hook is the truthful session boundary.
        return try await finalizePendingActivity(reason: reason)
    }

    public func addFeedback(_ feedback: UserFeedback) async throws -> AgentSkill? {
        let feedbackEntry = try await diary.append(.feedback(feedback), at: feedback.timestamp)
        let event = feedback.eventID.flatMap { eventByID[$0] }
        apply(feedback: feedback, event: event)

        if case .intentWasIncorrect(let title, let summary) = feedback.kind {
            if var intent = activeIntent {
                intent.title = title
                intent.summary = summary
                intent.origin = .corrected
                intent.confidence = 1
                intent.contextTerms = TextSemantics.tokens(in: "\(title) \(summary)")
                activeIntent = intent
            }
            if let target = feedback.eventID.flatMap({ diaryEntryIDByEventID[$0] }) {
                _ = try await diary.appendCorrection(to: target, text: "Intent corrected to: \(title) — \(summary)", at: feedback.timestamp)
            }
        } else if case .freeformCorrection(let correction) = feedback.kind,
                  let target = feedback.eventID.flatMap({ diaryEntryIDByEventID[$0] }) {
            _ = try await diary.appendCorrection(to: target, text: correction, at: feedback.timestamp)
        } else if case .intentChanged(let title, let summary) = feedback.kind {
            _ = try await beginIntent(title: title, summary: summary, origin: .corrected, at: feedback.timestamp)
        }

        guard let skill = skillExtractor.extract(from: feedback, event: event, sourceEntryID: feedbackEntry.id, at: feedback.timestamp) else {
            return nil
        }
        let existingSkill = Self.latestSkills(from: await diary.allEntries()).first {
            $0.domain == skill.domain
                && $0.name == skill.name
                && $0.guidance == skill.guidance
        }
        if var reinforcedSkill = existingSkill {
            reinforcedSkill.triggerTerms.formUnion(skill.triggerTerms)
            if !reinforcedSkill.sourceEntryIDs.contains(feedbackEntry.id) {
                reinforcedSkill.sourceEntryIDs.append(feedbackEntry.id)
            }
            reinforcedSkill.revision += 1
            reinforcedSkill.confidence = min(
                0.98,
                reinforcedSkill.confidence + (1 - reinforcedSkill.confidence) * 0.22
            )
            if let index = learnedSkills.firstIndex(where: { $0.id == reinforcedSkill.id }) {
                learnedSkills[index] = reinforcedSkill
            } else {
                learnedSkills.append(reinforcedSkill)
            }
            _ = try await diary.append(.skillLearned(reinforcedSkill), at: feedback.timestamp)
            return reinforcedSkill
        }
        learnedSkills.append(skill)
        _ = try await diary.append(.skillLearned(skill), at: feedback.timestamp)
        return skill
    }

    @discardableResult
    public func addAgentReflection(_ reflection: AgentReflection) async throws -> DiaryEntry {
        try await diary.append(.agentReflection(reflection), at: reflection.timestamp)
    }

    /// Adds a richer semantic snapshot to the activity that is currently in
    /// progress without creating another hook or another diary row. The caller
    /// must provide the original Context so a slow model response can never be
    /// attached to whatever app the user happens to be using later.
    @discardableResult
    public func enrichPendingActivityContext(
        _ enriched: ActivityContext,
        matching original: ActivityContext
    ) -> Bool {
        guard var pending = pendingActivitySession,
              pending.context.belongsToSameSession(as: original),
              pending.context.belongsToSameSession(as: enriched) else {
            return false
        }
        pending.context = pending.context.mergingRicherValues(from: enriched)
        pending.representativeEvent.context = pending.context
        pendingActivitySession = pending
        return true
    }

    /// Applies a model-produced semantic interpretation to the exact activity
    /// that caused the analysis. If that activity is still open, the richer
    /// Context is folded into its future immutable activity row. If it has
    /// already been persisted, a separate append-only enrichment fact is
    /// written and Replay projects it onto the original activity moment.
    @discardableResult
    public func applyContextEnrichment(
        targetEventID: UUID,
        enrichedContext: ActivityContext,
        activityTitle: String,
        summary: String,
        tags: [String] = [],
        matching originalContext: ActivityContext,
        at timestamp: Date = Date()
    ) async throws -> ContextEnrichmentApplication {
        guard !originalContext.isSensitive, !enrichedContext.isSensitive else {
            return .rejectedSensitive
        }

        var normalizedContext = originalContext.mergingRicherValues(from: enrichedContext)
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedSummary.isEmpty {
            normalizedContext.contentSummary = normalizedSummary
        }
        normalizedContext.semanticTags.insert(ActivityContext.modelEnrichedSummaryTag)
        normalizedContext.semanticTags.formUnion(tags.map { $0.lowercased() })

        if var pending = pendingActivitySession,
           pending.eventIDs.contains(targetEventID),
           pending.context.belongsToSameSession(as: originalContext) {
            pending.context = pending.context.mergingRicherValues(from: normalizedContext)
            pending.representativeEvent.context = pending.context
            pendingActivitySession = pending
            return .mergedIntoPending
        }

        let targetEntryID: UUID?
        if let indexed = diaryEntryIDByEventID[targetEventID] {
            targetEntryID = indexed
        } else {
            targetEntryID = await diary.allEntries().reversed().first { entry in
                guard case .activity(let record) = entry.payload else { return false }
                if record.event.id == targetEventID { return true }
                return record.session?.eventIDs.contains(targetEventID) == true
            }?.id
        }

        guard let targetEntryID else { return .targetNotFound }
        let title = activityTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let enrichment = ActivityContextEnrichment(
            targetEventID: targetEventID,
            targetActivityEntryID: targetEntryID,
            activityTitle: title.isEmpty ? normalizedSummary : title,
            summary: normalizedSummary,
            context: normalizedContext,
            tags: Array(Set(tags.map { $0.lowercased() })).sorted()
        )
        let entry = try await diary.append(.contextEnrichment(enrichment), at: timestamp)
        return .appended(entry)
    }

    @discardableResult
    public func addEvidence(_ evidence: KeyEvidence) async throws -> DiaryEntry {
        try await diary.append(.evidence(evidence), at: evidence.capturedAt)
    }

    public func hideDiaryEntry(_ entryID: UUID, reason: String? = nil, at timestamp: Date = Date()) async throws {
        _ = try await diary.setHidden(true, entryID: entryID, reason: reason, at: timestamp)
    }

    public func revealDiaryEntry(_ entryID: UUID, at timestamp: Date = Date()) async throws {
        _ = try await diary.setHidden(false, entryID: entryID, at: timestamp)
    }

    public func appendCorrection(to entryID: UUID, text: String, at timestamp: Date = Date()) async throws {
        _ = try await diary.appendCorrection(to: entryID, text: text, at: timestamp)
    }

    public func replay(for date: Date, includeHidden: Bool = false) async -> SemanticReplay {
        let day = await diary.dayKey(for: date)
        let entries = await diary.allEntries()
        let dailyEntries = await filter(entries: entries, toDay: day)
        return SemanticReplayBuilder().build(
            day: day,
            entries: dailyEntries,
            contextEntries: entries,
            includeHidden: includeHidden
        )
    }

    /// Returns the persisted semantic replay for every day that has at least
    /// one diary fact. The runtime used to ask only for `replay(for: Date())`,
    /// which made older, perfectly valid diary files invisible to the shell.
    /// This is a read-only projection: the append-only diary is never changed.
    public func allReplays(includeHidden: Bool = false) async -> [SemanticReplay] {
        let entries = await diary.allEntries()
        guard !entries.isEmpty else { return [] }

        var entriesByDay: [String: [DiaryEntry]] = [:]
        for entry in entries {
            let day = await diary.dayKey(for: entry.timestamp)
            entriesByDay[day, default: []].append(entry)
        }

        return entriesByDay.keys.sorted().map { day in
            let dailyEntries = entriesByDay[day, default: []]
            return SemanticReplayBuilder().build(
                day: day,
                entries: dailyEntries,
                contextEntries: entries,
                includeHidden: includeHidden
            )
        }
    }

    /// Rehydrates the in-memory skill index after an app restart. Skill facts
    /// are immutable diary entries, so runtime state must be reconstructed from
    /// disk instead of starting with an empty array on every launch.
    public func restorePersistedSkills() async {
        learnedSkills = Self.latestSkills(from: await diary.allEntries())
    }

    /// Returns the latest revision of every persisted Skill, including Skills
    /// learned in previous days and previous launches.
    public func persistedSkills() async -> [AgentSkill] {
        Self.latestSkills(from: await diary.allEntries())
    }

    private static func latestSkills(from entries: [DiaryEntry]) -> [AgentSkill] {
        var latestByKey: [String: AgentSkill] = [:]
        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard case .skillLearned(let skill) = entry.payload else { continue }
            let key = "\(skill.domain.rawValue)|\(skill.name.lowercased())"
            guard var accumulated = latestByKey[key] else {
                latestByKey[key] = skill
                continue
            }

            accumulated.triggerTerms.formUnion(skill.triggerTerms)
            for sourceEntryID in skill.sourceEntryIDs
                where !accumulated.sourceEntryIDs.contains(sourceEntryID) {
                accumulated.sourceEntryIDs.append(sourceEntryID)
            }
            accumulated.guidance = skill.guidance
            accumulated.confidence = max(accumulated.confidence, skill.confidence)
            accumulated.revision = max(
                accumulated.revision,
                skill.revision,
                accumulated.sourceEntryIDs.count
            )
            latestByKey[key] = accumulated
        }
        return latestByKey.values.sorted {
            if $0.createdAt == $1.createdAt { return $0.name < $1.name }
            return $0.createdAt > $1.createdAt
        }
    }

    public func currentIntent() -> IntentSession? {
        activeIntent
    }

    public func skills() -> [AgentSkill] {
        learnedSkills
    }

    public func habitContexts() async -> [HabitContext] {
        habitExtractor.extract(from: await diary.allEntries())
    }

    @discardableResult
    public func addDailyContextDigest(
        _ digest: DailyContextDigest,
        at entryTimestamp: Date = Date()
    ) async throws -> DiaryEntry {
        try await diary.append(.dailyContextDigest(digest), at: entryTimestamp)
    }

    public func latestDailyContextDigest(for date: Date) async -> DailyContextDigest? {
        let day = await diary.dayKey(for: date)
        return await diary.allEntries().reversed().compactMap { entry -> DailyContextDigest? in
            guard case .dailyContextDigest(let digest) = entry.payload,
                  digest.day == day else { return nil }
            return digest
        }.first
    }

    public func recordedDays() async -> [String] {
        var days: Set<String> = []
        for entry in await diary.allEntries() {
            days.insert(await diary.dayKey(for: entry.timestamp))
        }
        return days.sorted()
    }

    public func updateConfiguration(_ configuration: ContextEngineConfiguration) {
        self.configuration = configuration
    }

    private func inferIntent(from event: ActivityEvent) async throws -> IntentSession {
        let title = event.context.windowTitle
            ?? event.context.documentPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? event.context.url?.host()
            ?? "当前活动"
        let summary = event.context.contentSummary
            ?? event.context.selectedText
            ?? "继续在 \(event.context.applicationName ?? "当前应用") 中处理刚才的事情"
        return IntentSession(
            startedAt: event.timestamp,
            title: title,
            summary: summary,
            origin: .inferred,
            confidence: 0.68,
            state: .proposed,
            contextTerms: TextSemantics.tokens(in: event.context.searchableText),
            supportingEventIDs: [event.id]
        )
    }

    private func relevance(of event: ActivityEvent, to intent: IntentSession) -> Double {
        let eventTerms = TextSemantics.tokens(in: event.context.searchableText)
        guard !intent.contextTerms.isEmpty || !eventTerms.isEmpty else { return 0.5 }
        let union = intent.contextTerms.union(eventTerms)
        let overlap = intent.contextTerms.intersection(eventTerms)
        var score = union.isEmpty ? 0 : Double(overlap.count) / Double(union.count)

        for term in eventTerms {
            score += relevanceProfile.relevantTerms[term, default: 0]
            score -= relevanceProfile.distractingTerms[term, default: 0]
        }
        if event.semantics.contains(.opinionOutput) || event.semantics.contains(.compositionContinued) {
            score += 0.12
        }
        if event.semantics.contains(.readingProgress), !overlap.isEmpty {
            score += 0.14
        }
        return min(max(score, 0), 1)
    }

    private func updateDrift(
        event: ActivityEvent,
        intent: IntentSession,
        relevance: Double
    ) async throws -> (prompts: [AgentPrompt], entryIDs: [UUID]) {
        var prompts: [AgentPrompt] = []
        var entryIDs: [UUID] = []
        let uncertain = configuration.drift.uncertaintyBand.contains(relevance)

        if uncertain, canAskCuriousQuestion(at: event.timestamp) {
            let question = AgentPrompt.curiousQuestion(text: "I’m curious—does this page help with “\(intent.title)”?")
            prompts.append(question)
            lastCuriousQuestionAt = event.timestamp
            let promptEntry = try await diary.append(.reminder(question), at: event.timestamp)
            entryIDs.append(promptEntry.id)
        }

        if relevance < configuration.drift.relevanceThreshold {
            driftReturnCandidateSince = nil
            if activeDrift == nil {
                let drift = DriftEpisode(
                    intentSessionID: intent.id,
                    beganAt: event.timestamp,
                    lastObservedAt: event.timestamp,
                    minimumRelevance: relevance,
                    eventIDs: [event.id]
                )
                activeDrift = drift
            } else if var drift = activeDrift {
                drift.lastObservedAt = event.timestamp
                drift.minimumRelevance = min(drift.minimumRelevance, relevance)
                drift.eventIDs.append(event.id)
                activeDrift = drift
            }

            if var drift = activeDrift {
                let elapsed = event.timestamp.timeIntervalSince(drift.beganAt)
                let adjustedElapsed = elapsed / max(relevanceProfile.reminderTimingMultiplier, 0.1)
                let eligibleStages = configuration.drift.stages.filter { adjustedElapsed >= $0.after }

                // A single low-relevance hook is classifier uncertainty, not a
                // diary event. Persist the episode only after it has remained
                // away long enough to be meaningful (or is about to trigger a
                // reminder). Raw hooks still update the live drift state from
                // the first observation.
                if (elapsed >= driftDiaryMinimumDuration || !eligibleStages.isEmpty),
                   persistedDriftEpisodeIDs.insert(drift.id).inserted {
                    let driftEntry = try await diary.append(.driftStarted(drift), at: event.timestamp)
                    entryIDs.append(driftEntry.id)
                }

                if let stage = eligibleStages.last, !drift.emittedLevels.contains(stage.level) {
                    let prompt = AgentPrompt.reminder(
                        stage: stage,
                        text: "We were working on “\(intent.title)”. Want me to take you back to that thread?",
                        canReturn: true
                    )
                    prompts.append(prompt)
                    for completedStage in eligibleStages {
                        drift.emittedLevels.insert(completedStage.level)
                    }
                    let reminderEntry = try await diary.append(.reminder(prompt), at: event.timestamp)
                    entryIDs.append(reminderEntry.id)
                }
                activeDrift = drift
            }
        } else if var drift = activeDrift {
            // One relevant hook is not enough to claim that the user returned.
            // Keep the original episode alive through brief app/window jitter
            // and close it only after relevant behavior remains stable.
            guard relevance >= configuration.drift.uncertaintyBand.upperBound else {
                driftReturnCandidateSince = nil
                return (prompts, entryIDs)
            }
            if driftReturnCandidateSince == nil {
                driftReturnCandidateSince = event.timestamp
                return (prompts, entryIDs)
            }
            guard let candidateSince = driftReturnCandidateSince,
                  event.timestamp.timeIntervalSince(candidateSince) >= driftReturnStabilityDuration else {
                return (prompts, entryIDs)
            }

            drift.endedAt = event.timestamp
            activeDrift = nil
            driftReturnCandidateSince = nil
            if persistedDriftEpisodeIDs.remove(drift.id) != nil {
                let prompt = AgentPrompt.returnedToIntent(intentSessionID: intent.id)
                prompts.append(prompt)
                let returnEntry = try await diary.append(.returnedToIntent(intentSessionID: intent.id), at: event.timestamp)
                entryIDs.append(returnEntry.id)
            }
        }
        return (prompts, entryIDs)
    }

    private func canAskCuriousQuestion(at timestamp: Date) -> Bool {
        guard let lastCuriousQuestionAt else { return true }
        return timestamp.timeIntervalSince(lastCuriousQuestionAt) >= configuration.curiousQuestionCooldown
    }

    private func makeEvidenceIfUseful(for event: ActivityEvent) -> KeyEvidence? {
        guard !event.context.isSensitive else { return nil }
        let isOutput = event.semantics.contains(.opinionOutput)
            || event.semantics.contains(.taskSubmission)
        let selectedText = event.context.selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectionWasObserved: Bool
        switch event.signal {
        case .mouseClicked, .clipboardUsed:
            selectionWasObserved = !(selectedText?.isEmpty ?? true)
        default:
            selectionWasObserved = false
        }
        let deservesEvidence = isOutput || selectionWasObserved
        guard deservesEvidence else { return nil }

        if selectionWasObserved, !isOutput, let selectedText {
            let fingerprint = [
                event.context.url?.absoluteString,
                event.context.windowTitle,
                selectedText
            ].compactMap { $0 }.joined(separator: "|").lowercased()
            if fingerprint == lastSelectedEvidenceFingerprint,
               let lastSelectedEvidenceAt,
               event.timestamp.timeIntervalSince(lastSelectedEvidenceAt) < 600 {
                return nil
            }
            lastSelectedEvidenceFingerprint = fingerprint
            lastSelectedEvidenceAt = event.timestamp
        }
        return KeyEvidence(
            capturedAt: event.timestamp,
            kind: event.context.screenshotResourcePath == nil
                ? (selectedText == nil ? .taskSceneCard : .selectedText)
                : .screenshot,
            title: isOutput ? "A thought was expressed" : "Selected text",
            summary: event.context.contentSummary,
            localResourcePath: event.context.screenshotResourcePath,
            url: event.context.url,
            selectedText: selectedText,
            submittedText: event.context.submittedText,
            windowTitle: event.context.windowTitle,
            eventID: event.id
        )
    }

    private func makeEvidenceIfUseful(for session: ActivitySessionSummary) -> KeyEvidence? {
        guard !session.context.isSensitive else { return nil }
        guard session.kind == .reading || session.kind == .researching else { return nil }
        guard session.context.selectedText != nil
                || session.context.url != nil
                || session.context.documentPath != nil else {
            return nil
        }
        return KeyEvidence(
            capturedAt: session.startedAt,
            kind: session.context.selectedText == nil ? .pageReference : .selectedText,
            title: "Reading context",
            summary: session.context.contentSummary,
            url: session.context.url,
            selectedText: session.context.selectedText,
            windowTitle: session.context.windowTitle,
            eventID: session.eventIDs.first
        )
    }

    private func closePendingActivityIfNeeded(before event: ActivityEvent) async throws -> [UUID] {
        guard let pendingActivitySession else { return [] }

        // An idle interval is delimited by idleStarted/idleEnded. A long idle is
        // expected to exceed the generic activity timeout, so let idleEnded be
        // absorbed before applying that timeout. Otherwise the pending idle is
        // finalized with a zero-second duration and disappears from the diary.
        if case .idleEnded = event.signal, pendingActivitySession.kind == .idle {
            return []
        }

        let gap = event.timestamp.timeIntervalSince(pendingActivitySession.lastObservedAt)
        if gap > activitySessionInactivityTimeout {
            return try await finalizePendingActivity(reason: .inactivityTimeout)
        }

        if event.context.isSensitive
            || event.context.isAgentOneInternalContext
            || event.context.isSystemNoiseContext {
            return try await finalizePendingActivity(reason: .contextChanged)
        }

        let incomingKind = ActivitySemanticClassifier.kind(for: event)
        if incomingKind != .idle,
           pendingActivitySession.kind != .idle,
           !event.context.belongsToSameSession(as: pendingActivitySession.context) {
            return try await finalizePendingActivity(reason: .contextChanged)
        }

        if case .idleStarted = event.signal, pendingActivitySession.kind != .idle {
            return try await finalizePendingActivity(reason: .becameIdle)
        }

        if !ActivitySemanticClassifier.canMerge(
            current: pendingActivitySession.kind,
            incoming: incomingKind,
            event: event
        ) {
            return try await finalizePendingActivity(reason: .activityChanged)
        }
        return []
    }

    private func observeSemanticActivity(
        _ event: ActivityEvent,
        relevance: Double?,
        evidenceIDs: [UUID]
    ) async throws -> [UUID] {
        _ = relevance
        guard !event.context.isSensitive,
              !event.context.isAgentOneInternalContext,
              !event.context.isSystemNoiseContext else { return [] }
        if case .mouseMoved = event.signal { return [] }

        let incomingKind = ActivitySemanticClassifier.kind(for: event)

        if case .idleEnded = event.signal {
            guard var pending = pendingActivitySession, pending.kind == .idle else { return [] }
            pending.absorb(event, inferredKind: .idle, evidenceIDs: evidenceIDs)
            pendingActivitySession = pending
            return try await finalizePendingActivity(reason: .resumedFromIdle)
        }

        if var pending = pendingActivitySession {
            pending.absorb(event, inferredKind: incomingKind, evidenceIDs: evidenceIDs)
            pendingActivitySession = pending
        } else {
            pendingActivitySession = PendingActivitySession(
                event: event,
                kind: incomingKind,
                evidenceIDs: evidenceIDs
            )
        }

        if ActivitySemanticClassifier.isMilestone(event) {
            return try await finalizePendingActivity(reason: .semanticMilestone)
        }
        return []
    }

    private func finalizePendingActivity(reason: ActivitySessionEndReason) async throws -> [UUID] {
        guard let pending = pendingActivitySession else { return [] }
        pendingActivitySession = nil
        let session = pending.summary(reason: reason)
        guard session.isDiaryWorthy else { return [] }
        var appended: [UUID] = []
        var evidenceIDs = pending.evidenceIDs

        if let evidence = makeEvidenceIfUseful(for: session) {
            let evidenceEntry = try await diary.append(.evidence(evidence), at: session.startedAt)
            appended.append(evidenceEntry.id)
            evidenceIDs.append(evidence.id)
        }

        var representativeEvent = pending.representativeEvent
        representativeEvent.context = session.context
        let relevance = activeIntent.map { self.relevance(of: representativeEvent, to: $0) }
        let record = ActivityDiaryRecord(
            event: representativeEvent,
            inferredIntentSessionID: activeIntent?.id,
            relevance: relevance,
            narrative: SemanticActivityNarrative.text(for: session),
            evidenceIDs: evidenceIDs,
            session: session
        )
        let entry = try await diary.append(.activity(record), at: session.startedAt)
        appended.append(entry.id)
        for eventID in pending.eventIDs {
            diaryEntryIDByEventID[eventID] = entry.id
        }
        return appended
    }

    private func apply(feedback: UserFeedback, event: ActivityEvent?) {
        let terms = event.map { TextSemantics.tokens(in: $0.context.searchableText) } ?? []
        switch feedback.kind {
        case .eventWasRelated:
            for term in terms { relevanceProfile.relevantTerms[term, default: 0] += 0.08 }
        case .eventWasDistraction:
            for term in terms { relevanceProfile.distractingTerms[term, default: 0] += 0.08 }
        case .reminderTooEarly:
            relevanceProfile.reminderTimingMultiplier = min(3, relevanceProfile.reminderTimingMultiplier * 1.2)
        case .reminderHelpful:
            relevanceProfile.reminderTimingMultiplier = max(0.5, relevanceProfile.reminderTimingMultiplier * 0.98)
        case .reminderTooStrong, .intentWasIncorrect, .intentChanged, .freeformCorrection:
            break
        }
    }

    private func filter(entries: [DiaryEntry], toDay day: String) async -> [DiaryEntry] {
        var result: [DiaryEntry] = []
        for entry in entries {
            if await diary.dayKey(for: entry.timestamp) == day {
                result.append(entry)
            }
        }
        return result
    }
}
