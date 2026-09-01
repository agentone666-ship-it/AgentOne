import AppKit
import SwiftUI

/// App 根入口持有一个实例即可。控制器提供非激活、跨桌面、可拖动的常驻数字生命浮窗。
@MainActor
final class FloatingCompanionController: ObservableObject {
    @Published private(set) var isVisible = false
    @Published var mood: AgentMood = .observing {
        didSet { applyMoodToDigitalLife() }
    }

    let life = DigitalLifeController(state: .focused)
    let chat = AgentChatController()

    private var panel: NSPanel?
    private var contentContainer: NSView?
    private var hostingView: NSHostingView<DigitalLifeFloatingContent>?
    private var promptPlacement = DigitalLifePanelPlacement()
    private var dragStartPointer: NSPoint?
    private var dragStartOrigin: NSPoint?

    private enum Layout {
        // These dimensions tightly wrap the 126pt life, its 4pt local padding and the panel's
        // 10pt outer padding. Keeping the clear panel close to visible content prevents it from
        // stealing clicks from the app underneath.
        static let compactSize = NSSize(width: 154, height: 154)
        static let lifeHitSize: CGFloat = 134
        static let promptCardWidth: CGFloat = 258
        static let promptSpacing: CGFloat = 4
        static let outerPadding: CGFloat = 10
        static let promptedWidth: CGFloat = 416
        static let promptedMinimumHeight: CGFloat = 190
        static let promptedMaximumHeight: CGFloat = 340
        static let chatCardWidth: CGFloat = 364
        static let chatCardHeight: CGFloat = 450
        static let chatWidth: CGFloat = 522
        static let chatHeight: CGFloat = 470
        static let screenInset: CGFloat = 12
        static let savedXKey = "AgentOne.FloatingCompanion.originX"
        static let savedYKey = "AgentOne.FloatingCompanion.originY"
    }

    init() {
        chat.observeVisibility { [weak self] isOpen in
            guard let self else { return }
            if isOpen {
                self.life.clearPrompt()
                self.life.transition(to: .curious)
                self.show()
                self.updatePanelSize(animated: true)
                // While chatting, let the panel activate the app so the IME
                // candidate window anchors to our key window. A nonactivating
                // panel leaves the IME attached to the previously active app,
                // whose stacking puts the candidate bar behind this panel.
                self.panel?.styleMask.remove(.nonactivatingPanel)
                self.panel?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                self.life.settle()
                self.panel?.styleMask.insert(.nonactivatingPanel)
                self.updatePanelSize(animated: true)
            }
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        updatePanelSize(animated: panel.isVisible)
        panel.orderFrontRegardless()
        (panel as? CompanionPanel)?.refreshMousePassThrough()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func stop() {
        (panel as? CompanionPanel)?.stopMousePassThroughMonitoring()
        panel?.orderOut(nil)
        isVisible = false
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func toggleChat() {
        chat.toggle()
    }

    func openChat() {
        chat.open()
    }

    func ask(_ text: String, mood: AgentMood = .curious) {
        self.mood = mood
        life.becomeCurious(about: text)
        show()
    }

    func clearMessage() {
        life.clearPrompt()
        life.settle()
        updatePanelSize(animated: true)
    }

    func remindAboutDistraction(level: Int, taskName: String?) {
        life.currentTaskName = taskName
        life.remindAboutDistraction(level: level)
        show()
    }

    func showReturnCard(taskName: String, note: String?, level: Int) {
        life.showReturnCard(taskName: taskName, note: note, level: level)
        show()
    }

    func inviteToReview(title: String, detail: String?) {
        mood = .curious
        life.inviteToReflection(title: title, detail: detail)
        show()
    }

    private func makePanel() -> NSPanel {
        let panel = CompanionPanel(
            // Always restore the life itself first. A pending prompt expands from that stable
            // compact anchor before the still-hidden panel is ordered onscreen.
            contentRect: NSRect(origin: .zero, size: Layout.compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        // The panel lives outside the main window scene, so it does not inherit the
        // app's forced dark scheme. Pin it explicitly, otherwise semantic colors
        // (.primary text, .ultraThinMaterial) follow the light system appearance
        // and black text lands on our dark surfaces.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.worksWhenModal = true
        panel.isExcludedFromWindowsMenu = true
        // Dragging is intentionally limited to the life itself. Treating the clear window
        // background as draggable would make its otherwise invisible pixels swallow clicks.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .none
            : .utilityWindow
        // Keep the AppKit window size independent from SwiftUI's intrinsic content size. Using
        // NSHostingView as the panel's contentView made AppKit keep the initial 154pt compact
        // proposal even after the borderless panel expanded for Chat. A neutral container owns
        // the window bounds and explicit edge constraints give SwiftUI the current proposal.
        let contentContainer = NSView(frame: NSRect(origin: .zero, size: Layout.compactSize))
        contentContainer.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(rootView: floatingView)
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        self.contentContainer = contentContainer
        self.hostingView = hostingView
        panel.contentView = contentContainer
        panel.interactivePointProvider = { [weak self, weak panel] point in
            guard let self, let panel else { return false }
            return self.isInteractivePoint(point, in: panel)
        }
        panel.startMousePassThroughMonitoring()
        restoreOrPosition(panel)
        return panel
    }

    private var floatingView: DigitalLifeFloatingContent {
        DigitalLifeFloatingContent(
            controller: life,
            chat: chat,
            promptPlacement: promptPlacement,
            onAction: { [weak self] action in
                guard let self else { return }
                switch action {
                case .returnToTask:
                    self.life.celebrate()
                    NotificationCenter.default.post(
                        name: .agentOneRequestedReturnToTask,
                        object: self,
                        userInfo: self.currentTaskContext
                    )
                case .changeIntention:
                    self.life.rest()
                    NotificationCenter.default.post(
                        name: .agentOneReportedIntentionChange,
                        object: self,
                        userInfo: self.currentTaskContext
                    )
                case .openJournal:
                    NotificationCenter.default.post(name: .agentOneRequestedOpenMainWindow, object: nil)
                case .answerCuriosity:
                    self.openChat()
                case .touched:
                    self.toggleChat()
                case .dismissPrompt:
                    self.life.settle()
                }
            },
            onPromptVisibilityChange: { [weak self] hasPrompt in
                guard hasPrompt || self?.chat.isOpen == false else { return }
                self?.updatePanelSize(animated: true)
            },
            onDragChanged: { [weak self] in
                self?.continueDragging()
            },
            onDragEnded: { [weak self] in
                self?.finishDragging()
            }
        )
    }

    private func applyMoodToDigitalLife() {
        // A spoken prompt is part of LUMA's current turn. Model/runtime mood updates can
        // arrive immediately after the prompt is installed; transitioning with the
        // default `prompt: nil` here used to erase that turn before the user could see it.
        // Let the explicit prompt actions decide when the turn is finished.
        guard life.prompt == nil else { return }
        switch mood {
        case .focused, .observing:
            life.settle()
        case .curious:
            life.transition(to: .curious)
        case .resting:
            life.rest()
        case .delighted:
            life.celebrate()
        }
    }

    private var currentTaskContext: [AnyHashable: Any]? {
        guard let taskName = life.currentTaskName, !taskName.isEmpty else { return nil }
        var context: [AnyHashable: Any] = [
            AgentOneCompanionContextKey.taskName: taskName,
            AgentOneCompanionContextKey.taskSceneReference: "task:\(taskName)"
        ]
        if let note = life.currentTaskNote, !note.isEmpty {
            context[AgentOneCompanionContextKey.taskNote] = note
        }
        return context
    }

    private func updatePanelSize(animated: Bool, preferredScreen: NSScreen? = nil) {
        guard let panel else { return }
        let lifeFrame = compactLifeFrame(in: panel)
        let targetScreen = preferredScreen ?? screen(withLargestIntersection: lifeFrame) ?? panel.screen
        let targetSize = targetPanelSize()

        if chat.isOpen || life.prompt != nil {
            let newPlacement = placement(for: lifeFrame, targetSize: targetSize, screen: targetScreen)
            if newPlacement != promptPlacement {
                promptPlacement = newPlacement
                hostingView?.rootView = floatingView
            }
        }

        // Pin the life to one screen corner while the speech bubble grows into the side with room.
        // The window changes size, but the visible creature keeps the same screen coordinate.
        let targetX: CGFloat = switch promptPlacement.horizontal {
        case .promptLeading: lifeFrame.maxX - targetSize.width
        case .promptTrailing: lifeFrame.minX
        }
        let targetY: CGFloat = switch promptPlacement.vertical {
        case .bottomAnchored: lifeFrame.minY
        case .topAnchored: lifeFrame.maxY - targetSize.height
        }
        let targetFrame = NSRect(
            x: targetX,
            y: targetY,
            width: targetSize.width,
            height: targetSize.height
        )
        panel.setFrame(
            clampedFrame(targetFrame, preferredScreen: targetScreen),
            display: true,
            animate: animated
                && panel.isVisible
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        // Force one layout pass after the animated/non-animated frame update. The hosting view
        // is pinned to this container, so its SwiftUI root receives the real panel size rather
        // than the compact life form's old intrinsic width.
        let contentSize = panel.contentLayoutRect.size
        contentContainer?.frame = NSRect(origin: .zero, size: contentSize)
        hostingView?.invalidateIntrinsicContentSize()
        contentContainer?.needsLayout = true
        contentContainer?.layoutSubtreeIfNeeded()
        (panel as? CompanionPanel)?.refreshMousePassThrough()
    }

    private func targetPanelSize() -> NSSize {
        if chat.isOpen {
            return NSSize(width: Layout.chatWidth, height: Layout.chatHeight)
        }
        guard let prompt = life.prompt else { return Layout.compactSize }
        let cardHeight = promptCardHeight(prompt)
        let height = min(
            max(cardHeight + 20, Layout.promptedMinimumHeight),
            Layout.promptedMaximumHeight
        )
        return NSSize(width: Layout.promptedWidth, height: height)
    }

    private func promptCardHeight(_ prompt: DigitalLifePrompt) -> CGFloat {
        let textWidth: CGFloat = 210
        let titleHeight = measuredHeight(
            prompt.title,
            width: textWidth,
            font: .systemFont(ofSize: 14, weight: .semibold)
        )
        let detailHeight = prompt.detail.map {
            measuredHeight($0, width: textWidth, font: .systemFont(ofSize: 11.5)) + 5
        } ?? 0
        let textHeight = min(max(titleHeight + detailHeight, 20), 220)
        let hasActions = prompt.primaryActionTitle != nil || prompt.secondaryActionTitle != nil
        return 28 + textHeight + (hasActions ? 41 : 0)
    }

    private func isInteractivePoint(_ point: NSPoint, in panel: NSPanel) -> Bool {
        let lifeOrigin = NSPoint(
            x: (chat.isOpen || life.prompt != nil) && promptPlacement.horizontal == .promptLeading
                ? panel.frame.width - Layout.outerPadding - Layout.lifeHitSize
                : Layout.outerPadding,
            y: promptPlacement.vertical == .bottomAnchored
                ? Layout.outerPadding
                : panel.frame.height - Layout.outerPadding - Layout.lifeHitSize
        )
        let lifeCenter = NSPoint(
            x: lifeOrigin.x + Layout.lifeHitSize / 2,
            y: lifeOrigin.y + Layout.lifeHitSize / 2
        )
        let deltaX = point.x - lifeCenter.x
        let deltaY = point.y - lifeCenter.y
        let lifeRadius = Layout.lifeHitSize / 2
        if deltaX * deltaX + deltaY * deltaY <= lifeRadius * lifeRadius {
            return true
        }

        if chat.isOpen {
            let chatOrigin = NSPoint(
                x: promptPlacement.horizontal == .promptLeading
                    ? Layout.outerPadding
                    : Layout.outerPadding + Layout.lifeHitSize + Layout.promptSpacing,
                y: promptPlacement.vertical == .bottomAnchored
                    ? Layout.outerPadding
                    : panel.frame.height - Layout.outerPadding - Layout.chatCardHeight
            )
            return NSRect(
                origin: chatOrigin,
                size: NSSize(width: Layout.chatCardWidth, height: Layout.chatCardHeight)
            ).contains(point)
        }

        guard let prompt = life.prompt else { return false }
        let cardHeight = min(
            promptCardHeight(prompt),
            panel.frame.height - Layout.outerPadding * 2
        )
        let promptOrigin = NSPoint(
            x: promptPlacement.horizontal == .promptLeading
                ? Layout.outerPadding
                : Layout.outerPadding + Layout.lifeHitSize + Layout.promptSpacing,
            y: promptPlacement.vertical == .bottomAnchored
                ? Layout.outerPadding
                : panel.frame.height - Layout.outerPadding - cardHeight
        )
        return NSRect(
            origin: promptOrigin,
            size: NSSize(width: Layout.promptCardWidth, height: cardHeight)
        ).contains(point)
    }

    private func measuredHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(bounds.height)
    }

    private func continueDragging() {
        guard let panel else { return }
        (panel as? CompanionPanel)?.capturesMouseInteraction = true
        let pointer = NSEvent.mouseLocation
        if dragStartPointer == nil {
            dragStartPointer = pointer
            dragStartOrigin = panel.frame.origin
        }
        guard let startPointer = dragStartPointer, let startOrigin = dragStartOrigin else { return }

        let proposedFrame = NSRect(
            origin: NSPoint(
                x: startOrigin.x + pointer.x - startPointer.x,
                y: startOrigin.y + pointer.y - startPointer.y
            ),
            size: panel.frame.size
        )
        // Follow the pointer without changing screen ownership mid-gesture. Clamping at the seam
        // made a wide prompt jump hundreds of points as soon as the pointer entered a new display.
        panel.setFrame(proposedFrame, display: true)
    }

    private func finishDragging() {
        guard let panel else { return }
        dragStartPointer = nil
        dragStartOrigin = nil
        let lifeFrame = compactLifeFrame(in: panel)
        let targetScreen = screen(containing: NSPoint(x: lifeFrame.midX, y: lifeFrame.midY))
            ?? screen(withLargestIntersection: lifeFrame)
        updatePanelSize(animated: false, preferredScreen: targetScreen)
        let origin = compactLifeFrame(in: panel).origin
        UserDefaults.standard.set(Double(origin.x), forKey: Layout.savedXKey)
        UserDefaults.standard.set(Double(origin.y), forKey: Layout.savedYKey)
        (panel as? CompanionPanel)?.capturesMouseInteraction = false
        (panel as? CompanionPanel)?.refreshMousePassThrough()
    }

    private func restoreOrPosition(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        if
            defaults.object(forKey: Layout.savedXKey) != nil,
            defaults.object(forKey: Layout.savedYKey) != nil
        {
            let savedOrigin = NSPoint(
                x: defaults.double(forKey: Layout.savedXKey),
                y: defaults.double(forKey: Layout.savedYKey)
            )
            let restored = NSRect(origin: savedOrigin, size: panel.frame.size)
            panel.setFrame(clampedFrame(restored, preferredScreen: screen(containing: savedOrigin)), display: false)
            return
        }

        guard let screen = NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - panel.frame.width - 28,
            y: visible.minY + 54
        )
        panel.setFrameOrigin(origin)
    }

    private func compactLifeFrame(in panel: NSPanel) -> NSRect {
        guard panel.frame.size != Layout.compactSize else { return panel.frame }

        let x: CGFloat = switch promptPlacement.horizontal {
        case .promptLeading: panel.frame.maxX - Layout.compactSize.width
        case .promptTrailing: panel.frame.minX
        }
        let y: CGFloat = switch promptPlacement.vertical {
        case .bottomAnchored: panel.frame.minY
        case .topAnchored: panel.frame.maxY - Layout.compactSize.height
        }
        return NSRect(origin: NSPoint(x: x, y: y), size: Layout.compactSize)
    }

    private func placement(
        for lifeFrame: NSRect,
        targetSize: NSSize,
        screen: NSScreen?
    ) -> DigitalLifePanelPlacement {
        guard let screen = screen ?? NSScreen.main else { return promptPlacement }
        let visible = screen.visibleFrame.insetBy(dx: Layout.screenInset, dy: Layout.screenInset)
        let horizontalGrowth = targetSize.width - Layout.compactSize.width
        let verticalGrowth = targetSize.height - Layout.compactSize.height
        let roomOnLeft = lifeFrame.minX - visible.minX
        let roomOnRight = visible.maxX - lifeFrame.maxX
        let roomAbove = visible.maxY - lifeFrame.maxY
        let roomBelow = lifeFrame.minY - visible.minY

        let horizontal: DigitalLifePanelPlacement.Horizontal
        if roomOnLeft >= horizontalGrowth || roomOnLeft >= roomOnRight {
            horizontal = .promptLeading
        } else {
            horizontal = .promptTrailing
        }

        let vertical: DigitalLifePanelPlacement.Vertical
        if roomAbove >= verticalGrowth || roomAbove >= roomBelow {
            vertical = .bottomAnchored
        } else {
            vertical = .topAnchored
        }
        return DigitalLifePanelPlacement(horizontal: horizontal, vertical: vertical)
    }

    private func clampedFrame(_ frame: NSRect, preferredScreen: NSScreen?) -> NSRect {
        guard let visible = (preferredScreen ?? NSScreen.main)?.visibleFrame else { return frame }
        let inset = Layout.screenInset
        let minimumX = visible.minX + inset
        let maximumX = max(minimumX, visible.maxX - frame.width - inset)
        let minimumY = visible.minY + inset
        let maximumY = max(minimumY, visible.maxY - frame.height - inset)
        return NSRect(
            x: min(max(frame.minX, minimumX), maximumX),
            y: min(max(frame.minY, minimumY), maximumY),
            width: frame.width,
            height: frame.height
        )
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func screen(withLargestIntersection frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

/// A non-activating panel can still become key when one of its SwiftUI buttons needs to receive
/// input. It never becomes the app's main document window, so minimizing AgentOne leaves it alone.
private final class CompanionPanel: NSPanel {
    var interactivePointProvider: ((NSPoint) -> Bool)?
    var capturesMouseInteraction = false
    private var globalMouseMovementMonitor: Any?
    private var localMouseMovementMonitor: Any?
    private let mouseMovementThrottle = MouseMovementThrottle(minimumInterval: 1 / 30)

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func startMousePassThroughMonitoring() {
        guard globalMouseMovementMonitor == nil, localMouseMovementMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let throttle = mouseMovementThrottle
        globalMouseMovementMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            guard throttle.shouldForward() else { return }
            Task { @MainActor in
                self?.refreshMousePassThrough()
            }
        }
        localMouseMovementMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if throttle.shouldForward() {
                self?.refreshMousePassThrough()
            }
            return event
        }
        refreshMousePassThrough()
    }

    func stopMousePassThroughMonitoring() {
        if let globalMouseMovementMonitor {
            NSEvent.removeMonitor(globalMouseMovementMonitor)
        }
        if let localMouseMovementMonitor {
            NSEvent.removeMonitor(localMouseMovementMonitor)
        }
        globalMouseMovementMonitor = nil
        localMouseMovementMonitor = nil
    }

    func refreshMousePassThrough() {
        guard isVisible || parent != nil else { return }
        if capturesMouseInteraction
            || (NSEvent.pressedMouseButtons & 1 != 0 && !ignoresMouseEvents)
        {
            return
        }
        let point = NSPoint(
            x: NSEvent.mouseLocation.x - frame.minX,
            y: NSEvent.mouseLocation.y - frame.minY
        )
        ignoresMouseEvents = !(interactivePointProvider?(point) ?? false)
    }
}

/// Global AppKit monitors are not actor-isolated. Throttle there, before a
/// main-actor task is created, so rapid pointer movement cannot queue hundreds
/// of pass-through refreshes behind the user's foreground work.
private final class MouseMovementThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private var lastForwardedUptime = -Double.infinity

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func shouldForward() -> Bool {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard uptime - lastForwardedUptime >= minimumInterval else { return false }
        lastForwardedUptime = uptime
        return true
    }
}

extension Notification.Name {
    static let agentOneRequestedReturnToTask = Notification.Name("AgentOne.requestedReturnToTask")
    static let agentOneRequestedOpenMainWindow = Notification.Name("AgentOne.requestedOpenMainWindow")
    static let agentOneReportedIntentionChange = Notification.Name("AgentOne.reportedIntentionChange")
    static let agentOneRequestedToggleChat = Notification.Name("AgentOne.requestedToggleChat")
}

enum AgentOneCompanionContextKey {
    static let taskName = "taskName"
    static let taskNote = "taskNote"
    static let taskSceneReference = "taskSceneReference"
}

/// 供 `MenuBarExtra` 直接使用的内容视图。
struct AgentOneMenuBarView: View {
    @ObservedObject var shellModel: AgentOneShellViewModel
    @ObservedObject var companion: FloatingCompanionController
    var openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MemoryGlowBeing(mood: shellModel.mood, size: 42, isActive: !shellModel.isPaused)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shellModel.isPaused ? "感知已暂停" : shellModel.currentIntent.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(shellModel.isPaused ? "点击继续，我会重新观察" : "已经一起专注 42 分钟")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button {
                openMainWindow()
            } label: {
                Label("打开 AgentOne", systemImage: "macwindow")
            }

            Button {
                companion.toggle()
            } label: {
                Label(companion.isVisible ? "隐藏桌面生命体" : "显示桌面生命体", systemImage: "sparkles")
            }

            Button {
                shellModel.togglePause()
            } label: {
                Label(shellModel.isPaused ? "继续感知" : "暂停感知", systemImage: shellModel.isPaused ? "play.fill" : "pause.fill")
            }

            Button {
                companion.toggleChat()
            } label: {
                Label(shellModel.isConversationMode ? "结束对话模式" : "开启对话模式", systemImage: "waveform.circle")
            }

            Divider()
            Button("退出 AgentOne") { NSApplication.shared.terminate(nil) }
        }
        .padding(8)
        .frame(width: 260)
    }
}
