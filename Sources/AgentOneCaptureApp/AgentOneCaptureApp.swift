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
    @Published var listening = false
    @Published var audioLevels = [Double](repeating:0,count:5)
    @Published var decisionStatus = "Laya 尚未启动"
    @Published var busy = false
    @Published var hasError = false
    @Published var message = "自动合并电脑声音与麦克风，由本机 Laya 辅助决定录音或听候"
    @Published var captureMode = UserDefaults.standard.string(forKey:"vNext.captureMode") ?? "preserve"
    @Published var labelStatus = "本机标签等待转写"
    @Published var automaticRecording = (UserDefaults.standard.object(forKey: "vNext.automaticRecording") as? Bool) ?? true
    @Published var systemReceiving = false
    @Published var microphoneReceiving = false
    @Published var systemHasSound = false
    @Published var microphoneHasSound = false
    @Published var loginStatus = ""
    @Published private(set) var place = ""
    @Published var automaticLocation = (UserDefaults.standard.object(forKey:"vNext.automaticLocation") as? Bool) ?? true
    @Published var locationStatus = "等待自动定位"
    @Published var connectionMode = UserDefaults.standard.string(forKey:"vNext.connectionMode") ?? "plugin"
    @Published var connectionStatus = "可生成插件或复制 MCP 配置"
    @Published var lastAgentConnection = "尚未收到 Agent 连接"
    @Published var connectionBusy = false
    private var exportedPlugin:URL?
    let locationService=AutomaticLocationService()
    @Published var autoResume = (UserDefaults.standard.object(forKey: "vNext.autoResume") as? Bool) ?? true
    @Published var pauseOnLock = (UserDefaults.standard.object(forKey: "vNext.pauseOnLock") as? Bool) ?? true
    @Published var query = ""
    @Published var rows: [[String: String]] = []
    @Published var eventRows: [[String: String]] = []
    @Published var eventCount = 0
    @Published var eventImportStatus = "旧事件待同步"
    @Published var eventCaptureEnabled = (UserDefaults.standard.object(forKey: "vNext.contextEvents") as? Bool) ?? true
    @Published var eventCaptureStatus = "事件记录未启动"
    @Published var pending = 0
    @Published var asrStatus = "本机转写未启用"
    @Published var localASR = UserDefaults.standard.bool(forKey: "vNext.localASR")
    @Published var audioExport = false
    let demo = ProcessInfo.processInfo.environment["AGENTONE_CAPTURE_DEMO"] == "1"
    let database: MemoryDatabase?
    let service: AudioCaptureService?
    let eventService: EventCaptureService?
    let worker: LocalTranscriptionWorker?
    let labeler:LocalTopicLabeler?
    private var desiredRecording = false
    private var sleeping = false
    private var locked = false
    private var suspended: Bool { sleeping || (locked && pauseOnLock) }
    private var observers: [NSObjectProtocol] = []
    private var polling: Task<Void,Never>?
    private var metering:Task<Void,Never>?
    private var decisions:Task<Void,Never>?
    private let laya=LayaDecisionClient()

    private init() {
        let root = demo ? FileManager.default.temporaryDirectory.appendingPathComponent("agentone-island-demo-\(UUID().uuidString)") : MemoryDatabase.defaultRoot
        let db = try? MemoryDatabase(root: root)
        database = db
        service = db.map { AudioCaptureService(database: $0) }
        eventService = db.map { EventCaptureService(database: $0) }
        worker = db.map { LocalTranscriptionWorker(database: $0) }
        labeler=db.map {LocalTopicLabeler(database:$0)}
        if db == nil { message = "Memory 目录无法打开；录音不会启动。" }
        service?.onFailure = { [weak self] message in
            guard let self else { return }
            self.hasError = true
            // Keep automatic intent for the next launch; do not loop on disk/device failures.
            if !self.automaticRecording { self.desiredRecording = false; UserDefaults.standard.set(false,forKey: "vNext.captureDesired") }
            Task { await self.stop(reason: "stream_error"); self.message = message }
        }
        eventService?.place = { [weak self] in self?.locationService.observation?.displayName }
        locationService.onChange = { [weak self] in
            guard let self else {return};self.locationStatus=self.locationService.status;self.updateMetadata()
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
                if let worker = self.worker {Task {await worker.runNext()}}
                if let labeler=self.labeler {Task {await labeler.runNext {text in await self.laya.classifyTranscript(text)};self.labelStatus=labeler.status}}
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        let developmentWorker=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentOne/Laya/laya-worker.py")
        if let workerURL=Bundle.main.url(forResource:"laya-worker",withExtension:"py") ?? (FileManager.default.fileExists(atPath:developmentWorker.path) ? developmentWorker:nil) {laya.start(workerURL:workerURL)}
        else {decisionStatus="Laya 组件缺失，自动触发暂不可用"}
        metering=Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {return}
                let active=self.service?.isRecording == true
                if self.listening != active {self.listening=active}
                let saving=active && (self.service?.decisionStatus.snapshot.saving ?? false)
                if self.recording != saving {self.recording=saving}
                if active,self.service?.automaticDecisions==false,let detail=self.service?.decisionStatus.snapshot.detail,self.decisionStatus != detail {self.decisionStatus=detail}
                let level=self.recording ? self.service?.activity.level(source:"mixed") ?? 0:0
                let levels=Array(self.audioLevels.suffix(4))+[level]
                if self.audioLevels != levels {self.audioLevels=levels}
                do {try await Task.sleep(for:.milliseconds(80))} catch {return}
            }
        }
        decisions=Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {return}
                if let service=self.service,service.isRecording,(service.automaticDecisions || service.preserveAllAudio) {
                    let token=service.sessionToken,evidence=service.activity.startEvidence()
                    let soundState = !evidence.inputsReady ? "输入状态未知，没有可靠的声音证据" : evidence.sustainedSound ? "持续检测到明显声音，声音已稳定持续 3 秒" : evidence.quietSeconds<3 ? "仅有短促声音，没有持续活动":"环境安静，没有明显的连续声音"
                    let state=["声音状态":soundState,"当前状态":service.decisionStatus.snapshot.saving ? "正在录音":"正在听候"]
                    let decision=await self.laya.decide(state:state)
                    guard !Task.isCancelled else {return}
                    service.applyDecision(decision,session:token)
                    self.decisionStatus=self.laya.status+" · "+service.decisionStatus.snapshot.detail
                }
                do {try await Task.sleep(for:.seconds(2))} catch {return}
            }
        }
        syncLegacyEvents()
        if localASR && SFSpeechRecognizer.authorizationStatus() == .notDetermined {enableASR()}
        if autoResume { setAutoResume(true) }
        switch AutomaticCapturePolicy.startup(enabled: automaticRecording,
                desired: UserDefaults.standard.object(forKey: "vNext.captureDesired") as? Bool,
                setupAttempted: UserDefaults.standard.bool(forKey: "vNext.permissionSetupAttempted"), demo: demo) {
        case .start(let prompts):
            desiredRecording = true
            if eventCaptureEnabled { eventService?.start() }
            if prompts { UserDefaults.standard.set(true,forKey: "vNext.permissionSetupAttempted") }
            Task { await start(prompts: prompts) }
        case .paused: message = "自动记录已手动暂停；点击恢复后继续"
        case .inactive: message = "自动记录已关闭；可以手动开始"
        }
        if automaticLocation && desiredRecording && !UserDefaults.standard.bool(forKey:"vNext.locationSetupAttempted") {requestLocationAccess()}
        refresh()
    }

    func toggleRecording() {
        guard !demo, !busy else { return }
        if listening { pauseRecording() }
        else {
            desiredRecording = true
            UserDefaults.standard.set(true,forKey: "vNext.permissionSetupAttempted")
            Task { await start(prompts: true) }
        }
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
        if automaticLocation {locationService.start(requestPermission:false)}
        updateMetadata()
        do {
            try await service.start(allowPermissionPrompts:prompts,automaticDecisions:automaticRecording && captureMode=="intelligent",preserveAllAudio:automaticRecording && captureMode=="preserve")
            if suspended || !desiredRecording { try await service.stop(reason: "start_cancelled"); return }
            listening = service.isRecording
            recording = service.isRecording && service.decisionStatus.snapshot.saving
            if eventCaptureEnabled { eventService?.start() }
            hasError = false
            UserDefaults.standard.set(true, forKey: "vNext.captureConsent")
            UserDefaults.standard.set(true, forKey: "vNext.captureDesired")
            message = automaticRecording ? (captureMode=="preserve" ? "持续保全系统声音与麦克风；模型分段/标记不会停止保存":"先听候，持续声音和模型稳定确认后才录音；不确定时不自动开启") : "系统音与麦克风合并保存 · 原音访问需单独开启"
        } catch {
            hasError = true
            if !automaticRecording { desiredRecording = false; UserDefaults.standard.set(false,forKey: "vNext.captureDesired") }
            recording = false
            message = "自动记录尚未开始：" + error.localizedDescription
            expanded = true; pinned = true
        }
    }

    func stop(reason: String) async {
        eventService?.stop();locationService.stop(status:"录音已暂停，定位同步暂停")
        do { try await service?.stop(reason: reason) }
        catch { message = "录音已停止，但末段封口失败；原文件保留为待恢复" }
        listening = false;recording = false;audioLevels=[Double](repeating:0,count:5)
        systemHasSound = false; microphoneHasSound = false
        systemReceiving = false; microphoneReceiving = false
        if reason == "user_paused" { message = "已手动暂停，不会自行恢复。点击恢复自动记录即可继续。" }
        else if reason == "sleep" || reason == "screen_locked" { message = "设备休眠或锁屏，已暂停" }
        refresh()
    }

    func prepareForExit() async {
        desiredRecording = false // Cancel an in-flight permission/start request.
        polling?.cancel();metering?.cancel();decisions?.cancel();laya.stop()
        await stop(reason: "application_exit")
        worker?.releaseOwnLeases()
    }

    private func resumeAfterSuspension(reason: String) async {
        if reason == "sleep" { sleeping = false } else { locked = false }
        if desiredRecording && !suspended { await start(prompts: false) }
    }

    func setEventCapture(_ value: Bool) {
        guard !demo else {return}
        eventCaptureEnabled=value;UserDefaults.standard.set(value,forKey: "vNext.contextEvents")
        if value && desiredRecording && !suspended {eventService?.start()} else {eventService?.stop()}
        refresh()
    }
    func syncLegacyEvents() {
        guard !demo,let database else {return}
        eventImportStatus="正在同步旧事件…"
        Task {
            do {
                let report=try await Task.detached(priority:.utility) {try LegacyEventImporter(database:database).sync(diaryRoot:database.root.deletingLastPathComponent().appendingPathComponent("Diary"))}.value
                eventImportStatus="已同步 \(report.imported) 条旧事件" + (report.skippedFiles+report.malformedEntries>0 ? "（部分来源无法读取）" : "")
            } catch {eventImportStatus="旧事件同步失败，原 Diary 保留"}
            refresh()
        }
    }
    func openEventSource(_ row: [String:String]) {
        guard let database,let ref=row["source_ref"],ref.hasPrefix("Diary/Daily/") else {return}
        let relative=String(ref.split(separator:"#").first ?? "")
        let url=database.root.deletingLastPathComponent().appendingPathComponent(relative).resolvingSymlinksInPath()
        guard url.path.hasPrefix(database.root.deletingLastPathComponent().appendingPathComponent("Diary/Daily").resolvingSymlinksInPath().path+"/") else {return}
        NSWorkspace.shared.open(url)
    }
    func updateMetadata() {
        guard !demo else { return }
        let observation=automaticLocation ? locationService.observation:nil
        let label=observation?.displayName ?? ""
        if place != label {place=label}
        let app = NSWorkspace.shared.frontmostApplication
        service?.metadata.update(place: place, application: app?.localizedName, bundleID: app?.bundleIdentifier,location:observation)
    }

    func requestLocationAccess() {
        guard !demo else {return}
        UserDefaults.standard.set(true,forKey:"vNext.locationSetupAttempted")
        NSApp.activate(ignoringOtherApps:true)
        locationService.start(requestPermission:true)
    }
    func setAutomaticLocation(_ value:Bool) {
        guard !demo else {return}
        automaticLocation=value;UserDefaults.standard.set(value,forKey:"vNext.automaticLocation")
        if value {requestLocationAccess()} else {locationService.stop()}
        updateMetadata()
    }
    func openLocationSettings() {if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {NSWorkspace.shared.open(url)}}
    private func connectionPackage() throws -> AgentConnectionPackage {
        guard let database,let node=AgentConnectionPackage.findNode() else {throw CaptureFailure.message("需要安装 Node.js 22.19 或更新版本，才能连接本机记忆")}
        let bundled=Bundle.main.resourceURL?.appendingPathComponent("agentone-memory")
        let development=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("plugins/agentone-memory")
        let resources=bundled.flatMap {FileManager.default.fileExists(atPath:$0.appendingPathComponent("server.mjs").path) ? $0:nil} ?? development
        return AgentConnectionPackage(resources:resources,memoryRoot:database.root,node:node)
    }
    func preparePlugin(reveal:Bool) {
        guard !demo else {return}
        do {
            let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentOne/Connections")
            let exported=try exportedPlugin ?? connectionPackage().export(to:root)
            exportedPlugin=exported
            if reveal {NSWorkspace.shared.activateFileViewerSelecting([exported])}
            else {
                let guide=try String(contentsOf:exported.appendingPathComponent("接入说明.txt"),encoding:.utf8)
                NSPasteboard.general.clearContents();NSPasteboard.general.setString(guide,forType:.string)
            }
            connectionStatus=reveal ? "插件已生成；请在 Agent 中导入，随后检查连接":"插件接入说明已复制，可交给你的 Agent 安装"
        } catch {connectionStatus=error.localizedDescription}
    }
    func copyMCPConfiguration() {
        guard !demo else {return}
        do {let text=try connectionPackage().configurationText();NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string);connectionStatus="MCP 配置已复制；添加到宿主后即可连接"}
        catch {connectionStatus=error.localizedDescription}
    }
    func checkAgentConnection() {
        guard !demo,!connectionBusy else {return}
        connectionBusy=true;connectionStatus="正在检查本机连接服务…"
        Task {
            defer {connectionBusy=false}
            do {let package=try connectionPackage();let count=try await Task.detached(priority:.utility) {try package.connectionCheck()}.value;connectionStatus="本机服务正常 · \(count) 个工具；等待 Agent 导入或调用"}
            catch {connectionStatus=error.localizedDescription}
            refresh()
        }
    }

    func setCaptureMode(_ value:String) {
        guard !demo,["preserve","intelligent"].contains(value),captureMode != value else {return}
        captureMode=value;UserDefaults.standard.set(value,forKey:"vNext.captureMode")
        if listening {
            Task {await stop(reason:"capture_mode_changed");if desiredRecording {await start(prompts:false)}}
        }
    }

    func setAutomaticRecording(_ value: Bool) {
        guard !demo else { return }
        automaticRecording = value
        UserDefaults.standard.set(value,forKey: "vNext.automaticRecording")
        if value {
            desiredRecording = true
            UserDefaults.standard.set(true,forKey: "vNext.captureDesired")
            UserDefaults.standard.set(true,forKey: "vNext.permissionSetupAttempted")
            Task { await start(prompts: true) }
        } else { pauseRecording() }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func setAutoResume(_ value: Bool) {
        autoResume = value
        UserDefaults.standard.set(value, forKey: "vNext.autoResume")
        // Registration is separate from system approval; report the actual status.
        do {
            if value && SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
            else if !value && SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            switch SMAppService.mainApp.status {
            case .enabled: loginStatus = "已允许登录时启动"
            case .requiresApproval: loginStatus = "等待在系统设置中允许登录启动"
            case .notRegistered: loginStatus = "未注册登录启动"
            default: loginStatus = "登录启动不可用"
            }
        } catch { loginStatus = "登录启动注册失败，请检查系统设置" }
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
        systemReceiving = listening && (service?.activity.hasSamples(source: "system_audio") ?? false)
        microphoneReceiving = listening && (service?.activity.hasSamples(source: "microphone") ?? false)
        systemHasSound = listening && (service?.activity.hasSound(source: "system_audio") ?? false)
        microphoneHasSound = listening && (service?.activity.hasSound(source: "microphone") ?? false)
        do {
            try database.execute("INSERT INTO meta VALUES ('local_asr_status',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[worker?.status ?? "本机转写不可用"])
            if let raw=try database.rows("SELECT value FROM meta WHERE key='last_agent_connection'").first?["value"],let data=raw.data(using:.utf8),let host=try JSONSerialization.jsonObject(with:data) as? [String:Any],let name=host["name"] as? String,let ms=host["connected_ms"] as? Double {
                lastAgentConnection="最近连接："+name+" · "+Date(timeIntervalSince1970:ms/1000).formatted(date:.abbreviated,time:.shortened)
            }
            eventCaptureStatus=eventService?.status ?? "事件服务不可用"
            eventCount=Int(try database.rows("SELECT COUNT(*) AS count FROM context_events WHERE hidden=0").first?["count"] ?? "0") ?? 0
            eventRows=try database.rows("SELECT * FROM context_events WHERE hidden=0 AND (?='' OR instr(lower(COALESCE(title,'')||text||COALESCE(application,'')||COALESCE(url,'')),lower(?))>0) ORDER BY started_ms DESC LIMIT 30",[query,query])
            pending = Int(try database.rows("SELECT COUNT(*) AS count FROM jobs WHERE state IN ('pending','leased')").first?["count"] ?? "0") ?? 0
            let sql = """
            SELECT s.*,t.text,t.status AS transcript_status,a.payload_json,l.value AS local_label_json FROM segments s
            LEFT JOIN transcripts t ON t.segment_id=s.id AND t.revision=(SELECT MAX(revision) FROM transcripts WHERE segment_id=s.id)
            LEFT JOIN analyses a ON a.segment_id=s.id AND a.transcript_revision=t.revision AND a.revision=(SELECT MAX(revision) FROM analyses WHERE segment_id=s.id AND transcript_revision=t.revision)
            LEFT JOIN meta l ON l.key='local_label:'||s.id||':'||t.revision
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
                    guard try database.rows("SELECT value FROM meta WHERE key='schema_version'").first?["value"] == "2" else { throw CaptureFailure.message("schema unavailable") }
                }
                try FileManager.default.removeItem(at: root)
                print("{\"product\":\"AgentOne Capture\",\"agent_runtime\":false,\"schema\":2,\"recording_output\":\"mixed\",\"sources\":[\"system_audio\",\"microphone\"],\"recording_started\":false}")
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
