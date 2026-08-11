import Foundation

enum AgentChatRole: String, Codable, Sendable {
    case user
    case agent
}

struct AgentChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let role: AgentChatRole
    var content: String
    let createdAt: Date
    var contextLabel: String?

    init(
        id: UUID = UUID(),
        role: AgentChatRole,
        content: String,
        createdAt: Date = Date(),
        contextLabel: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.contextLabel = contextLabel
    }
}

struct AgentChatSendRequest: Sendable {
    let id: UUID
    let text: String
    let includeCurrentContext: Bool
    let history: [AgentChatMessage]
}

@MainActor
final class AgentChatController: ObservableObject {
    @Published var isOpen = false
    @Published var draft = ""
    @Published private(set) var messages: [AgentChatMessage] = [
        AgentChatMessage(
            role: .agent,
            content: "我在。你可以直接说，也可以让我一起看你刚才在做什么。"
        )
    ]
    @Published private(set) var isThinking = false
    @Published var includesCurrentContext = true
    @Published private(set) var canIncludeCurrentContext = false
    @Published private(set) var contextStatusText = "还没有读取此刻的 Context"
    @Published private(set) var contextLabel: String?

    var onSend: ((AgentChatSendRequest) -> Void)?
    var onCancel: ((UUID) -> Void)?

    private var activeRequestID: UUID?
    private var visibilityObservers: [(Bool) -> Void] = []
    private let maximumRetainedMessages = 40

    /// Visibility has more than one owner: the floating panel must resize itself while the app
    /// shell mirrors the state in its sidebar. Keep observers additive so wiring one concern can
    /// never silently disable another.
    func observeVisibility(_ observer: @escaping (Bool) -> Void) {
        visibilityObservers.append(observer)
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        visibilityObservers.forEach { $0(true) }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        visibilityObservers.forEach { $0(false) }
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func updateContextAvailability(label: String?, isSensitive: Bool) {
        contextLabel = isSensitive ? nil : label
        canIncludeCurrentContext = label != nil && !isSensitive
        if isSensitive {
            includesCurrentContext = false
            contextStatusText = "敏感 Context 已自动屏蔽"
        } else if let label, !label.isEmpty {
            contextStatusText = "可引用：\(label)"
        } else {
            includesCurrentContext = false
            contextStatusText = "没有可引用的当前 Context"
        }
    }

    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }

        draft = ""
        let requestID = UUID()
        let usesContext = includesCurrentContext && canIncludeCurrentContext
        messages.append(
            AgentChatMessage(
                role: .user,
                content: String(text.prefix(8_000)),
                contextLabel: usesContext ? contextLabel : nil
            )
        )
        trimHistoryIfNeeded()
        isThinking = true
        activeRequestID = requestID

        let request = AgentChatSendRequest(
            id: requestID,
            text: String(text.prefix(8_000)),
            includeCurrentContext: usesContext,
            history: Array(messages.suffix(20))
        )
        guard let onSend else {
            receiveOfflineFallback(for: requestID)
            return
        }
        onSend(request)
    }

    func receive(
        _ text: String,
        for requestID: UUID,
        contextLabel: String? = nil
    ) {
        guard activeRequestID == requestID else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(
            AgentChatMessage(
                role: .agent,
                content: normalized.isEmpty ? "我刚才想了一下，但没有组织好语言。再问我一次好吗？" : normalized,
                contextLabel: contextLabel
            )
        )
        finish(requestID)
    }

    func receiveError(_ message: String, for requestID: UUID) {
        guard activeRequestID == requestID else { return }
        messages.append(AgentChatMessage(role: .agent, content: message))
        finish(requestID)
    }

    func cancel() {
        guard let activeRequestID else { return }
        onCancel?(activeRequestID)
        messages.append(AgentChatMessage(role: .agent, content: "好，我先停在这里。"))
        finish(activeRequestID)
    }

    func clearConversation() {
        if let activeRequestID {
            onCancel?(activeRequestID)
        }
        activeRequestID = nil
        isThinking = false
        messages = [
            AgentChatMessage(role: .agent, content: "这里重新变安静了。想聊时再叫我。")
        ]
    }

    private func receiveOfflineFallback(for requestID: UUID) {
        receiveError("我现在还没有接到模型口粮，但可以先陪你把这件事记下来。", for: requestID)
    }

    private func finish(_ requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        isThinking = false
        trimHistoryIfNeeded()
    }

    private func trimHistoryIfNeeded() {
        guard messages.count > maximumRetainedMessages else { return }
        messages.removeFirst(messages.count - maximumRetainedMessages)
    }
}
