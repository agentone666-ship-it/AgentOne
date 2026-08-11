import AppKit
import SwiftUI
import AgentOneModelRuntime

enum AgentInferenceMode: String, CaseIterable, Identifiable {
    case cloud = "云端模型"
    case local = "本地模型"
    case automatic = "自动判断"

    var id: String { rawValue }

    init(route: ModelInferenceRoute) {
        switch route {
        case .cloud: self = .cloud
        case .local: self = .local
        case .automatic: self = .automatic
        }
    }

    var route: ModelInferenceRoute {
        switch self {
        case .cloud: .cloud
        case .local: .local
        case .automatic: .automatic
        }
    }

    var symbol: String {
        switch self {
        case .cloud: "cloud.fill"
        case .local: "desktopcomputer"
        case .automatic: "arrow.triangle.branch"
        }
    }

    var detail: String {
        switch self {
        case .cloud: "效果优先。优先使用你的 Kimi Code 连接，也可以在高级设置中使用 API Key。"
        case .local: "所有推理都留在设备上。需要先安装兼容的本地模型。"
        case .automatic: "由路由模型按内容敏感度、复杂度与成本自动选择。"
        }
    }
}

private enum ModelAccessChoice: Equatable {
    case kimi
    case apiKey
    case skipped
}

enum ReminderPreset: String, CaseIterable, Identifiable {
    case gentle = "温和"
    case balanced = "标准"
    case active = "积极"

    var id: String { rawValue }

    static let preferenceKey = "agentOne.reminder.preset"

    static var savedPreference: ReminderPreset {
        UserDefaults.standard.string(forKey: preferenceKey)
            .flatMap(ReminderPreset.init(rawValue:)) ?? .balanced
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.preferenceKey)
    }

    var delay: String {
        switch self {
        case .gentle: "5 分钟后好奇地问"
        case .balanced: "2 分钟后轻轻询问"
        case .active: "45 秒后给一个小暗示"
        }
    }

    var pulseCount: Int {
        switch self {
        case .gentle: 1
        case .balanced: 2
        case .active: 3
        }
    }
}

struct AgentOneOnboardingView: View {
    let onComplete: () -> Void

    @ObservedObject private var modelSettings = AgentModelSettings.shared
    @State private var page = 0
    @State private var homePath = AgentHomePreferences.rootURL.path
    @State private var mode: AgentInferenceMode = .cloud
    @State private var apiKey = ""
    @State private var apiKeyBaseURL = AgentModelSettings.defaultAPIKeyBaseURL
    @State private var apiKeyModel = AgentModelSettings.defaultAPIKeyModel
    @State private var reminder: ReminderPreset = .balanced
    @State private var showKey = false
    @State private var modelAccessChoice: ModelAccessChoice = .kimi
    @State private var connectionError: String?

    var body: some View {
        ZStack {
            AmbientBackground()

            HStack(spacing: 0) {
                visualColumn
                    .frame(width: 365)

                VStack(spacing: 0) {
                    HStack {
                        ForEach(0..<4, id: \.self) { index in
                            Capsule()
                                .fill(index <= page ? AgentOnePalette.blue : AgentOnePalette.border)
                                .frame(width: index == page ? 32 : 9, height: 5)
                                .animation(.snappy, value: page)
                        }
                        Spacer()
                        Text("\(page + 1) / 4")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AgentOnePalette.textTertiary)
                    }
                    .padding(.horizontal, 42)
                    .padding(.top, 32)

                    Group {
                        switch page {
                        case 0: homeStep
                        case 1: modelStep
                        case 2: reminderStep
                        default: readyStep
                        }
                    }
                    .frame(maxWidth: 620, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 58)

                    HStack {
                        if page > 0 {
                            Button("返回") {
                                withAnimation(.snappy) { page -= 1 }
                            }
                            .buttonStyle(QuietActionButtonStyle())
                        }
                        Spacer()
                        Button(page == 3 ? "开始共同生活" : "继续") {
                            if page == 3 {
                                persistOnboardingChoices()
                                onComplete()
                            } else {
                                withAnimation(.snappy) { page += 1 }
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                    }
                    .padding(.horizontal, 42)
                    .padding(.bottom, 34)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var visualColumn: some View {
        ZStack {
            LinearGradient(
                colors: [AgentOnePalette.surface1, AgentOnePalette.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Rectangle()
                .fill(AgentOnePalette.separator)
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(spacing: AgentOneMetric.spacingXXL) {
                MemoryGlowBeing(mood: onboardingMood, size: 190)
                VStack(spacing: AgentOneMetric.spacingS) {
                    Text("不是一个新账号")
                        .font(AgentOneType.caption)
                        .fontWeight(.bold)
                        .tracking(1.2)
                        .foregroundStyle(AgentOnePalette.blue)
                    Text("是一段共同时间的开始")
                        .font(AgentOneType.title)
                    Text("它生活在你的电脑里。\n你拥有它的全部记忆与成长。")
                        .font(AgentOneType.callout)
                        .foregroundStyle(AgentOnePalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
            }
            .padding(AgentOneMetric.spacingXXL)
        }
    }

    private var onboardingMood: AgentMood {
        switch page {
        case 0: .observing
        case 1: .curious
        case 2: .focused
        default: .delighted
        }
    }

    private var homeStep: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXL) {
            stepHeading("选择它的家", "Agent Home 保存日记、结构化记忆、Skills、关键证据和生命状态。你可以随时完整迁移。")

            VStack(alignment: .leading, spacing: AgentOneMetric.spacingM) {
                Text("AGENT HOME")
                    .font(AgentOneType.caption)
                    .fontWeight(.bold)
                    .tracking(1.4)
                    .foregroundStyle(AgentOnePalette.textSecondary)
                Button {
                    chooseHomeFolder()
                } label: {
                    HStack(spacing: AgentOneMetric.spacingM) {
                        Image(systemName: "folder.fill").foregroundStyle(AgentOnePalette.blue)
                        Text(homePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("更改").foregroundStyle(AgentOnePalette.blue)
                    }
                    .font(AgentOneType.caption)
                    .padding(AgentOneMetric.spacingL)
                    .background(
                        AgentOnePalette.surface1.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: AgentOneMetric.radiusSmall, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: AgentOneMetric.radiusSmall, style: .continuous)
                            .stroke(AgentOnePalette.border)
                    }
                }
                .buttonStyle(.plain)
            }

            privacyPromise
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXL) {
            stepHeading("给它接上思考能力", "推荐使用 Kimi 自动登录。这不是登录 AgentOne；你的日记、记忆和成长仍然属于这台 Mac。")

            VStack(alignment: .leading, spacing: AgentOneMetric.spacingM) {
                KimiConnectionCard(
                    modelSettings: modelSettings,
                    detail: "通过 Kimi Code 官方设备码授权，使用你的订阅让它开始理解、回顾和陪伴。",
                    showsRecommendedBadge: true,
                    isEmphasized: modelAccessChoice == .kimi,
                    footnote: modelSettings.hasKimiConnection ? "连接完成" : "凭据只保存在本机私密文件",
                    footnoteTint: modelSettings.hasKimiConnection ? AgentOnePalette.mint : AgentOnePalette.textTertiary,
                    errorText: connectionError,
                    primaryTitle: modelSettings.isConnectingKimi ? "等待 Kimi 授权…" : (modelSettings.hasKimiConnection ? "已连接" : "用 Kimi 自动登录"),
                    primaryDisabled: modelSettings.isConnectingKimi || modelSettings.hasKimiConnection,
                    onPrimary: {
                        modelAccessChoice = .kimi
                        connectKimi()
                    }
                )

                Button {
                    modelAccessChoice = .apiKey
                    connectionError = nil
                } label: {
                    HStack(spacing: AgentOneMetric.spacingS) {
                        Image(systemName: "key.horizontal.fill")
                            .foregroundStyle(modelAccessChoice == .apiKey ? AgentOnePalette.violet : AgentOnePalette.textSecondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                            Text("使用 API Key")
                                .font(AgentOneType.caption)
                                .fontWeight(.semibold)
                            Text("接入兼容模型服务，Key 只保存在本机私密配置。")
                                .font(AgentOneType.caption)
                                .foregroundStyle(AgentOnePalette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: modelAccessChoice == .apiKey ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(modelAccessChoice == .apiKey ? AgentOnePalette.violet : AgentOnePalette.borderBright)
                    }
                    .padding(AgentOneMetric.spacingM)
                }
                .buttonStyle(AgentOneSelectableCardStyle(isSelected: modelAccessChoice == .apiKey, tint: AgentOnePalette.violet))

                if modelAccessChoice == .apiKey {
                    VStack(spacing: AgentOneMetric.spacingM) {
                        TextField("", text: $apiKeyBaseURL, prompt: Text("服务地址").foregroundStyle(AgentOnePalette.textTertiary))
                            .agentOneInputField(tint: AgentOnePalette.violet)
                        TextField("", text: $apiKeyModel, prompt: Text("模型名").foregroundStyle(AgentOnePalette.textTertiary))
                            .agentOneInputField(tint: AgentOnePalette.violet)
                        HStack(spacing: AgentOneMetric.spacingS) {
                            Group {
                                if showKey {
                                    TextField("", text: $apiKey, prompt: Text("输入模型 API Key").foregroundStyle(AgentOnePalette.textTertiary))
                                } else {
                                    SecureField("", text: $apiKey, prompt: Text("输入模型 API Key").foregroundStyle(AgentOnePalette.textTertiary))
                                }
                            }
                            Button { showKey.toggle() } label: {
                                Image(systemName: showKey ? "eye.slash.fill" : "eye.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AgentOnePalette.textSecondary)
                        }
                        .agentOneInputField(tint: AgentOnePalette.violet)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Button {
                    modelAccessChoice = .skipped
                    connectionError = nil
                } label: {
                    HStack(spacing: AgentOneMetric.spacingS) {
                        Image(systemName: "clock.badge.questionmark")
                            .foregroundStyle(modelAccessChoice == .skipped ? AgentOnePalette.textPrimary : AgentOnePalette.textSecondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                            Text("暂时跳过")
                                .font(AgentOneType.caption)
                                .fontWeight(.semibold)
                            Text("先不用模型，之后随时可以在设置中连接。")
                                .font(AgentOneType.caption)
                                .foregroundStyle(AgentOnePalette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: modelAccessChoice == .skipped ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(modelAccessChoice == .skipped ? AgentOnePalette.textPrimary : AgentOnePalette.borderBright)
                    }
                    .padding(AgentOneMetric.spacingM)
                }
                .buttonStyle(AgentOneSelectableCardStyle(isSelected: modelAccessChoice == .skipped, tint: AgentOnePalette.textPrimary))
            }
        }
    }

    private var reminderStep: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXL) {
            stepHeading("我该什么时候碰一碰你？", "只有新行为与刚才确认的意图冲突时，我才会把它当作可能的岔路。以后会根据你的反馈自动调整。")

            HStack(spacing: AgentOneMetric.spacingM) {
                ForEach(ReminderPreset.allCases) { option in
                    Button {
                        reminder = option
                    } label: {
                        VStack(alignment: .leading, spacing: AgentOneMetric.spacingM) {
                            HStack {
                                ForEach(0..<option.pulseCount, id: \.self) { _ in
                                    Circle()
                                        .fill(option == reminder ? AgentOnePalette.violet : AgentOnePalette.borderBright)
                                        .frame(width: 5, height: 5)
                                }
                                Spacer()
                                if option == reminder {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AgentOnePalette.violet)
                                }
                            }
                            Text(option.rawValue).font(AgentOneType.headline)
                            Text(option.delay)
                                .font(AgentOneType.caption)
                                .foregroundStyle(AgentOnePalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(AgentOneMetric.spacingL)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    }
                    .buttonStyle(AgentOneSelectableCardStyle(isSelected: option == reminder, tint: AgentOnePalette.violet))
                }
            }

            HStack(alignment: .top, spacing: AgentOneMetric.spacingM) {
                Image(systemName: "hand.raised.fill").foregroundStyle(AgentOnePalette.mint)
                Text("提醒会从动作、气泡逐级增强，后续可接入触觉反馈，但永远不会强行阻止你。你也可以随时告诉我：“我现在只是想休息。”")
                    .font(AgentOneType.callout)
                    .foregroundStyle(AgentOnePalette.textSecondary)
                    .lineSpacing(3)
            }
            .agentOneCard(padding: AgentOneMetric.spacingL)
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXL) {
            stepHeading("准备好认识彼此了", "我一开始不会完全懂你。每一次确认、纠正和没有打扰，都会成为我们以后更有默契的原因。")

            VStack(spacing: 0) {
                ReadyRow(symbol: "folder.fill", title: "家", value: homePath)
                Divider().overlay(AgentOnePalette.separator).padding(.leading, 40)
                ReadyRow(symbol: mode.symbol, title: "思考", value: mode.rawValue)
                Divider().overlay(AgentOnePalette.separator).padding(.leading, 40)
                ReadyRow(symbol: kimiReadySymbol, title: "Kimi", value: kimiReadyStatus)
                Divider().overlay(AgentOnePalette.separator).padding(.leading, 40)
                ReadyRow(symbol: "bell.badge.fill", title: "提醒", value: reminder.rawValue)
                Divider().overlay(AgentOnePalette.separator).padding(.leading, 40)
                ReadyRow(symbol: "person.crop.circle.badge.xmark", title: "AgentOne 账号", value: "不需要")
            }
            .agentOneCard(padding: AgentOneMetric.spacingS)

            Text("继续即表示你知道：屏幕感知需要 macOS 屏幕录制与辅助功能权限。支付、密码及系统安全输入区域永远不会被采集。")
                .font(AgentOneType.caption)
                .foregroundStyle(AgentOnePalette.textTertiary)
                .lineSpacing(3)
        }
    }

    private func stepHeading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingS) {
            Text(title)
                .font(AgentOneType.title)
            Text(detail)
                .font(AgentOneType.callout)
                .foregroundStyle(AgentOnePalette.textSecondary)
                .lineSpacing(4)
        }
    }

    private var privacyPromise: some View {
        HStack(alignment: .top, spacing: AgentOneMetric.spacingM) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(AgentOnePalette.mint)
            VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                Text("这段生命属于你")
                    .font(AgentOneType.caption)
                    .fontWeight(.semibold)
                Text("没有产品账号，没有平台侧记忆副本。日记采用追加式记录，可以隐藏敏感片段，也可以通过删除软件销毁整个 Agent。")
                    .font(AgentOneType.caption)
                    .foregroundStyle(AgentOnePalette.textSecondary)
                    .lineSpacing(3)
            }
        }
        .agentOneCard(padding: AgentOneMetric.spacingL)
    }

    private func chooseHomeFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择 Agent Home"
        panel.prompt = "选为它的家"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            homePath = url.path
        }
    }

    private func persistOnboardingChoices() {
        let settings = AgentModelSettings.shared
        AgentHomePreferences.save(rootPath: homePath)
        settings.route = mode.route
        reminder.persist()

        if modelAccessChoice == .apiKey {
            let normalizedBaseURL = apiKeyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedModel = apiKeyModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedBaseURL.isEmpty { settings.apiKeyBaseURL = normalizedBaseURL }
            if !normalizedModel.isEmpty { settings.apiKeyModel = normalizedModel }
            let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedKey.isEmpty {
                if settings.saveAPIKey(normalizedKey) {
                    settings.preferredCloudAuthentication = .apiKey
                }
            } else if settings.hasAPIKey {
                settings.preferredCloudAuthentication = .apiKey
            }
        }
    }

    private var kimiReadySymbol: String {
        if modelSettings.hasKimiConnection { return "checkmark.bubble.fill" }
        if modelAccessChoice == .apiKey { return "key.horizontal.fill" }
        return "bubble.left.and.bubble.right"
    }

    private var kimiReadyStatus: String {
        if modelSettings.hasKimiConnection { return "已连接" }
        if modelAccessChoice == .apiKey {
            return apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !modelSettings.hasAPIKey
                ? "API Key 尚未填写"
                : "使用 API Key"
        }
        if modelAccessChoice == .skipped { return "暂时跳过，可稍后设置" }
        return "尚未完成连接"
    }

    private func connectKimi() {
        connectionError = nil
        Task { @MainActor in
            let connected = await modelSettings.connectKimi()
            if !connected {
                connectionError = modelSettings.credentialError ?? "没有完成连接。你也可以选择 API Key 或暂时跳过。"
            }
        }
    }
}

private struct ReadyRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: AgentOneMetric.spacingM) {
            Image(systemName: symbol)
                .foregroundStyle(AgentOnePalette.blue)
                .frame(width: 24)
            Text(title)
                .font(AgentOneType.caption)
                .fontWeight(.semibold)
            Spacer()
            Text(value)
                .font(AgentOneType.caption)
                .foregroundStyle(AgentOnePalette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, AgentOneMetric.spacingM)
        .frame(height: 42)
    }
}

// MARK: - Shared components (onboarding & settings)

/// 可选卡片容器：填充 + 描边 + 选中高亮。onboarding 的接入方式 / 提醒预设与设置页的提醒预设共用。
struct AgentOneSelectableCardStyle: ButtonStyle {
    var isSelected: Bool
    var tint: Color = AgentOnePalette.blue
    var cornerRadius: CGFloat = AgentOneMetric.radiusCard

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.09) : AgentOnePalette.surface1.opacity(0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(isSelected ? tint.opacity(0.32) : AgentOnePalette.border, lineWidth: 1)
                    }
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.2), value: isSelected)
    }
}

/// Kimi 连接卡：onboarding 与设置页共用，凭证由本机私密文件管理。
struct KimiConnectionCard: View {
    @ObservedObject var modelSettings: AgentModelSettings
    var detail: String
    var showsRecommendedBadge = false
    var isEmphasized = false
    var footnote: String? = nil
    var footnoteTint: Color = AgentOnePalette.textTertiary
    var errorText: String? = nil
    var primaryTitle: String
    var primaryDisabled = false
    var onPrimary: () -> Void
    var onDisconnect: (() -> Void)? = nil

    private var connected: Bool { modelSettings.hasKimiConnection }

    var body: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingM) {
            HStack(alignment: .top, spacing: AgentOneMetric.spacingM) {
                ZStack {
                    Circle()
                        .fill((connected ? AgentOnePalette.mint : AgentOnePalette.blue).opacity(0.13))
                    Image(systemName: connected ? "checkmark.bubble.fill" : "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(connected ? AgentOnePalette.mint : AgentOnePalette.blue)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                    HStack(spacing: AgentOneMetric.spacingS) {
                        Text(connected ? "Kimi 已连接" : "连接 Kimi")
                            .font(AgentOneType.headline)
                        if connected {
                            Circle()
                                .fill(AgentOnePalette.mint)
                                .frame(width: 6, height: 6)
                        } else if showsRecommendedBadge {
                            AgentOnePill(title: "推荐", tint: AgentOnePalette.blue)
                        }
                    }
                    Text(detail)
                        .font(AgentOneType.callout)
                        .foregroundStyle(AgentOnePalette.textSecondary)
                        .lineSpacing(3)
                }

                Spacer(minLength: AgentOneMetric.spacingM)

                if connected, let onDisconnect {
                    Button("断开", action: onDisconnect)
                        .buttonStyle(QuietActionButtonStyle())
                } else {
                    Button(primaryTitle, action: onPrimary)
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(primaryDisabled)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(AgentOneType.caption)
                    .foregroundStyle(.red.opacity(0.86))
            } else if let footnote {
                Text(footnote)
                    .font(AgentOneType.caption)
                    .foregroundStyle(footnoteTint)
            }
        }
        .padding(AgentOneMetric.spacingL)
        .background(
            RoundedRectangle(cornerRadius: AgentOneMetric.radiusCard, style: .continuous)
                .fill(
                    connected
                        ? AgentOnePalette.mint.opacity(0.055)
                        : (isEmphasized ? AgentOnePalette.blue.opacity(0.075) : AgentOnePalette.surface1.opacity(0.55))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AgentOneMetric.radiusCard, style: .continuous)
                        .stroke(
                            connected
                                ? AgentOnePalette.mint.opacity(0.3)
                                : (isEmphasized ? AgentOnePalette.blue.opacity(0.3) : AgentOnePalette.border),
                            lineWidth: 1
                        )
                }
        )
    }
}

private struct AgentOneInputFieldModifier: ViewModifier {
    var tint: Color
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(AgentOneType.callout)
            .foregroundStyle(AgentOnePalette.textPrimary)
            .tint(tint)
            .focused($isFocused)
            .padding(AgentOneMetric.spacingM)
            .background(
                AgentOnePalette.surface1.opacity(0.9),
                in: RoundedRectangle(cornerRadius: AgentOneMetric.radiusSmall, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AgentOneMetric.radiusSmall, style: .continuous)
                    .stroke(isFocused ? tint.opacity(0.55) : AgentOnePalette.border, lineWidth: 1)
            }
            .animation(.snappy(duration: 0.18), value: isFocused)
    }
}

extension View {
    /// 统一输入框：radiusSmall 圆角容器 + focus 态 accent 描边。onboarding 与设置的凭证编辑器共用。
    func agentOneInputField(tint: Color = AgentOnePalette.blue) -> some View {
        modifier(AgentOneInputFieldModifier(tint: tint))
    }
}
