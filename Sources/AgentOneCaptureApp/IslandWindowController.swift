import AppKit
import SwiftUI

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class IslandContainerView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// One screen-space geometry for the hardware notch, window and hover target.
struct IslandGeometry {
    let frame: NSRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var isNotched: Bool { notchHeight > 0 }
    var compactSize: NSSize { NSSize(width: isNotched ? notchWidth + 104 : 232, height: isNotched ? notchHeight : 38) }
    var expandedSize: NSSize { NSSize(width: 480, height: min(456 + notchHeight, frame.height - 70)) }
    var top: CGFloat { frame.maxY - (isNotched ? 0 : 7) }
    func window(expanded: Bool) -> NSRect {
        let size = expanded ? expandedSize : compactSize
        return NSRect(x: floor(frame.midX - size.width / 2), y: top - size.height, width: size.width, height: size.height)
    }
    var activationRect: NSRect {
        // The physical camera cutout itself is included, not just our visible wings.
        window(expanded: false)
    }
    init(frame: NSRect, notchWidth: CGFloat = 0, notchHeight: CGFloat = 0) {
        self.frame = frame; self.notchWidth = notchWidth; self.notchHeight = notchHeight
    }
    init(screen: NSScreen) {
        notchHeight = screen.safeAreaInsets.top
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, notchHeight > 0 {
            notchWidth = right.minX - left.maxX
        } else { notchWidth = 0 }
        frame = notchHeight > 0 ? screen.frame : screen.visibleFrame
    }
}

/// Debounced pointer transitions, independent of events swallowed by the hardware notch.
struct IslandHoverState {
    private var entered: TimeInterval?
    private var exited: TimeInterval?
    mutating func update(inside: Bool, expanded: Bool, protected: Bool, now: TimeInterval) -> Bool? {
        if inside {
            exited = nil
            if entered == nil { entered = now }
            if !expanded, now - (entered ?? now) >= 0.16 { return true }
        } else {
            entered = nil
            if protected { exited = nil; return nil }
            if exited == nil { exited = now }
            if expanded, now - (exited ?? now) >= 0.6 { return false }
        }
        return nil
    }
    mutating func reset() { entered = nil; exited = nil }
}

/// AppKit owns window size; SwiftUI never constrains the panel to its compact size.
@MainActor final class IslandWindowController {
    let panel: NSPanel
    private let container: NSView
    private let hostingView: NSHostingView<AnyView>
    private var timer: Timer?
    private var hover = IslandHoverState()
    private(set) var expanded = false
    var pinned = false
    var onExpansionRequested: ((Bool) -> Void)?
    var onGeometryChanged: ((IslandGeometry) -> Void)?
    private var geometry: IslandGeometry?
    private var holdUntil: TimeInterval = 0
    private var requiresPointerExit = false
    static var targetScreen: NSScreen? { NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main }

    init(content: AnyView) {
        _ = NSApplication.shared
        let panel = IslandPanel(contentRect: .zero,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        self.panel = panel
        container = IslandContainerView(frame: .zero)
        container.autoresizingMask = [.width,.height]
        hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container
        // Hovering must not put keyboard focus into the first text field.
        panel.initialFirstResponder = container
        panel.makeFirstResponder(container)
    }

    func startHoverMonitoring() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.08,repeats: true) { [weak self] _ in
            Task { @MainActor in self?.samplePointer() }
        }
        self.timer = timer
        RunLoop.main.add(timer,forMode: .common)
    }
    func stopHoverMonitoring() { timer?.invalidate(); timer = nil }

    func samplePointer(at point: NSPoint = NSEvent.mouseLocation, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard panel.isVisible, let geometry else { return }
        let inside = expanded ? panel.frame.insetBy(dx: -8,dy: -6).contains(point) : geometry.activationRect.contains(point)
        if requiresPointerExit {
            if inside { return }
            requiresPointerExit = false
            hover.reset()
        }
        let editing = panel.isKeyWindow && panel.firstResponder is NSTextView
        let protected = pinned || editing || NSApp.modalWindow != nil || now < holdUntil
        if let requested = hover.update(inside: inside,expanded: expanded,protected: protected,now: now) {
            position(expanded: requested,animated: true)
            onExpansionRequested?(requested)
        }
    }

    func show(expanded: Bool, screen: NSScreen? = IslandWindowController.targetScreen) {
        // Explicit opening also serves keyboard/accessibility navigation; hover keeps its 600 ms exit delay.
        holdUntil = expanded ? ProcessInfo.processInfo.systemUptime + 8 : 0
        hover.reset()
        position(expanded: expanded,screen: screen)
        panel.orderFrontRegardless()
    }

    func position(expanded: Bool, screen: NSScreen? = IslandWindowController.targetScreen, animated: Bool = false) {
        guard let screen else { return }
        let geometry = IslandGeometry(screen: screen)
        self.geometry = geometry
        if self.expanded != expanded { hover.reset() }
        if self.expanded && !expanded && geometry.activationRect.contains(NSEvent.mouseLocation) { requiresPointerExit = true }
        self.expanded = expanded
        onGeometryChanged?(geometry)
        let target = geometry.window(expanded: expanded)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target,display: true)
            }
        } else { panel.setFrame(target,display: true) }
        container.layoutSubtreeIfNeeded()
    }
}
