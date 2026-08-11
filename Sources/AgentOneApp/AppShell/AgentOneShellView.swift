import SwiftUI

@MainActor
struct AgentOneShellView: View {
    @StateObject private var model: AgentOneShellViewModel
    @ObservedObject private var runtimeHealth = AgentOneRuntimeHealthStore.shared
    @AppStorage("agentOne.didCompleteOnboarding") private var didCompleteOnboarding = false
    @State private var hasSignaledReady = false
    private let forceOnboarding: Bool?
    private let onReady: () -> Void
    private let onOnboardingComplete: () -> Void

    init(
        forceOnboarding: Bool? = nil,
        onReady: @escaping () -> Void = {},
        onOnboardingComplete: @escaping () -> Void = {}
    ) {
        _model = StateObject(wrappedValue: AgentOneShellViewModel())
        self.forceOnboarding = forceOnboarding
        self.onReady = onReady
        self.onOnboardingComplete = onOnboardingComplete
    }

    init(
        model: AgentOneShellViewModel,
        forceOnboarding: Bool? = nil,
        onReady: @escaping () -> Void = {},
        onOnboardingComplete: @escaping () -> Void = {}
    ) {
        _model = StateObject(wrappedValue: model)
        self.forceOnboarding = forceOnboarding
        self.onReady = onReady
        self.onOnboardingComplete = onOnboardingComplete
    }

    var body: some View {
        Group {
            if forceOnboarding ?? !didCompleteOnboarding {
                AgentOneOnboardingView {
                    didCompleteOnboarding = true
                    onOnboardingComplete()
                }
            } else {
                shell
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 960, minHeight: 650)
        .task {
            while !Task.isCancelled {
                runtimeHealth.refreshFromDisk()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var shell: some View {
        NavigationSplitView {
            AgentOneSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 194, ideal: 216, max: 244)
        } detail: {
            ZStack {
                AmbientBackground()
                content
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(AgentOnePalette.blue)
        .task {
            guard !hasSignaledReady else { return }
            hasSignaledReady = true
            onReady()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .now:
            NowView(model: model)
        case .replay:
            ReplayView(model: model)
        case .memory:
            MemoryLibraryView(model: model)
        case .journal:
            AgentJournalView(model: model)
        case .skills:
            SkillsLibraryView(model: model)
        case .settings:
            AgentOneSettingsView(model: model)
        }
    }
}

private struct AgentOneSidebar: View {
    @ObservedObject var model: AgentOneShellViewModel
    @ObservedObject private var runtimeHealth = AgentOneRuntimeHealthStore.shared

    var body: some View {
        ZStack {
            AgentOnePalette.surface1.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    MemoryGlowBeing(mood: model.mood, size: 38, isActive: !model.isPaused)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LUMA")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .tracking(1.5)
                        Text(sidebarStatus)
                            .font(AgentOneType.caption)
                            .foregroundStyle(AgentOnePalette.textSecondary)
                    }
                    Spacer()
                    Circle()
                        .fill(sidebarStatusColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: sidebarStatusColor.opacity(model.isPaused ? 0 : 0.7), radius: 5)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 22)

                VStack(spacing: 5) {
                    ForEach(AgentOneSection.allCases) { section in
                        Button {
                            model.select(section)
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: section.symbol)
                                    .font(AgentOneType.headline)
                                    .frame(width: 20)
                                Text(section.title)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                            }
                            .foregroundStyle(
                                model.selection == section
                                    ? AgentOnePalette.textPrimary
                                    : AgentOnePalette.textSecondary
                            )
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background {
                                if model.selection == section {
                                    RoundedRectangle(cornerRadius: AgentOneMetric.radiusSmall, style: .continuous)
                                        .fill(AgentOnePalette.blue.opacity(0.10))
                                        .overlay(alignment: .leading) {
                                            Capsule()
                                                .fill(AgentOnePalette.blue)
                                                .frame(width: 3, height: 18)
                                                .offset(x: -1)
                                        }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        NotificationCenter.default.post(name: .agentOneRequestedToggleChat, object: nil)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: model.isConversationMode ? "waveform.circle.fill" : "waveform.circle")
                            Text(model.isConversationMode ? "对话陪伴中" : "开启对话模式")
                            Spacer()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.isConversationMode ? AgentOnePalette.mint : AgentOnePalette.textSecondary)
                        .padding(11)
                        .background(AgentOnePalette.surface2, in: RoundedRectangle(cornerRadius: AgentOneMetric.radiusSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 7) {
                        Image(systemName: "internaldrive.fill")
                        Text("Agent Home · 本地")
                        Spacer()
                    }
                    .font(AgentOneType.caption)
                    .foregroundStyle(AgentOnePalette.textTertiary)
                }
                .padding(13)
            }
        }
    }

    private var sidebarStatus: String {
        if model.isPaused { return "感知已暂停" }
        if runtimeHealth.hasBlockingCaptureIssue { return "采集链路未连接" }
        return model.mood.title
    }

    private var sidebarStatusColor: Color {
        if model.isPaused { return .gray }
        if runtimeHealth.hasBlockingCaptureIssue { return AgentOnePalette.amber }
        return AgentOnePalette.mint
    }
}

struct NowView: View {
    @ObservedObject var model: AgentOneShellViewModel
    @ObservedObject private var runtimeHealth = AgentOneRuntimeHealthStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    SectionHeading(
                        eyebrow: "Live context",
                        title: "此刻",
                        subtitle: "我正在理解你和电脑之间发生的事情。"
                    )
                    Spacer()
                    HStack(spacing: 9) {
                        Button {
                            model.togglePause()
                        } label: {
                            Label(model.isPaused ? "继续感知" : "暂停感知", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                        }
                        .buttonStyle(QuietActionButtonStyle())
                    }
                }

                if let issue = runtimeHealth.captureIssueSummary {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AgentOnePalette.amber)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("现在还不能理解具体 Context")
                                .font(AgentOneType.headline)
                            Text(issue)
                                .font(AgentOneType.callout)
                                .foregroundStyle(AgentOnePalette.textSecondary)
                                .lineSpacing(3)
                        }
                        Spacer()
                        Button("查看并授权") { model.select(.settings) }
                            .buttonStyle(QuietActionButtonStyle())
                    }
                    .padding(14)
                    .background(AgentOnePalette.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: AgentOneMetric.radiusCard, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: AgentOneMetric.radiusCard, style: .continuous).stroke(AgentOnePalette.amber.opacity(0.28)) }
                }

                HStack(spacing: 22) {
                    MemoryGlowBeing(mood: model.mood, size: 148, isActive: !model.isPaused)

                    VStack(alignment: .leading, spacing: 13) {
                        HStack(spacing: 8) {
                            AgentOnePill(
                                title: model.hasLiveContext ? "实时 Context" : "示例 Context",
                                symbol: model.hasLiveContext ? "dot.radiowaves.left.and.right" : "sparkles",
                                tint: model.hasLiveContext ? AgentOnePalette.blue : AgentOnePalette.violet
                            )
                            AgentOnePill(title: model.currentIntent.application, symbol: "macwindow", tint: AgentOnePalette.mint)
                            AgentOnePill(title: "置信度 \(Int(model.currentIntent.confidence * 100))%", symbol: "waveform.path.ecg")
                        }
                        Text(model.isPaused ? "我先在这里安静等你。" : model.currentIntent.title)
                            .font(AgentOneType.title)
                            .foregroundStyle(AgentOnePalette.textPrimary)
                        Text(model.isPaused ? "恢复感知后，我会从新的上下文重新理解，而不是武断地延续旧判断。" : model.currentIntent.detail)
                            .font(AgentOneType.body)
                            .foregroundStyle(AgentOnePalette.textSecondary)
                            .lineSpacing(3)
                        if !model.isPaused {
                            HStack(spacing: 9) {
                                Button("对，就是这个") {}
                                    .buttonStyle(PrimaryActionButtonStyle())
                                Button("不太对") { model.mood = .curious }
                                    .buttonStyle(QuietActionButtonStyle())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(26)
                .background(
                    LinearGradient(
                        colors: [AgentOnePalette.surface2, model.mood.accent.opacity(0.09)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: AgentOneMetric.radiusHero, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AgentOneMetric.radiusHero, style: .continuous)
                        .stroke(model.mood.accent.opacity(0.18), lineWidth: 1)
                }

                ModelHookStatusCard(latestThought: model.agentJournalEntries.first)

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 15) {
                        Label("我为什么这样理解", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(AgentOneType.headline)
                        ForEach(Array(model.currentIntent.signals.enumerated()), id: \.offset) { index, signal in
                            HStack(alignment: .top, spacing: 11) {
                                Text("0\(index + 1)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(AgentOnePalette.blue)
                                    .padding(.top, 2)
                                Text(signal)
                                    .font(AgentOneType.callout)
                                    .foregroundStyle(AgentOnePalette.textSecondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .agentOneCard()

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("岔路口袋", systemImage: "tray.full.fill")
                                .font(AgentOneType.headline)
                            Spacer()
                            Text("2")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AgentOnePalette.violet)
                        }
                        Text("突然感兴趣的内容不会丢。回到任务后，我会替你暂存，等合适的时候再打开。")
                            .font(AgentOneType.callout)
                            .foregroundStyle(AgentOnePalette.textSecondary)
                            .lineSpacing(3)
                        Button("查看刚才的岔路") { model.select(.replay) }
                            .font(.system(size: 11, weight: .semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(AgentOnePalette.violet)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .agentOneCard()
                }
            }
            .padding(30)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Makes the capture → model → reflection boundary visible instead of leaving
/// it implicit in a generic "Context understood" health row. The card shows a
/// safe, user-facing semantic summary, never a hidden chain-of-thought or raw
/// prompt payload.
struct ModelHookStatusCard: View {
    @ObservedObject private var health = AgentOneRuntimeHealthStore.shared
    let latestThought: AgentJournalCard?

    private var statusTint: Color { health.modelInference.state.tint }

    private var statusSymbol: String { health.modelInference.state.symbol }

    private var statusTitle: String {
        switch health.modelInference.state {
        case .healthy: "AI Hook 已触发"
        case .waiting: "AI Hook 等待中"
        case .blocked: "AI Hook 被阻断"
        case .error: "AI Hook 出错"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Label("AI Hook · context_enrichment", systemImage: "brain.head.profile")
                    .font(AgentOneType.headline)
                AgentOnePill(title: statusTitle, symbol: statusSymbol, tint: statusTint)
                Spacer()
                if let updatedAt = health.modelInference.updatedAt {
                    Text(Self.timeFormatter.string(from: updatedAt))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(AgentOnePalette.textTertiary)
                }
            }

            Text(health.modelInference.detail)
                .font(AgentOneType.callout)
                .foregroundStyle(AgentOnePalette.textSecondary)
                .lineSpacing(3)

            if let latestThought {
                VStack(alignment: .leading, spacing: 8) {
                    Text("这次模型对你在做什么的理解")
                        .font(AgentOneType.caption)
                        .foregroundStyle(AgentOnePalette.textTertiary)
                    Text(latestThought.observation)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(AgentOnePalette.textPrimary)
                    if let hypothesis = latestThought.hypothesis {
                        Text(hypothesis)
                            .font(AgentOneType.callout)
                            .foregroundStyle(AgentOnePalette.textSecondary)
                            .lineSpacing(3)
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    statusTint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: AgentOneMetric.radiusCard, style: .continuous)
                )
            } else if health.modelInference.state == .healthy {
                Text("模型调用已经成功，但这次还没有可展示的 Agent 工作性思考。打开“Agent 日记”查看完整结果。")
                    .font(AgentOneType.callout)
                    .foregroundStyle(AgentOnePalette.textSecondary)
            }

            Text("这里显示的是可复核的语义摘要，不是原始内部推理链。")
                .font(AgentOneType.caption)
                .foregroundStyle(AgentOnePalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentOneCard()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct RuntimeHealthOverview: View {
    @ObservedObject private var health = AgentOneRuntimeHealthStore.shared
    var showsPermissionActions = false

    var body: some View {
        VStack(spacing: 0) {
            healthRow(
                title: "行为信号",
                symbol: "keyboard.badge.ellipsis",
                health: health.behaviorSignals,
                actionTitle: health.behaviorSignals.state == .blocked && showsPermissionActions ? "开启输入监控" : nil,
                action: health.requestInputMonitoringPermission
            )
            Divider().overlay(AgentOnePalette.separator)
            healthRow(
                title: "Accessibility Context",
                symbol: "doc.text.magnifyingglass",
                health: health.accessibilityContext,
                actionTitle: health.accessibilityContext.state == .blocked && showsPermissionActions ? "开启辅助功能" : nil,
                action: health.requestAccessibilityPermission
            )
            Divider().overlay(AgentOnePalette.separator)
            healthRow(
                title: "回车关键截图",
                symbol: "camera.viewfinder",
                health: health.screenshotEvidence,
                actionTitle: health.screenshotEvidence.state == .blocked && showsPermissionActions ? "开启屏幕录制" : nil,
                action: health.requestScreenRecordingPermission
            )
            Divider().overlay(AgentOnePalette.separator)
            healthRow(
                title: "AI Hook / 模型理解",
                symbol: "brain.head.profile",
                health: health.modelInference
            )
            Divider().overlay(AgentOnePalette.separator)
            healthRow(
                title: "日记落盘",
                symbol: "book.pages.fill",
                health: health.diaryPersistence
            )
        }
        .agentOneCard(padding: AgentOneMetric.spacingL)
    }

    private func healthRow(
        title: String,
        symbol: String,
        health item: RuntimeSubsystemHealth,
        actionTitle: String? = nil,
        action: @escaping () -> Void = {}
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(item.state.tint)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: item.state.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(item.state.tint)
                    Text(item.headline)
                        .font(AgentOneType.caption)
                        .foregroundStyle(item.state.tint)
                }
                Text(item.detail)
                    .font(AgentOneType.caption)
                    .foregroundStyle(AgentOnePalette.textSecondary)
                    .lineSpacing(2)
                if let updatedAt = item.updatedAt {
                    Text("最近更新 · \(Self.timeFormatter.string(from: updatedAt))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AgentOnePalette.textTertiary)
                }
            }
            Spacer(minLength: 10)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(QuietActionButtonStyle())
            }
        }
        .padding(.vertical, 11)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AgentOnePalette.background)
            .padding(.horizontal, 14)
            .frame(height: 31)
            .background(AgentOnePalette.blue.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
    }
}

struct QuietActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AgentOnePalette.textSecondary)
            .padding(.horizontal, 13)
            .frame(height: 31)
            .background(configuration.isPressed ? AgentOnePalette.surface3 : AgentOnePalette.surface2, in: Capsule())
            .overlay { Capsule().stroke(AgentOnePalette.border, lineWidth: 1) }
    }
}
