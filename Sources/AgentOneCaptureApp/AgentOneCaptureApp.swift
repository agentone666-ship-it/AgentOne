import AppKit
import AgentOneCaptureKit
import Combine
import Darwin
import ServiceManagement
import Speech
import SwiftUI

@MainActor final class CaptureModel: ObservableObject {
    static let shared = CaptureModel()
    @Published var expanded = !UserDefaults.standard.bool(forKey: "vNext.captureConsent") || ProcessInfo.processInfo.environment["AGENTONE_CAPTURE_DEMO"] == "1"
    @Published var recording = false
    @Published var busy = false
    @Published var hasError = false
    @Published var message = "点击开启后，才会请求系统音与麦克风权限"
    @Published var place = UserDefaults.standard.string(forKey: "vNext.place") ?? ""
    @Published var autoResume = UserDefaults.standard.bool(forKey: "vNext.autoResume")
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
    private var suspended: Bool { sleeping || locked }
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
            Task { @MainActor in self?.locked = true; await self?.stop(reason: "screen_locked") }
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
        if recording { desiredRecording = false; UserDefaults.standard.set(false,forKey: "vNext.captureDesired"); Task { await stop(reason: "user_paused") } }
        else { desiredRecording = true; Task { await start(prompts: true) } }
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
            message = "两路分别保存 · 锁屏时暂停 · 原音访问需单独开启"
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
        _ = try? database?.execute("UPDATE jobs SET state='pending',lease_token=NULL,lease_until_ms=NULL WHERE state='leased' AND lease_owner='native-local-asr'")
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

private struct IslandView: View {
    @ObservedObject var model: CaptureModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { model.expanded.toggle() } label: {
                HStack {
                    Image(systemName: "waveform.circle.fill").foregroundStyle(.indigo)
                    Text("AgentOne").fontWeight(.medium)
                    Spacer()
                    Circle().fill(model.hasError ? Color.orange : (model.recording ? Color.green : Color.secondary)).frame(width: 5,height: 5)
                    Text(model.demo ? "界面演示" : (model.hasError ? "录音异常" : (model.recording ? "双路录制中" : "未录音"))).font(.caption)
                    Image(systemName: model.expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if model.expanded {
                HStack {
                    Text("系统声音 ＋ 麦克风 · 独立轨道").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.busy ? "正在启动…" : (model.recording ? "暂停" : "开启录音")) { model.toggleRecording() }.disabled(model.busy || model.demo)
                }
                Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
                HStack {
                    Text("地点").font(.caption).foregroundStyle(.secondary)
                    TextField("未标注",text: $model.place).textFieldStyle(.roundedBorder).onChange(of: model.place) { _,_ in model.updateMetadata() }
                    Text("你标注").font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("下次登录自动续录",isOn: Binding(get: {model.autoResume},set: {model.setAutoResume($0)})).font(.caption).disabled(model.demo)
                Toggle("允许 MCP 读取原音（宿主可能使用云模型）",isOn: Binding(get: {model.audioExport},set: {model.setAudioExport($0)})).font(.caption2).disabled(model.demo)
                HStack {
                    Text(model.asrStatus).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if !model.localASR { Button("启用本机转写") { model.enableASR() }.font(.caption).disabled(model.demo) }
                }
                Divider()
                HStack { Text("回忆").fontWeight(.medium); Spacer(); Text("\(model.pending) 项待处理").font(.caption).foregroundStyle(.secondary) }
                TextField("搜索原话、主题或地点",text: $model.query).textFieldStyle(.roundedBorder).onChange(of: model.query) { _,_ in model.refresh() }
                ScrollView {
                    VStack(alignment: .leading,spacing: 12) {
                        if model.rows.isEmpty { Text("录音片段封口后显示在这里。转写和标签尚未完成时，原音仍可保留。") .font(.caption).foregroundStyle(.secondary).padding(.vertical,18) }
                        ForEach(model.rows, id: \.["id"]) { row in
                            VStack(alignment: .leading,spacing: 5) {
                                HStack {
                                    Text(time(row["started_ms"])).font(.caption).monospacedDigit()
                                    Text(row["source"] == "microphone" ? "麦克风" : "系统音").font(.caption2).foregroundStyle(.secondary)
                                    if let place = row["place"] { Text(place).font(.caption2).foregroundStyle(.secondary) }
                                    Spacer()
                                    if row["state"] == "sealed" { Button("原音") { model.openAudio(row) }.font(.caption) }
                                }
                                Text(row["text"].flatMap {$0.isEmpty ? nil : $0} ?? (row["state"] == "incomplete" ? "末段不完整，保留待恢复" : "待转写")).font(.caption).lineLimit(3)
                                if let payload = row["payload_json"],let data = payload.data(using: .utf8),let value = try? JSONSerialization.jsonObject(with: data) as? [String:Any],let tags = value["tags"] as? [String] {
                                    Text(tags.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                                }
                            }.padding(10).frame(maxWidth: .infinity,alignment: .leading).background(.white.opacity(0.06),in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }.frame(maxHeight: .infinity)
                HStack {
                    Button("打开 Memory") { if let root=model.database?.root { NSWorkspace.shared.open(root) } }.font(.caption)
                    Spacer()
                    Button("删除最近片段",role: .destructive) { model.deleteRecent() }.font(.caption).disabled(model.rows.isEmpty)
                }
                Text("MCP 提供资料与分析队列；待办执行交给你的 Agent。") .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(model.expanded ? 18 : 12).frame(width: model.expanded ? 420 : 240,height: model.expanded ? 560 : 42)
            .background(Color(red: 0.035,green: 0.04,blue: 0.055),in: RoundedRectangle(cornerRadius: model.expanded ? 26 : 20))
            .preferredColorScheme(.dark)
    }
    private func time(_ value: String?) -> String {
        guard let value,let ms = Double(value) else { return "未知时间" }
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

private final class IslandPanel: NSPanel { override var canBecomeKey: Bool { true } }

@MainActor final class CaptureAppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var subscription: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var stopping = false
    private var readyToExit = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = CaptureModel.shared
        let panel = IslandPanel(contentRect: .zero,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        self.panel = panel
        subscription = model.$expanded.sink { [weak self] expanded in Task { @MainActor in self?.position(expanded: expanded) } }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,object: nil,queue: .main) { [weak self] _ in
            Task { @MainActor in self?.position(expanded: CaptureModel.shared.expanded) }
        }
        position(expanded: model.expanded); panel.orderFrontRegardless(); model.launch()
        if model.demo,let path = ProcessInfo.processInfo.environment["AGENTONE_CAPTURE_PREVIEW_PATH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let view=panel.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds,to: bitmap)
                    try? bitmap.representation(using: .png,properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }
    private func position(expanded: Bool) {
        guard let panel,let screen=NSScreen.main else { return }
        let size=NSSize(width: expanded ? 420 : 240,height: expanded ? min(560,screen.visibleFrame.height - 20) : 42)
        panel.setFrame(NSRect(x: screen.visibleFrame.midX-size.width/2,y: screen.visibleFrame.maxY-size.height-6,width: size.width,height: size.height),display: true,animate: false)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToExit { return .terminateNow }
        if stopping { return .terminateCancel }
        stopping = true
        Task { @MainActor in
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
            Button("展开灵动岛") { CaptureModel.shared.expanded = true }
            Button(CaptureModel.shared.recording ? "暂停录音" : "开启双路录音") { CaptureModel.shared.toggleRecording() }
            Divider()
            Button("退出 AgentOne") { NSApp.terminate(nil) }
        }
    }
}
