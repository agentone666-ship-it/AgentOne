import Foundation

public enum SkillDomain: String, Codable, Hashable, Sendable {
    case intentDetection
    case driftDetection
    case reminderTiming
    case social
    case taskRecovery
    case companionship
}

public struct AgentSkill: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var name: String
    public var domain: SkillDomain
    public var triggerTerms: Set<String>
    public var guidance: String
    public var confidence: Double
    public var sourceEntryIDs: [UUID]
    public var revision: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        name: String,
        domain: SkillDomain,
        triggerTerms: Set<String> = [],
        guidance: String,
        confidence: Double,
        sourceEntryIDs: [UUID] = [],
        revision: Int = 1
    ) {
        self.id = id
        self.createdAt = createdAt
        self.name = name
        self.domain = domain
        self.triggerTerms = triggerTerms
        self.guidance = guidance
        self.confidence = min(max(confidence, 0), 1)
        self.sourceEntryIDs = sourceEntryIDs
        self.revision = revision
    }

    /// A Skill grows from three auditable signals rather than an arbitrary UI
    /// counter: model/user confidence, distinct supporting diary evidence, and
    /// the number of reinforced revisions persisted over time.
    public var completion: Double {
        let distinctEvidenceCount = Set(sourceEntryIDs).count
        let evidenceProgress = min(1, Double(distinctEvidenceCount) / 5)
        let revisionProgress = min(1, Double(max(1, revision)) / 5)
        return min(1, max(0,
            confidence * 0.55
                + evidenceProgress * 0.30
                + revisionProgress * 0.15
        ))
    }

    /// Detail sections unlock at 20-point completion intervals. A newly
    /// learned, reasonably confident Skill normally starts around level 2–3,
    /// so the user can inspect its trigger and guidance immediately while the
    /// evidence trail and mature behavior still have room to grow.
    public var masteryLevel: Int {
        switch completion {
        case ..<0.20: 1
        case ..<0.40: 2
        case ..<0.60: 3
        case ..<0.80: 4
        default: 5
        }
    }
}

public struct SkillExtractor: Sendable {
    public init() {}

    public func extract(
        from feedback: UserFeedback,
        event: ActivityEvent?,
        sourceEntryID: UUID,
        at timestamp: Date
    ) -> AgentSkill? {
        let terms = event.map { TextSemantics.tokens(in: $0.context.searchableText) } ?? []

        switch feedback.kind {
        case .eventWasRelated:
            return AgentSkill(
                createdAt: timestamp,
                name: "Recognize related detours",
                domain: .intentDetection,
                triggerTerms: terms,
                guidance: "Treat contexts with these terms as potentially supporting the active task before calling them a distraction.",
                confidence: 0.62,
                sourceEntryIDs: [sourceEntryID]
            )
        case .eventWasDistraction:
            return AgentSkill(
                createdAt: timestamp,
                name: "Recognize this distraction pattern",
                domain: .driftDetection,
                triggerTerms: terms,
                guidance: "Lower relevance when this context appears without semantic overlap with the active intent.",
                confidence: 0.62,
                sourceEntryIDs: [sourceEntryID]
            )
        case .reminderHelpful:
            return AgentSkill(
                createdAt: timestamp,
                name: "Reuse a helpful reminder rhythm",
                domain: .reminderTiming,
                guidance: "Preserve the reminder timing and gentle modality used in this episode.",
                confidence: 0.7,
                sourceEntryIDs: [sourceEntryID]
            )
        case .reminderTooEarly:
            return AgentSkill(
                createdAt: timestamp,
                name: "Wait longer before asking",
                domain: .reminderTiming,
                guidance: "Increase the drift duration before the first interruption for similar contexts.",
                confidence: 0.7,
                sourceEntryIDs: [sourceEntryID]
            )
        case .reminderTooStrong:
            return AgentSkill(
                createdAt: timestamp,
                name: "Use a softer intervention",
                domain: .reminderTiming,
                guidance: "Prefer creature motion or a curious text bubble over sound or persistent interruption.",
                confidence: 0.72,
                sourceEntryIDs: [sourceEntryID]
            )
        case .intentWasIncorrect, .intentChanged, .freeformCorrection:
            return AgentSkill(
                createdAt: timestamp,
                name: "Learn from an intent correction",
                domain: .intentDetection,
                triggerTerms: terms,
                guidance: "Use the user's correction as higher-priority evidence than the earlier inference.",
                confidence: 0.76,
                sourceEntryIDs: [sourceEntryID]
            )
        }
    }
}

enum TextSemantics {
    static func tokens(in text: String) -> Set<String> {
        let normalized = text.lowercased()
        let components = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(components.filter { $0.count >= 2 })
    }
}
