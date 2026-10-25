import AppKit
import SwiftUI

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// AppKit owns the outer window size. SwiftUI's initial intrinsic size must
/// never become the panel's minimum/maximum size after the island collapses.
@MainActor final class IslandWindowController {
    let panel: NSPanel
    private let container: NSView
    private let hostingView: NSHostingView<AnyView>

    init(content: AnyView) {
        _ = NSApplication.shared
        let panel = IslandPanel(contentRect: .zero,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        self.panel = panel

        container = NSView(frame: .zero)
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
    }

    func show(expanded: Bool, screen: NSScreen? = NSScreen.main) {
        position(expanded: expanded,screen: screen)
        panel.orderFrontRegardless()
    }

    func position(expanded: Bool, screen: NSScreen? = NSScreen.main) {
        guard let screen else { return }
        let size = NSSize(width: expanded ? 420 : 240,height: expanded ? min(560,screen.visibleFrame.height - 20) : 42)
        panel.setFrame(NSRect(x: screen.visibleFrame.midX-size.width/2,y: screen.visibleFrame.maxY-size.height-6,width: size.width,height: size.height),display: true,animate: false)
        container.layoutSubtreeIfNeeded()
    }
}
