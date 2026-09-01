import CoreGraphics
import Foundation

/// A composer location that has already been validated by a real typing burst.
///
/// The location is stored relative to the focused window rather than as an
/// absolute screen point. This lets a continuous chat session survive window
/// moves and resizes while still being invalidated by the runtime whenever the
/// user clicks elsewhere or activates another application.
public struct ReturnInputSessionAnchor: Equatable, Sendable {
    public let normalizedX: Double
    public let normalizedY: Double
    public let bundleIdentifier: String?
    public let windowIdentifier: String?
    public let capturedAt: Date

    public init?(
        point: CGPoint,
        bundleIdentifier: String?,
        windowIdentifier: String?,
        windowFrame: CGRect,
        capturedAt: Date
    ) {
        guard windowFrame.width > 1,
              windowFrame.height > 1,
              windowFrame.insetBy(dx: -4, dy: -4).contains(point) else {
            return nil
        }
        normalizedX = (point.x - windowFrame.minX) / windowFrame.width
        normalizedY = (point.y - windowFrame.minY) / windowFrame.height
        self.bundleIdentifier = Self.normalizedIdentity(bundleIdentifier)
        self.windowIdentifier = Self.normalizedIdentity(windowIdentifier)
        self.capturedAt = capturedAt
    }

    /// Resolves the prior composer point into the current window and validates
    /// it against current AX geometry. Known chat apps can reuse the strict
    /// bottom-composer zone when Electron exposes no editable AX control;
    /// generic apps still require concrete focused/caret geometry.
    public func resolvedPoint(
        bundleIdentifier: String?,
        windowIdentifier: String?,
        windowFrame: CGRect,
        focusedFrame: CGRect?,
        caretFrame: CGRect?,
        profile: ReturnInputComposerProfile,
        at timestamp: Date,
        maximumAge: TimeInterval = 12 * 60 * 60
    ) -> CGPoint? {
        let age = timestamp.timeIntervalSince(capturedAt)
        guard age >= -1,
              age <= maximumAge,
              windowFrame.width > 1,
              windowFrame.height > 1 else {
            return nil
        }

        let currentBundle = Self.normalizedIdentity(bundleIdentifier)
        if let storedBundle = self.bundleIdentifier,
           storedBundle != currentBundle {
            return nil
        }
        let currentWindow = Self.normalizedIdentity(windowIdentifier)
        if let storedWindow = self.windowIdentifier,
           let currentWindow,
           storedWindow != currentWindow {
            return nil
        }

        let point = CGPoint(
            x: windowFrame.minX + windowFrame.width * normalizedX,
            y: windowFrame.minY + windowFrame.height * normalizedY
        )
        guard profile.validatesTypingAnchor(
            point,
            focusedFrame: focusedFrame,
            caretFrame: caretFrame,
            in: windowFrame
        ) else {
            return nil
        }
        return point
    }

    private static func normalizedIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
