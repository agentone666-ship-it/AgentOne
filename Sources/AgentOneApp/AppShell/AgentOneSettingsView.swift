import SwiftUI
import AgentOneModelRuntime

struct AgentOneSettingsView: View {
    @ObservedObject var model: AgentOneShellViewModel
    @ObservedObject private var modelSettings = AgentModelSettings.shared
    @State private var inferenceMode: AgentInferenceMode
    @State private var reminderPreset: ReminderPreset
    @AppStorage(CompanionPreferenceKeys.surpriseFrequency) private var surpriseFrequency = 0.45
    @State private var cloudLedgerEnabled: Bool
    @AppStorage(CompanionPreferenceKeys.journalInvitationsEnabled) private var journalInvitationEnabled = true
    @AppStorage(CompanionPreferenceKeys.proactiveCompanionEnabled) private var proactiveCompanionEnabled = true
    @State private var launchAtLogin = true
    @State private var companionAlwaysVisible = true
    @State private var excludedApps = ["1Password", "系统密码输入", "支付页面"]
    @State private var showsCredentialEditor = false
    @State private var showsAdvancedModelOptions = false
    @State private var connectionError: String?

    init(model: AgentOneShellViewModel) {
        self.model = model
        let settings = AgentModelSettings.shared
        _inferenceMode = State(initialValue: AgentInferenceMode(route: settings.route))
        _reminderPreset = State(initialValue: ReminderPreset.savedPreference)
        _cloudLedgerEnabled = State(initialValue: settings.auditsCloudInvocations)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AgentOneMetric.spacingXL) {
                SectionHeading(
                    eyebrow: "Your boundaries",
                    title: "设置",
                    subtitle: "尽量少让你做配置。这里留下的，是值得由你亲自决定的边界。"
                )

                settingsSection("运行健康", symbol: "stethoscope") {
                    RuntimeHealthOverview(showsPermissionActions: true)
                    Text("授权后通常需要重新启动 AgentOne。绿色只代表该层真实可用；模型成功还必须出现 context_enrichment，不能用连接成功代替。")
                        .font(AgentOneType.caption)
                        .foregroundStyle(AgentOnePalette.textTertiary)
                        .lineSpacing(3)
                }

                settingsSection("生命与陪伴", symbol: "sparkles") {
                    SettingsToggleRow(
                        title: "始终显示桌面生命体",
                        detail: "安静时降低亮度和动作，不抢夺注意力。",
                        isOn: $companionAlwaysVisible
                    )
                    Divider().overlay(AgentOnePalette.separator)
                    SettingsToggleRow(
                        title: "每天邀请回顾日记",
                        detail: "当一天的 Context 已经提炼完成，我会在你停下来或轻松浏览时主动探头；跳过后不再追问这版日记。",
                        isOn: $journalInvitationEnabled
                    )
                    Divider().overlay(AgentOnePalette.separator)
                    SettingsToggleRow(
                        title: "允许 LUMA 主动找我",
                        detail: "只在有具体内容可说、没有敏感 Context 且不打断输入时出现。关闭后仍会安静记录和总结。",
                        isOn: $proactiveCompanionEnabled
                    )
                    Divider().overlay(AgentOnePalette.separator)
                    SettingsToggleRow(
                        title: "登录后自然出现",
                        detail: "无需产品账号，Agent 随这台 Mac 启动。",
                        isOn: $launchAtLogin
                    )

                    VStack(alignment: .leading, spacing: AgentOneMetric.spacingM) {
                        HStack {
                            Text("惊喜频率")
                                .font(AgentOneType.caption)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(surpriseFrequencyLabel)
                                .font(AgentOneType.caption)
                                .foregroundStyle(AgentOnePalette.violet)
                        }
                        Slider(value: $surpriseFrequency, in: 0...1)
                            .tint(AgentOnePalette.violet)
                        Text("我会根据你对过去惊喜的反应继续微调，但不会用情绪让你产生负担。")
                            .font(AgentOneType.caption)
                            .foregroundStyle(AgentOnePalette.textTertiary)
                    }
                    .padding(.top, AgentOneMetric.spacingXS)
                }

                settingsSection("思考方式", symbol: "brain.head.profile") {
                    Picker("模型路由", selection: $inferenceMode) {
                        ForEach(AgentInferenceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(alignment: .top, spacing: AgentOneMetric.spacingM) {
                        Image(systemName: inferenceMode.symbol)
                            .foregroundStyle(AgentOnePalette.blue)
                        Text(inferenceMode.detail)
                            .font(AgentOneType.callout)
                            .foregroundStyle(AgentOnePalette.textSecondary)
                            .lineSpacing(3)
                    }

                    KimiConnectionCard(
                        modelSettings: modelSettings,
                        detail: "使用 Kimi Code 订阅来思考。浏览器只负责 Kimi 授权，AgentOne 仍然没有产品账号。",
                        errorText: connectionError,
                        primaryTitle: modelSettings.isConnectingKimi ? "等待 Kimi 授权…" : "用 Kimi 自动登录",
                        primaryDisabled: modelSettings.isConnectingKimi,
                        onPrimary: {
                            connectKimi()
                        },
                        onDisconnect: {
                            modelSettings.disconnectKimi()
                            connectionError = nil
                        }
                    )

                    Button {
                        withAnimation(.snappy) {
                            showsAdvancedModelOptions.toggle()
                        }
                    } label: {
                        HStack(spacing: AgentOneMetric.spacingS) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                            Text("外部模型")
                            Spacer()
                            Text(modelSettings.hasAPIKey ? "API Key 已保存" : "API Key")
                                .foregroundStyle(AgentOnePalette.textTertiary)
                            Image(systemName: showsAdvancedModelOptions ? "chevron.up" : "chevron.down")
                        }
                        .font(AgentOneType.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(AgentOnePalette.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showsAdvancedModelOptions {
                        HStack(alignment: .top, spacing: AgentOneMetric.spacingM) {
                            Image(systemName: "key.horizontal.fill")
                                .foregroundStyle(AgentOnePalette.violet)
                            VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                                Text("使用模型 API Key")
                                    .font(AgentOneType.caption)
                                    .fontWeight(.semibold)
                                Text("使用 OpenAI-compatible 服务。Key 保存在本机私密配置中，调用时才注入请求。")
                                    .font(AgentOneType.caption)
                                    .foregroundStyle(AgentOnePalette.textSecondary)
                                    .lineSpacing(3)
                            }
                            Spacer()
                            Button(modelSettings.hasAPIKey ? "管理" : "设置") {
                                showsCredentialEditor = true
                            }
                            .buttonStyle(QuietActionButtonStyle())
                        }
                        .padding(AgentOneMetric.spacingM)
                        .background(
                            AgentOnePalette.surface2.opacity(0.55),
                            in: RoundedRectangle(cornerRadius: AgentOneMetric.radiusSmall, style: .continuous)
                        )
                    }

                    Divider().overlay(AgentOnePalette.separator)
                    SettingsToggleRow(
                        title: "显示云端调用记录",
                        detail: "在日记中标出何时、为何及哪些 Context 离开过设备。",
                        isOn: $cloudLedgerEnabled
                    )
                }

                settingsSection("提醒与走神", symbol: "bell.and.waves.left.and.right") {
                    HStack(alignment: .top, spacing: AgentOneMetric.spacingM) {
                        ForEach(ReminderPreset.allCases) { preset in
                            Button {
                                reminderPreset = preset
                            } label: {
                                VStack(spacing: AgentOneMetric.spacingXS) {
                                    Text(preset.rawValue)
                                        .font(AgentOneType.caption)
                                        .fontWeight(.semibold)
                                    Text(preset.delay)
                                        .font(AgentOneType.caption)
                                        .foregroundStyle(AgentOnePalette.textSecondary)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(.horizontal, AgentOneMetric.spacingS)
                                .frame(maxWidth: .infinity, minHeight: 54)
                            }
                            .buttonStyle(AgentOneSelectableCardStyle(
                                isSelected: reminderPreset == preset,
                                tint: AgentOnePalette.blue,
                                cornerRadius: AgentOneMetric.radiusSmall
                            ))
                        }
                    }
                    Text("实际等待时间会在这个基准上根据语义相关性、任务阶段和你的历史反馈自动调整。")
                        .font(AgentOneType.caption)
                        .foregroundStyle(AgentOnePalette.textTertiary)
                }

                settingsSection("Context 与隐私", symbol: "lock.shield.fill") {
                    HStack(alignment: .top, spacing: AgentOneMetric.spacingM) {
                        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                            Text("Agent Home")
                                .font(AgentOneType.caption)
                                .fontWeight(.semibold)
                            Text(AgentHomePreferences.rootURL.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AgentOnePalette.textSecondary)
                        }
                        Spacer()
                        Button("在访达中显示") {}
                            .buttonStyle(QuietActionButtonStyle())
                        Button("迁移") {}
                            .buttonStyle(QuietActionButtonStyle())
                    }

                    Divider().overlay(AgentOnePalette.separator)
                    VStack(alignment: .leading, spacing: AgentOneMetric.spacingM) {
                        Text("永不采集")
                            .font(AgentOneType.caption)
                            .fontWeight(.semibold)
                        HStack(spacing: AgentOneMetric.spacingS) {
                            ForEach(excludedApps, id: \.self) { app in
                                AgentOnePill(title: app, symbol: "eye.slash.fill", tint: .red.opacity(0.82))
                            }
                        }
                        Text("支付、密码及系统安全输入区域不能由用户解除屏蔽。聊天正文等敏感 Context 可单独授权。")
                            .font(AgentOneType.caption)
                            .foregroundStyle(AgentOnePalette.textTertiary)
                            .lineSpacing(3)
                    }

                    Divider().overlay(AgentOnePalette.separator)
                    HStack {
                        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                            Text("隐藏敏感片段")
                                .font(AgentOneType.caption)
                                .fontWeight(.semibold)
                            Text("隐藏后不参与日常检索和回放，但不改写历史。")
                                .font(AgentOneType.caption)
                                .foregroundStyle(AgentOnePalette.textSecondary)
                        }
                        Spacer()
                        Button("管理隐藏片段") {}
                            .buttonStyle(QuietActionButtonStyle())
                    }
                }

                HStack(alignment: .top) {
                    Text("AgentOne 没有账号。删除应用及 Agent Home，即销毁这个数字生命和全部共同记忆。")
                        .font(AgentOneType.caption)
                        .foregroundStyle(AgentOnePalette.textTertiary)
                    Spacer()
                    Text("Prototype 0.1")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AgentOnePalette.textTertiary.opacity(0.65))
                }
                .padding(.bottom, AgentOneMetric.spacingM)
            }
            .padding(30)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: inferenceMode) { _, newValue in
            modelSettings.route = newValue.route
        }
        .onChange(of: reminderPreset) { _, newValue in
            newValue.persist()
        }
        .onChange(of: cloudLedgerEnabled) { _, newValue in
            modelSettings.auditsCloudInvocations = newValue
        }
        .sheet(isPresented: $showsCredentialEditor) {
            ModelCredentialEditor(settings: modelSettings)
        }
    }

    private var surpriseFrequencyLabel: String {
        switch surpriseFrequency {
        case 0..<0.25: "偶尔"
        case 0.25..<0.7: "自然"
        default: "更主动"
        }
    }

    private func connectKimi() {
        connectionError = nil
        Task { @MainActor in
            let connected = await modelSettings.connectKimi()
            if !connected {
                connectionError = modelSettings.credentialError ?? "没有完成连接。你可以稍后再试。"
            }
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingL) {
            Label(title, systemImage: symbol)
                .font(AgentOneType.headline)
                .foregroundStyle(AgentOnePalette.textPrimary)
            content()
        }
        .agentOneCard()
    }
}

private struct ModelCredentialEditor: View {
    @ObservedObject var settings: AgentModelSettings
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var draftBaseURL: String
    @State private var draftModel: String
    @State private var revealsDraft = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isTestingConnection = false
    @State private var confirmsRemoval = false

    init(settings: AgentModelSettings) {
        self.settings = settings
        _draftBaseURL = State(initialValue: settings.apiKeyBaseURL)
        _draftModel = State(initialValue: settings.apiKeyModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXL) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                    Text("模型 API Key")
                        .font(AgentOneType.title)
                    Text("保存在这台 Mac 的私密配置文件中，不访问钥匙串，也不会写入日记、Agent Home 或导出文件。")
                        .font(AgentOneType.callout)
                        .foregroundStyle(AgentOnePalette.textSecondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(QuietActionButtonStyle())
            }

            HStack(spacing: AgentOneMetric.spacingM) {
                Image(systemName: settings.hasAPIKey ? "checkmark.shield.fill" : "key.horizontal.fill")
                    .foregroundStyle(settings.hasAPIKey ? AgentOnePalette.mint : AgentOnePalette.blue)
                Text(settings.hasAPIKey ? "本机已有 API Key。输入新 Key 会替换它。" : "尚未保存 API Key。可以接入任意兼容 Chat Completions 的模型服务。")
                    .font(AgentOneType.callout)
                    .foregroundStyle(AgentOnePalette.textSecondary)
            }
            .agentOneCard(padding: AgentOneMetric.spacingM)

            VStack(alignment: .leading, spacing: AgentOneMetric.spacingS) {
                Text("兼容模型服务")
                    .font(AgentOneType.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(AgentOnePalette.textSecondary)
                TextField("", text: $draftBaseURL, prompt: Text("服务地址").foregroundStyle(AgentOnePalette.textTertiary))
                    .agentOneInputField(tint: AgentOnePalette.violet)
                TextField("", text: $draftModel, prompt: Text("模型名").foregroundStyle(AgentOnePalette.textTertiary))
                    .agentOneInputField(tint: AgentOnePalette.violet)
                Text("服务地址和模型名保存在本机设置中；API Key 文件权限为 0600，运行时通过环境变量或 Authorization Header 注入。")
                    .font(AgentOneType.caption)
                    .foregroundStyle(AgentOnePalette.textTertiary)
            }

            VStack(alignment: .leading, spacing: AgentOneMetric.spacingS) {
                Text("新 API Key")
                    .font(AgentOneType.caption)
                    .fontWeight(.semibold)
                HStack(spacing: AgentOneMetric.spacingS) {
                    Group {
                        if revealsDraft {
                            TextField("", text: $draft, prompt: Text("输入新 Key").foregroundStyle(AgentOnePalette.textTertiary))
                        } else {
                            SecureField("", text: $draft, prompt: Text("输入新 Key").foregroundStyle(AgentOnePalette.textTertiary))
                        }
                    }

                    Button {
                        revealsDraft.toggle()
                    } label: {
                        Image(systemName: revealsDraft ? "eye.slash.fill" : "eye.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AgentOnePalette.textSecondary)
                    .accessibilityLabel(revealsDraft ? "隐藏正在输入的 Key" : "显示正在输入的 Key")
                }
                .agentOneInputField(tint: AgentOnePalette.violet)

                Text("出于安全考虑，已保存的 Key 不会回填显示。")
                    .font(AgentOneType.caption)
                    .foregroundStyle(AgentOnePalette.textTertiary)
            }

            if let message = statusMessage ?? settings.credentialError {
                Text(message)
                    .font(AgentOneType.caption)
                    .foregroundStyle(
                        settings.credentialError == nil && !statusIsError
                            ? AgentOnePalette.mint
                            : .red.opacity(0.85)
                    )
            }

            HStack {
                if settings.hasAPIKey {
                    Button("移除已保存的 Key", role: .destructive) {
                        confirmsRemoval = true
                    }
                    .buttonStyle(QuietActionButtonStyle())
                }
                Spacer()
                if settings.hasAPIKey {
                    Button(isTestingConnection ? "正在测试…" : "测试连接") {
                        Task { await testConnection() }
                    }
                    .buttonStyle(QuietActionButtonStyle())
                    .disabled(isTestingConnection)
                }
                Button("保存到本机") {
                    saveDraft()
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(AmbientBackground())
        .confirmationDialog(
            "移除模型 API Key？",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                settings.removeAPIKey()
                statusIsError = settings.credentialError != nil
                statusMessage = settings.credentialError == nil ? "已从本机私密配置中移除。" : nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后不会影响本地日记；云端推理会暂停，直到再次保存 Key。")
        }
    }

    private func saveDraft() {
        guard let configuration = validatedConfiguration() else {
            statusIsError = true
            statusMessage = "请填写有效的 http/https 服务地址和模型名。"
            return
        }
        settings.apiKeyBaseURL = configuration.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        settings.apiKeyModel = configuration.model
        let normalizedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let didSave = normalizedDraft.isEmpty ? settings.hasAPIKey : settings.saveAPIKey(normalizedDraft)
        if didSave {
            settings.preferredCloudAuthentication = .apiKey
            draft = ""
            revealsDraft = false
            statusIsError = false
            statusMessage = "已保存到本机私密配置，不会触发钥匙串授权。"
        } else {
            statusIsError = true
            statusMessage = nil
        }
    }

    @MainActor
    private func testConnection() async {
        guard !isTestingConnection else { return }
        isTestingConnection = true
        statusMessage = "正在用一个最小请求验证模型连接…"
        statusIsError = false
        defer { isTestingConnection = false }

        let apiKey = settings.loadAPIKey()
        guard !apiKey.isEmpty else {
            statusMessage = settings.credentialError ?? "本机私密配置中没有可用的 API Key。"
            statusIsError = true
            return
        }

        guard let configuration = validatedConfiguration() else {
            statusMessage = "请填写有效的 http/https 服务地址和模型名。"
            statusIsError = true
            return
        }

        do {
            let result = try await OpenAICompatibleModelClient(configuration: .init(
                baseURL: configuration.baseURL,
                model: configuration.model,
                providerName: "OpenAI-compatible"
            )).infer(
                ModelInferenceRequest(
                    purpose: "user_initiated_connection_test",
                    systemPrompt: "This is a connection test. Reply with only OK.",
                    userPrompt: "OK",
                    context: nil,
                    allowsCloudProcessing: true
                ),
                apiKey: apiKey
            )
            statusMessage = "连接成功：\(result.provider) · \(result.model)"
            statusIsError = false
        } catch {
            statusMessage = "连接失败：\(error.localizedDescription)"
            statusIsError = true
        }
    }

    private var canSave: Bool {
        validatedConfiguration() != nil && (
            settings.hasAPIKey || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private func validatedConfiguration() -> (baseURL: URL, model: String)? {
        let rawURL = draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: rawURL),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil,
            !model.isEmpty
        else { return nil }
        return (url, model)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                Text(title)
                    .font(AgentOneType.caption)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(AgentOneType.caption)
                    .foregroundStyle(AgentOnePalette.textSecondary)
            }
        }
        .toggleStyle(.switch)
        .tint(AgentOnePalette.blue)
    }
}
