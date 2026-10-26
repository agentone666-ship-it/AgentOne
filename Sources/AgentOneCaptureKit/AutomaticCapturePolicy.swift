import Foundation

/// Persisted user intent takes precedence over automatic launch and wake events.
public struct AutomaticCapturePolicy: Sendable {
    public enum Startup: Equatable, Sendable {
        case inactive
        case paused
        case start(allowPermissionPrompts: Bool)
    }
    public static func startup(enabled: Bool, desired: Bool?, setupAttempted: Bool, demo: Bool) -> Startup {
        guard !demo, enabled else { return .inactive }
        guard desired != false else { return .paused }
        return .start(allowPermissionPrompts: !setupAttempted)
    }
}
