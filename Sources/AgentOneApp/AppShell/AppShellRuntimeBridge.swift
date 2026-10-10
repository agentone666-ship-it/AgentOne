import AgentOneCore
import Foundation
import SwiftUI

/// Converts the Core actor's immutable, Sendable output into MainActor UI state.
/// The shell only renders persisted runtime data. Empty state is explicit so
/// demo copy can never be mistaken for a real memory or model thought.
@MainActor
extension AgentOneShellViewModel {
    func consumeRuntime(
        event: ActivityEvent,
        output: ContextEngineOutput,
        replay: SemanticReplay? = nil,
        habits: [HabitContext]? = nil
    ) {
        if let intent = output.activeIntent {
            currentIntent = IntentSnapshot(
                id: intent.id,
                title: intent.title,
                detail: intent.summary,
                application: event.context.applicationName ?? "当前应用",
                confidence: intent.confidence,
                startedAt: intent.startedAt,
                signals: Self.runtimeSignals(for: event, relevance: output.relevance)
            )
        } else {
            currentIntent = IntentSnapshot(
                id: event.id,
                title: event.context.windowTitle ?? "正在理解当前活动",
                detail: event.context.contentSummary ?? Self.activityDescription(for: event),
                application: event.context.applicationName ?? "当前应用",
                confidence: 0.5,
                startedAt: event.timestamp,
                signals: Self.runtimeSignals(for: event, relevance: output.relevance)
            )
        }

        hasLiveContext = true
        lastRuntimeUpdate = event.timestamp
        if let replay {
            // Live capture keeps today's library projection fresh, but it must
            // never pull the user out of a historical day they deliberately
            // opened. Previously every new click/scroll/Return reapplied
            // today's replay unconditionally, leaving the old date chip
            // highlighted while the visible content had silently jumped back
            // to today.
            persistedReplaysByDay[replay.day] = replay
            mergeSkillCards(from: replay)
            rebuildReplayLibraryMetadata()
            rebuildMemoryLibrary()
            if selectedReplayDay == replay.day || !isBrowsingReplayHistory {
                selectedReplayDay = replay.day
                isBrowsingReplayHistory = replay.day != Self.dayKey(Date())
                applyRuntimeReplay(replay)
            }
        }
        if let habits { consumeHabitContexts(habits) }
    }

    /// Loads an already persisted diary on launch without pretending the old
    /// session is necessarily the user's current intent.
    func consumePersistedReplay(_ replay: SemanticReplay, habits: [HabitContext] = []) {
        persistedReplaysByDay[replay.day] = replay
        if selectedReplayDay == nil {
            selectedReplayDay = replay.day
        }
        mergeSkillCards(from: replay)
        rebuildReplayLibraryMetadata()
        if selectedReplayDay == replay.day || !isBrowsingReplayHistory {
            applyRuntimeReplay(replay)
        }
        consumeHabitContexts(habits)
        rebuildMemoryLibrary()
    }

    /// Loads the complete local library in one pass. Replay, Journal, Memory
    /// and Skills all use this same snapshot, so the UI cannot accidentally
    /// show a current-day-only view for one section and a different projection
    /// for another.
    func consumePersistedLibrary(
        _ replays: [SemanticReplay],
        habits: [HabitContext] = [],
        skills persistedSkills: [AgentSkill] = []
    ) {
        persistedReplaysByDay = Dictionary(uniqueKeysWithValues: replays.map { ($0.day, $0) })
        self.skills = persistedSkills.map(Self.makeSkillCard(from:))
        replays.forEach { mergeSkillCards(from: $0) }
        consumeHabitContexts(habits)
        rebuildReplayLibraryMetadata()
        rebuildMemoryLibrary()

        let today = Self.dayKey(Date())
        let preferredDay = replays.contains(where: { $0.day == today })
            ? today
            : replays.map(\.day).max()
        if selectedReplayDay == nil || !persistedReplaysByDay.keys.contains(selectedReplayDay ?? "") {
            selectedReplayDay = preferredDay
        }
        isBrowsingReplayHistory = selectedReplayDay != today
        if let selectedReplayDay,
           let selectedReplay = persistedReplaysByDay[selectedReplayDay] {
            applyRuntimeReplay(selectedReplay)
        } else {
            replayMoments = []
            agentJournalEntries = []
            dailyDigest = nil
            hasLiveReplay = false
            replayDayLabel = "还没有记录"
        }
    }

    func selectReplayDay(_ day: String) {
        guard let replay = persistedReplaysByDay[day] else { return }
        selectedReplayDay = day
        isBrowsingReplayHistory = day != Self.dayKey(Date())
        applyRuntimeReplay(replay)
    }

    private func rebuildReplayLibraryMetadata() {
        let sorted = persistedReplaysByDay.values.sorted { $0.day > $1.day }
        replayDays = sorted.map { replay in
            ReplayDayOption(
                day: replay.day,
                label: Self.localizedDayLabel(replay.day),
                contextCount: replay.contextLogMoments.count,
                journalCount: replay.agentJournalMoments.count,
                skillCount: replay.moments.filter { $0.kind == .learnedSkill }.count
            )
        }
        totalRecordedDays = sorted.count
        totalRecordedContextCount = sorted.reduce(0) { $0 + $1.contextLogMoments.count }
    }

    private func rebuildMemoryLibrary() {
        var cards: [MemoryCard] = []
        let sorted = persistedReplaysByDay.values.sorted { $0.day > $1.day }
        for replay in sorted {
            if let digest = replay.latestDailyContextDigest {
                cards.append(MemoryCard(
                    id: digest.id,
                    title: digest.headline,
                    detail: digest.overview,
                    source: .observed,
                    date: Self.localizedDayLabel(replay.day),
                    tags: ["每日 Context", digest.mood],
                    confidence: digest.sourceContextCount == 0 ? nil : min(1, Double(digest.sourceContextCount) / 10),
                    evidenceCount: digest.evidenceCount
                ))
                continue
            }

            // A day may legitimately predate daily-digest generation. Keep a
            // concrete, evidence-backed Context memory visible instead of
            // making the user believe that the day was lost.
            if let moment = replay.contextLogMoments.last {
                cards.append(MemoryCard(
                    id: moment.sourceEntryID,
                    title: moment.title,
                    detail: moment.detail ?? "这段经历已保存在 Context 回放中。",
                    source: .observed,
                    date: Self.localizedDayLabel(replay.day),
                    tags: ["可回忆 Context", "回放证据"],
                    confidence: nil,
                    evidenceCount: moment.evidenceIDs.count
                ))
            }
        }
        memories = cards
    }

    private func consumeHabitContexts(_ habits: [HabitContext]) {
        learnedHabits = habits.map { habit in
            MemoryCard(
                title: habit.title,
                detail: habit.summary,
                source: habit.supportingSessionCount >= 2 ? .observed : .inferred,
                date: habit.supportingSessionCount >= 2 ? "已观察 \(habit.supportingSessionCount) 次" : "正在学习",
                tags: ["习惯 Context", habit.kind == .readingRhythm ? "阅读节奏" : "活动节奏"],
                confidence: habit.confidence,
                evidenceCount: habit.evidenceEntryIDs.count
            )
        }
    }

    private func applyRuntimeReplay(_ replay: SemanticReplay) {
        let evidenceByID = Dictionary(uniqueKeysWithValues: replay.evidence.map { ($0.id, $0) })
        // The diary is permanent, so its read model must be permanent too. The
        // previous UI-only suffixes silently hid the beginning of busy days
        // (Context after 160 rows and Agent thoughts after 80 rows) even though
        // every immutable fact was still present on disk. SwiftUI renders the
        // corresponding views lazily, so retaining the complete selected day
        // here preserves history without eagerly constructing every row.
        let mapped = replay.contextLogMoments.map {
            Self.makeReplayMoment(from: $0, evidenceByID: evidenceByID)
        }
        replayMoments = mapped
        dailyDigest = replay.latestDailyContextDigest.map(Self.makeDailyDigestCard)
        agentJournalEntries = replay.agentJournalMoments
            .reversed()
            .map { Self.makeAgentJournalCard(from: $0, evidenceByID: evidenceByID) }
        mergeSkillCards(from: replay)
        hasLiveReplay = !mapped.isEmpty
        replayDayLabel = Self.localizedDayLabel(replay.day)

        if selectedReplayMomentID == nil {
            self.selectedReplayMomentID = mapped.last?.id
        } else if let selectedReplayMomentID,
                  !mapped.contains(where: { $0.id == selectedReplayMomentID }) {
            self.selectedReplayMomentID = mapped.last?.id
        }
    }

    private func mergeSkillCards(from replay: SemanticReplay) {
        for moment in replay.moments where moment.kind == .learnedSkill {
            let rawName = moment.title.replacingOccurrences(of: "Learned: ", with: "")
            let name = Self.localizedSkillName(rawName)
            guard !skills.contains(where: { $0.name == name }) else { continue }
            skills.append(Self.makeSkillCard(from: moment))
        }
    }

    private static func makeSkillCard(from skill: AgentSkill) -> AgentSkillCard {
        let distinctEvidenceCount = Set(skill.sourceEntryIDs).count
        let guidance = localizedSkillGuidance(skill.guidance)
        let rawTriggerTerms = skill.triggerTerms.sorted()
        return AgentSkillCard(
            id: skill.id,
            name: localizedSkillName(skill.name),
            detail: skill.masteryLevel >= 3
                ? guidance
                : "我正在确认这条经验在哪些 Context 里稳定成立。",
            level: skill.masteryLevel,
            completion: skill.completion,
            evidenceCount: distinctEvidenceCount,
            learnedFrom: "真实反馈与 \(distinctEvidenceCount) 条证据",
            domain: localizedSkillDomain(skill.domain),
            triggerTerms: representativeSkillTriggerTerms(from: rawTriggerTerms),
            rawTriggerTerms: rawTriggerTerms,
            guidance: guidance,
            confidence: skill.confidence,
            revision: skill.revision,
            evidenceIDs: skill.sourceEntryIDs,
            createdAt: skill.createdAt,
            hasCompleteRecord: true,
            symbol: "wand.and.stars",
            tint: AgentOnePalette.violet
        )
    }

    private static func makeAgentJournalCard(
        from moment: AgentOneCore.ReplayMoment,
        evidenceByID: [UUID: KeyEvidence]
    ) -> AgentJournalCard {
        let evidence = moment.evidenceIDs.lazy
            .compactMap { evidenceByID[$0] }
            .first(where: { $0.kind == .screenshot })
        return AgentJournalCard(
            id: moment.id,
            timestamp: moment.timestamp,
            observation: moment.title,
            submittedText: moment.submittedText.map { sanitizedDisplayText($0) },
            evidenceLabel: evidence == nil ? nil : "回车关键截图",
            evidenceResourcePath: evidence?.localResourcePath,
            hypothesis: moment.thoughtHypothesis,
            consideredAction: moment.thoughtConsideredAction,
            why: moment.thoughtWhy,
            disposition: localizedDisposition(moment.thoughtDisposition),
            uncertainty: moment.thoughtUncertainty ?? 0
        )
    }

    private static func makeSkillCard(from moment: AgentOneCore.ReplayMoment) -> AgentSkillCard {
        let rawName = moment.title.replacingOccurrences(of: "Learned: ", with: "")
        let guidance = localizedSkillGuidance(
            moment.detail ?? "这项能力来自真实反馈，并会在后续经历中继续修正。"
        )
        return AgentSkillCard(
            id: moment.id,
            name: localizedSkillName(rawName),
            detail: guidance,
            level: 2,
            completion: 0.20,
            evidenceCount: max(1, moment.evidenceIDs.count),
            learnedFrom: "真实日记与用户反馈",
            domain: "历史 Skill",
            triggerTerms: [],
            rawTriggerTerms: [],
            guidance: guidance,
            confidence: 0.40,
            revision: 1,
            evidenceIDs: moment.evidenceIDs,
            createdAt: moment.timestamp,
            hasCompleteRecord: false,
            symbol: "wand.and.stars",
            tint: AgentOnePalette.violet
        )
    }

    private static func localizedSkillDomain(_ domain: SkillDomain) -> String {
        switch domain {
        case .intentDetection: "意图识别"
        case .driftDetection: "分心识别"
        case .reminderTiming: "提醒节奏"
        case .social: "社交理解"
        case .taskRecovery: "任务恢复"
        case .companionship: "陪伴方式"
        }
    }

    private static func localizedSkillName(_ name: String) -> String {
        switch name {
        case "Recognize related detours": "识别看似绕路、其实相关的活动"
        case "Recognize this distraction pattern": "识别这类分心模式"
        case "Reuse a helpful reminder rhythm": "复用有效的提醒节奏"
        case "Wait longer before asking": "晚一点再问"
        case "Use a softer intervention": "更轻地介入"
        case "Learn from an intent correction": "从意图纠正中学习"
        default: name
        }
    }

    private static func localizedSkillGuidance(_ guidance: String) -> String {
        switch guidance {
        case "Treat contexts with these terms as potentially supporting the active task before calling them a distraction.":
            "当 Context 出现这些线索时，先判断它是否在支持当前任务，再把它认定为分心。"
        case "Lower relevance when this context appears without semantic overlap with the active intent.":
            "当这类 Context 与当前意图没有语义关联时，降低相关性并把它视为潜在分心。"
        case "Preserve the reminder timing and gentle modality used in this episode.":
            "在相似场景中复用这次有效的提醒时机，并保持轻柔的表达方式。"
        case "Increase the drift duration before the first interruption for similar contexts.":
            "遇到相似 Context 时，延长首次打扰前的等待时间。"
        case "Prefer creature motion or a curious text bubble over sound or persistent interruption.":
            "优先使用生命体动作或好奇的文字气泡，不要直接使用声音或持续打断。"
        case "Use the user's correction as higher-priority evidence than the earlier inference.":
            "把用户的纠正当作比先前推断优先级更高的证据。"
        default: guidance
        }
    }

    /// The append-only diary retains every raw trigger term, but a Skill's
    /// default view should read like learned judgement rather than a database
    /// dump. Keep the full set available behind an explicit disclosure and
    /// surface a small, deterministic group of human-readable clues first.
    private static func representativeSkillTriggerTerms(
        from rawTerms: [String],
        limit: Int = 12
    ) -> [String] {
        let lowSignalTerms: Set<String> = [
            "agent", "agentone", "app", "applications", "browser", "chat",
            "chrome", "com", "contents", "context", "default", "enrichment",
            "hook", "http", "https", "jsonl", "main", "md", "model", "output",
            "page", "png", "process", "profile", "projects", "scrollarea",
            "sidecar", "swift", "tabbarview", "token", "unavailable", "users",
            "window", "zip", "应用", "内容", "工作台", "窗口", "页面", "更多",
            "状态", "文件", "消息", "输出", "完成", "查看全部"
        ]

        return rawTerms
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { term in
                guard term.count >= 2, term.count <= 32 else { return false }
                let lowered = term.lowercased()
                guard !lowSignalTerms.contains(lowered) else { return false }
                guard lowered.range(of: #"^\d+$"#, options: .regularExpression) == nil else { return false }
                guard lowered.range(of: #"^[0-9a-f]{8,}$"#, options: .regularExpression) == nil else { return false }
                guard lowered.range(of: #"^[a-z]?\d+[a-z0-9-]*$"#, options: .regularExpression) == nil else { return false }
                return term.contains(where: { $0.isLetter })
            }
            .sorted { lhs, rhs in
                let lhsHasChinese = lhs.unicodeScalars.contains { (0x4E00 ... 0x9FFF).contains($0.value) }
                let rhsHasChinese = rhs.unicodeScalars.contains { (0x4E00 ... 0x9FFF).contains($0.value) }
                if lhsHasChinese != rhsHasChinese { return lhsHasChinese }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private static func makeDailyDigestCard(
        from digest: DailyContextDigest
    ) -> DailyDigestCard {
        DailyDigestCard(
            id: digest.id,
            generatedAt: digest.generatedAt,
            isFinal: digest.isFinal,
            headline: digest.headline,
            overview: digest.overview,
            highlights: digest.highlights,
            rhythm: digest.rhythm,
            unfinishedThread: digest.unfinishedThread,
            agentNote: digest.agentNote,
            invitation: digest.invitation,
            mood: digest.mood,
            sourceContextCount: digest.sourceContextCount,
            evidenceCount: digest.evidenceCount,
            personalizedMemoryCount: digest.personalizedMemoryCount
        )
    }

    private static func localizedDisposition(_ disposition: AgentThoughtDisposition?) -> String {
        switch disposition {
        case .spoken: "我去找你了"
        case .heldBack: "想了，但没说"
        case .postponedForSurprise: "偷偷藏着"
        case .observationOnly: "我先窝着观察"
        case nil: "未标记"
        }
    }

    private static func makeReplayMoment(
        from moment: AgentOneCore.ReplayMoment,
        evidenceByID: [UUID: KeyEvidence]
    ) -> ReplayMoment {
        let evidence = moment.evidenceIDs.lazy.compactMap { evidenceByID[$0] }.first
        return ReplayMoment(
            id: moment.id,
            time: timeFormatter.string(from: moment.timestamp),
            title: localizedReplayTitle(moment),
            detail: sanitizedDisplayText(moment.detail ?? localizedLane(moment.lane)),
            application: localizedLane(moment.lane),
            kind: shellKind(for: moment.kind),
            evidenceLabel: evidence?.kind == .screenshot
                ? "回车关键截图"
                : (moment.evidenceIDs.isEmpty ? nil : "关键证据"),
            evidenceResourcePath: evidence?.localResourcePath
        )
    }

    /// Evidence summaries are captured from raw window content, which may
    /// contain terminal chrome (box-drawing and block glyphs), prompt markers
    /// and oversized dumps. They are persisted verbatim in the append-only
    /// diary, so readability is restored here, at the display seam.
    private static func sanitizedDisplayText(_ text: String, limit: Int = 220) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2500 ... 0x259F, // box drawing + block elements
                 0x25A0 ... 0x25FF: // geometric shapes (■ ▶ ● …)
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        let cleanedLines = String(String.UnicodeScalarView(scalars))
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let letters = line.filter { $0.isLetter || $0.isNumber }
                return letters.count >= 2
            }
        var result = cleanedLines.joined(separator: " · ")
        if result.count > limit {
            let cutoff = result.index(result.startIndex, offsetBy: limit)
            result = result[..<cutoff].trimmingCharacters(in: .whitespaces) + " …"
        }
        return result.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : result
    }

    private static func shellKind(for kind: ReplayMomentKind) -> ReplayMoment.Kind {
        switch kind {
        case .activity, .intent:
            return .focus
        case .evidence, .learnedSkill, .summary:
            return .output
        case .drift, .reminder:
            return .detour
        case .returned, .correction:
            return .returnToTask
        case .thought:
            return .rest
        }
    }

    private static func localizedReplayTitle(_ moment: AgentOneCore.ReplayMoment) -> String {
        switch moment.kind {
        case .intent:
            if moment.title.hasPrefix("Started: ") {
                return "开始：" + moment.title.dropFirst("Started: ".count)
            }
            return "确认了当前意图"
        case .drift:
            if moment.title == "Attention stayed elsewhere" {
                return "注意力离开了当前任务"
            }
            return "注意力开始偏离"
        case .reminder:
            return "我好奇地问了一句"
        case .returned:
            if moment.title == "Returned after a sustained detour" {
                return "一次走神结束，回到了任务"
            }
            return "回到了刚才的意图"
        case .thought:
            return "我当时这样想"
        case .correction:
            return "你纠正了我的理解"
        case .evidence:
            return moment.title == "A thought was expressed" ? "记录了一个观点" : moment.title
        case .learnedSkill:
            return moment.title.replacingOccurrences(of: "Learned: ", with: "学会了：")
        case .summary:
            return "今天的回顾"
        case .activity:
            return localizedActivityNarrative(moment.title)
        }
    }

    private static func localizedActivityNarrative(_ narrative: String) -> String {
        if narrative.hasPrefix("Read ") {
            let content = String(narrative.dropFirst("Read ".count))
            if let range = content.range(of: " for about "), content.hasSuffix(" minutes") {
                let place = content[..<range.lowerBound]
                let minutes = content[range.upperBound...].dropLast(" minutes".count)
                return "持续阅读 · \(place) · 约 \(minutes) 分钟"
            }
            if content.hasSuffix(" as one continuous session") {
                return "持续阅读 · " + content.dropLast(" as one continuous session".count)
            }
            return "持续阅读 · \(content)"
        }
        let semanticPrefixes: [(String, String)] = [
            ("Wrote in ", "持续写作 · "),
            ("Researched in ", "持续查资料 · "),
            ("Communicated in ", "持续沟通 · "),
            ("Watched ", "持续观看 · "),
            ("Navigated ", "浏览与切换 · "),
            ("Took a break", "暂时离开电脑")
        ]
        for (source, target) in semanticPrefixes where narrative.hasPrefix(source) {
            var content = String(narrative.dropFirst(source.count))
            if let range = content.range(of: " for about "), content.hasSuffix(" minutes") {
                let place = content[..<range.lowerBound]
                let minutes = content[range.upperBound...].dropLast(" minutes".count)
                return "\(target)\(place) · 约 \(minutes) 分钟"
            }
            if content.hasSuffix(" as one continuous session") {
                content.removeLast(" as one continuous session".count)
            }
            return target + content
        }
        let replacements: [(String, String)] = [
            ("Expressed or submitted a thought in ", "输出了一个观点 · "),
            ("Continued reading in ", "继续阅读 · "),
            ("Worked on writing in ", "继续写作 · "),
            ("Moved attention to ", "切换注意力 · "),
            ("Stepped away from the computer", "暂时离开电脑"),
            ("Interacted with ", "进行了操作 · ")
        ]
        for (source, target) in replacements where narrative.hasPrefix(source) {
            return target + narrative.dropFirst(source.count)
        }
        return narrative
    }

    private static func localizedLane(_ lane: ReplayLane) -> String {
        switch lane {
        case .userActivity: "电脑活动"
        case .agentMind: "Agent 的想法"
        case .relationship: "我们之间"
        }
    }

    private static func runtimeSignals(for event: ActivityEvent, relevance: Double?) -> [String] {
        var signals: [String] = [activityDescription(for: event)]
        if let application = event.context.applicationName {
            signals.append("正在使用 \(application)")
        }
        if let relevance {
            signals.append("与当前意图相关度 \(Int(relevance * 100))%")
        }
        if event.context.isSensitive {
            signals.append("敏感 Context 已屏蔽")
        }
        return Array(signals.prefix(3))
    }

    private static func activityDescription(for event: ActivityEvent) -> String {
        if event.semantics.contains(.opinionOutput) { return "回车触发：可能完成了一次观点输出" }
        if event.semantics.contains(.compositionStarted) { return "检测到开始输入" }
        if event.semantics.contains(.compositionContinued) { return "正在持续输入" }
        if event.semantics.contains(.readingProgress) { return "滚动行为：可能正在继续阅读" }
        if event.semantics.contains(.contextSwitch) { return "切换到了新的应用 Context" }
        if event.semantics.contains(.possibleBreak) { return "可能暂时离开了电脑" }
        if event.semantics.contains(.revision) { return "检测到修改或删除内容" }
        return "捕捉到一次操作信号"
    }

    private static func localizedDayLabel(_ day: String) -> String {
        guard let date = dayParser.date(from: day) else { return day }
        return dayLabelFormatter.string(from: date)
    }

    private static func dayKey(_ date: Date) -> String {
        dayParser.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 · EEEE"
        return formatter
    }()
}
