import AgentOneCore
import Foundation
import SwiftUI

/// A deterministic, synthetic read model used only for documentation images.
/// It never starts sensors, opens Agent Home, reads user defaults, or calls a
/// model. Keeping the fixture in production source lets screenshots exercise
/// the exact same SwiftUI views that users see.
@MainActor
enum DocumentationDemo {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["AGENTONE_DOCUMENTATION_DEMO"] == "1"
    }

    static func configure(_ model: AgentOneShellViewModel) {
        let now = Date()
        let startedAt = now.addingTimeInterval(-42 * 60)

        model.selection = selectedSection
        model.mood = .focused
        model.hasLiveContext = true
        model.hasLiveReplay = true
        model.lastRuntimeUpdate = now
        model.replayDayLabel = "今天"
        model.selectedReplayDay = "2026-08-11"
        model.replayDays = [
            ReplayDayOption(day: "2026-08-11", label: "今天", contextCount: 6, journalCount: 3, skillCount: 2),
            ReplayDayOption(day: "2026-08-10", label: "昨天", contextCount: 9, journalCount: 2, skillCount: 1),
            ReplayDayOption(day: "2026-08-08", label: "上周六", contextCount: 7, journalCount: 2, skillCount: 1)
        ]
        model.totalRecordedContextCount = 84
        model.totalRecordedDays = 12

        model.currentIntent = IntentSnapshot(
            title: "整理注意力恢复的论文方法章节",
            detail: "你正在把刚读到的认知切换研究，整理成一段可放进论文的方法说明。",
            application: "Arc · Paper Draft",
            confidence: 0.91,
            startedAt: startedAt,
            signals: [
                "持续写作 18 分钟",
                "回车提交了一个方法假设",
                "刚才阅读的论文 URL 与当前段落语义相关"
            ]
        )

        model.replayMoments = [
            ReplayMoment(
                time: "09:18",
                title: "阅读注意力恢复研究",
                detail: "围绕 task switching cost 阅读论文，并沿着参考文献补了一个定义。",
                application: "Arc",
                kind: .focus,
                evidenceLabel: "阅读 Context · URL 已补全"
            ),
            ReplayMoment(
                time: "09:46",
                title: "写下方法章节的核心判断",
                detail: "“恢复任务现场比单纯阻止分心更重要。”输入框局部 OCR 已记录本次提交。",
                application: "Paper Draft",
                kind: .output,
                evidenceLabel: "回车 Hook · 输入框局部截图"
            ),
            ReplayMoment(
                time: "10:02",
                title: "短暂离开到视频推荐页",
                detail: "新页面与论文主题没有语义关联，LUMA 先保持安静并开始计算走神时长。",
                application: "Arc",
                kind: .detour,
                evidenceLabel: "意图冲突 · 低强度提醒"
            ),
            ReplayMoment(
                time: "10:09",
                title: "通过任务现场卡片回到写作",
                detail: "恢复论文标签页与原滚动位置，继续修改刚才未完成的段落。",
                application: "Paper Draft",
                kind: .returnToTask,
                evidenceLabel: "返回成功 · 现场已恢复"
            ),
            ReplayMoment(
                time: "12:16",
                title: "明确告诉 LUMA：现在想休息",
                detail: "这一段娱乐被识别为主动休息，不再触发任务冲突提醒。",
                application: "LUMA Chat",
                kind: .rest,
                evidenceLabel: "用户状态反馈"
            )
        ]
        model.selectedReplayMomentID = model.replayMoments.first?.id

        model.agentJournalEntries = [
            AgentJournalCard(
                id: UUID(),
                timestamp: now.addingTimeInterval(-7 * 60),
                observation: "你不是不想继续，而是离开后丢失了刚才那段思路的入口。",
                submittedText: "恢复任务现场比单纯阻止分心更重要。",
                evidenceLabel: "回车输入框 · 本地 OCR",
                evidenceResourcePath: nil,
                hypothesis: "对你来说，带着原句和滚动位置返回，比一句“别分心”更有效。",
                consideredAction: "下次遇到同类写作中断，优先展示任务现场卡片。",
                why: "你已经自己回到写作，所以我把这个想法留在日记里，没有再打断。",
                disposition: "held_back",
                uncertainty: 0.12
            ),
            AgentJournalCard(
                id: UUID(),
                timestamp: now.addingTimeInterval(-35 * 60),
                observation: "你查的“task switching cost”虽然离开了论文页面，但仍然服务于当前段落。",
                submittedText: nil,
                evidenceLabel: "浏览器 URL + 页面正文",
                evidenceResourcePath: nil,
                hypothesis: "搜索支线和原意图一致，不应该被误判成走神。",
                consideredAction: "继续观察，不提醒。",
                why: "页面主题和论文段落有高语义关联。",
                disposition: "observation_only",
                uncertainty: 0.08
            )
        ]

        model.dailyDigest = DailyDigestCard(
            id: UUID(),
            generatedAt: now,
            isFinal: false,
            headline: "今天你把“如何回来”变成了一个具体方法",
            overview: "上午的主线是论文方法章节。你完成了阅读、观点输出、一次走神和一次成功返回，活动被聚合成 6 段 Context，而不是 137 条滚轮与点击信号。",
            highlights: [
                "从两篇研究中补全 task switching cost 的定义",
                "写下“恢复任务现场比阻止分心更重要”的核心判断",
                "第一次用现场卡片恢复标签页与原滚动位置"
            ],
            rhythm: "连续专注约 42 分钟后更容易发生无目的跳转。",
            unfinishedThread: "方法章节还缺少一个真实使用场景作为例子。",
            agentNote: "我想记住：提醒你回来时，最好把刚才的思路一起递回来。",
            invitation: "晚一点要不要一起把今天的场景压缩成论文里的一个例子？",
            mood: "quietly_proud",
            sourceContextCount: 6,
            evidenceCount: 3,
            personalizedMemoryCount: 4
        )

        let memories = [
            MemoryCard(
                title: "写作中断后需要具体的返回入口",
                detail: "原句、标签页和滚动位置比通用提醒更容易让你重新进入任务。",
                source: .observed,
                date: "从 12 天的共同经历中发现",
                tags: ["注意力恢复", "写作", "任务现场"],
                confidence: 0.86,
                evidenceCount: 9
            ),
            MemoryCard(
                title: "相关检索不等于走神",
                detail: "只要搜索概念与当前段落语义一致，就应该保留为研究支线。",
                source: .confirmed,
                date: "你纠正过 4 次",
                tags: ["研究", "意图识别"],
                confidence: 0.93,
                evidenceCount: 11
            ),
            MemoryCard(
                title: "午后更适合轻量复盘",
                detail: "娱乐或休息状态下，你愿意边浏览边和 LUMA 聊两分钟。",
                source: .inferred,
                date: "最近一周",
                tags: ["节奏", "陪伴"],
                confidence: 0.72,
                evidenceCount: 6
            )
        ]
        model.memories = memories
        model.learnedHabits = memories

        model.skills = [
            AgentSkillCard(
                id: UUID(),
                name: "识别看似绕路、其实相关的研究支线",
                detail: "结合当前写作意图、搜索词、页面 URL 与正文，先判断新页面是否仍在服务原任务。",
                level: 5,
                completion: 0.84,
                evidenceCount: 11,
                learnedFrom: "4 次用户纠正 + 7 次成功判断",
                domain: "意图识别",
                triggerTerms: ["论文", "概念检索", "相关支线", "页面语义"],
                rawTriggerTerms: ["task switching cost", "attention restoration", "方法章节", "reference"],
                guidance: "出现跨页面跳转时，先比较与当前任务的语义关系，再决定是否进入走神计时。",
                confidence: 0.91,
                revision: 11,
                evidenceIDs: (0..<11).map { _ in UUID() },
                createdAt: now.addingTimeInterval(-12 * 24 * 60 * 60),
                hasCompleteRecord: true,
                symbol: "point.3.connected.trianglepath.dotted",
                tint: AgentOnePalette.violet
            ),
            AgentSkillCard(
                id: UUID(),
                name: "用任务现场卡片帮助返回写作",
                detail: "当走神持续后恢复原窗口、滚动位置和关键句，让用户不用重新寻找认知入口。",
                level: 4,
                completion: 0.67,
                evidenceCount: 8,
                learnedFrom: "6 次成功返回 + 2 次提醒反馈",
                domain: "注意力恢复",
                triggerTerms: ["离开写作", "返回任务", "恢复现场"],
                rawTriggerTerms: ["return card", "scroll position", "selected text"],
                guidance: "提醒时优先展示离开前最后一句和恢复入口，避免只说“该回去了”。",
                confidence: 0.82,
                revision: 8,
                evidenceIDs: (0..<8).map { _ in UUID() },
                createdAt: now.addingTimeInterval(-9 * 24 * 60 * 60),
                hasCompleteRecord: true,
                symbol: "arrow.uturn.backward.circle.fill",
                tint: AgentOnePalette.mint
            )
        ]

        let health = AgentOneRuntimeHealthStore.shared
        health.updateCapturePermissions(
            isMonitoring: true,
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            screenRecordingGranted: true
        )
        health.markScreenshotCaptured(
            recognizedLineCount: 1,
            fullScreenOCRLineCount: 18,
            recognizedSubmittedText: true,
            source: .focusedInput,
            cropPixelWidth: 1180,
            cropPixelHeight: 212,
            at: now.addingTimeInterval(-7 * 60)
        )
        health.markModelAnalysisSucceeded(
            provider: "OpenAI-compatible",
            model: "demo-model",
            at: now.addingTimeInterval(-6 * 60)
        )
        health.markDiaryPersisted(at: now.addingTimeInterval(-5 * 60))
    }

    private static var selectedSection: AgentOneSection {
        let raw = ProcessInfo.processInfo.environment["AGENTONE_DOCUMENTATION_SECTION"] ?? "now"
        return AgentOneSection(rawValue: raw) ?? .now
    }
}
