import AppKit
import AgentOneCaptureKit
import Combine
import Darwin
import ServiceManagement
import Speech
import SwiftUI

@MainActor final class CaptureModel: ObservableObject {
    static let shared = CaptureModel()
    @Published var expanded = ProcessInfo.processInfo.environment["AGENTONE_CAPTURE_DEMO"] == "1"
    @Published var pinned = false
    @Published var notchHeight: CGFloat = 0
    @Published var notchWidth: CGFloat = 0
    @Published var recording = false
    @Published var busy = false
    @Published var hasError = false
    @Published var message = "点击开启后，才会请求系统音与麦克风权限"
    @Published var place = UserDefaults.standard.string(forKey: "vNext.place") ?? ""
    @Published var autoResume = UserDefaults.standard.bool(forKey: "vNext.autoResume")
    @Published var pauseOnLock = (UserDefaults.standard.object(forKey: "vNext.pauseOnLock") as? Bool) ?? true
    @Published var query = ""
    @Published var rows: [[String: String]] = []
    @Published var pending = 0
    @Published var asrStatus = "本机转写未启用"
    @Published var localASR = UserDefaults.standard.bool(forKey: "vNext.localASR")
    @Published var audioExport = false
    let demo = ProcessInfo.processInfo.environment["AGENTONE_CAPTURE_DEMO"] == "1"
    let database: MemoryDatabase?
    let service: AudioCaptureService?
    let worker: LocalTranscriptionWorker?
    private var desiredRecording = false
    private var sleeping = false
    private var locked = false
    private var suspended: Bool { sleeping || (locked && pauseOnLock) }
    private var observers: [NSObjectProtocol] = []
    private var polling: Task<Void,Never>?

    private init() {
        let root = demo ? FileManager.default.temporaryDirectory.appendingPathComponent("agentone-island-demo-\(UUID().uuidString)") : MemoryDatabase.defaultRoot
        let db = try? MemoryDatabase(root: root)
        database = db
        service = db.map { AudioCaptureService(database: $0) }
        worker = db.map { LocalTranscriptionWorker(database: $0) }
        if db == nil { message = "Memory 目录无法打开；录音不会启动。" }
        service?.onFailure = { [weak self] message in
            guard let self else { return }
            self.desiredRecording = false
            self.hasError = true
            UserDefaults.standard.set(false,forKey: "vNext.captureDesired")
            Task { await self.stop(reason: "stream_error"); self.message = message }
        }
        worker?.enabled = localASR
        audioExport = (try? db?.rows("SELECT value FROM meta WHERE key='allow_audio_export'").first?["value"]) == "1"
    }

    func launch() {
        guard !demo else { message = "界面演示 · 不采集声音"; return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; await self?.stop(reason: "sleep") }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.resumeAfterSuspension(reason: "sleep") }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.locked = true; if self?.pauseOnLock == true { await self?.stop(reason: "screen_locked") } }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.resumeAfterSuspension(reason: "screen_locked") }
        })
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                do { try self.service?.heartbeat() } catch { self.hasError = true; self.desiredRecording = false; UserDefaults.standard.set(false,forKey: "vNext.captureDesired"); await self.stop(reason: "storage_error"); self.message = "Memory 状态写入失败，已停止录音" }
                if let worker = self.worker { Task { await worker.runNext() } }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        if autoResume && UserDefaults.standard.bool(forKey: "vNext.captureConsent") && UserDefaults.standard.bool(forKey: "vNext.captureDesired") {
            desiredRecording = true
            Task { await start(prompts: false) }
        }
        refresh()
    }

    func toggleRecording() {
        guard !demo, !busy else { return }
        if recording { pauseRecording() }
        else { desiredRecording = true; Task { await start(prompts: true) } }
    }

    func pauseRecording() {
        guard !demo else { return }
        desiredRecording = false
        UserDefaults.standard.set(false,forKey: "vNext.captureDesired")
        Task { await stop(reason: "user_paused") }
    }

    private func start(prompts: Bool) async {
        guard !busy, !suspended, let service else { return }
        busy = true; defer { busy = false }
        updateMetadata()
        do {
            try await service.start(allowPermissionPrompts: prompts)
            if suspended || !desiredRecording { try await service.stop(reason: "start_cancelled"); return }
            recording = service.isRecording
            hasError = false
            UserDefaults.standard.set(true, forKey: "vNext.captureConsent")
            UserDefaults.standard.set(true, forKey: "vNext.captureDesired")
            message = "两路分别保存 · 原音访问需单独开启"
        } catch { hasError = true; desiredRecording = false; UserDefaults.standard.set(false,forKey: "vNext.captureDesired"); recording = false; message = error.localizedDescription }
    }

    func stop(reason: String) async {
        do { try await service?.stop(reason: reason) }
        catch { message = "录音已停止，但末段封口失败；原文件保留为待恢复" }
        recording = false
        if reason == "user_paused" { message = "已暂停。已封口的音频与待处理任务仍保留。" }
        else if reason == "sleep" || reason == "screen_locked" { message = "设备休眠或锁屏，已暂停" }
        refresh()
    }

    func prepareForExit() async {
        desiredRecording = false // Cancel an in-flight permission/start request.
        polling?.cancel()
        await stop(reason: "application_exit")
        worker?.releaseOwnLeases()
    }

    private func resumeAfterSuspension(reason: String) async {
        if reason == "sleep" { sleeping = false } else { locked = false }
        if desiredRecording && !suspended { await start(prompts: false) }
    }

    func updateMetadata() {
        guard !demo else { return }
        UserDefaults.standard.set(place, forKey: "vNext.place")
        let app = NSWorkspace.shared.frontmostApplication
        service?.metadata.update(place: place, application: app?.localizedName, bundleID: app?.bundleIdentifier)
    }

    func setAutoResume(_ value: Bool) {
        autoResume = value
        UserDefaults.standard.set(value, forKey: "vNext.autoResume")
        // Login launch is an explicit user action. SwiftPM binaries cannot
        // register as login apps; the signed .app supplies that lifecycle.
        do {
            if value { try SMAppService.mainApp.register() }
            else if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            if value && SMAppService.mainApp.status == .requiresApproval { message = "请在系统设置的登录项目中允许 AgentOne，自动续录设置才会生效。" }
        } catch { message = "自动续录偏好已保存；登录启动需在系统设置中确认或使用打包的 App。" }
    }

    func enableASR() {
        guard !demo, let worker else { return }
        Task {
            localASR = await worker.requestAuthorization()
            UserDefaults.standard.set(localASR, forKey: "vNext.localASR")
            asrStatus = worker.status
        }
    }

    func setAudioExport(_ value: Bool) {
        guard !demo,let database else { return }
        do {
            try database.execute("INSERT INTO meta VALUES ('allow_audio_export',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[value ? "1" : "0"])
            audioExport = value
        } catch { message = "原音访问设置保存失败" }
    }

    func refresh() {
        guard let database, !demo else { return }
        updateMetadata()
        do {
            pending = Int(try database.rows("SELECT COUNT(*) AS count FROM jobs WHERE state IN ('pending','leased')").first?["count"] ?? "0") ?? 0
            let sql = """
            SELECT s.*,t.text,a.payload_json FROM segments s
            LEFT JOIN transcripts t ON t.segment_id=s.id AND t.revision=(SELECT MAX(revision) FROM transcripts WHERE segment_id=s.id)
            LEFT JOIN analyses a ON a.segment_id=s.id AND a.transcript_revision=t.revision AND a.revision=(SELECT MAX(revision) FROM analyses WHERE segment_id=s.id AND transcript_revision=t.revision)
            WHERE s.state IN ('sealed','incomplete') AND (?='' OR instr(lower(COALESCE(t.text,'')||COALESCE(a.payload_json,'')||COALESCE(s.place,'')),lower(?))>0)
            ORDER BY s.started_ms DESC LIMIT 12
            """
            rows = try database.rows(sql,[query,query])
            asrStatus = worker?.status ?? "转写服务不可用"
        } catch { message = "Memory 读取失败，请检查目录权限" }
    }

    func openAudio(_ row: [String:String]) {
        guard let database,let id=row["id"],row["state"] == "sealed" else { return }
        do { NSWorkspace.shared.open(try database.verifiedAudioURL(id)) }
        catch { message = "原音不存在或校验失败" }
    }

    func deleteRecent() {
        guard let database, let row = rows.first, let id = row["id"] else { return }
        let alert = NSAlert(); alert.messageText = "永久删除最近这一段音频及分析？"
        alert.informativeText = "本机转写、标签、派生事实和任务将一并删除。已被其他 Agent 读取或导出的副本无法收回。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try database.deleteSegment(id)
            message = "已从本机记忆中删除该片段。"
        } catch { message = "该片段已从检索中移除；文件删除失败，请检查 Memory 目录。" }
        refresh()
    }
}

@MainActor final class CaptureAppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandWindowController?
    private var subscription: AnyCancellable?
    private var pinSubscription: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var stopping = false
    private var readyToExit = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = CaptureModel.shared
        let island = IslandWindowController(content: AnyView(IslandView(model: model,onExpand: { [weak self] in self?.expandIsland() })))
        self.island = island
        island.onGeometryChanged = { [weak model] geometry in
            guard let model else { return }
            if model.notchHeight != geometry.notchHeight { model.notchHeight = geometry.notchHeight }
            if model.notchWidth != geometry.notchWidth { model.notchWidth = geometry.notchWidth }
        }
        island.onExpansionRequested = { [weak model] expanded in model?.expanded = expanded }
        pinSubscription = model.$pinned.sink { [weak island] in island?.pinned = $0 }
        subscription = model.$expanded.removeDuplicates().sink { [weak self] expanded in
            Task { @MainActor in
                guard let island = self?.island, island.expanded != expanded else { return }
                island.position(expanded: expanded,animated: true)
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,object: nil,queue: .main) { [weak self] _ in
            Task { @MainActor in self?.island?.position(expanded: CaptureModel.shared.expanded) }
        }
        island.show(expanded: model.expanded)
        if !model.demo { island.startHoverMonitoring() }
        model.launch()
        if model.demo,let path = ProcessInfo.processInfo.environment["AGENTONE_CAPTURE_PREVIEW_PATH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let view=island.panel.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds,to: bitmap)
                    try? bitmap.representation(using: .png,properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }
    func expandIsland() {
        CaptureModel.shared.expanded = true
        island?.show(expanded: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToExit { return .terminateNow }
        if stopping { return .terminateCancel }
        stopping = true
        Task { @MainActor in
            self.island?.stopHoverMonitoring()
            await CaptureModel.shared.prepareForExit()
            self.readyToExit = true
            sender.terminate(nil)
        }
        return .terminateCancel
    }
}

@main struct AgentOneCaptureApp: App {
    @NSApplicationDelegateAdaptor(CaptureAppDelegate.self) private var delegate
    init() {
        if CommandLine.arguments.contains("--self-check") {
            do {
                let root=FileManager.default.temporaryDirectory.appendingPathComponent("agentone-self-check-\(UUID().uuidString)")
                do {
                    let database=try MemoryDatabase(root: root)
                    guard try database.rows("SELECT value FROM meta WHERE key='schema_version'").first?["value"] == "1" else { throw CaptureFailure.message("schema unavailable") }
                }
                try FileManager.default.removeItem(at: root)
                print("{\"product\":\"AgentOne Capture\",\"agent_runtime\":false,\"schema\":1,\"sources\":[\"system_audio\",\"microphone\"],\"recording_started\":false}")
                Darwin.exit(0)
            } catch { fputs("Capture self-check failed\n",stderr); Darwin.exit(1) }
        }
    }
    var body: some Scene {
        MenuBarExtra("AgentOne",systemImage: "waveform.circle") {
            Button("展开灵动岛") { delegate.expandIsland() }
            Button("暂停录音") { CaptureModel.shared.pauseRecording() }
            Divider()
            Button("退出 AgentOne") { NSApp.terminate(nil) }
        }
    }
}
