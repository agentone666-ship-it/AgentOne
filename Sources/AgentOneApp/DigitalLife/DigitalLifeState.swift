import Foundation
import SwiftUI

/// The visible, user-facing state of the digital life.
///
/// This is deliberately a semantic model rather than a list of animations. The renderer owns
/// how a state looks, while the rest of the app only needs to express what the life is doing.
enum DigitalLifeState: Equatable, Sendable {
    case focused
    case curious
    case thinking
    case distraction(level: Int)
    case celebrating
    case resting
    case energySaver
    case concealingSurprise

    var displayName: String {
        switch self {
        case .focused: "专注静默"
        case .curious: "好奇探视"
        case .thinking: "思考聚合"
        case let .distraction(level): "走神提醒 · \(clamped(level))"
        case .celebrating: "庆祝"
        case .resting: "休息"
        case .energySaver: "节能"
        case .concealingSurprise: "藏着惊喜"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .focused:
            "数字生命正在安静陪伴"
        case .curious:
            "数字生命好奇地探过来"
        case .thinking:
            "数字生命正在思考并整理记忆"
        case let .distraction(level):
            "数字生命正在进行第 \(clamped(level)) 级轻提醒"
        case .celebrating:
            "数字生命正在为你庆祝"
        case .resting:
            "数字生命正在休息"
        case .energySaver:
            "数字生命正在节省口粮"
        case .concealingSurprise:
            "数字生命似乎藏着一个惊喜"
        }
    }

    var normalizedDistractionLevel: Double {
        guard case let .distraction(level) = self else { return 0 }
        return Double(clamped(level) - 1) / 3
    }

    private func clamped(_ level: Int) -> Int {
        min(max(level, 1), 4)
    }
}

enum DigitalLifeAction: Equatable, Sendable {
    case touched
    case answerCuriosity
    case returnToTask
    case changeIntention
    case dismissPrompt
    case openJournal
}

struct DigitalLifePrompt: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case curiosity
        case returnToTask
        case reflection
        case energy
    }

    var kind: Kind
    var title: String
    var detail: String?
    var primaryActionTitle: String?
    var secondaryActionTitle: String?

    static func curiosity(_ question: String) -> Self {
        .init(
            kind: .curiosity,
            title: question,
            detail: "我只是有点好奇。你的回答会让我下次看得更准。",
            primaryActionTitle: "告诉它",
            secondaryActionTitle: "先不说"
        )
    }

    static func distraction(level: Int, taskName: String?) -> Self {
        let safeLevel = min(max(level, 1), 4)
        let task = taskName.map { "「\($0)」" } ?? "刚才的事情"
        let titles = [
            "我好像看见你拐了个弯。",
            "还记得我们刚才在做 \(task) 吗？",
            "那条岔路我替你收好了，要回去吗？",
            "我们是换了目标，还是想回到 \(task)？"
        ]
        return .init(
            kind: .returnToTask,
            title: titles[safeLevel - 1],
            detail: safeLevel == 1 ? nil : "点一下就能看见离开前的任务现场卡片。",
            primaryActionTitle: "回到刚才",
            secondaryActionTitle: "我换目标了"
        )
    }

    static func returnCard(taskName: String, note: String?) -> Self {
        .init(
            kind: .returnToTask,
            title: "我把「\(taskName)」的线索放在手边了。",
            detail: note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "点一下就能看见离开前的任务现场卡片。",
            primaryActionTitle: "回到刚才",
            secondaryActionTitle: "我换目标了"
        )
    }

    static func reflectionInvitation(_ title: String, detail: String?) -> Self {
        .init(
            kind: .reflection,
            title: title,
            detail: detail,
            primaryActionTitle: "看看今天",
            secondaryActionTitle: "晚点再说"
        )
    }
}

/// A small controller for prototypes and the floating window. Production services can either
/// drive this object or feed `DigitalLifeView` with a value state directly.
@MainActor
final class DigitalLifeController: ObservableObject {
    @Published private(set) var state: DigitalLifeState
    @Published private(set) var prompt: DigitalLifePrompt?
    @Published private(set) var interactionRevision = 0

    var currentTaskName: String? {
        didSet {
            if currentTaskName != oldValue {
                currentTaskNote = nil
            }
        }
    }
    var currentTaskNote: String?
    private var transientStateTask: Task<Void, Never>?

    init(
        state: DigitalLifeState = .focused,
        prompt: DigitalLifePrompt? = nil,
        currentTaskName: String? = nil,
        currentTaskNote: String? = nil
    ) {
        self.state = state
        self.prompt = prompt
        self.currentTaskName = currentTaskName
        self.currentTaskNote = currentTaskNote
    }

    func transition(to newState: DigitalLifeState, prompt newPrompt: DigitalLifePrompt? = nil) {
        transientStateTask?.cancel()
        transientStateTask = nil
        state = newState
        prompt = newPrompt
        interactionRevision &+= 1
    }

    func becomeCurious(about question: String) {
        transition(to: .curious, prompt: .curiosity(question))
    }

    func beginThinking() {
        transition(to: .thinking)
    }

    func remindAboutDistraction(level: Int) {
        let safeLevel = min(max(level, 1), 4)
        transition(
            to: .distraction(level: safeLevel),
            prompt: .distraction(level: safeLevel, taskName: currentTaskName)
        )
    }

    func showReturnCard(taskName: String, note: String?, level: Int) {
        let safeLevel = min(max(level, 1), 4)
        currentTaskName = taskName
        currentTaskNote = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        transition(
            to: .distraction(level: safeLevel),
            prompt: .returnCard(taskName: taskName, note: note)
        )
    }

    func inviteToReflection(title: String, detail: String?) {
        transition(
            to: .curious,
            prompt: .reflectionInvitation(title, detail: detail)
        )
    }

    func escalateDistractionReminder() {
        let nextLevel: Int
        if case let .distraction(level) = state {
            nextLevel = min(level + 1, 4)
        } else {
            nextLevel = 1
        }
        remindAboutDistraction(level: nextLevel)
    }

    func celebrate() {
        transition(to: .celebrating)
        transientStateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, self?.state == .celebrating else { return }
            self?.settle()
        }
    }

    func rest() {
        transition(to: .resting)
    }

    func conserveEnergy() {
        transition(to: .energySaver)
    }

    func concealSurprise() {
        transition(to: .concealingSurprise)
    }

    func settle() {
        transition(to: .focused)
    }

    func clearPrompt() {
        prompt = nil
        interactionRevision &+= 1
    }

    func registerTouch() {
        interactionRevision &+= 1
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
