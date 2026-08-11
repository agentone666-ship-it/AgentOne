import AppKit
import Foundation

struct PassivePointerSignal: Sendable {
    enum Kind: Sendable {
        case primaryClick
        case secondaryClick
        case scroll
    }

    let timestamp: Date
    let kind: Kind
    let magnitude: Double
    let metadata: [String: String]
}

/// Converts AppKit's passive global mouse copies into bounded-rate immutable
/// observations before anything is scheduled on the main actor.
final class PassivePointerEventSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastScrollUptime = -Double.infinity
    private var lastScrollDirection: String?
    private let scrollSampleInterval: TimeInterval

    init(scrollSampleInterval: TimeInterval = 0.75) {
        self.scrollSampleInterval = scrollSampleInterval
    }

    func sample(_ event: NSEvent) -> PassivePointerSignal? {
        switch event.type {
        case .leftMouseDown:
            return clickSignal(kind: .primaryClick)
        case .rightMouseDown:
            return clickSignal(kind: .secondaryClick)
        case .scrollWheel:
            return scrollSignal(event)
        default:
            return nil
        }
    }

    private func clickSignal(kind: PassivePointerSignal.Kind) -> PassivePointerSignal {
        let point = NSEvent.mouseLocation
        return PassivePointerSignal(
            timestamp: Date(),
            kind: kind,
            magnitude: 1,
            metadata: [
                "screenX": String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), point.x),
                "screenY": String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), point.y)
            ]
        )
    }

    private func scrollSignal(_ event: NSEvent) -> PassivePointerSignal? {
        let direction = event.scrollingDeltaY >= 0 ? "up" : "down"
        let uptime = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let shouldForward = direction != lastScrollDirection
            || uptime - lastScrollUptime >= scrollSampleInterval
        if shouldForward {
            lastScrollUptime = uptime
            lastScrollDirection = direction
        }
        lock.unlock()

        guard shouldForward else { return nil }
        return PassivePointerSignal(
            timestamp: Date(),
            kind: .scroll,
            magnitude: abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY),
            metadata: [
                "direction": direction,
                "phase": Self.scrollPhaseName(event.phase, momentumPhase: event.momentumPhase)
            ]
        )
    }

    private static func scrollPhaseName(
        _ phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) -> String {
        if momentumPhase != [] { return "momentum" }
        if phase.contains(.began) { return "began" }
        if phase.contains(.changed) { return "changed" }
        if phase.contains(.ended) { return "ended" }
        return "unknown"
    }
}
