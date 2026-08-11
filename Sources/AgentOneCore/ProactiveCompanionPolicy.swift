import Foundation

public enum ProactiveCompanionOpportunity: String, Codable, Hashable, Sendable {
    case inviteDailyReview
}

/// Pure decision policy for when LUMA may initiate a lightweight interaction.
/// UI and timers remain native-app concerns; this type keeps the interruption
/// boundary deterministic and directly testable.
public struct ProactiveCompanionSnapshot: Hashable, Sendable {
    public var now: Date
    public var secondsSinceLastInteraction: TimeInterval
    public var leisureContextDuration: TimeInterval
    public var hasDailyDigest: Bool
    public var alreadyInvitedForDigest: Bool
    public var invitationsEnabled: Bool
    public var isChatOpen: Bool
    public var hasVisiblePrompt: Bool
    public var isSensitiveContext: Bool
    public var lastInvitationAt: Date?
    public var timeZone: TimeZone

    public init(
        now: Date = Date(),
        secondsSinceLastInteraction: TimeInterval,
        leisureContextDuration: TimeInterval = 0,
        hasDailyDigest: Bool,
        alreadyInvitedForDigest: Bool,
        invitationsEnabled: Bool = true,
        isChatOpen: Bool = false,
        hasVisiblePrompt: Bool = false,
        isSensitiveContext: Bool = false,
        lastInvitationAt: Date? = nil,
        timeZone: TimeZone = .current
    ) {
        self.now = now
        self.secondsSinceLastInteraction = max(0, secondsSinceLastInteraction)
        self.leisureContextDuration = max(0, leisureContextDuration)
        self.hasDailyDigest = hasDailyDigest
        self.alreadyInvitedForDigest = alreadyInvitedForDigest
        self.invitationsEnabled = invitationsEnabled
        self.isChatOpen = isChatOpen
        self.hasVisiblePrompt = hasVisiblePrompt
        self.isSensitiveContext = isSensitiveContext
        self.lastInvitationAt = lastInvitationAt
        self.timeZone = timeZone
    }
}

public struct ProactiveCompanionPolicy: Sendable {
    public var quietCooldown: TimeInterval
    public var ordinaryIdleThreshold: TimeInterval
    public var eveningIdleThreshold: TimeInterval
    public var leisureContextThreshold: TimeInterval

    public init(
        quietCooldown: TimeInterval = 6 * 60 * 60,
        ordinaryIdleThreshold: TimeInterval = 90,
        eveningIdleThreshold: TimeInterval = 45,
        leisureContextThreshold: TimeInterval = 5 * 60
    ) {
        self.quietCooldown = max(0, quietCooldown)
        self.ordinaryIdleThreshold = max(0, ordinaryIdleThreshold)
        self.eveningIdleThreshold = max(0, eveningIdleThreshold)
        self.leisureContextThreshold = max(0, leisureContextThreshold)
    }

    public func opportunity(
        for snapshot: ProactiveCompanionSnapshot
    ) -> ProactiveCompanionOpportunity? {
        guard snapshot.invitationsEnabled,
              snapshot.hasDailyDigest,
              !snapshot.alreadyInvitedForDigest,
              !snapshot.isChatOpen,
              !snapshot.hasVisiblePrompt,
              !snapshot.isSensitiveContext else {
            return nil
        }
        if let last = snapshot.lastInvitationAt,
           snapshot.now.timeIntervalSince(last) < quietCooldown {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = snapshot.timeZone
        let hour = calendar.component(.hour, from: snapshot.now)
        let isEvening = hour >= 19 || hour < 2
        let idleThreshold = isEvening
            ? eveningIdleThreshold
            : ordinaryIdleThreshold

        guard snapshot.secondsSinceLastInteraction >= idleThreshold
                || snapshot.leisureContextDuration >= leisureContextThreshold else {
            return nil
        }
        return .inviteDailyReview
    }
}
