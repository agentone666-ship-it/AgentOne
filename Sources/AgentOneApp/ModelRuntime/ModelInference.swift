import Foundation
import AgentOneCore

public enum ModelInferenceRoute: String, Codable, Sendable {
    case cloud
    case local
    case automatic
}

public struct ModelInferenceRequest: Sendable {
    public var purpose: String
    public var systemPrompt: String
    public var userPrompt: String
    public var context: ActivityContext?
    public var allowsCloudProcessing: Bool

    public init(purpose: String, systemPrompt: String, userPrompt: String, context: ActivityContext?, allowsCloudProcessing: Bool) {
        self.purpose = purpose
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.context = context
        self.allowsCloudProcessing = allowsCloudProcessing
    }
}

public struct ModelInferenceResult: Sendable {
    public var text: String
    public var route: ModelInferenceRoute
    public var provider: String
    public var model: String
    public var sentContextFields: [String]

    public init(text: String, route: ModelInferenceRoute, provider: String, model: String, sentContextFields: [String]) {
        self.text = text
        self.route = route
        self.provider = provider
        self.model = model
        self.sentContextFields = sentContextFields
    }
}

public struct ModelInvocationAudit: Codable, Sendable {
    public struct Usage: Codable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var totalTokens: Int
        public var turns: Int
        public var toolCalls: Int
        public var durationMs: Int

        public init(inputTokens: Int, outputTokens: Int, totalTokens: Int, turns: Int, toolCalls: Int, durationMs: Int) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
            self.turns = turns
            self.toolCalls = toolCalls
            self.durationMs = durationMs
        }
    }

    public var timestamp: Date
    public var purpose: String
    public var route: ModelInferenceRoute
    public var provider: String
    public var model: String
    public var sentContextFields: [String]
    public var usage: Usage?
    public var succeeded: Bool
    public var fallback: String?
    public var errorCode: String?

    public init(timestamp: Date, purpose: String, route: ModelInferenceRoute, provider: String, model: String, sentContextFields: [String], usage: Usage?, succeeded: Bool, fallback: String?, errorCode: String?) {
        self.timestamp = timestamp
        self.purpose = purpose
        self.route = route
        self.provider = provider
        self.model = model
        self.sentContextFields = sentContextFields
        self.usage = usage
        self.succeeded = succeeded
        self.fallback = fallback
        self.errorCode = errorCode
    }
}

public enum ModelInferenceError: LocalizedError {
    case missingCredential
    case cloudProcessingDisabled
    case sensitiveContextBlocked
    case localModelUnavailable
    case invalidServerResponse
    case server(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "还没有保存模型 API Key。"
        case .cloudProcessingDisabled: "这次 Context 没有被允许离开设备。"
        case .sensitiveContextBlocked: "支付、密码或安全输入 Context 永远不会发送给模型。"
        case .localModelUnavailable: "本地模型尚未安装。"
        case .invalidServerResponse: "模型服务返回了无法识别的内容。"
        case .server(let statusCode, let message): "模型服务请求失败（\(statusCode)）：\(message)"
        }
    }
}

public protocol AgentModelClient: Sendable {
    func infer(_ request: ModelInferenceRequest, apiKey: String) async throws -> ModelInferenceResult
}

/// OpenAI-compatible Chat Completions client used by the user-supplied API Key
/// route. The base URL and model are local, non-secret settings; only the key
/// enters the Authorization header at request time.
public actor OpenAICompatibleModelClient: AgentModelClient {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var model: String
        public var providerName: String

        public init(baseURL: URL, model: String, providerName: String) {
            self.baseURL = baseURL
            self.model = model
            self.providerName = providerName
        }

        public static let defaultCloud = Configuration(
            baseURL: URL(string: "http://algoagent.zhuaninc.com/algo")!,
            model: "glm-5.2",
            providerName: "OpenAI-compatible"
        )

        public var chatCompletionsEndpoint: URL {
            if baseURL.path.hasSuffix("/chat/completions") { return baseURL }
            return baseURL
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("completions", isDirectory: false)
        }
    }

    private struct ServerErrorEnvelope: Decodable {
        struct ErrorBody: Decodable { var message: String? }
        var error: ErrorBody?
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration = .defaultCloud, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func infer(_ request: ModelInferenceRequest, apiKey: String) async throws -> ModelInferenceResult {
        guard request.allowsCloudProcessing else {
            throw ModelInferenceError.cloudProcessingDisabled
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelInferenceError.missingCredential
        }
        guard request.context?.isSensitive != true else {
            throw ModelInferenceError.sensitiveContextBlocked
        }

        let sentFields = Self.sentContextFields(for: request.context)
        var urlRequest = URLRequest(url: configuration.chatCompletionsEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 45
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": Self.cloudInput(for: request)]
            ],
            "stream": false
        ])

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ModelInferenceError.invalidServerResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let decodedError = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data)
            let serverMessage = Self.safeServerMessage(decodedError?.error?.message, statusCode: http.statusCode)
            throw ModelInferenceError.server(statusCode: http.statusCode, message: serverMessage)
        }
        guard let text = Self.chatCompletionText(from: data) else {
            throw ModelInferenceError.invalidServerResponse
        }

        return ModelInferenceResult(
            text: text,
            route: .cloud,
            provider: configuration.providerName,
            model: configuration.model,
            sentContextFields: sentFields
        )
    }

    private static func chatCompletionText(from data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else { return nil }

        if let content = message["content"] as? String {
            let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        if let content = message["content"] as? [[String: Any]] {
            let text = content.compactMap { item -> String? in
                if let value = item["text"] as? String { return value }
                if let value = item["content"] as? String { return value }
                return nil
            }.joined()
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        return nil
    }

    private static func safeServerMessage(_ message: String?, statusCode: Int) -> String {
        switch statusCode {
        case 401, 403: return "鉴权失败，请检查 API Key。"
        case 404: return "没有找到 Chat Completions 接口，请检查服务地址。"
        case 429: return "请求过于频繁或额度不足。"
        default:
            guard let message else { return "上游服务暂时不可用。" }
            let lowered = message.lowercased()
            if lowered.contains("key") || lowered.contains("token") || lowered.contains("authorization") {
                return "上游服务拒绝了请求。"
            }
            return String(message.prefix(180))
        }
    }

    private static func sentContextFields(for context: ActivityContext?) -> [String] {
        guard let context else { return [] }
        var fields: [String] = []
        if context.applicationName != nil { fields.append("applicationName") }
        if context.bundleIdentifier != nil { fields.append("bundleIdentifier") }
        if context.windowTitle != nil { fields.append("windowTitle") }
        if context.url != nil { fields.append("url") }
        if context.documentPath != nil { fields.append("documentPath") }
        if context.contentSummary != nil { fields.append("contentSummary") }
        if context.selectedText != nil { fields.append("selectedText") }
        if context.submittedText != nil { fields.append("submittedText") }
        if context.screenText != nil { fields.append("screenText") }
        if context.interactionTarget != nil { fields.append("interactionTarget") }
        if context.contextTransition != nil { fields.append("contextTransition") }
        if !context.semanticTags.isEmpty { fields.append("semanticTags") }
        return fields
    }

    private static func cloudInput(for request: ModelInferenceRequest) -> String {
        guard let context = request.context else { return request.userPrompt }
        var payload: [String: Any] = [:]
        if let value = context.applicationName { payload["applicationName"] = value }
        if let value = context.bundleIdentifier { payload["bundleIdentifier"] = value }
        if let value = context.windowTitle { payload["windowTitle"] = value }
        if let value = context.url { payload["url"] = value.absoluteString }
        if let value = context.documentPath { payload["documentPath"] = value }
        if let value = context.contentSummary { payload["contentSummary"] = value }
        if let value = context.selectedText { payload["selectedText"] = value }
        if let value = context.submittedText { payload["submittedText"] = value }
        if let value = context.screenText { payload["screenText"] = value }
        if let value = context.interactionTarget { payload["interactionTarget"] = value }
        if let value = context.contextTransition { payload["contextTransition"] = value }
        if !context.semanticTags.isEmpty { payload["semanticTags"] = context.semanticTags.sorted() }

        guard
            !payload.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return request.userPrompt
        }
        return "\(request.userPrompt)\n\n[AgentOne authorized context]\n\(json)"
    }
}

public actor ModelInferenceRouter {
    private let cloudClient: any AgentModelClient

    public init(cloudClient: any AgentModelClient = OpenAICompatibleModelClient()) {
        self.cloudClient = cloudClient
    }

    public func infer(
        _ request: ModelInferenceRequest,
        route: ModelInferenceRoute,
        apiKey: String
    ) async throws -> ModelInferenceResult {
        if request.context?.isSensitive == true {
            throw ModelInferenceError.sensitiveContextBlocked
        }

        switch route {
        case .cloud:
            return try await cloudClient.infer(request, apiKey: apiKey)
        case .local:
            throw ModelInferenceError.localModelUnavailable
        case .automatic:
            // Automatic routing intentionally falls back to the implemented
            // cloud path only when the user has allowed cloud processing.
            guard request.allowsCloudProcessing else {
                throw ModelInferenceError.localModelUnavailable
            }
            return try await cloudClient.infer(request, apiKey: apiKey)
        }
    }
}
