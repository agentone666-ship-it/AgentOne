import AppKit
import SwiftUI

struct ReplayView: View {
    @ObservedObject var model: AgentOneShellViewModel

    private var selectedMoment: ReplayMoment? {
        guard let id = model.selectedReplayMomentID else { return model.replayMoments.first }
        return model.replayMoments.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
                HStack(alignment: .top) {
                    SectionHeading(
                        eyebrow: "Context log",
                        title: "\(model.replayDayLabel)的 Context 日志",
                        subtitle: "按时间回顾真实发生的活动、意图变化与关键证据；这里只记录发生了什么。"
                    )
                Spacer()
                VStack(alignment: .trailing, spacing: AgentOneMetric.spacingS) {
                    AgentOnePill(title: model.replayDayLabel, symbol: "calendar", tint: AgentOnePalette.violet)
                    Text(model.hasLiveReplay ? "Context 已同步" : "等待真实 Context")
                        .font(AgentOneType.caption)
                        .foregroundStyle(
                            model.hasLiveReplay
                                ? AgentOnePalette.mint
                                : AgentOnePalette.textSecondary
                        )
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 20)

            ReplayDayPicker(model: model)
                .padding(.horizontal, 30)
                .padding(.bottom, 12)

            if model.replayMoments.isEmpty {
                VStack(spacing: AgentOneMetric.spacingL) {
                    MemoryGlowBeing(mood: .observing, size: 82)
                    Text("今天还没有可回放的 Context 日志")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("开始阅读、写作、搜索或提交观点后，我会把连续状态压缩成可核验的日志节点；总结和我的想法会留在 Agent 日记里。")
                        .font(AgentOneType.callout)
                        .foregroundStyle(AgentOnePalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.replayMoments.enumerated()), id: \.element.id) { index, moment in
                            ReplayTimelineRow(
                                moment: moment,
                                isSelected: selectedMoment?.id == moment.id,
                                isLast: index == model.replayMoments.count - 1
                            ) {
                                withAnimation(.snappy(duration: 0.25)) {
                                    model.selectedReplayMomentID = moment.id
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 23)
                }
                .frame(minWidth: 390, idealWidth: 470, maxWidth: 540)

                Rectangle()
                    .fill(AgentOnePalette.separator)
                    .frame(width: 1)

                if let moment = selectedMoment {
                    ReplayDetail(moment: moment)
                        .id(moment.id)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                }
            }
        }
    }
}

private struct DailyDigestHeroCard: View {
    let digest: DailyDigestCard?
    let observedContextCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingL) {
            if let digest {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                        Text("LUMA 把今天串起来了")
                            .font(AgentOneType.caption)
                            .foregroundStyle(AgentOnePalette.violet)
                        Text(digest.headline)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    AgentOnePill(
                        title: digest.isFinal ? "今日定稿" : "活的日记 · 会继续长",
                        symbol: "sparkles",
                        tint: AgentOnePalette.mint
                    )
                }

                Text(digest.overview)
                    .font(AgentOneType.body)
                    .foregroundStyle(AgentOnePalette.textSecondary)
                    .lineSpacing(4)

                VStack(alignment: .leading, spacing: AgentOneMetric.spacingS) {
                    ForEach(Array(digest.highlights.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: AgentOneMetric.spacingM) {
                            Text(String(format: "%02d", index + 1))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(AgentOnePalette.blue)
                            Text(item)
                                .font(AgentOneType.callout)
                                .foregroundStyle(AgentOnePalette.textPrimary)
                        }
                    }
                }

                if digest.rhythm != nil || digest.unfinishedThread != nil {
                    HStack(alignment: .top, spacing: AgentOneMetric.spacingM) {
                        if let rhythm = digest.rhythm {
                            DigestField(
                                title: "我看到的节奏",
                                text: rhythm,
                                symbol: "waveform.path.ecg"
                            )
                        }
                        if let unfinished = digest.unfinishedThread {
                            DigestField(
                                title: "留到明天的一根线",
                                text: unfinished,
                                symbol: "arrow.turn.down.right"
                            )
                        }
                    }
                }

                HStack(alignment: .top, spacing: AgentOneMetric.spacingM) {
                    MemoryGlowBeing(mood: .curious, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("我私下留的一句话")
                            .font(AgentOneType.caption)
                            .foregroundStyle(AgentOnePalette.violet)
                        Text("“\(digest.agentNote)”")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .italic()
                            .lineSpacing(3)
                    }
                    Spacer()
                    Text("\(digest.sourceContextCount) 段 Context · \(digest.evidenceCount) 个关键证据")
                        .font(AgentOneType.caption)
                        .foregroundStyle(AgentOnePalette.textTertiary)
                }
            } else {
                HStack(spacing: AgentOneMetric.spacingL) {
                    MemoryGlowBeing(mood: .observing, size: 54)
                    VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                        Text("我还在把今天串成一篇日记")
                            .font(AgentOneType.headline)
                        Text(observedContextCount == 0
                            ? "有了几段具体的阅读、写作、沟通或产出 Context 后，我会自动去重、找主线，再留下自己的那句话。"
                            : "已经收到了 \(observedContextCount) 段可回忆 Context。它们不会原样堆在这里，我会在停下来的间隙主动提炼。")
                            .font(AgentOneType.callout)
                            .foregroundStyle(AgentOnePalette.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentOneCard(padding: AgentOneMetric.spacingXL)
    }
}

private struct DigestField: View {
    let title: String
    let text: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingS) {
            Label(title, systemImage: symbol)
                .font(AgentOneType.caption)
                .foregroundStyle(AgentOnePalette.blue)
            Text(text)
                .font(AgentOneType.callout)
                .foregroundStyle(AgentOnePalette.textSecondary)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AgentOneMetric.spacingM)
        .background(AgentOnePalette.surface2, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ReplayTimelineRow: View {
    let moment: ReplayMoment
    let isSelected: Bool
    let isLast: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isSelected ? moment.kind.color : .clear)
                    .frame(width: 3)
                    .padding(.trailing, AgentOneMetric.spacingM)

                HStack(alignment: .top, spacing: 15) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle().fill(moment.kind.color.opacity(0.14)).frame(width: 32, height: 32)
                            Image(systemName: moment.kind.symbol)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(moment.kind.color)
                        }
                        if !isLast {
                            Rectangle()
                                .fill(AgentOnePalette.separator)
                                .frame(width: 1, height: 71)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(moment.time)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(moment.kind.color)
                            Text(moment.application)
                                .font(AgentOneType.caption)
                                .foregroundStyle(AgentOnePalette.textTertiary)
                        }
                        Text(moment.title)
                            .font(AgentOneType.headline)
                            .foregroundStyle(AgentOnePalette.textPrimary)
                        Text(moment.detail)
                            .font(AgentOneType.callout)
                            .lineLimit(2)
                            .foregroundStyle(AgentOnePalette.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.top, 1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, AgentOneMetric.spacingM)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(
                RoundedRectangle(cornerRadius: AgentOneMetric.radiusSmall, style: .continuous)
                    .fill(isSelected ? AgentOnePalette.surface2 : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ReplayDetail: View {
    let moment: ReplayMoment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AgentOneMetric.spacingXL) {
                ZStack {
                    if let path = moment.evidenceResourcePath,
                       let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .overlay(Color.black.opacity(0.12))
                    } else {
                        RoundedRectangle(cornerRadius: AgentOneMetric.radiusHero, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [moment.kind.color.opacity(0.22), AgentOnePalette.surface1],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        VStack(spacing: AgentOneMetric.spacingM) {
                            Image(systemName: moment.kind.symbol)
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(moment.kind.color)
                            Text(moment.evidenceLabel ?? "日记节点")
                                .font(AgentOneType.caption)
                                .foregroundStyle(AgentOnePalette.textSecondary)
                        }
                    }
                }
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: AgentOneMetric.radiusHero, style: .continuous))
                .overlay(alignment: .topLeading) {
                    AgentOnePill(title: moment.time, symbol: "clock", tint: moment.kind.color)
                        .padding(AgentOneMetric.spacingL)
                }

                VStack(alignment: .leading, spacing: AgentOneMetric.spacingS) {
                    Text(moment.title)
                        .font(AgentOneType.title)
                    Text(moment.detail)
                        .font(AgentOneType.body)
                        .foregroundStyle(AgentOnePalette.textSecondary)
                        .lineSpacing(4)
                }

                Text("这里只展示结构化 Context 与关键时刻的单张截图；LUMA 的总结和内心记录在 Agent 日记中。")
                    .font(AgentOneType.caption)
                    .foregroundStyle(AgentOnePalette.textTertiary)
            }
            .padding(AgentOneMetric.spacingXXL)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MemoryLibraryView: View {
    @ObservedObject var model: AgentOneShellViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    SectionHeading(
                        eyebrow: "Shared memory",
                        title: "我们的记忆",
                        subtitle: "记忆不会被悄悄篡改。误解、纠正和重新认识都会作为新的经历追加下来。"
                    )
                    Spacer()
                    Button("查看记忆规则") {}
                        .buttonStyle(QuietActionButtonStyle())
                        .font(AgentOneType.caption)
                        .opacity(0.75)
                }

                HStack(spacing: AgentOneMetric.spacingM) {
                    MemoryMetric(title: "共同经历", value: "\(model.totalRecordedContextCount)", symbol: "sparkles", tint: AgentOnePalette.blue)
                    MemoryMetric(title: "Agent 学到的习惯", value: "\(model.learnedHabits.count)", symbol: "scope", tint: AgentOnePalette.violet)
                    MemoryMetric(title: "可追溯证据", value: "\(model.learnedHabits.reduce(0) { $0 + ($1.evidenceCount ?? 0) })", symbol: "point.3.connected.trianglepath.dotted", tint: AgentOnePalette.amber)
                }

                HStack {
                    Label("Agent 正在认识你", systemImage: "lightbulb.max.fill")
                        .font(AgentOneType.headline)
                    Spacer()
                    Text("从持续活动段学习 · 每条认识都能回到原始日记证据")
                        .font(AgentOneType.caption)
                        .foregroundStyle(AgentOnePalette.textSecondary)
                }

                if model.learnedHabits.isEmpty {
                    HStack(spacing: AgentOneMetric.spacingM) {
                        MemoryGlowBeing(mood: .curious, size: 42)
                        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                            Text("我还在观察你的节奏")
                                .font(AgentOneType.headline)
                            Text("完成一段阅读后，我会在这里解释自己学到了什么，以及用了几段日记作为证据。")
                                .font(AgentOneType.caption)
                                .foregroundStyle(AgentOnePalette.textSecondary)
                        }
                    }
                    .agentOneCard()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: AgentOneMetric.spacingL)], spacing: AgentOneMetric.spacingL) {
                        ForEach(model.learnedHabits) { memory in
                            MemoryCardView(memory: memory)
                        }
                    }
                }

                if !model.memories.isEmpty {
                    Label("其他共同记忆", systemImage: "books.vertical.fill")
                        .font(AgentOneType.headline)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: AgentOneMetric.spacingL)], spacing: AgentOneMetric.spacingL) {
                        ForEach(model.memories) { memory in
                            MemoryCardView(memory: memory)
                        }
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 1160)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct MemoryMetric: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: AgentOneMetric.spacingM) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(AgentOneType.title)
                Text(title).font(AgentOneType.caption).foregroundStyle(AgentOnePalette.textSecondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .agentOneCard(padding: AgentOneMetric.spacingL)
    }
}

private struct MemoryCardView: View {
    let memory: MemoryCard

    private var sourceColor: Color {
        switch memory.source {
        case .confirmed: AgentOnePalette.mint
        case .observed: AgentOnePalette.blue
        case .inferred: AgentOnePalette.amber
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingM) {
            HStack {
                AgentOnePill(title: memory.source.rawValue, tint: sourceColor)
                Spacer()
                Text(memory.date)
                    .font(AgentOneType.caption)
                    .foregroundStyle(AgentOnePalette.textTertiary)
            }
            Text(memory.title)
                .font(.system(size: 14, weight: .semibold))
            Text(memory.detail)
                .font(AgentOneType.callout)
                .foregroundStyle(AgentOnePalette.textSecondary)
                .lineSpacing(3)
                .frame(minHeight: 48, alignment: .top)
            HStack(spacing: 6) {
                ForEach(memory.tags, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(AgentOneType.caption)
                        .foregroundStyle(AgentOnePalette.textTertiary)
                }
            }
            if let confidence = memory.confidence {
                HStack(spacing: AgentOneMetric.spacingS) {
                    ProgressView(value: confidence)
                        .tint(sourceColor)
                        .frame(maxWidth: 110)
                    Text("置信度 \(Int(confidence * 100))%")
                        .font(AgentOneType.caption)
                        .foregroundStyle(AgentOnePalette.textTertiary)
                    if let evidenceCount = memory.evidenceCount {
                        Text("· \(evidenceCount) 段证据")
                            .font(AgentOneType.caption)
                            .foregroundStyle(AgentOnePalette.textTertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentOneCard()
    }
}

struct AgentJournalView: View {
    @ObservedObject var model: AgentOneShellViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeading(
                    eyebrow: "Inner journal",
                    title: "\(model.replayDayLabel)的 Agent 日记",
                    subtitle: "我会把这一天的 Context 提炼成一篇日记，再留下观察、联想和那些最后没有说出口的话。"
                )

                ReplayDayPicker(model: model)

                DailyDigestHeroCard(
                    digest: model.dailyDigest,
                    observedContextCount: model.replayMoments.count
                )

                ModelHookStatusCard(latestThought: model.agentJournalEntries.first)

                if model.agentJournalEntries.isEmpty {
                    VStack(spacing: AgentOneMetric.spacingL) {
                        MemoryGlowBeing(mood: .curious, size: 92)
                        Text("今天还没有形成额外的内心记录")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("上面是我对一天的总结。等具体 Context 触发模型分析后，我的观察、猜测、考虑过的动作和保持安静的原因也会继续追加在这里。")
                            .font(AgentOneType.callout)
                            .foregroundStyle(AgentOnePalette.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 600)
                        Text("自动保存 · 不可改写")
                            .font(AgentOneType.caption)
                            .foregroundStyle(AgentOnePalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .agentOneCard(padding: 30)
                } else {
                    LazyVStack(spacing: AgentOneMetric.spacingL) {
                        ForEach(model.agentJournalEntries) { entry in
                            AgentJournalEntryCard(entry: entry)
                        }
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct AgentJournalEntryCard: View {
    let entry: AgentJournalCard

    private var confidence: Int {
        Int(((1 - entry.uncertainty) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingM) {
            HStack(spacing: AgentOneMetric.spacingS) {
                Image(systemName: "sparkles")
                    .foregroundStyle(AgentOnePalette.violet)
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(AgentOnePalette.blue)
                AgentOnePill(title: entry.disposition, tint: AgentOnePalette.violet)
                Spacer()
                Text("把握度 \(confidence)% · 自动保存 · 不可改写")
                    .font(AgentOneType.caption)
                    .foregroundStyle(AgentOnePalette.textTertiary)
            }
            Text(entry.observation)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            if let submittedText = entry.submittedText {
                JournalField(title: "你当时按回车提交了", content: submittedText)
            }
            if let resourcePath = entry.evidenceResourcePath {
                JournalScreenshotEvidence(
                    label: entry.evidenceLabel ?? "关键截图",
                    resourcePath: resourcePath
                )
            }
            if let hypothesis = entry.hypothesis {
                JournalField(title: "我对你的猜测（以后可能会改）", content: hypothesis)
            }
            if let action = entry.consideredAction {
                JournalField(title: "我差点想做", content: action)
            }
            if let why = entry.why {
                JournalField(title: "最后为什么说／没说", content: why)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentOneCard(padding: AgentOneMetric.spacingXL)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct JournalScreenshotEvidence: View {
    let label: String
    let resourcePath: String

    private var image: NSImage? {
        NSImage(contentsOfFile: resourcePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingS) {
            AgentOnePill(
                title: label,
                symbol: "camera.viewfinder",
                tint: AgentOnePalette.blue
            )
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .background(Color.black.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AgentOnePalette.separator, lineWidth: 1)
                    }
                    .accessibilityLabel("回车时保存的关键截图")
            } else {
                Label("截图索引仍在，但本地图片当前不可读取", systemImage: "exclamationmark.triangle")
                    .font(AgentOneType.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, AgentOneMetric.spacingXS)
    }
}

private struct JournalField: View {
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
            Text(title)
                .font(AgentOneType.caption)
                .foregroundStyle(AgentOnePalette.textSecondary)
            Text(content)
                .font(AgentOneType.callout)
                .foregroundStyle(AgentOnePalette.textSecondary)
                .lineSpacing(4)
        }
    }
}

struct SkillsLibraryView: View {
    @ObservedObject var model: AgentOneShellViewModel
    @State private var selectedSkill: AgentSkillCard?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    SectionHeading(
                        eyebrow: "Automatic evolution",
                        title: "我学会的 Skills",
                        subtitle: "共同经历会沉淀成能力，并在真实使用和反馈里继续变化，不需要你逐条配置。"
                    )
                    Spacer()
                    AgentOnePill(title: "自动进化中", symbol: "arrow.triangle.2.circlepath", tint: AgentOnePalette.mint)
                }

                if model.skills.isEmpty {
                    HStack(spacing: AgentOneMetric.spacingM) {
                        MemoryGlowBeing(mood: .observing, size: 48)
                        VStack(alignment: .leading, spacing: AgentOneMetric.spacingXS) {
                            Text("还没有从真实反馈中学会 Skill")
                                .font(AgentOneType.headline)
                            Text("当你纠正意图、标记相关/分心，或评价提醒节奏后，经验会自动沉淀到这里。")
                                .font(AgentOneType.caption)
                                .foregroundStyle(AgentOnePalette.textSecondary)
                        }
                    }
                    .agentOneCard()
                } else {
                    ForEach(model.skills) { skill in
                        Button {
                            selectedSkill = skill
                        } label: {
                            SkillRow(skill: skill)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看 Skill：\(skill.name)，完成度 \(skill.completionPercent)%")
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $selectedSkill) { skill in
            SkillDetailView(skill: skill)
        }
    }
}

private struct ReplayDayPicker: View {
    @ObservedObject var model: AgentOneShellViewModel

    var body: some View {
        if model.replayDays.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.replayDays) { option in
                        Button {
                            model.selectReplayDay(option.day)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.label)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                Text("\(option.contextCount) 段 Context · \(option.journalCount) 条内心")
                                    .font(.system(size: 10, weight: .regular, design: .rounded))
                                    .foregroundStyle(
                                        model.selectedReplayDay == option.day
                                            ? AgentOnePalette.textPrimary.opacity(0.76)
                                            : AgentOnePalette.textTertiary
                                    )
                            }
                            .foregroundStyle(
                                model.selectedReplayDay == option.day
                                    ? AgentOnePalette.textPrimary
                                    : AgentOnePalette.textSecondary
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(
                                        model.selectedReplayDay == option.day
                                            ? AgentOnePalette.violet.opacity(0.22)
                                            : AgentOnePalette.surface2
                                    )
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        model.selectedReplayDay == option.day
                                            ? AgentOnePalette.violet.opacity(0.72)
                                            : AgentOnePalette.separator,
                                        lineWidth: 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看 \(option.label) 的记录")
                    }
                }
            }
        }
    }
}

private struct SkillRow: View {
    let skill: AgentSkillCard

    var body: some View {
        HStack(spacing: AgentOneMetric.spacingL) {
            Image(systemName: skill.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(skill.tint)
                .frame(width: 48, height: 48)
                .background(skill.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AgentOneMetric.radiusSmall, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: AgentOneMetric.spacingS) {
                    Text(skill.name).font(.system(size: 14, weight: .semibold))
                    AgentOnePill(title: "Lv.\(skill.level)", tint: skill.tint)
                }
                Text(skill.detail)
                    .font(AgentOneType.callout)
                    .foregroundStyle(AgentOnePalette.textSecondary)
                    .lineLimit(2)
                Text("来自 \(skill.learnedFrom) · \(skill.evidenceCount) 条成长证据")
                    .font(AgentOneType.caption)
                    .foregroundStyle(AgentOnePalette.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: AgentOneMetric.spacingS) {
                Text("完成度 \(skill.completionPercent)%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(skill.tint)
                ProgressView(value: skill.completion, total: 1)
                    .tint(skill.tint)
                    .frame(width: 110)
                HStack(spacing: AgentOneMetric.spacingXS) {
                    Text("查看成长档案")
                    Image(systemName: "chevron.right")
                }
                .font(AgentOneType.caption)
                .foregroundStyle(AgentOnePalette.textSecondary)
            }
        }
        .agentOneCard(padding: AgentOneMetric.spacingL)
        .contentShape(Rectangle())
    }
}

private struct SkillDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let skill: AgentSkillCard

    private var triggerDescription: String {
        guard !skill.rawTriggerTerms.isEmpty else {
            return "没有绑定固定关键词；主要根据连续行为、当前意图和你的反馈判断是否触发。"
        }
        return "已从 \(skill.rawTriggerTerms.count) 个历史线索中提炼出 \(skill.triggerTerms.count) 个代表性线索。Agent 不会单凭某个词下结论，而会结合当前任务、连续行为与语义关联一起唤起。"
    }

    private var evidenceDescription: String {
        "第 \(skill.revision) 次修正 · \(skill.evidenceCount) 条不可变证据 · 当前置信度 \(Int((skill.confidence * 100).rounded()))%"
    }

    private var evidenceReferences: [String] {
        skill.evidenceIDs.prefix(8).map { String($0.uuidString.prefix(8)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AgentOneMetric.spacingXL) {
                HStack(alignment: .top, spacing: AgentOneMetric.spacingL) {
                    Image(systemName: skill.symbol)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(skill.tint)
                        .frame(width: 58, height: 58)
                        .background(
                            skill.tint.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: AgentOneMetric.radiusCard, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: AgentOneMetric.spacingS) {
                        Text("SKILL GROWTH RECORD")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(AgentOnePalette.blue)
                        Text(skill.name)
                            .font(AgentOneType.title)
                            .foregroundStyle(AgentOnePalette.textPrimary)
                        HStack(spacing: AgentOneMetric.spacingS) {
                            AgentOnePill(title: "Lv.\(skill.level)", tint: skill.tint)
                            AgentOnePill(title: skill.domain, symbol: "scope", tint: AgentOnePalette.blue)
                            if !skill.hasCompleteRecord {
                                AgentOnePill(title: "历史记录待恢复", symbol: "clock.arrow.circlepath", tint: AgentOnePalette.amber)
                            }
                        }
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AgentOnePalette.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(AgentOnePalette.surface2, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭 Skill 详情")
                }

                VStack(alignment: .leading, spacing: AgentOneMetric.spacingM) {
                    HStack {
                        Text("完成度")
                            .font(AgentOneType.headline)
                        Spacer()
                        Text("\(skill.completionPercent)%")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(skill.tint)
                    }
                    ProgressView(value: skill.completion, total: 1)
                        .tint(skill.tint)
                    SkillLevelRail(currentLevel: skill.level, tint: skill.tint)
                    if let next = skill.nextUnlockPercent {
                        Text("再积累 \(max(0, next - skill.completionPercent))% 完成度，将解锁下一层内容。新的真实反馈、相似 Context 证据和反复验证都会推动成长。")
                            .font(AgentOneType.caption)
                            .foregroundStyle(AgentOnePalette.textSecondary)
                    } else {
                        Text("这项 Skill 已完整解锁，但仍会继续吸收新的真实证据和修正。")
                            .font(AgentOneType.caption)
                            .foregroundStyle(AgentOnePalette.mint)
                    }
                }
                .agentOneCard(padding: AgentOneMetric.spacingL)

                SkillDetailStage(
                    stage: 1,
                    title: "它是什么",
                    symbol: "sparkle.magnifyingglass",
                    minimumPercent: 0,
                    isUnlocked: skill.isUnlocked(1),
                    tint: skill.tint,
                    content: "属于「\(skill.domain)」。\(skill.learnedFrom)，最初形成于 \(Self.dateFormatter.string(from: skill.createdAt))。"
                )
                SkillDetailStage(
                    stage: 2,
                    title: "什么时候会想起它",
                    symbol: "scope",
                    minimumPercent: 20,
                    isUnlocked: skill.isUnlocked(2),
                    tint: skill.tint,
                    content: triggerDescription,
                    tokens: skill.triggerTerms,
                    allTokens: skill.rawTriggerTerms
                )
                SkillDetailStage(
                    stage: 3,
                    title: "Agent 学到的具体做法",
                    symbol: "brain.head.profile",
                    minimumPercent: 40,
                    isUnlocked: skill.isUnlocked(3),
                    tint: skill.tint,
                    content: skill.guidance
                )
                SkillDetailStage(
                    stage: 4,
                    title: "证据与修正轨迹",
                    symbol: "point.3.connected.trianglepath.dotted",
                    minimumPercent: 60,
                    isUnlocked: skill.isUnlocked(4),
                    tint: skill.tint,
                    content: evidenceDescription,
                    tokens: evidenceReferences.map { "证据 #\($0)" }
                )
                SkillDetailStage(
                    stage: 5,
                    title: "成熟能力",
                    symbol: "wand.and.stars.inverse",
                    minimumPercent: 80,
                    isUnlocked: skill.isUnlocked(5),
                    tint: skill.tint,
                    content: "这条经验已经被多次验证。遇到相似 Context 时，Agent 会优先参考它，同时保留新证据，必要时继续生成下一版，而不是把结论永久写死。"
                )
            }
            .padding(28)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 620, idealHeight: 720)
        .background(AgentOnePalette.background)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()
}

private struct SkillLevelRail: View {
    let currentLevel: Int
    let tint: Color

    var body: some View {
        HStack(spacing: AgentOneMetric.spacingS) {
            ForEach(1...5, id: \.self) { level in
                HStack(spacing: AgentOneMetric.spacingXS) {
                    Image(systemName: level <= currentLevel ? "lock.open.fill" : "lock.fill")
                    Text("Lv.\(level)")
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(level <= currentLevel ? tint : AgentOnePalette.textTertiary)
                if level < 5 {
                    Rectangle()
                        .fill(level < currentLevel ? tint.opacity(0.55) : AgentOnePalette.separator)
                        .frame(height: 1)
                }
            }
        }
    }
}

private struct SkillDetailStage: View {
    @State private var showsAllTokens = false

    let stage: Int
    let title: String
    let symbol: String
    let minimumPercent: Int
    let isUnlocked: Bool
    let tint: Color
    let content: String
    var tokens: [String] = []
    var allTokens: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: AgentOneMetric.spacingL) {
            Image(systemName: isUnlocked ? symbol : "lock.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isUnlocked ? tint : AgentOnePalette.textTertiary)
                .frame(width: 38, height: 38)
                .background(
                    (isUnlocked ? tint : AgentOnePalette.textTertiary).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: AgentOneMetric.radiusSmall, style: .continuous)
                )
            VStack(alignment: .leading, spacing: AgentOneMetric.spacingS) {
                HStack {
                    Text("Lv.\(stage) · \(title)")
                        .font(AgentOneType.headline)
                        .foregroundStyle(isUnlocked ? AgentOnePalette.textPrimary : AgentOnePalette.textSecondary)
                    Spacer()
                    AgentOnePill(
                        title: isUnlocked ? "已解锁" : "\(minimumPercent)% 解锁",
                        symbol: isUnlocked ? "checkmark" : "lock",
                        tint: isUnlocked ? AgentOnePalette.mint : AgentOnePalette.textTertiary
                    )
                }
                Text(isUnlocked ? content : "继续积累真实反馈和可核验的 Context 证据后，这部分会自动打开。")
                    .font(AgentOneType.callout)
                    .foregroundStyle(AgentOnePalette.textSecondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                if isUnlocked, !tokens.isEmpty {
                    FlowTokenView(tokens: tokens, tint: tint)
                }
                if isUnlocked, allTokens.count > tokens.count {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsAllTokens.toggle()
                        }
                    } label: {
                        HStack(spacing: AgentOneMetric.spacingXS) {
                            Image(systemName: showsAllTokens ? "chevron.up" : "chevron.down")
                            Text(showsAllTokens
                                ? "收起原始线索"
                                : "查看全部 \(allTokens.count) 个原始线索")
                        }
                        .font(AgentOneType.caption)
                        .foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)

                    if showsAllTokens {
                        ScrollView {
                            Text(allTokens.joined(separator: "\n"))
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(AgentOnePalette.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 180)
                        .padding(AgentOneMetric.spacingM)
                        .background(AgentOnePalette.surface2, in: RoundedRectangle(cornerRadius: AgentOneMetric.radiusSmall, style: .continuous))
                    }
                }
            }
        }
        .agentOneCard(padding: AgentOneMetric.spacingL)
    }
}

private struct FlowTokenView: View {
    let tokens: [String]
    let tint: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AgentOneMetric.spacingS) {
                ForEach(Array(tokens.prefix(12).enumerated()), id: \.offset) { _, token in
                    Text(token)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(tint.opacity(0.11), in: Capsule())
                }
            }
        }
    }
}
