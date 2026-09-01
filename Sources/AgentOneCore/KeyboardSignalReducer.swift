import Foundation

/// A privacy-preserving description of one physical key-down observation.
///
/// The reducer never receives or stores the character that was typed. The
/// platform layer classifies only the handful of key categories that AgentOne
/// needs for intent inference.
public struct KeyboardObservation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case returnKey
        case deletionKey
        case shortcut(modifierPattern: String)
        case textInput(estimatedCharacterCount: Int)
    }

    public let timestamp: Date
    public let kind: Kind
    public let isAutorepeat: Bool

    public init(timestamp: Date, kind: Kind, isAutorepeat: Bool) {
        self.timestamp = timestamp
        self.kind = kind
        self.isAutorepeat = isAutorepeat
    }
}

public enum ReducedKeyboardSignal: Equatable, Sendable {
    case typingStarted
    case typingProgress(estimatedCharacterCount: Int)
    case returnPressed
    case deletionBurst(repeatCount: Int)
    case shortcut(modifierPattern: String)
}

/// Converts a high-rate stream of read-only keyboard observations into sparse
/// semantic signals. This is intentionally stateful so the macOS event tap can
/// do all coalescing before it schedules any work on AgentOne's main actor.
public struct KeyboardSignalReducer: Sendable {
    private var lastTypingAt: Date?
    private var lastTypingProgressAt: Date?
    private var typingCharactersSinceProgress = 0
    private var recentDeletionCount = 0

    public let typingSessionGap: TimeInterval
    public let typingProgressInterval: TimeInterval

    public init(
        typingSessionGap: TimeInterval = 1.5,
        typingProgressInterval: TimeInterval = 0.75
    ) {
        self.typingSessionGap = typingSessionGap
        self.typingProgressInterval = typingProgressInterval
    }

    public mutating func consume(_ observation: KeyboardObservation) -> [ReducedKeyboardSignal] {
        // macOS emits repeated keyDown events while a key is held. AgentOne has
        // no reason to process those copies: ignoring them prevents backlogs and
        // guarantees one semantic Return signal per physical press.
        guard !observation.isAutorepeat else { return [] }

        switch observation.kind {
        case .returnKey:
            recentDeletionCount = 0
            typingCharactersSinceProgress = 0
            // Return closes the current draft. The very next physical text key
            // must start a fresh typing burst even when it arrives within the
            // normal coalescing gap. Otherwise a short second message can
            // reach Return without refreshing its input Context.
            lastTypingAt = nil
            lastTypingProgressAt = observation.timestamp
            return [.returnPressed]

        case .deletionKey:
            recentDeletionCount += 1
            guard recentDeletionCount >= 3 else { return [] }
            let count = recentDeletionCount
            recentDeletionCount = 0
            return [.deletionBurst(repeatCount: count)]

        case .shortcut(let modifierPattern):
            recentDeletionCount = 0
            return [.shortcut(modifierPattern: modifierPattern)]

        case .textInput(let estimatedCharacterCount):
            let count = max(1, estimatedCharacterCount)
            let startsNewSession = lastTypingAt.map {
                observation.timestamp.timeIntervalSince($0) > typingSessionGap
            } ?? true
            lastTypingAt = observation.timestamp
            recentDeletionCount = 0

            if startsNewSession {
                typingCharactersSinceProgress = count
                lastTypingProgressAt = observation.timestamp
                return [.typingStarted]
            }

            typingCharactersSinceProgress += count
            let elapsed = lastTypingProgressAt.map {
                observation.timestamp.timeIntervalSince($0)
            } ?? typingProgressInterval
            guard elapsed >= typingProgressInterval else { return [] }

            let progress = typingCharactersSinceProgress
            typingCharactersSinceProgress = 0
            lastTypingProgressAt = observation.timestamp
            return [.typingProgress(estimatedCharacterCount: progress)]
        }
    }

    /// Pointer focus changes and application switches delimit typing bursts
    /// even if they happen faster than `typingSessionGap`.
    public mutating func resetTypingSession() {
        lastTypingAt = nil
        lastTypingProgressAt = nil
        typingCharactersSinceProgress = 0
        recentDeletionCount = 0
    }
}
