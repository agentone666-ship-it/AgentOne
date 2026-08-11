import Foundation

public enum EvidenceKind: String, Codable, Hashable, Sendable {
    case screenshot
    case pageReference
    case selectedText
    case documentReference
    case taskSceneCard
}

public struct KeyEvidence: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public var kind: EvidenceKind
    public var title: String
    public var summary: String?
    public var localResourcePath: String?
    public var url: URL?
    public var selectedText: String?
    public var submittedText: String?
    public var windowTitle: String?
    public var scrollPosition: Double?
    public var eventID: UUID?
    public var isSensitive: Bool

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        kind: EvidenceKind,
        title: String,
        summary: String? = nil,
        localResourcePath: String? = nil,
        url: URL? = nil,
        selectedText: String? = nil,
        submittedText: String? = nil,
        windowTitle: String? = nil,
        scrollPosition: Double? = nil,
        eventID: UUID? = nil,
        isSensitive: Bool = false
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.kind = kind
        self.title = title
        self.summary = summary
        self.localResourcePath = localResourcePath
        self.url = url
        self.selectedText = selectedText
        self.submittedText = submittedText
        self.windowTitle = windowTitle
        self.scrollPosition = scrollPosition
        self.eventID = eventID
        self.isSensitive = isSensitive
    }
}

public struct ActivityDiaryRecord: Codable, Hashable, Sendable {
    public var event: ActivityEvent
    public var inferredIntentSessionID: UUID?
    public var relevance: Double?
    public var narrative: String
    public var evidenceIDs: [UUID]
    public var session: ActivitySessionSummary?

    public init(
        event: ActivityEvent,
        inferredIntentSessionID: UUID? = nil,
        relevance: Double? = nil,
        narrative: String,
        evidenceIDs: [UUID] = [],
        session: ActivitySessionSummary? = nil
    ) {
        self.event = event
        self.inferredIntentSessionID = inferredIntentSessionID
        self.relevance = relevance
        self.narrative = narrative
        self.evidenceIDs = evidenceIDs
        self.session = session
    }
}

public enum AgentThoughtDisposition: String, Codable, Hashable, Sendable {
    case spoken
    case heldBack
    case postponedForSurprise
    case observationOnly
}

public struct AgentReflection: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public var observation: String
    public var hypothesis: String?
    public var consideredAction: String?
    public var finalAction: String?
    public var disposition: AgentThoughtDisposition
    public var why: String?
    public var uncertainty: Double
    public var relatedEventIDs: [UUID]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        observation: String,
        hypothesis: String? = nil,
        consideredAction: String? = nil,
        finalAction: String? = nil,
        disposition: AgentThoughtDisposition = .observationOnly,
        why: String? = nil,
        uncertainty: Double = 0,
        relatedEventIDs: [UUID] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.observation = observation
        self.hypothesis = hypothesis
        self.consideredAction = consideredAction
        self.finalAction = finalAction
        self.disposition = disposition
        self.why = why
        self.uncertainty = min(max(uncertainty, 0), 1)
        self.relatedEventIDs = relatedEventIDs
    }
}

public struct DiaryCorrection: Codable, Hashable, Sendable {
    public var targetEntryID: UUID
    public var correction: String
    public var suppliedByUser: Bool

    public init(targetEntryID: UUID, correction: String, suppliedByUser: Bool = true) {
        self.targetEntryID = targetEntryID
        self.correction = correction
        self.suppliedByUser = suppliedByUser
    }
}

public struct DiaryVisibilityChange: Codable, Hashable, Sendable {
    public var targetEntryID: UUID
    public var isHidden: Bool
    public var reason: String?

    public init(targetEntryID: UUID, isHidden: Bool, reason: String? = nil) {
        self.targetEntryID = targetEntryID
        self.isHidden = isHidden
        self.reason = reason
    }
}

/// A semantic interpretation that arrived after the raw activity was observed.
///
/// This is intentionally a separate append-only fact instead of a mutation of
/// `ActivityDiaryRecord`. A model may finish after the corresponding activity
/// session has already been persisted, so the diary keeps both the original
/// observation and the later interpretation. Replay folds the latest matching
/// enrichment back into the original activity moment.
public struct ActivityContextEnrichment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var targetEventID: UUID
    public var targetActivityEntryID: UUID?
    public var activityTitle: String
    public var summary: String
    public var context: ActivityContext
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        targetEventID: UUID,
        targetActivityEntryID: UUID? = nil,
        activityTitle: String,
        summary: String,
        context: ActivityContext,
        tags: [String] = []
    ) {
        self.id = id
        self.targetEventID = targetEventID
        self.targetActivityEntryID = targetActivityEntryID
        self.activityTitle = activityTitle
        self.summary = summary
        self.context = context
        self.tags = tags
    }
}

/// A model-produced, user-visible synthesis of one day's semantic Context.
///
/// This is deliberately stored as a new immutable diary fact. A later snapshot
/// can supersede it in the read model without rewriting what the Agent believed
/// earlier in the day.
public struct DailyContextDigest: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var day: String
    public var generatedAt: Date
    public var isFinal: Bool
    public var headline: String
    public var overview: String
    public var highlights: [String]
    public var rhythm: String?
    public var unfinishedThread: String?
    public var agentNote: String
    public var invitation: String?
    public var mood: String
    public var sourceContextCount: Int
    public var evidenceCount: Int
    public var personalizedMemoryCount: Int

    public init(
        id: UUID = UUID(),
        day: String,
        generatedAt: Date = Date(),
        isFinal: Bool = false,
        headline: String,
        overview: String,
        highlights: [String],
        rhythm: String? = nil,
        unfinishedThread: String? = nil,
        agentNote: String,
        invitation: String? = nil,
        mood: String = "curious",
        sourceContextCount: Int,
        evidenceCount: Int,
        personalizedMemoryCount: Int = 0
    ) {
        self.id = id
        self.day = day
        self.generatedAt = generatedAt
        self.isFinal = isFinal
        self.headline = headline
        self.overview = overview
        self.highlights = Array(highlights.prefix(6))
        self.rhythm = rhythm
        self.unfinishedThread = unfinishedThread
        self.agentNote = agentNote
        self.invitation = invitation
        self.mood = mood
        self.sourceContextCount = max(0, sourceContextCount)
        self.evidenceCount = max(0, evidenceCount)
        self.personalizedMemoryCount = max(0, personalizedMemoryCount)
    }
}

public enum ContextEnrichmentApplication: Hashable, Sendable {
    /// The activity is still open. Its eventual immutable activity row will
    /// contain the richer Context, so no second diary fact is necessary.
    case mergedIntoPending
    /// The activity was already immutable. This is the appended semantic fact.
    case appended(DiaryEntry)
    /// No persisted or pending activity can be associated with the target.
    case targetNotFound
    /// Sensitive Context is never persisted as enrichment.
    case rejectedSensitive
}

public enum DiaryEntryPayload: Codable, Hashable, Sendable {
    case activity(ActivityDiaryRecord)
    case contextEnrichment(ActivityContextEnrichment)
    case intentStarted(IntentSession)
    case intentConfirmed(intentSessionID: UUID)
    case driftStarted(DriftEpisode)
    case reminder(AgentPrompt)
    case returnedToIntent(intentSessionID: UUID)
    case feedback(UserFeedback)
    case correction(DiaryCorrection)
    case visibilityChanged(DiaryVisibilityChange)
    case agentReflection(AgentReflection)
    case evidence(KeyEvidence)
    case skillLearned(AgentSkill)
    case daySummary(String)
    case dailyContextDigest(DailyContextDigest)
}

/// Diary entries are immutable facts in an append-only history. Corrections and hiding
/// are themselves new entries; the original record is never rewritten.
public struct DiaryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let payload: DiaryEntryPayload

    public init(id: UUID = UUID(), timestamp: Date = Date(), payload: DiaryEntryPayload) {
        self.id = id
        self.timestamp = timestamp
        self.payload = payload
    }
}

public struct DiaryProjection: Codable, Hashable, Sendable {
    public var visibleEntries: [DiaryEntry]
    public var hiddenEntryIDs: Set<UUID>
    public var correctionsByEntryID: [UUID: [DiaryCorrection]]

    public init(entries: [DiaryEntry]) {
        var hidden: Set<UUID> = []
        var corrections: [UUID: [DiaryCorrection]] = [:]

        for entry in entries.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch entry.payload {
            case .visibilityChanged(let change):
                if change.isHidden {
                    hidden.insert(change.targetEntryID)
                } else {
                    hidden.remove(change.targetEntryID)
                }
            case .correction(let correction):
                corrections[correction.targetEntryID, default: []].append(correction)
            default:
                break
            }
        }

        self.hiddenEntryIDs = hidden
        self.correctionsByEntryID = corrections
        self.visibleEntries = entries.filter { !hidden.contains($0.id) }
    }
}
