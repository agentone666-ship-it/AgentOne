import AppKit
import Foundation

public struct PassivePointerSignal: Sendable {
    public enum Kind: Sendable {
        case primaryClick
        case secondaryClick
        case scroll
    }

    public let timestamp: Date
    public let kind: Kind
    public let magnitude: Double
    public let metadata: [String: String]
}

/// Converts AppKit's passive global mouse copies into bounded-rate immutable
/// observations before anything is scheduled on the main actor.
public final class PassivePointerEventSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastScrollUptime = -Double.infinity
    private var lastScrollDirection: String?
    private let scrollSampleInterval: TimeInterval

    public init(scrollSampleInterval: TimeInterval = 0.75) {
        self.scrollSampleInterval = scrollSampleInterval
    }

    public func sample(_ event: NSEvent) -> PassivePointerSignal? {
        switch event.type {
        case .leftMouseDown:
            return clickSignal(event, kind: .primaryClick)
        case .rightMouseDown:
            return clickSignal(event, kind: .secondaryClick)
        case .scrollWheel:
            return scrollSignal(event)
        default:
            return nil
        }
    }

    private func clickSignal(
        _ event: NSEvent,
        kind: PassivePointerSignal.Kind
    ) -> PassivePointerSignal {
        // CGEvent locations share the top-left global Quartz space used by
        // ScreenCaptureKit and Accessibility frames. NSEvent.mouseLocation is
        // bottom-left AppKit space; storing it unchanged was the reason a click
        // in a bottom composer could anchor a crop near the top of the window.
        let point = event.cgEvent?.location ?? Self.quartzPoint(fromAppKit: NSEvent.mouseLocation)
        return PassivePointerSignal(
            timestamp: Date(),
            kind: kind,
            magnitude: 1,
            metadata: [
                "screenX": String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), point.x),
                "screenY": String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), point.y),
                "coordinateSpace": "quartz-top-left"
            ]
        )
    }

    private static func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(
            x: point.x,
            y: mainDisplayBounds.minY + mainDisplayBounds.maxY - point.y
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
