import Foundation
import AgentOneCore
import SwiftUI

enum RuntimeHealthState: String, Sendable {
    case healthy
    case waiting
    case blocked
    case error

    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .waiting: "clock.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .healthy: AgentOnePalette.mint
        case .waiting: AgentOnePalette.blue
        case .blocked: .orange
        case .error: .red
        }
    }
}

struct RuntimeSubsystemHealth: Equatable, Sendable {
    var state: RuntimeHealthState
    var headline: String
    var detail: String
    var updatedAt: Date?
}

/// One honest view of the complete capture → Context → model → diary chain.
/// Runtime components report immediate state here, while the disk refresh is a
/// fallback that also makes failures visible after an app relaunch.
@MainActor
final class AgentOneRuntimeHealthStore: ObservableObject {
    static let shared = AgentOneRuntimeHealthStore()

    @Published private(set) var behaviorSignals = RuntimeSubsystemHealth(
        state: .waiting,
        headline: "正在检查输入监听",
        detail: "还没有确认是否能收到全局鼠标、滚轮和键盘信号。",
        updatedAt: nil
    )
    @Published private(set) var accessibilityContext = RuntimeSubsystemHealth(
        state: .waiting,
        headline: "正在检查页面 Context",
        detail: "还没有确认是否能读取窗口标题、网址与可见正文。",
        updatedAt: nil
    )
    @Published private(set) var screenshotEvidence = RuntimeSubsystemHealth(
        state: .waiting,
        headline: "正在检查关键截图",
        detail: "回车证据只截取一个关键窗口，不录制连续画面。",
        updatedAt: nil
    )
    @Published private(set) var modelInference = RuntimeSubsystemHealth(
        state: .waiting,
        headline: "等待第一次 Context 理解",
        detail: "配置模型不代表已经产生思考；成功调用后这里会显示真实时间。",
        updatedAt: nil
    )
    @Published private(set) var diaryPersistence = RuntimeSubsystemHealth(
        state: .waiting,
        headline: "正在检查今日日记",
        detail: "还没有确认今天的结构化 Context 是否已经落盘。",
        updatedAt: nil
    )

    private var requestAccessibilityAction: (() -> Void)?
    private var requestInputMonitoringAction: (() -> Void)?
    private var requestScreenRecordingAction: (() -> Void)?
    private var lastExplicitModelUpdate: Date?
    private var lastExplicitDiaryUpdate: Date?

    var hasBlockingCaptureIssue: Bool {
        behaviorSignals.state == .blocked || accessibilityContext.state == .blocked
            || behaviorSignals.state == .error || accessibilityContext.state == .error
    }

    var captureIssueSummary: String? {
        if behaviorSignals.state == .blocked && accessibilityContext.state == .blocked {
            return "输入监控和辅助功能都未授权：现在只能看到应用切换，读不到真实操作与页面正文。"
        }
        if behaviorSignals.state == .blocked {
            return "输入监控未授权：收不到全局点击、滚轮和键盘信号。"
        }
        if accessibilityContext.state == .blocked {
            return "辅助功能未授权：读不到网址、窗口标题和页面正文。"
        }
        if behaviorSignals.state == .error || accessibilityContext.state == .error {
            return "Context 采集链路发生错误，请到设置查看具体状态。"
        }
        return nil
    }

    func registerPermissionActions(
        accessibility: @escaping () -> Void,
        inputMonitoring: @escaping () -> Void,
        screenRecording: @escaping () -> Void
    ) {
        requestAccessibilityAction = accessibility
        requestInputMonitoringAction = inputMonitoring
        requestScreenRecordingAction = screenRecording
    }

    func requestAccessibilityPermission() {
        requestAccessibilityAction?()
    }

    func requestInputMonitoringPermission() {
        requestInputMonitoringAction?()
    }

    func requestScreenRecordingPermission() {
        requestScreenRecordingAction?()
    }

    func updateCapturePermissions(
        isMonitoring: Bool,
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        screenRecordingGranted: Bool
    ) {
        let now = Date()
        behaviorSignals = inputMonitoringGranted
            ? RuntimeSubsystemHealth(
                state: isMonitoring ? .healthy : .waiting,
                headline: isMonitoring ? "全局行为信号正常" : "输入权限已就绪",
                detail: isMonitoring
                    ? "可以接收点击、滚轮、输入节奏和应用切换。"
                    : "Agent 启动感知后会开始接收全局行为信号。",
                updatedAt: now
            )
            : RuntimeSubsystemHealth(
                state: .blocked,
                headline: "输入监控未授权",
                detail: "无法接收全局点击、滚轮和键盘节奏；持续阅读状态不会真实触发。",
                updatedAt: now
            )
        accessibilityContext = accessibilityGranted
            ? RuntimeSubsystemHealth(
                state: isMonitoring ? .healthy : .waiting,
                headline: isMonitoring ? "页面 Context 可读取" : "辅助功能已就绪",
                detail: "可以读取当前窗口的标题、网址、可见正文与选中文本。",
                updatedAt: now
            )
            : RuntimeSubsystemHealth(
                state: .blocked,
                headline: "辅助功能未授权",
                detail: "只能看到应用名，无法知道用户具体在读、写或搜索什么。",
                updatedAt: now
            )
        screenshotEvidence = screenRecordingGranted
            ? RuntimeSubsystemHealth(
                state: .healthy,
                headline: "输入框关键截图可用",
                detail: "回车时只截取聚焦输入框或光标附近区域并在本地 OCR；不会录制连续画面，也不会用整窗 OCR 猜提交内容。",
                updatedAt: now
            )
            : RuntimeSubsystemHealth(
                state: .blocked,
                headline: "关键截图未授权",
                detail: "仍会尝试读取 Accessibility 正文，但不暴露编辑器的应用无法记录回车前后的具体内容。",
                updatedAt: now
            )
    }

    func noteBehaviorSignal(at date: Date) {
        guard behaviorSignals.state != .blocked else { return }
        behaviorSignals = RuntimeSubsystemHealth(
            state: .healthy,
            headline: "全局行为信号正常",
            detail: "最近收到真实操作信号。",
            updatedAt: date
        )
    }

    func markScreenshotCaptured(
        recognizedLineCount: Int,
        fullScreenOCRLineCount: Int = 0,
        recognizedSubmittedText: Bool,
        source: ReturnInputCaptureSource,
        cropPixelWidth: Int,
        cropPixelHeight: Int,
        at date: Date = Date()
    ) {
        let regionName = source.userFacingName
        let dimensions = "\(cropPixelWidth)×\(cropPixelHeight)"
        let locator = fullScreenOCRLineCount > 0
            ? "先完成整屏 OCR 定位（发现 \(fullScreenOCRLineCount) 行候选文字），再裁剪输入框做二次 OCR。"
            : "先尝试整屏定位输入框，再使用输入框裁剪图做二次 OCR。"
        let detail: String
        if recognizedSubmittedText {
            detail = "\(locator) 这次回车只截取了\(regionName)（\(dimensions)），并从其中 \(recognizedLineCount) 行本地 OCR 识别本次提交；全窗口文字未参与提交判断。"
        } else if recognizedLineCount > 0 {
            detail = "\(locator) 这次回车只保存了\(regionName)（\(dimensions)）并识别出 \(recognizedLineCount) 行文字，但没有可靠恢复提交正文。"
        } else {
            detail = "\(locator) 这次回车已保存\(regionName)裁剪图（\(dimensions)）；输入框可能在提交后被清空，本地 OCR 没有识别到可用文字。"
        }
        screenshotEvidence = RuntimeSubsystemHealth(
            state: recognizedSubmittedText || recognizedLineCount > 0 ? .healthy : .waiting,
            headline: recognizedSubmittedText ? "已识别输入框提交内容" : "输入区域截图已保存",
            detail: detail,
            updatedAt: date
        )
    }

    func markScreenshotDiscardedSensitive(at date: Date = Date()) {
        screenshotEvidence = RuntimeSubsystemHealth(
            state: .blocked,
            headline: "敏感截图已丢弃",
            detail: "OCR 命中凭证、验证码或支付信息，图片只在内存中检查后即丢弃，未写入日记也未发送模型。",
            updatedAt: date
        )
    }

    func markScreenshotUnavailable(reason: String, at date: Date = Date()) {
        let permission = reason == "screen_recording_permission"
        screenshotEvidence = RuntimeSubsystemHealth(
            state: permission ? .blocked : .error,
            headline: permission ? "关键截图未授权" : "关键截图失败",
            detail: permission
                ? "开启屏幕录制后，回车才能为不暴露编辑器正文的应用生成本地截图与 OCR。"
                : "本次没有生成截图证据；Accessibility Context 仍会继续工作。",
            updatedAt: date
        )
    }

    func markModelAnalysisStarted(at date: Date = Date()) {
        lastExplicitModelUpdate = date
        modelInference = RuntimeSubsystemHealth(
            state: .waiting,
            headline: "AI Hook 已触发 · 正在理解",
            detail: "context_enrichment 已开始，正在等待模型返回语义结果。",
            updatedAt: date
        )
    }

    func markModelAnalysisSucceeded(
        provider: String,
        model: String,
        at date: Date = Date()
    ) {
        lastExplicitModelUpdate = date
        let identity = [provider, model].filter { !$0.isEmpty }.joined(separator: " · ")
        modelInference = RuntimeSubsystemHealth(
            state: .healthy,
            headline: "AI Hook 已触发 · 理解完成",
            detail: identity.isEmpty
                ? "context_enrichment 已返回真实语义理解与 Agent 工作性思考。"
                : "context_enrichment 已返回真实语义理解：\(identity)",
            updatedAt: date
        )
    }

    func markModelAnalysisSkipped(reason: String, at date: Date = Date()) {
        lastExplicitModelUpdate = date
        let normalized = reason.lowercased()
        let blocked = normalized.contains("credential")
            || normalized.contains("permission")
            || normalized.contains("sensitive")
        modelInference = RuntimeSubsystemHealth(
            state: blocked ? .blocked : .waiting,
            headline: blocked ? "AI Hook 被阻断" : "本次没有触发 AI Hook",
            detail: Self.localizedModelReason(reason),
            updatedAt: date
        )
    }

    func markModelAnalysisFailed(errorCode: String, at date: Date = Date()) {
        lastExplicitModelUpdate = date
        modelInference = RuntimeSubsystemHealth(
            state: .error,
            headline: "AI Hook 已触发 · 理解失败",
            detail: "模型返回错误：\(errorCode)。日记不会把这次活动伪装成已理解。",
            updatedAt: date
        )
    }

    func markDiaryPersisted(at date: Date = Date()) {
        lastExplicitDiaryUpdate = date
        diaryPersistence = RuntimeSubsystemHealth(
            state: .healthy,
            headline: "今日日记已落盘",
            detail: "结构化活动、关键证据和 Agent 思考已写入 append-only 日记。",
            updatedAt: date
        )
    }

    func markDiaryPersistenceFailed(_ errorCode: String, at date: Date = Date()) {
        lastExplicitDiaryUpdate = date
        diaryPersistence = RuntimeSubsystemHealth(
            state: .error,
            headline: "今日日记写入失败",
            detail: "结构化 Context 没有成功落盘：\(errorCode)。",
            updatedAt: date
        )
    }

    func refreshFromDisk() {
        refreshModelStatusFromAudit()
        refreshDiaryStatusFromDisk()
    }

    private func refreshModelStatusFromAudit() {
        let settings = AgentModelSettings.shared
        let hasCloudCredential = settings.hasAPIKey || settings.hasKimiConnection
        if settings.route == .local {
            if lastExplicitModelUpdate == nil {
                modelInference = RuntimeSubsystemHealth(
                    state: .waiting,
                    headline: "本地模型尚未报告结果",
                    detail: "路由选择了本地，但还没有看到一次真实的 Context enrichment。",
                    updatedAt: nil
                )
            }
            return
        }

        guard hasCloudCredential else {
            modelInference = RuntimeSubsystemHealth(
                state: .blocked,
                headline: "模型凭证未配置",
                detail: "当前云端/自动路由没有可用凭证，Context 不会产生模型思考。",
                updatedAt: nil
            )
            return
        }

        guard let audit = Self.latestContextAudit() else {
            if lastExplicitModelUpdate == nil {
                modelInference = RuntimeSubsystemHealth(
                    state: .waiting,
                    headline: "模型已配置，尚未理解 Context",
                    detail: "只完成连接还不算运行成功；等待第一条 context_enrichment 审计。",
                    updatedAt: nil
                )
            }
            return
        }
        if let explicit = lastExplicitModelUpdate, explicit > audit.timestamp { return }
        modelInference = audit.succeeded
            ? RuntimeSubsystemHealth(
                state: .healthy,
                headline: "AI Hook 已触发 · 理解完成",
                detail: "最近一次真实 context_enrichment 已通过模型完成。",
                updatedAt: audit.timestamp
            )
            : RuntimeSubsystemHealth(
                state: .error,
                headline: "AI Hook 已触发 · 理解失败",
                detail: "最近一次 context_enrichment 失败：\(audit.errorCode ?? "未知错误")。",
                updatedAt: audit.timestamp
            )
    }

    private func refreshDiaryStatusFromDisk() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let dailyURL = AgentHomePreferences.diaryURL
            .appendingPathComponent("Daily", isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: Date())).md")
        guard FileManager.default.fileExists(atPath: dailyURL.path) else {
            if lastExplicitDiaryUpdate == nil {
                diaryPersistence = RuntimeSubsystemHealth(
                    state: .waiting,
                    headline: "今天还没有日记",
                    detail: "尚未发现今天的 Markdown 日记文件。",
                    updatedAt: nil
                )
            }
            return
        }
        let modified = (try? dailyURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let explicit = lastExplicitDiaryUpdate, let modified, explicit > modified { return }
        diaryPersistence = RuntimeSubsystemHealth(
            state: .healthy,
            headline: "今日日记已落盘",
            detail: "已找到今天的 append-only Markdown 日记。",
            updatedAt: modified
        )
    }

    private static func localizedModelReason(_ reason: String) -> String {
        switch reason.lowercased() {
        case "missing_credential": "没有可用模型凭证，云端 Context 理解未发生。"
        case "no_concrete_context", "no_context": "当前只有泛化行为信号，没有足够的页面正文、网址或文档信息。"
        case "sensitive_context_blocked": "检测到密码、支付或安全输入，Context 已在模型请求前阻断。"
        case "local_model_unavailable": "本地模型尚未安装或不可用。"
        case "local_resources_memory_pressure", "local_resources_available_memory",
             "local_resources_memory_compression", "local_resources_swap_usage":
            "系统内存比较紧张。Context 已保存，本地模型会等电脑空闲后再分析。"
        case "local_resources_system_load":
            "系统正在忙。Context 已保存，本地模型不会和前台应用抢 CPU。"
        case "local_resources_thermal_state":
            "电脑温度较高。Context 已保存，本地模型会在降温后再分析。"
        case "local_resources_low_power_mode":
            "电脑处于低电量模式。本地模型已暂停。"
        case "local_resources_foreground_activity":
            "你还在打字或操作电脑。Context 已保存，语义分析会延后到空闲时。"
        case "permission_unavailable": "系统权限不足，无法形成可发送给模型的具体 Context。"
        default: reason.isEmpty ? "运行时没有提供原因。" : reason
        }
    }

    private struct ContextAudit {
        var timestamp: Date
        var succeeded: Bool
        var errorCode: String?
    }

    private static func latestContextAudit() -> ContextAudit? {
        let url = AgentHomePreferences.rootURL
            .appendingPathComponent("Model Invocations", isDirectory: true)
            .appendingPathComponent("model-invocations.jsonl")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let lines = data.split(separator: 0x0A).suffix(500).reversed()
        for line in lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                object["purpose"] as? String == "context_enrichment",
                let timestampString = object["timestamp"] as? String,
                let timestamp = parseISO8601(timestampString),
                let succeeded = object["succeeded"] as? Bool
            else { continue }
            return ContextAudit(
                timestamp: timestamp,
                succeeded: succeeded,
                errorCode: object["errorCode"] as? String
            )
        }
        return nil
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum AgentOneSection: String, CaseIterable, Identifiable, Hashable {
    case now
    case replay
    case memory
    case journal
    case skills
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: "此刻"
        case .replay: "回放"
        case .memory: "记忆"
        case .journal: "Agent 日记"
        case .skills: "Skills"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .now: "sparkles"
        case .replay: "clock.arrow.circlepath"
        case .memory: "circle.hexagongrid.fill"
        case .journal: "quote.bubble.fill"
        case .skills: "wand.and.stars"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum AgentMood: String, CaseIterable, Identifiable {
    case observing
    case focused
    case curious
    case resting
    case delighted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .observing: "正在观察"
        case .focused: "和你一起专注"
        case .curious: "有点好奇"
        case .resting: "安静待着"
        case .delighted: "发现了新东西"
        }
    }

    var accent: Color {
        switch self {
        case .observing: AgentOnePalette.blue
        case .focused: AgentOnePalette.mint
        case .curious: AgentOnePalette.violet
        case .resting: Color(red: 0.45, green: 0.55, blue: 0.73)
        case .delighted: AgentOnePalette.amber
        }
    }
}

struct IntentSnapshot: Identifiable {
    let id: UUID
    var title: String
    var detail: String
    var application: String
    var confidence: Double
    var startedAt: Date
    var signals: [String]

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        application: String,
        confidence: Double,
        startedAt: Date,
        signals: [String]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.application = application
        self.confidence = confidence
        self.startedAt = startedAt
        self.signals = signals
    }
}

struct ReplayMoment: Identifiable {
    enum Kind {
        case focus, output, detour, returnToTask, rest

        var symbol: String {
            switch self {
            case .focus: "scope"
            case .output: "return"
            case .detour: "arrow.triangle.branch"
            case .returnToTask: "arrow.uturn.backward"
            case .rest: "cup.and.saucer.fill"
            }
        }

        var color: Color {
            switch self {
            case .focus: AgentOnePalette.mint
            case .output: AgentOnePalette.blue
            case .detour: AgentOnePalette.amber
            case .returnToTask: AgentOnePalette.violet
            case .rest: AgentOnePalette.textTertiary
            }
        }
    }

    let id: UUID
    var time: String
    var title: String
    var detail: String
    var application: String
    var kind: Kind
    var evidenceLabel: String?
    var evidenceResourcePath: String?

    init(
        id: UUID = UUID(),
        time: String,
        title: String,
        detail: String,
        application: String,
        kind: Kind,
        evidenceLabel: String?,
        evidenceResourcePath: String? = nil
    ) {
        self.id = id
        self.time = time
        self.title = title
        self.detail = detail
        self.application = application
        self.kind = kind
        self.evidenceLabel = evidenceLabel
        self.evidenceResourcePath = evidenceResourcePath
    }
}

struct ReplayDayOption: Identifiable, Hashable {
    let day: String
    let label: String
    let contextCount: Int
    let journalCount: Int
    let skillCount: Int

    var id: String { day }
}

struct MemoryCard: Identifiable {
    enum Source: String {
        case confirmed = "你确认的"
        case observed = "共同经历"
        case inferred = "我的发现"
    }

    let id: UUID
    var title: String
    var detail: String
    var source: Source
    var date: String
    var tags: [String]
    var confidence: Double? = nil
    var evidenceCount: Int? = nil

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        source: Source,
        date: String,
        tags: [String],
        confidence: Double? = nil,
        evidenceCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.source = source
        self.date = date
        self.tags = tags
        self.confidence = confidence
        self.evidenceCount = evidenceCount
    }
}

struct AgentSkillCard: Identifiable {
    let id: UUID
    var name: String
    var detail: String
    var level: Int
    var completion: Double
    var evidenceCount: Int
    var learnedFrom: String
    var domain: String
    var triggerTerms: [String]
    var rawTriggerTerms: [String]
    var guidance: String
    var confidence: Double
    var revision: Int
    var evidenceIDs: [UUID]
    var createdAt: Date
    var hasCompleteRecord: Bool
    var symbol: String
    var tint: Color

    var completionPercent: Int {
        Int((min(1, max(0, completion)) * 100).rounded())
    }

    func isUnlocked(_ stage: Int) -> Bool {
        level >= stage
    }

    var nextUnlockPercent: Int? {
        switch level {
        case 1: 20
        case 2: 40
        case 3: 60
        case 4: 80
        default: nil
        }
    }
}

struct AgentJournalCard: Identifiable {
    let id: UUID
    var timestamp: Date
    var observation: String
    var submittedText: String?
    var evidenceLabel: String?
    var evidenceResourcePath: String?
    var hypothesis: String?
    var consideredAction: String?
    var why: String?
    var disposition: String
    var uncertainty: Double
}

struct DailyDigestCard: Identifiable {
    let id: UUID
    var generatedAt: Date
    var isFinal: Bool
    var headline: String
    var overview: String
    var highlights: [String]
    var rhythm: String?
    var unfinishedThread: String?
    var agentNote: String
    var invitation: String?
    var mood: String
    var sourceContextCount: Int
    var evidenceCount: Int
    var personalizedMemoryCount: Int
}

@MainActor
final class AgentOneShellViewModel: ObservableObject {
    @Published var selection: AgentOneSection = .now
    @Published var mood: AgentMood = .focused
    @Published var companionIsVisible = false
    @Published var isConversationMode = false
    @Published var isPaused = false
    @Published var selectedReplayMomentID: UUID?
    @Published var hasLiveContext = false
    @Published var hasLiveReplay = false
    @Published var lastRuntimeUpdate: Date?
    @Published var replayDayLabel = "今天"
    @Published var replayDays: [ReplayDayOption] = []
    @Published var selectedReplayDay: String?
    @Published var totalRecordedContextCount = 0
    @Published var totalRecordedDays = 0
    @Published var learnedHabits: [MemoryCard] = []
    @Published var agentJournalEntries: [AgentJournalCard] = []
    @Published var dailyDigest: DailyDigestCard?
    @Published var skills: [AgentSkillCard] = []
    @Published var memories: [MemoryCard] = []

    @Published var currentIntent = IntentSnapshot(
        title: "等待理解此刻的 Context",
        detail: "开始阅读、写作或浏览后，我会从当前页面和连续行为中理解你具体在做什么。",
        application: "尚未捕获",
        confidence: 0,
        startedAt: Date(),
        signals: ["等待 Accessibility Context"]
    )

    @Published var replayMoments: [ReplayMoment] = []

    /// The complete persisted replay read model. It is intentionally kept out
    /// of the view layer so Replay, Journal and Memory can all select the same
    /// historical day without re-reading or mutating the append-only diary.
    var persistedReplaysByDay: [String: AgentOneCore.SemanticReplay] = [:]
    var isBrowsingReplayHistory = false

    func select(_ section: AgentOneSection) {
        withAnimation(.snappy(duration: 0.28)) {
            selection = section
        }
    }

    func togglePause() {
        isPaused.toggle()
        mood = isPaused ? .resting : .focused
    }
}
