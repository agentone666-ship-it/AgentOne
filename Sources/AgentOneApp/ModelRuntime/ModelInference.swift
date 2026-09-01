import Foundation
import AgentOneCore
import Darwin

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
    case localResourcesConstrained(reason: String)
    case invalidServerResponse
    case server(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "还没有保存模型 API Key。"
        case .cloudProcessingDisabled: "这次 Context 没有被允许离开设备。"
        case .sensitiveContextBlocked: "支付、密码或安全输入 Context 永远不会发送给模型。"
        case .localModelUnavailable: "本地模型尚未安装。"
        case .localResourcesConstrained: "电脑现在比较忙，本地模型先不抢资源；Context 已经保留，稍后空闲时再分析。"
        case .invalidServerResponse: "模型服务返回了无法识别的内容。"
        case .server(let statusCode, let message): "模型服务请求失败（\(statusCode)）：\(message)"
        }
    }
}

public enum LocalInferenceResourceBlockReason: String, Codable, Sendable {
    case memoryPressure = "memory_pressure"
    case availableMemory = "available_memory"
    case memoryCompression = "memory_compression"
    case swapUsage = "swap_usage"
    case systemLoad = "system_load"
    case thermalState = "thermal_state"
    case lowPowerMode = "low_power_mode"
    case foregroundActivity = "foreground_activity"

    public var userMessage: String {
        switch self {
        case .memoryPressure, .availableMemory, .memoryCompression, .swapUsage:
            "系统内存比较紧张"
        case .systemLoad:
            "系统正在忙"
        case .thermalState:
            "电脑温度较高"
        case .lowPowerMode:
            "电脑处于低电量模式"
        case .foregroundActivity:
            "你还在操作电脑"
        }
    }
}

public struct LocalInferenceResourceSnapshot: Equatable, Sendable {
    public var memoryPressureLevel: Int32
    public var availableMemoryBytes: UInt64
    public var compressedMemoryBytes: UInt64
    public var swapUsedBytes: UInt64
    public var physicalMemoryBytes: UInt64
    public var oneMinuteLoadAverage: Double
    public var logicalProcessorCount: Int
    public var thermalState: Int
    public var isLowPowerModeEnabled: Bool

    public init(
        memoryPressureLevel: Int32,
        availableMemoryBytes: UInt64,
        compressedMemoryBytes: UInt64,
        swapUsedBytes: UInt64,
        physicalMemoryBytes: UInt64,
        oneMinuteLoadAverage: Double,
        logicalProcessorCount: Int,
        thermalState: Int,
        isLowPowerModeEnabled: Bool
    ) {
        self.memoryPressureLevel = memoryPressureLevel
        self.availableMemoryBytes = availableMemoryBytes
        self.compressedMemoryBytes = compressedMemoryBytes
        self.swapUsedBytes = swapUsedBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.oneMinuteLoadAverage = oneMinuteLoadAverage
        self.logicalProcessorCount = logicalProcessorCount
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}

public struct LocalInferenceResourceDecision: Equatable, Sendable {
    public var canRun: Bool
    public var reason: LocalInferenceResourceBlockReason?

    public init(canRun: Bool, reason: LocalInferenceResourceBlockReason?) {
        self.canRun = canRun
        self.reason = reason
    }
}

/// A hard resource gate in front of every local-model wake. Context capture and
/// append-only diary writes never depend on this gate: when the Mac is busy,
/// AgentOne keeps the evidence and delays semantic enrichment instead of
/// competing with foreground typing, scrolling, calls, or other applications.
public enum LocalInferenceResourcePolicy {
    public static let minimumAvailableMemoryBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
    public static let minimumMaximumCompressedMemoryBytes: UInt64 = 3 * 1_024 * 1_024 * 1_024
    public static let minimumMaximumSwapUsedBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

    public static func currentSnapshot() -> LocalInferenceResourceSnapshot {
        let memory = currentMemoryUsage()
        return LocalInferenceResourceSnapshot(
            memoryPressureLevel: currentMemoryPressureLevel(),
            availableMemoryBytes: memory.available,
            compressedMemoryBytes: memory.compressed,
            swapUsedBytes: currentSwapUsedBytes(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            oneMinuteLoadAverage: currentOneMinuteLoadAverage(),
            logicalProcessorCount: max(ProcessInfo.processInfo.activeProcessorCount, 1),
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    public static func evaluate(
        snapshot: LocalInferenceResourceSnapshot = currentSnapshot(),
        secondsSinceLastInteraction: TimeInterval,
        minimumIdleSeconds: TimeInterval,
        userInitiated: Bool,
        ignoreSystemPressure: Bool = false
    ) -> LocalInferenceResourceDecision {
        // macOS memory-pressure levels use 1 = normal, 2 = warning, 4 = critical.
        if !ignoreSystemPressure {
            guard snapshot.memoryPressureLevel < 2 else {
                return .init(canRun: false, reason: .memoryPressure)
            }
            guard snapshot.availableMemoryBytes >= minimumAvailableMemoryBytes else {
                return .init(canRun: false, reason: .availableMemory)
            }
            // `inactive` pages make macOS look deceptively available while it
            // is already compressing and swapping heavily. Loading even a 3B
            // model in that state causes the foreground to hitch, so these are
            // separate hard gates rather than diagnostics only.
            let maximumCompressedMemoryBytes = max(
                minimumMaximumCompressedMemoryBytes,
                snapshot.physicalMemoryBytes / 4
            )
            guard snapshot.compressedMemoryBytes <= maximumCompressedMemoryBytes else {
                return .init(canRun: false, reason: .memoryCompression)
            }
            let maximumSwapUsedBytes = max(
                minimumMaximumSwapUsedBytes,
                snapshot.physicalMemoryBytes / 4
            )
            guard snapshot.swapUsedBytes <= maximumSwapUsedBytes else {
                return .init(canRun: false, reason: .swapUsage)
            }
            // ProcessInfo thermal state: nominal 0, fair 1, serious 2, critical 3.
            guard snapshot.thermalState < 2 else {
                return .init(canRun: false, reason: .thermalState)
            }
            guard !snapshot.isLowPowerModeEnabled else {
                return .init(canRun: false, reason: .lowPowerMode)
            }

            let normalizedLoad = snapshot.oneMinuteLoadAverage
                / Double(max(snapshot.logicalProcessorCount, 1))
            let loadLimit = userInitiated ? 0.90 : 0.65
            guard snapshot.oneMinuteLoadAverage < 0 || normalizedLoad < loadLimit else {
                return .init(canRun: false, reason: .systemLoad)
            }
        }
        guard userInitiated || secondsSinceLastInteraction >= minimumIdleSeconds else {
            return .init(canRun: false, reason: .foregroundActivity)
        }
        return .init(canRun: true, reason: nil)
    }

    private static func currentMemoryPressureLevel() -> Int32 {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(
            "kern.memorystatus_vm_pressure_level",
            &level,
            &size,
            nil,
            0
        ) == 0 else {
            return 1
        }
        return level
    }

    private static func currentMemoryUsage() -> (available: UInt64, compressed: UInt64) {
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        var statistics = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (UInt64.max, 0) }
        let availablePages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.speculative_count)
            + UInt64(statistics.purgeable_count)
        var pageSize: UInt64 = 16_384
        var pageSizeLength = MemoryLayout<UInt64>.size
        _ = sysctlbyname("hw.pagesize", &pageSize, &pageSizeLength, nil, 0)
        return (
            available: availablePages * pageSize,
            compressed: UInt64(statistics.compressor_page_count) * pageSize
        )
    }

    private static func currentSwapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return 0
        }
        return usage.xsu_used
    }

    private static func currentOneMinuteLoadAverage() -> Double {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) > 0 else { return -1 }
        return averages[0]
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
        public var route: ModelInferenceRoute
        public var requiresAPIKey: Bool
        public var supportsImageInput: Bool
        public var enforcesResourcePolicy: Bool

        public init(
            baseURL: URL,
            model: String,
            providerName: String,
            route: ModelInferenceRoute = .cloud,
            requiresAPIKey: Bool = true,
            supportsImageInput: Bool = false,
            enforcesResourcePolicy: Bool = true
        ) {
            self.baseURL = baseURL
            self.model = model
            self.providerName = providerName
            self.route = route
            self.requiresAPIKey = requiresAPIKey
            self.supportsImageInput = supportsImageInput
            self.enforcesResourcePolicy = enforcesResourcePolicy
        }

        public static let defaultCloud = Configuration(
            baseURL: URL(string: "http://algoagent.zhuaninc.com/algo")!,
            model: "glm-5.2",
            providerName: "OpenAI-compatible",
            route: .cloud,
            requiresAPIKey: true
        )

        public static let defaultLocal = Configuration(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "llama3.2:3b",
            providerName: "ollama",
            route: .local,
            requiresAPIKey: false,
            supportsImageInput: false
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
        guard configuration.route != .cloud || request.allowsCloudProcessing else {
            throw ModelInferenceError.cloudProcessingDisabled
        }
        guard !configuration.requiresAPIKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelInferenceError.missingCredential
        }
        guard request.context?.isSensitive != true else {
            throw ModelInferenceError.sensitiveContextBlocked
        }
        if configuration.route == .local, configuration.enforcesResourcePolicy {
            let decision = LocalInferenceResourcePolicy.evaluate(
                secondsSinceLastInteraction: .greatestFiniteMagnitude,
                minimumIdleSeconds: 0,
                userInitiated: true,
                // Call sites own the foreground/system-pressure decision. The
                // client repeats only the global thermal/memory policy when no
                // call-site override exists, avoiding a race between a passed
                // preflight and the request itself.
                ignoreSystemPressure: false
            )
            guard decision.canRun else {
                throw ModelInferenceError.localResourcesConstrained(
                    reason: decision.reason?.rawValue ?? "unknown"
                )
            }
        }

        let sentFields = Self.sentContextFields(for: request.context)
        var urlRequest = URLRequest(url: configuration.chatCompletionsEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.route == .local ? 60 : 45
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": Self.userMessageContent(for: request, configuration: configuration)]
            ],
            "stream": false,
            "temperature": 0.2,
            "max_tokens": Self.maxOutputTokens(for: request.purpose)
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

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
            route: configuration.route,
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

    private static func userMessageContent(
        for request: ModelInferenceRequest,
        configuration: Configuration
    ) -> Any {
        let text = cloudInput(for: request)
        guard configuration.route == .local,
              configuration.supportsImageInput,
              let path = request.context?.screenshotResourcePath,
              let image = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !image.isEmpty else {
            return text
        }
        // The screenshot path itself never leaves the process. For a local
        // vision model, attach only the authorized PNG/JPEG bytes to Ollama's
        // OpenAI-compatible endpoint so OCR and visual layout can be checked
        // against the same key-moment evidence stored in the diary.
        return [
            ["type": "text", "text": text],
            [
                "type": "image_url",
                "image_url": ["url": "data:\(imageMIMEType(for: path));base64,\(image.base64EncodedString())"]
            ]
        ]
    }

    private static func maxOutputTokens(for purpose: String) -> Int {
        switch purpose {
        case "context_enrichment": 640
        case "daily_context_digest": 1_000
        case "local_model_connection_test": 32
        default: 512
        }
    }

    private static func imageMIMEType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        default: "image/png"
        }
    }
}

public actor ModelInferenceRouter {
    private let cloudClient: any AgentModelClient
    private let localClient: any AgentModelClient

    public init(
        cloudClient: any AgentModelClient = OpenAICompatibleModelClient(),
        localClient: any AgentModelClient = OpenAICompatibleModelClient(configuration: .defaultLocal)
    ) {
        self.cloudClient = cloudClient
        self.localClient = localClient
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
            return try await localClient.infer(request, apiKey: "")
        case .automatic:
            do {
                return try await localClient.infer(request, apiKey: "")
            } catch {
                guard request.allowsCloudProcessing,
                      !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ModelInferenceError.localModelUnavailable
                }
                return try await cloudClient.infer(request, apiKey: apiKey)
            }
        }
    }
}
