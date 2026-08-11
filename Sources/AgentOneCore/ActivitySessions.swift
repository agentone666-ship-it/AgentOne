import Foundation

/// The semantic state shown in the diary. These are deliberately larger than
/// individual input hooks: clicks, scroll ticks and key bursts are observations
/// inside one state, not diary moments of their own.
public enum ContinuousActivityKind: String, Codable, Hashable, Sendable {
    case reading
    case composing
    case researching
    case communicating
    case watching
    case navigating
    case idle
}

public enum ActivitySessionEndReason: String, Codable, Hashable, Sendable {
    case contextChanged
    case activityChanged
    case becameIdle
    case resumedFromIdle
    case semanticMilestone
    case inactivityTimeout
    case runtimeStopped
    case explicitFlush
}

/// A compact, immutable description of a semantic activity. Raw hooks remain
/// available to the live intent/drift state machine, while the diary receives
/// only this segment after it has ended or reached an important milestone.
public struct ActivitySessionSummary: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var kind: ContinuousActivityKind
    public var startedAt: Date
    public var lastObservedAt: Date
    public var endedAt: Date
    public var eventCount: Int
    public var totalMagnitude: Double
    public var clickCount: Int
    public var typingCount: Int
    public var scrollCount: Int
    public var navigationCount: Int
    public var activationCount: Int
    public var idleTransitionCount: Int
    public var context: ActivityContext
    public var eventIDs: [UUID]
    public var endReason: ActivitySessionEndReason

    public init(
        id: UUID = UUID(),
        kind: ContinuousActivityKind,
        startedAt: Date,
        lastObservedAt: Date,
        endedAt: Date,
        eventCount: Int,
        totalMagnitude: Double = 0,
        clickCount: Int = 0,
        typingCount: Int = 0,
        scrollCount: Int = 0,
        navigationCount: Int = 0,
        activationCount: Int = 0,
        idleTransitionCount: Int = 0,
        context: ActivityContext,
        eventIDs: [UUID],
        endReason: ActivitySessionEndReason
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.lastObservedAt = lastObservedAt
        self.endedAt = endedAt
        self.eventCount = max(1, eventCount)
        self.totalMagnitude = max(0, totalMagnitude)
        self.clickCount = max(0, clickCount)
        self.typingCount = max(0, typingCount)
        self.scrollCount = max(0, scrollCount)
        self.navigationCount = max(0, navigationCount)
        self.activationCount = max(0, activationCount)
        self.idleTransitionCount = max(0, idleTransitionCount)
        self.context = context
        self.eventIDs = eventIDs
        self.endReason = endReason
    }

    public var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// Prevents a technically valid but semantically empty segment from
    /// becoming a diary row. The raw hooks still informed intent and drift.
    var isDiaryWorthy: Bool {
        switch kind {
        case .reading:
            // Trackpad and wheel hooks can arrive dozens of times per second.
            // Volume is evidence only after the user has stayed long enough
            // for this to be a real reading segment rather than app-switch
            // jitter.
            return duration >= 8 && (scrollCount >= 5 || duration >= 30)
        case .composing:
            return typingCount >= 1
        case .researching:
            return duration >= 8 && (eventCount >= 10 || duration >= 30)
        case .communicating:
            return duration >= 8 && (eventCount >= 3 || duration >= 15)
        case .watching:
            return duration >= 8 && (eventCount >= 10 || duration >= 30)
        case .navigating:
            return duration >= 8 && (eventCount >= 10 || duration >= 60)
        case .idle:
            return duration >= 180
        }
    }

    // Explicit decoding keeps diaries written by the reading-only build valid.
    // New counters default to values derivable from that legacy session.
    private enum CodingKeys: String, CodingKey {
        case id, kind, startedAt, lastObservedAt, endedAt, eventCount, totalMagnitude
        case clickCount, typingCount, scrollCount, navigationCount, activationCount
        case idleTransitionCount, context, eventIDs, endReason
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(ContinuousActivityKind.self, forKey: .kind)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        lastObservedAt = try values.decode(Date.self, forKey: .lastObservedAt)
        endedAt = try values.decode(Date.self, forKey: .endedAt)
        eventCount = max(1, try values.decode(Int.self, forKey: .eventCount))
        totalMagnitude = max(0, try values.decodeIfPresent(Double.self, forKey: .totalMagnitude) ?? 0)
        clickCount = max(0, try values.decodeIfPresent(Int.self, forKey: .clickCount) ?? 0)
        typingCount = max(0, try values.decodeIfPresent(Int.self, forKey: .typingCount) ?? 0)
        scrollCount = max(0, try values.decodeIfPresent(Int.self, forKey: .scrollCount) ?? (kind == .reading ? eventCount : 0))
        navigationCount = max(0, try values.decodeIfPresent(Int.self, forKey: .navigationCount) ?? 0)
        activationCount = max(0, try values.decodeIfPresent(Int.self, forKey: .activationCount) ?? 0)
        idleTransitionCount = max(0, try values.decodeIfPresent(Int.self, forKey: .idleTransitionCount) ?? 0)
        context = try values.decode(ActivityContext.self, forKey: .context)
        eventIDs = try values.decodeIfPresent([UUID].self, forKey: .eventIDs) ?? []
        endReason = try values.decode(ActivitySessionEndReason.self, forKey: .endReason)
    }
}

struct ActivityObservationCounts: Sendable {
    var totalMagnitude: Double = 0
    var clickCount = 0
    var typingCount = 0
    var scrollCount = 0
    var navigationCount = 0
    var activationCount = 0
    var idleTransitionCount = 0

    mutating func absorb(_ event: ActivityEvent) {
        switch event.signal {
        case .mouseClicked:
            clickCount += 1
            navigationCount += 1
        case .scrolled(_, let delta, _):
            scrollCount += 1
            navigationCount += 1
            totalMagnitude += abs(delta)
        case .keyboard(let behavior):
            switch behavior {
            case .typingStarted, .typingBurst, .typingPaused, .returnPressed, .deletePressed:
                typingCount += 1
            case .navigation, .shortcut, .escapePressed:
                navigationCount += 1
            }
        case .applicationActivated, .windowFocused:
            activationCount += 1
        case .contentChanged:
            typingCount += 1
        case .clipboardUsed:
            navigationCount += 1
        case .idleStarted, .idleEnded:
            idleTransitionCount += 1
        case .mouseMoved, .voiceConversationStarted, .voiceConversationEnded:
            break
        }
    }
}

struct PendingActivitySession: Sendable {
    let id: UUID
    var kind: ContinuousActivityKind
    let startedAt: Date
    var lastObservedAt: Date
    var eventCount: Int
    var counts: ActivityObservationCounts
    var context: ActivityContext
    var representativeEvent: ActivityEvent
    var eventIDs: [UUID]
    var evidenceIDs: [UUID]

    init(event: ActivityEvent, kind: ContinuousActivityKind, evidenceIDs: [UUID] = []) {
        id = UUID()
        self.kind = kind
        startedAt = event.timestamp
        lastObservedAt = event.timestamp
        eventCount = 1
        var counts = ActivityObservationCounts()
        counts.absorb(event)
        self.counts = counts
        context = event.context
        representativeEvent = event
        eventIDs = [event.id]
        self.evidenceIDs = evidenceIDs
    }

    mutating func absorb(
        _ event: ActivityEvent,
        inferredKind: ContinuousActivityKind,
        evidenceIDs: [UUID] = []
    ) {
        if ActivitySemanticClassifier.shouldPromote(kind, to: inferredKind) {
            kind = inferredKind
            representativeEvent = event
        }
        lastObservedAt = max(lastObservedAt, event.timestamp)
        eventCount += 1
        counts.absorb(event)
        eventIDs.append(event.id)
        self.evidenceIDs.append(contentsOf: evidenceIDs.filter { !self.evidenceIDs.contains($0) })
        context = context.mergingRicherValues(from: event.context)
    }

    func summary(reason: ActivitySessionEndReason) -> ActivitySessionSummary {
        let persistedEventIDs: [UUID]
        if let first = eventIDs.first, let last = eventIDs.last, first != last {
            persistedEventIDs = [first, last]
        } else {
            persistedEventIDs = eventIDs.prefix(1).map { $0 }
        }
        return ActivitySessionSummary(
            id: id,
            kind: kind,
            startedAt: startedAt,
            lastObservedAt: lastObservedAt,
            endedAt: lastObservedAt,
            eventCount: eventCount,
            totalMagnitude: counts.totalMagnitude,
            clickCount: counts.clickCount,
            typingCount: counts.typingCount,
            scrollCount: counts.scrollCount,
            navigationCount: counts.navigationCount,
            activationCount: counts.activationCount,
            idleTransitionCount: counts.idleTransitionCount,
            context: context,
            eventIDs: persistedEventIDs,
            endReason: reason
        )
    }
}

enum ActivitySemanticClassifier {
    static func kind(for event: ActivityEvent) -> ContinuousActivityKind {
        let tags = Set(event.context.semanticTags.map { $0.lowercased() })
        let haystack = event.context.searchableText.lowercased()
        let isCommunication = !tags.isDisjoint(with: ["chat", "message", "communication", "meeting"])
            || ["微信", "messages", "slack", "discord", "飞书会议", "zoom"].contains { haystack.contains($0) }
        let isWatching = !tags.isDisjoint(with: ["video", "watching", "media"])
            || ["youtube", "bilibili", "哔哩哔哩", "抖音"].contains { haystack.contains($0) }
        let isResearch = !tags.isDisjoint(with: ["research", "paper", "reference"])
            || ["paper", "论文", "arxiv", "scholar"].contains { haystack.contains($0) }

        switch event.signal {
        case .scrolled:
            if isCommunication { return .communicating }
            return isWatching ? .watching : .reading
        case .keyboard(let behavior):
            switch behavior {
            case .typingStarted, .typingBurst, .typingPaused, .returnPressed, .deletePressed:
                return isCommunication ? .communicating : .composing
            case .navigation, .shortcut, .escapePressed:
                return isResearch ? .researching : (isWatching ? .watching : .navigating)
            }
        case .contentChanged:
            return isCommunication ? .communicating : .composing
        case .voiceConversationStarted, .voiceConversationEnded:
            return .communicating
        case .idleStarted, .idleEnded:
            return .idle
        case .mouseMoved, .mouseClicked, .applicationActivated, .windowFocused, .clipboardUsed:
            if isCommunication { return .communicating }
            if isWatching { return .watching }
            if isResearch { return .researching }
            return .navigating
        }
    }

    static func isWeakNavigation(_ event: ActivityEvent) -> Bool {
        switch event.signal {
        case .mouseMoved, .mouseClicked, .applicationActivated, .windowFocused, .clipboardUsed:
            return true
        case .keyboard(let behavior):
            switch behavior {
            case .navigation, .shortcut, .escapePressed: return true
            default: return false
            }
        default:
            return false
        }
    }

    static func isMilestone(_ event: ActivityEvent) -> Bool {
        event.semantics.contains(.opinionOutput) || event.semantics.contains(.taskSubmission)
    }

    static func shouldPromote(_ current: ContinuousActivityKind, to incoming: ContinuousActivityKind) -> Bool {
        guard current != incoming else { return false }
        guard current == .navigating || current == .researching else { return false }
        switch incoming {
        case .reading, .composing, .communicating, .watching:
            return true
        case .researching, .navigating, .idle:
            return false
        }
    }

    static func canMerge(
        current: ContinuousActivityKind,
        incoming: ContinuousActivityKind,
        event: ActivityEvent
    ) -> Bool {
        if current == incoming { return true }
        if isWeakNavigation(event), current != .idle { return true }
        if shouldPromote(current, to: incoming) { return true }
        return false
    }
}

enum SemanticActivityNarrative {
    static func text(for session: ActivitySessionSummary) -> String {
        let place = conciseTopic(session.context.contentSummary)
            ?? session.context.windowTitle
            ?? session.context.applicationName
            ?? session.context.url?.host
            ?? "the current page"
        switch session.kind {
        case .reading:
            return durationPrefix("Read \(place)", session: session)
        case .composing:
            return durationPrefix("Wrote in \(place)", session: session)
        case .researching:
            return durationPrefix("Researched in \(place)", session: session)
        case .communicating:
            return durationPrefix("Communicated in \(place)", session: session)
        case .watching:
            return durationPrefix("Watched \(place)", session: session)
        case .navigating:
            return durationPrefix("Navigated \(place)", session: session)
        case .idle:
            return durationPrefix("Took a break", session: session)
        }
    }

    private static func durationPrefix(_ prefix: String, session: ActivitySessionSummary) -> String {
        guard session.duration >= 60 else { return "\(prefix) as one continuous session" }
        let minutes = max(1, Int((session.duration / 60).rounded()))
        return "\(prefix) for about \(minutes) minutes"
    }

    private static func conciseTopic(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let sentence = normalized.split(whereSeparator: { ".。！？!?\n".contains($0) }).first.map(String.init)
            ?? normalized
        return String(sentence.prefix(110))
    }
}

/// Read-only migration for diaries written before the semantic state machine.
/// It never edits the append-only Markdown; Replay consumes the projected
/// segments and suppresses the thousands of original low-level rows.
struct LegacySemanticActivityProjection: Sendable {
    struct ProjectedSession: Sendable {
        var sourceEntryID: UUID
        var representativeRecord: ActivityDiaryRecord
        var session: ActivitySessionSummary
    }

    var sessionsByFirstEntryID: [UUID: ProjectedSession]
    var suppressedEntryIDs: Set<UUID>

    static func build(from entries: [DiaryEntry], inactivityTimeout: TimeInterval = 180) -> Self {
        var sessionsByFirstEntryID: [UUID: ProjectedSession] = [:]
        var suppressedEntryIDs: Set<UUID> = []
        var pending: PendingLegacySemanticSession?

        func flush(_ pending: inout PendingLegacySemanticSession?, reason: ActivitySessionEndReason = .explicitFlush) {
            guard let value = pending else { return }
            let session = value.summary(reason: reason)
            guard session.isDiaryWorthy else {
                suppressedEntryIDs.formUnion(value.sourceEntryIDs)
                pending = nil
                return
            }
            var representative = value.representativeRecord
            representative.event.context = session.context
            representative.narrative = SemanticActivityNarrative.text(for: session)
            representative.evidenceIDs = value.evidenceIDs
            representative.session = session
            sessionsByFirstEntryID[value.firstEntryID] = ProjectedSession(
                sourceEntryID: value.firstEntryID,
                representativeRecord: representative,
                session: session
            )
            pending = nil
        }

        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard case .activity(let record) = entry.payload else { continue }

            if record.session != nil {
                flush(&pending)
                continue
            }

            if record.event.context.isSensitive
                || record.event.context.isAgentOneInternalContext
                || record.event.context.isSystemNoiseContext {
                flush(&pending)
                suppressedEntryIDs.insert(entry.id)
                continue
            }

            if case .idleEnded = record.event.signal {
                suppressedEntryIDs.insert(entry.id)
                if var current = pending, current.kind == .idle {
                    current.absorb(entry: entry, record: record, inferredKind: .idle)
                    pending = current
                    flush(&pending, reason: .resumedFromIdle)
                }
                continue
            }

            let incomingKind = ActivitySemanticClassifier.kind(for: record.event)
            if var current = pending {
                let gap = entry.timestamp.timeIntervalSince(current.lastObservedAt)
                let sameContext = incomingKind == .idle
                    || current.kind == .idle
                    || record.event.context.belongsToSameSession(as: current.context)
                if gap <= inactivityTimeout,
                   sameContext,
                   ActivitySemanticClassifier.canMerge(current: current.kind, incoming: incomingKind, event: record.event) {
                    current.absorb(entry: entry, record: record, inferredKind: incomingKind)
                    pending = current
                    suppressedEntryIDs.insert(entry.id)
                } else {
                    let reason: ActivitySessionEndReason = gap > inactivityTimeout
                        ? .inactivityTimeout
                        : (sameContext ? .activityChanged : .contextChanged)
                    flush(&pending, reason: reason)
                }
            }

            if pending == nil {
                pending = PendingLegacySemanticSession(entry: entry, record: record, kind: incomingKind)
            }

            if case .idleStarted = record.event.signal {
                // Keep the interruption open until idleEnded or the next event.
                continue
            }
            if ActivitySemanticClassifier.isMilestone(record.event) {
                flush(&pending, reason: .semanticMilestone)
            }
        }
        flush(&pending)

        return LegacySemanticActivityProjection(
            sessionsByFirstEntryID: sessionsByFirstEntryID,
            suppressedEntryIDs: suppressedEntryIDs
        )
    }
}

private struct PendingLegacySemanticSession: Sendable {
    let firstEntryID: UUID
    let startedAt: Date
    var lastObservedAt: Date
    var kind: ContinuousActivityKind
    var eventCount: Int
    var counts: ActivityObservationCounts
    var context: ActivityContext
    var representativeRecord: ActivityDiaryRecord
    var firstEventID: UUID
    var lastEventID: UUID
    var evidenceIDs: [UUID]
    var sourceEntryIDs: [UUID]

    init(entry: DiaryEntry, record: ActivityDiaryRecord, kind: ContinuousActivityKind) {
        firstEntryID = entry.id
        startedAt = entry.timestamp
        lastObservedAt = entry.timestamp
        self.kind = kind
        eventCount = 1
        var counts = ActivityObservationCounts()
        counts.absorb(record.event)
        self.counts = counts
        context = record.event.context
        representativeRecord = record
        firstEventID = record.event.id
        lastEventID = record.event.id
        evidenceIDs = record.evidenceIDs
        sourceEntryIDs = [entry.id]
    }

    mutating func absorb(entry: DiaryEntry, record: ActivityDiaryRecord, inferredKind: ContinuousActivityKind) {
        if ActivitySemanticClassifier.shouldPromote(kind, to: inferredKind) {
            kind = inferredKind
            representativeRecord = record
        }
        lastObservedAt = max(lastObservedAt, entry.timestamp)
        eventCount += 1
        counts.absorb(record.event)
        context = context.mergingRicherValues(from: record.event.context)
        lastEventID = record.event.id
        sourceEntryIDs.append(entry.id)
        for evidenceID in record.evidenceIDs where !evidenceIDs.contains(evidenceID) {
            evidenceIDs.append(evidenceID)
        }
    }

    func summary(reason: ActivitySessionEndReason) -> ActivitySessionSummary {
        ActivitySessionSummary(
            kind: kind,
            startedAt: startedAt,
            lastObservedAt: lastObservedAt,
            endedAt: lastObservedAt,
            eventCount: eventCount,
            totalMagnitude: counts.totalMagnitude,
            clickCount: counts.clickCount,
            typingCount: counts.typingCount,
            scrollCount: counts.scrollCount,
            navigationCount: counts.navigationCount,
            activationCount: counts.activationCount,
            idleTransitionCount: counts.idleTransitionCount,
            context: context,
            eventIDs: firstEventID == lastEventID ? [firstEventID] : [firstEventID, lastEventID],
            endReason: reason
        )
    }
}

extension ActivityContext {
    var isAgentOneInternalContext: Bool {
        if bundleIdentifier == "life.agentone.desktop" { return true }
        return applicationName?.caseInsensitiveCompare("AgentOne") == .orderedSame
    }

    var isSystemNoiseContext: Bool {
        let bundle = bundleIdentifier?.lowercased() ?? ""
        if ["com.apple.dock", "com.apple.loginwindow", "com.apple.controlcenter"].contains(bundle) {
            return true
        }
        let name = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["windowmanager", "window manager", "程序坞", "loginwindow", "control center", "控制中心"].contains(name)
    }

    var sessionIdentity: String {
        let stableURL = url.map { value -> String in
            guard var parts = URLComponents(url: value, resolvingAgainstBaseURL: false) else {
                return value.absoluteString
            }
            parts.fragment = nil
            return parts.string ?? value.absoluteString
        }
        return [
            bundleIdentifier,
            windowIdentifier,
            stableURL,
            documentPath,
            windowTitle,
            applicationName
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    func belongsToSameSession(as other: ActivityContext) -> Bool {
        if isSensitive || other.isSensitive { return false }
        let pairs: [(String?, String?)] = [
            (bundleIdentifier, other.bundleIdentifier),
            (windowIdentifier, other.windowIdentifier),
            (normalizedSessionURL, other.normalizedSessionURL),
            (documentPath, other.documentPath),
            (windowTitle, other.windowTitle),
            (applicationName, other.applicationName)
        ]
        var compared = 0
        for (lhs, rhs) in pairs {
            guard let lhs = normalizedSessionValue(lhs),
                  let rhs = normalizedSessionValue(rhs) else {
                continue
            }
            compared += 1
            if lhs != rhs { return false }
        }
        return compared > 0
    }

    func mergingRicherValues(from newer: ActivityContext) -> ActivityContext {
        // Accessibility is sampled repeatedly while an activity is in
        // progress. Once the semantic model has converted that raw page text
        // into a diary-quality summary, an ordinary later sample must not
        // overwrite it. A newer model result may still refine an older one.
        let mergedContentSummary: String?
        if hasModelEnrichedSummary && !newer.hasModelEnrichedSummary {
            mergedContentSummary = contentSummary
        } else {
            mergedContentSummary = newer.contentSummary ?? contentSummary
        }
        return ActivityContext(
            applicationName: newer.applicationName ?? applicationName,
            bundleIdentifier: newer.bundleIdentifier ?? bundleIdentifier,
            windowTitle: newer.windowTitle ?? windowTitle,
            windowIdentifier: newer.windowIdentifier ?? windowIdentifier,
            url: newer.url ?? url,
            documentPath: newer.documentPath ?? documentPath,
            contentSummary: mergedContentSummary,
            selectedText: newer.selectedText ?? selectedText,
            submittedText: newer.submittedText ?? submittedText,
            screenText: newer.screenText ?? screenText,
            interactionTarget: newer.interactionTarget ?? interactionTarget,
            contextTransition: newer.contextTransition ?? contextTransition,
            screenshotResourcePath: newer.screenshotResourcePath ?? screenshotResourcePath,
            semanticTags: semanticTags.union(newer.semanticTags),
            isSensitive: isSensitive || newer.isSensitive
        )
    }

    private var normalizedSessionURL: String? {
        guard let url else { return nil }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    private func normalizedSessionValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
