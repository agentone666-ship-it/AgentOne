import Foundation

public enum PiProtocolV1 {
    public static let version = 1
}

public enum PiRequestType: String, Codable, Sendable {
    case health
    case wake
    case chat
    case shutdown
}

public enum PiResponseType: String, Codable, Sendable {
    case ready
    case event
    case result
    case error
}

/// Pi can only receive capabilities represented by this closed set. Adding a
/// new tool is therefore an explicit native-app release decision, not a value
/// a model or remote payload can smuggle into a request.
public enum PiAllowedTool: String, Codable, CaseIterable, Sendable {
    case getCurrentContext = "get_current_context"
    case searchMemory = "search_memory"
    case readRecentDiary = "read_recent_diary"
    case appendInnerJournal = "append_inner_journal"
    case updateWorkingIntention = "update_working_intention"
    case markContextRelated = "mark_context_related"
    case markContextDistracting = "mark_context_distracting"
    case showCuriosityPrompt = "show_curiosity_prompt"
    case showReturnCard = "show_return_card"
    case saveDetourForLater = "save_detour_for_later"
    case proposeSurprise = "propose_surprise"
    case consumeEnergyBudget = "consume_energy_budget"
}

public enum PiSurpriseRisk: String, Codable, Sendable {
    case none
    case low
    case medium
}

public struct PiActiveIntent: Codable, Equatable, Sendable {
    public var id: String?
    public var title: String
    public var summary: String?

    public init(id: String? = nil, title: String, summary: String? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
    }
}

public struct PiSanitizedContext: Codable, Equatable, Sendable {
    public var capturedAt: String
    public var applicationName: String?
    public var bundleIdentifier: String?
    public var windowTitle: String?
    public var url: String?
    public var documentPath: String?
    public var contentSummary: String?
    public var selectedText: String?
    public var submittedText: String?
    public var screenText: String?
    public var interactionTarget: String?
    public var contextTransition: String?
    public var semanticTags: [String]
    public var isSensitive: Bool
    public var activeIntent: PiActiveIntent?
    public var driftDurationSeconds: Double?

    public init(
        capturedAt: String,
        applicationName: String? = nil,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        documentPath: String? = nil,
        contentSummary: String? = nil,
        selectedText: String? = nil,
        submittedText: String? = nil,
        screenText: String? = nil,
        interactionTarget: String? = nil,
        contextTransition: String? = nil,
        semanticTags: [String] = [],
        isSensitive: Bool = false,
        activeIntent: PiActiveIntent? = nil,
        driftDurationSeconds: Double? = nil
    ) {
        self.capturedAt = capturedAt
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.url = url
        self.documentPath = documentPath
        self.contentSummary = contentSummary
        self.selectedText = selectedText
        self.submittedText = submittedText
        self.screenText = screenText
        self.interactionTarget = interactionTarget
        self.contextTransition = contextTransition
        self.semanticTags = semanticTags
        self.isSensitive = isSensitive
        self.activeIntent = activeIntent
        self.driftDurationSeconds = driftDurationSeconds
    }

    public var isSafeForPi: Bool {
        !isSensitive && !Self.containsProtectedMaterial(in: searchableText)
    }

    private var searchableText: String {
        [
            applicationName,
            bundleIdentifier,
            windowTitle,
            url,
            documentPath,
            contentSummary,
            selectedText,
            submittedText,
            screenText,
            interactionTarget,
            contextTransition,
            activeIntent?.title,
            activeIntent?.summary,
            semanticTags.joined(separator: " ")
        ]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private static func containsProtectedMaterial(in text: String) -> Bool {
        let patterns = [
            #"(?i)\b(?:sk|pk|rk|ak)[-_][A-Za-z0-9_-]{16,}\b"#,
            #"(?i)\bAIza[0-9A-Za-z_-]{20,}\b"#,
            #"(?i)\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}\b"#,
            #"(?i)(?:api[_ -]?key|access[_ -]?token|secret|密钥)\s*[:=：]\s*[^\s]{8,}"#,
            #"(?i)(?:password|密码)\s*[:=：]\s*[^\s]{4,}"#,
            #"(?i)(?:银行卡号|card number)\D{0,8}\d{6,19}"#,
            #"(?i)(?:验证码|one[ -]?time code|\botp\b)\D{0,12}\d{4,8}\b"#,
            #"\b[0-9a-fA-F]{32,}\b"#
        ]
        return patterns.contains {
            text.range(of: $0, options: .regularExpression) != nil
        }
    }
}

public struct PiRecentMemory: Codable, Equatable, Sendable {
    public var id: String
    public var timestamp: String
    public var kind: String
    public var summary: String
    public var tags: [String]

    public init(
        id: String,
        timestamp: String,
        kind: String,
        summary: String,
        tags: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
        self.tags = tags
    }
}

public struct PiWakeBudget: Codable, Equatable, Sendable {
    public var maxTokens: Int
    public var maxTurns: Int
    public var maxDurationMs: Int
    public var allowedTools: [PiAllowedTool]
    public var surpriseRisk: PiSurpriseRisk

    public init(
        maxTokens: Int,
        maxTurns: Int,
        maxDurationMs: Int,
        allowedTools: [PiAllowedTool],
        surpriseRisk: PiSurpriseRisk
    ) {
        self.maxTokens = maxTokens
        self.maxTurns = maxTurns
        self.maxDurationMs = maxDurationMs
        self.allowedTools = Array(Set(allowedTools)).sorted { $0.rawValue < $1.rawValue }
        self.surpriseRisk = surpriseRisk
    }
}

public struct PiWakePayload: Codable, Equatable, Sendable {
    public var reason: String
    public var sanitizedContext: PiSanitizedContext
    public var recentMemory: [PiRecentMemory]
    public var budget: PiWakeBudget

    public init(reason: String, sanitizedContext: PiSanitizedContext, recentMemory: [PiRecentMemory], budget: PiWakeBudget) {
        self.reason = reason
        self.sanitizedContext = sanitizedContext
        self.recentMemory = recentMemory
        self.budget = budget
    }
}

public enum PiChatRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct PiChatMessage: Codable, Equatable, Sendable {
    public var role: PiChatRole
    public var content: String

    public init(role: PiChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

public enum PiChatPurpose: String, Codable, Equatable, Sendable {
    case conversation
    case contextEnrichment = "context_enrichment"
    case dailyDigest = "daily_digest"
}

public struct PiChatPayload: Codable, Equatable, Sendable {
    public var purpose: PiChatPurpose
    public var messages: [PiChatMessage]
    public var sanitizedContext: PiSanitizedContext?
    public var recentMemory: [PiRecentMemory]
    public var maxTokens: Int
    public var maxDurationMs: Int

    public init(
        purpose: PiChatPurpose = .conversation,
        messages: [PiChatMessage],
        sanitizedContext: PiSanitizedContext? = nil,
        recentMemory: [PiRecentMemory] = [],
        maxTokens: Int = 2_400,
        maxDurationMs: Int = 30_000
    ) {
        self.purpose = purpose
        self.messages = messages
        self.sanitizedContext = sanitizedContext
        self.recentMemory = recentMemory
        self.maxTokens = maxTokens
        self.maxDurationMs = maxDurationMs
    }
}

public enum PiRequestPayload: Encodable, Sendable {
    case wake(PiWakePayload)
    case chat(PiChatPayload)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .wake(let payload): try payload.encode(to: encoder)
        case .chat(let payload): try payload.encode(to: encoder)
        }
    }
}

public struct PiRequestEnvelope: Encodable, Sendable {
    public let version: Int
    public let id: UUID
    public let type: PiRequestType
    public let payload: PiRequestPayload?

    private init(id: UUID, type: PiRequestType, payload: PiRequestPayload?) {
        version = PiProtocolV1.version
        self.id = id
        self.type = type
        self.payload = payload
    }

    public static func health(id: UUID = UUID()) -> PiRequestEnvelope {
        PiRequestEnvelope(id: id, type: .health, payload: nil)
    }

    public static func wake(id: UUID = UUID(), payload: PiWakePayload) -> PiRequestEnvelope {
        PiRequestEnvelope(id: id, type: .wake, payload: .wake(payload))
    }

    public static func chat(id: UUID = UUID(), payload: PiChatPayload) -> PiRequestEnvelope {
        PiRequestEnvelope(id: id, type: .chat, payload: .chat(payload))
    }

    public static func shutdown(id: UUID = UUID()) -> PiRequestEnvelope {
        PiRequestEnvelope(id: id, type: .shutdown, payload: nil)
    }
}

public enum PiJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PiJSONValue])
    case array([PiJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PiJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PiJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct PiResultPayload: Codable, Equatable, Sendable {
    public var outcome: String
    public var spokenText: String?
    public var actions: [PiRuntimeAction]
    public var usage: PiUsage
    public var model: PiRuntimeModelExecution?
}

public struct PiRuntimeModelExecution: Codable, Equatable, Sendable {
    public var route: String
    public var provider: String
    public var model: String
}

public struct PiUsage: Codable, Equatable, Sendable {
    public var turns: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var toolCalls: Int
    public var durationMs: Int
    public var stoppedByBudget: Bool
}

public enum PiRuntimeActionType: String, Codable, Sendable {
    case innerJournal = "inner_journal"
    case workingIntention = "working_intention"
    case contextClassification = "context_classification"
    case curiosityPrompt = "curiosity_prompt"
    case returnCard = "return_card"
    case savedDetour = "saved_detour"
    case surpriseProposal = "surprise_proposal"
    case energyConsumed = "energy_consumed"
}

public struct PiRuntimeAction: Codable, Equatable, Sendable {
    public var type: PiRuntimeActionType
    public var payload: [String: PiJSONValue]
}

public struct PiReadyPayload: Codable, Equatable, Sendable {
    public var runtime: String
    public var provider: String?
    public var model: String?
    public var runtimeMode: String?
    public var piVersion: String
    public var protocolVersion: Int
    public var safeTools: [PiAllowedTool]
}

public struct PiErrorPayload: Codable, Equatable, Sendable {
    public var code: String?
    public var message: String
    public var retryable: Bool?
}

public enum PiResponse: Decodable, Equatable, Sendable {
    case ready(id: UUID?, payload: PiReadyPayload)
    case event(id: UUID?, payload: PiJSONValue?)
    case result(id: UUID?, payload: PiResultPayload)
    case error(id: UUID?, payload: PiErrorPayload)

    public var id: UUID? {
        switch self {
        case .ready(let id, _), .event(let id, _), .result(let id, _), .error(let id, _):
            return id
        }
    }

    public var type: PiResponseType {
        switch self {
        case .ready: .ready
        case .event: .event
        case .result: .result
        case .error: .error
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case type
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == PiProtocolV1.version else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported Pi protocol version \(version)"
            )
        }

        // Error responses may intentionally use a non-UUID sentinel such as
        // "unknown" when the request could not be parsed. Treat that as an
        // uncorrelated event instead of tearing down an otherwise healthy
        // sidecar for malformed output.
        let rawID = try container.decodeIfPresent(String.self, forKey: .id)
        let id = rawID.flatMap(UUID.init(uuidString:))
        switch try container.decode(PiResponseType.self, forKey: .type) {
        case .ready:
            self = .ready(id: id, payload: try container.decode(PiReadyPayload.self, forKey: .payload))
        case .event:
            self = .event(id: id, payload: try container.decodeIfPresent(PiJSONValue.self, forKey: .payload))
        case .result:
            self = .result(id: id, payload: try container.decode(PiResultPayload.self, forKey: .payload))
        case .error:
            self = .error(id: id, payload: try container.decode(PiErrorPayload.self, forKey: .payload))
        }
    }
}
