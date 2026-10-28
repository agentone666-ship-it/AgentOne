import AgentOneCore
import AppKit
import ApplicationServices
import Foundation

/// Passive observations only: no model, action execution, screen recording or character logger.
@MainActor public final class EventCaptureService {
    private let database: MemoryDatabase
    private var pointerMonitor: Any?
    private var keyboardTap: PassiveKeyboardEventTap?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private let sampler=PassivePointerEventSampler()
    private var current: ContextEventRecord?
    private var windowKey: String?
    private var draft: ActiveApplicationContext?
    public private(set) var running=false
    public private(set) var status="事件记录未启动"
    public var place: () -> String? = { nil }
    public init(database: MemoryDatabase) { self.database=database }

    public func start() {
        guard !running else { return }
        running=true
        observer=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.draft=nil;self?.poll() }
        }
        let sampler=self.sampler
        pointerMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.scrollWheel], handler:makePassivePointerHandler(sampler:sampler) { [weak self] signal in
            Task { @MainActor in self?.pointer(signal) }
        })
        attachKeyboardIfAllowed()
        let timer=Timer(timeInterval:5,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.attachKeyboardIfAllowed();self?.poll() }
        }
        self.timer=timer;RunLoop.main.add(timer,forMode:.common)
        poll()
    }
    public func stop() {
        guard running else { return }
        if var record=current { record.ended=Date();try? database.saveEvent(record) }
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        keyboardTap?.stop();timer?.invalidate()
        keyboardTap=nil;pointerMonitor=nil;observer=nil;timer=nil;current=nil;windowKey=nil;draft=nil;running=false
        status="事件记录已暂停"
    }
    public func requestDetailsPermission() {
        _=AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt":true] as CFDictionary)
        if !CGPreflightListenEventAccess() { _=CGRequestListenEventAccess() }
    }
    private func attachKeyboardIfAllowed() {
        guard running else { return }
        if keyboardTap==nil,CGPreflightListenEventAccess() {
            let tap=PassiveKeyboardEventTap { [weak self] signal,timestamp in
                Task { @MainActor in self?.keyboard(signal,at:timestamp) }
            }
            if tap.start() { keyboardTap=tap }
        }
        status=AXIsProcessTrusted() ? (keyboardTap==nil ? "记录窗口/点击；键盘行为等待输入监控授权" : "记录应用、网页和交互事件") : "记录应用切换；详情等待辅助功能授权"
    }
    private func allowed(_ snapshot: ActiveApplicationContext) -> Bool {
        snapshot.bundleIdentifier != Bundle.main.bundleIdentifier && !snapshot.isSecureInput && !SensitiveContextPolicy.isProtectedSurface(bundleIdentifier:snapshot.bundleIdentifier,windowTitle:snapshot.windowTitle,focusedRole:snapshot.focusedRole)
    }
    private func read(_ scope: ActiveContextReader.Scope) -> ActiveApplicationContext? {
        guard running else { return nil }
        if !AXIsProcessTrusted() { return nil }
        return ActiveContextReader.read(scope:scope).flatMap { allowed($0) ? $0 : nil }
    }
    private func record(_ kind: String,snapshot: ActiveApplicationContext,at: Date,submitted: String? = nil,metadata: String? = nil) {
        guard running,allowed(snapshot) else { return }
        let text=[snapshot.visibleText,snapshot.selectedText,submitted,metadata].compactMap {$0}.joined(separator:"\n")
        let row=ContextEventRecord(started:at,kind:kind,application:snapshot.applicationName,title:snapshot.windowTitle,url:snapshot.url?.absoluteString,text:text,place:place())
        do {try database.saveEvent(row)} catch {status="事件保存失败，请检查 Memory 目录"}
    }
    private func poll() {
        guard running else { return }
        let now=Date()
        if var record=current {record.ended=now;try? database.saveEvent(record);current=record}
        guard let brief=read(.focusedElement) else {
            if !AXIsProcessTrusted(),let app=NSWorkspace.shared.frontmostApplication,app.bundleIdentifier != Bundle.main.bundleIdentifier {
                let key=app.bundleIdentifier ?? app.localizedName ?? "unknown"
                if key != windowKey {
                    current=ContextEventRecord(started:now,kind:"application_changed",application:app.localizedName,text:"仅应用切换，未读取窗口内容",place:place());windowKey=key
                    if let current {try? database.saveEvent(current)}
                }
            } else {current=nil;windowKey=nil}
            return
        }
        let key=[brief.bundleIdentifier,brief.windowTitle,brief.url?.absoluteString].compactMap {$0}.joined(separator:"|")
        guard key != windowKey else {return}
        draft=nil;keyboardTap?.resetTypingSession();windowKey=key
        let snapshot=read(.full) ?? brief
        let text=[snapshot.visibleText,snapshot.selectedText].compactMap {$0}.joined(separator:"\n")
        current=ContextEventRecord(started:now,kind:"window_context",application:snapshot.applicationName,title:snapshot.windowTitle,url:snapshot.url?.absoluteString,text:text,place:place())
        if let current {do {try database.saveEvent(current)} catch {status="事件保存失败，请检查 Memory 目录"}}
    }
    private func pointer(_ signal: PassivePointerSignal) {
        guard running,let snapshot=read(.full) else {return}
        let kind: String
        switch signal.kind {case .primaryClick:kind="primary_click";case .secondaryClick:kind="secondary_click";case .scroll:kind="scroll"}
        record(kind,snapshot:snapshot,at:signal.timestamp,metadata:signal.metadata.sorted {$0.key<$1.key}.map {"\($0.key)=\($0.value)"}.joined(separator:"; "))
    }
    private func keyboard(_ signal: ReducedKeyboardSignal,at timestamp: Date) {
        guard let snapshot=read(.focusedElement) else {draft=nil;return}
        switch signal {
        case .typingStarted:
            draft=snapshot
            record("typing_started",snapshot:snapshot,at:timestamp)
        case .typingProgress(let count):
            // Draft stays in memory until a submit-like Return; only a count is persisted here.
            draft=snapshot
            record("typing_progress",snapshot:snapshot,at:timestamp,metadata:"estimated_character_count=\(count)")
        case .returnPressed:
            let cached=draft.flatMap {$0.bundleIdentifier==snapshot.bundleIdentifier && timestamp.timeIntervalSince($0.capturedAt)<90 ? $0 : nil}
            record("return_pressed",snapshot:snapshot,at:timestamp,submitted:cached?.focusedText ?? snapshot.focusedText,metadata:cached==nil ? "AX snapshot after Return; text may already be cleared" : "bounded AX draft observed before Return; not proof of successful sending")
            draft=nil
        case .deletionBurst:record("deletion_burst",snapshot:snapshot,at:timestamp)
        case .shortcut(let modifiers):record("shortcut",snapshot:snapshot,at:timestamp,metadata:modifiers)
        }
    }
}
