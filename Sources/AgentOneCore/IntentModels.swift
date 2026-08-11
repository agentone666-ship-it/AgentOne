import Foundation

public enum IntentOrigin: String, Codable, Hashable, Sendable {
    case inferred
    case userConfirmed
    case userProvided
    case corrected
}

public enum IntentSessionState: String, Codable, Hashable, Sendable {
    case proposed
    case active
    case paused
    case completed
    case abandoned
}

public struct IntentSession: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var title: String
    public var summary: String
    public var origin: IntentOrigin
    public var confidence: Double
    public var state: IntentSessionState
    public var contextTerms: Set<String>
    public var supportingEventIDs: [UUID]

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        title: String,
        summary: String,
        origin: IntentOrigin = .inferred,
        confidence: Double,
        state: IntentSessionState = .proposed,
        contextTerms: Set<String> = [],
        supportingEventIDs: [UUID] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.summary = summary
        self.origin = origin
        self.confidence = min(max(confidence, 0), 1)
        self.state = state
        self.contextTerms = contextTerms
        self.supportingEventIDs = supportingEventIDs
    }
}

extension IntentSession {
    /// Drift reminders need a real task anchor. A placeholder inferred from an
    /// empty window title ("Current activity") is useful as transient UI state,
    /// but comparing every later app against it creates false drift episodes.
    var canAnchorDriftEvaluation: Bool {
        if origin != .inferred { return true }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let placeholders: Set<String> = ["", "current activity", "当前活动"]
        return state == .active
            && !placeholders.contains(normalized)
            && !contextTerms.isEmpty
    }

    var isInferredPlaceholder: Bool {
        guard origin == .inferred else { return false }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "current activity" || normalized == "当前活动"
    }
}

public enum ReminderModality: String, Codable, Hashable, Sendable {
    case creatureMotion
    case textBubble
    case persistentBubble
    case sound
    case haptic
}

public struct ReminderStage: Codable, Hashable, Sendable {
    public var level: Int
    public var after: TimeInterval
    public var modalities: Set<ReminderModality>

    public init(level: Int, after: TimeInterval, modalities: Set<ReminderModality>) {
        self.level = level
        self.after = max(0, after)
        self.modalities = modalities
    }
}

public struct DriftConfiguration: Codable, Hashable, Sendable {
    public var relevanceThreshold: Double
    public var uncertaintyBand: ClosedRange<Double>
    public var stages: [ReminderStage]

    public init(
        relevanceThreshold: Double = 0.3,
        uncertaintyBand: ClosedRange<Double> = 0.3...0.48,
        stages: [ReminderStage] = [
            ReminderStage(level: 1, after: 60, modalities: [.creatureMotion]),
            ReminderStage(level: 2, after: 180, modalities: [.creatureMotion, .textBubble]),
            ReminderStage(level: 3, after: 300, modalities: [.persistentBubble])
        ]
    ) {
        self.relevanceThreshold = min(max(relevanceThreshold, 0), 1)
        self.uncertaintyBand = uncertaintyBand
        self.stages = stages.sorted { $0.after < $1.after }
    }
}

public struct DriftEpisode: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let intentSessionID: UUID
    public let beganAt: Date
    public var lastObservedAt: Date
    public var endedAt: Date?
    public var minimumRelevance: Double
    public var emittedLevels: Set<Int>
    public var eventIDs: [UUID]

    public init(
        id: UUID = UUID(),
        intentSessionID: UUID,
        beganAt: Date,
        lastObservedAt: Date,
        minimumRelevance: Double,
        emittedLevels: Set<Int> = [],
        eventIDs: [UUID] = []
    ) {
        self.id = id
        self.intentSessionID = intentSessionID
        self.beganAt = beganAt
        self.lastObservedAt = lastObservedAt
        self.minimumRelevance = minimumRelevance
        self.emittedLevels = emittedLevels
        self.eventIDs = eventIDs
    }
}

public enum AgentPrompt: Codable, Hashable, Sendable {
    case curiousQuestion(text: String)
    case reminder(stage: ReminderStage, text: String, canReturn: Bool)
    case returnedToIntent(intentSessionID: UUID)
}

public enum UserFeedbackKind: Codable, Hashable, Sendable {
    case eventWasRelated
    case eventWasDistraction
    case intentWasIncorrect(correctedTitle: String, correctedSummary: String)
    case intentChanged(title: String, summary: String)
    case reminderHelpful
    case reminderTooEarly
    case reminderTooStrong
    case freeformCorrection(String)
}

public struct UserFeedback: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public var kind: UserFeedbackKind
    public var eventID: UUID?
    public var intentSessionID: UUID?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: UserFeedbackKind,
        eventID: UUID? = nil,
        intentSessionID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.eventID = eventID
        self.intentSessionID = intentSessionID
    }
}

public struct LearnedRelevanceProfile: Codable, Hashable, Sendable {
    public var relevantTerms: [String: Double]
    public var distractingTerms: [String: Double]
    public var reminderTimingMultiplier: Double

    public init(
        relevantTerms: [String: Double] = [:],
        distractingTerms: [String: Double] = [:],
        reminderTimingMultiplier: Double = 1
    ) {
        self.relevantTerms = relevantTerms
        self.distractingTerms = distractingTerms
        self.reminderTimingMultiplier = reminderTimingMultiplier
    }
}
