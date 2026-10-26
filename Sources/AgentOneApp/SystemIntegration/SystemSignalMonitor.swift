import AgentOneCaptureKit
import AppKit
import ApplicationServices
import AgentOneCore
import Foundation

/// Privacy-preserving system activity signal. It deliberately describes the
/// shape of an interaction rather than the text the user typed.
struct SystemActivitySignal: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case primaryClick
        case secondaryClick
        case scroll
        case typingStarted
        case typingProgress
        case returnPressed
        case deletionBurst
        case shortcut
        case applicationChanged
        case idle
        case resumed
    }

    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let applicationName: String?
    let bundleIdentifier: String?
    let magnitude: Double
    let metadata: [String: String]
}

@MainActor
final class SystemSignalMonitor: ObservableObject {
    @Published private(set) var latestSignal: SystemActivitySignal?
    @Published private(set) var isMonitoring = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasInputMonitoringPermission = false
    @Published private(set) var hasScreenRecordingPermission = false

    var onSignal: ((SystemActivitySignal) -> Void)?

    private var globalMonitor: Any?
    private var keyboardTap: PassiveKeyboardEventTap?
    private let pointerSampler = PassivePointerEventSampler()
    private var workspaceObserver: NSObjectProtocol?
    private var idleTimer: Timer?
    private var lastInteraction = Date()

    private let idleThreshold: TimeInterval = 90

    var secondsSinceLastInteraction: TimeInterval {
        max(0, Date().timeIntervalSince(lastInteraction))
    }

    init() {
        AgentOneRuntimeHealthStore.shared.registerPermissionActions(
            accessibility: { [weak self] in self?.requestAccessibilityPermission() },
            inputMonitoring: { [weak self] in self?.requestInputMonitoringPermission() },
            screenRecording: { [weak self] in self?.requestScreenRecordingPermission() }
        )
        refreshPermissions()
    }

    func start() {
        guard !isMonitoring else { return }
        refreshPermissions()

        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .scrollWheel
        ]

        let pointerSampler = pointerSampler
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let signal = pointerSampler.sample(event) else { return }
            Task { @MainActor in self?.consumePointerSignal(signal) }
        }

        let keyboardTap = PassiveKeyboardEventTap { [weak self] signal, timestamp in
            Task { @MainActor in
                self?.consumeKeyboardSignal(signal, timestamp: timestamp)
            }
        }
        if keyboardTap.start() {
            self.keyboardTap = keyboardTap
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let applicationName = application?.localizedName
            let bundleIdentifier = application?.bundleIdentifier
            Task { @MainActor in
                self?.applicationDidChange(
                    applicationName: applicationName,
                    bundleIdentifier: bundleIdentifier
                )
            }
        }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
                self?.evaluateIdleState()
            }
        }
        isMonitoring = true
        publishCaptureHealth()
        emit(.resumed)
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        keyboardTap?.stop()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        idleTimer?.invalidate()
        globalMonitor = nil
        keyboardTap = nil
        workspaceObserver = nil
        idleTimer = nil
        isMonitoring = false
        publishCaptureHealth()
    }

    /// Read-only permission preflight. This never opens a system prompt.
    func refreshPermissions() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasInputMonitoringPermission = CGPreflightListenEventAccess()
        hasScreenRecordingPermission = WindowContextCapture.hasScreenRecordingPermission
        publishCaptureHealth()
    }

    func requestAccessibilityPermission() {
        // The string value is stable public API. Using it directly also avoids
        // Swift 6 treating the imported C global as unsafe shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)
        publishCaptureHealth()
    }

    func requestInputMonitoringPermission() {
        hasInputMonitoringPermission = CGRequestListenEventAccess()
        publishCaptureHealth()
    }

    func requestScreenRecordingPermission() {
        hasScreenRecordingPermission = WindowContextCapture.requestScreenRecordingPermission()
        publishCaptureHealth()
    }

    private func consumePointerSignal(_ signal: PassivePointerSignal) {
        let wasIdle = signal.timestamp.timeIntervalSince(lastInteraction) >= idleThreshold
        lastInteraction = signal.timestamp
        if wasIdle { emit(.resumed) }

        switch signal.kind {
        case .primaryClick:
            keyboardTap?.resetTypingSession()
            emit(.primaryClick, metadata: signal.metadata, timestamp: signal.timestamp)
        case .secondaryClick:
            emit(.secondaryClick, metadata: signal.metadata, timestamp: signal.timestamp)
        case .scroll:
            emit(
                .scroll,
                magnitude: signal.magnitude,
                metadata: signal.metadata,
                timestamp: signal.timestamp
            )
        }
    }

    private func consumeKeyboardSignal(_ signal: ReducedKeyboardSignal, timestamp: Date) {
        // The CGEvent tap sees AgentOne's own windows too. Those events are
        // intentionally excluded so chatting with the companion cannot feed
        // another capture cycle back into itself.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            lastInteraction = timestamp
            return
        }

        let wasIdle = timestamp.timeIntervalSince(lastInteraction) >= idleThreshold
        lastInteraction = timestamp
        if wasIdle { emit(.resumed, timestamp: timestamp) }

        switch signal {
        case .typingStarted:
            emit(.typingStarted, timestamp: timestamp)
        case .typingProgress(let estimatedCharacterCount):
            emit(
                .typingProgress,
                magnitude: Double(estimatedCharacterCount),
                timestamp: timestamp
            )
        case .returnPressed:
            emit(.returnPressed, timestamp: timestamp)
        case .deletionBurst(let repeatCount):
            emit(.deletionBurst, magnitude: Double(repeatCount), timestamp: timestamp)
        case .shortcut(let modifierPattern):
            emit(
                .shortcut,
                metadata: ["modifierPattern": modifierPattern],
                timestamp: timestamp
            )
        }
    }

    private func applicationDidChange(
        applicationName: String?,
        bundleIdentifier: String?
    ) {
        keyboardTap?.resetTypingSession()
        let signal = SystemActivitySignal(
            timestamp: Date(),
            kind: .applicationChanged,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            magnitude: 1,
            metadata: ["localizedName": applicationName ?? "Unknown"]
        )
        latestSignal = signal
        AgentOneRuntimeHealthStore.shared.noteBehaviorSignal(at: signal.timestamp)
        onSignal?(signal)
    }

    private func evaluateIdleState() {
        guard isMonitoring else { return }
        let elapsed = Date().timeIntervalSince(lastInteraction)
        if elapsed >= idleThreshold, latestSignal?.kind != .idle {
            emit(.idle, magnitude: elapsed)
        }
    }

    private func emit(
        _ kind: SystemActivitySignal.Kind,
        magnitude: Double = 1,
        metadata: [String: String] = [:],
        application: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        timestamp: Date = Date()
    ) {
        let signal = SystemActivitySignal(
            timestamp: timestamp,
            kind: kind,
            applicationName: application?.localizedName,
            bundleIdentifier: application?.bundleIdentifier,
            magnitude: magnitude,
            metadata: metadata
        )
        latestSignal = signal
        AgentOneRuntimeHealthStore.shared.noteBehaviorSignal(at: signal.timestamp)
        onSignal?(signal)
    }

    private func publishCaptureHealth() {
        AgentOneRuntimeHealthStore.shared.updateCapturePermissions(
            isMonitoring: isMonitoring,
            accessibilityGranted: hasAccessibilityPermission,
            inputMonitoringGranted: hasInputMonitoringPermission,
            screenRecordingGranted: hasScreenRecordingPermission
        )
    }

}
