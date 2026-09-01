import AppKit
import Foundation
import AgentOneCredentialStore
import AgentOneModelAuth
import AgentOneModelRuntime

enum CloudAuthenticationPreference: String, Codable, Sendable {
    case kimi
    case apiKey
}

enum ResolvedCloudCredential: Sendable {
    case kimi(accessToken: String, deviceHeaders: KimiDeviceHeaders)
    case apiKey(apiKey: String, baseURL: String, model: String)

    var provider: String {
        switch self {
        case .kimi: "kimi-coding"
        case .apiKey: "openai-compatible-completions"
        }
    }

    var model: String {
        switch self {
        case .kimi: "kimi-for-coding"
        case .apiKey(_, _, let model): model
        }
    }
}

@MainActor
final class AgentModelSettings: ObservableObject {
    static let shared = AgentModelSettings()

    @Published var route: ModelInferenceRoute {
        didSet { defaults.set(route.rawValue, forKey: Keys.route) }
    }
    @Published var auditsCloudInvocations: Bool {
        didSet { defaults.set(auditsCloudInvocations, forKey: Keys.auditCloudInvocations) }
    }
    @Published var preferredCloudAuthentication: CloudAuthenticationPreference {
        didSet { defaults.set(preferredCloudAuthentication.rawValue, forKey: Keys.preferredCloudAuthentication) }
    }
    @Published var apiKeyBaseURL: String {
        didSet { defaults.set(apiKeyBaseURL, forKey: Keys.apiKeyBaseURL) }
    }
    @Published var apiKeyModel: String {
        didSet { defaults.set(apiKeyModel, forKey: Keys.apiKeyModel) }
    }
    @Published private(set) var hasKimiConnection: Bool {
        didSet { defaults.set(hasKimiConnection, forKey: Keys.hasKimiConnection) }
    }
    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var isConnectingKimi = false
    @Published private(set) var credentialError: String?
    @Published private(set) var localModelStatus: LocalModelStatus = .checking
    @Published private(set) var isTestingLocalModel = false
    @Published private(set) var localModelTestMessage: String?

    /// Compatibility while older views migrate from API-Key-only wording.
    var hasCredential: Bool { hasAPIKey }

    private enum Keys {
        static let route = "agentOne.model.route"
        static let auditCloudInvocations = "agentOne.model.auditCloudInvocations"
        static let preferredCloudAuthentication = "agentOne.model.preferredCloudAuthentication"
        static let apiKeyBaseURL = "agentOne.model.apiKeyBaseURL"
        static let apiKeyModel = "agentOne.model.apiKeyModel"
        static let hasKimiConnection = "agentOne.model.hasKimiConnection"
    }

    nonisolated static let defaultAPIKeyBaseURL = "http://algoagent.zhuaninc.com/algo"
    nonisolated static let defaultAPIKeyModel = "glm-5.2"
    nonisolated static let localBaseURL = "http://127.0.0.1:11434/v1"
    nonisolated static let localModel = "llama3.2:3b"

    private let defaults: UserDefaults
    private let credentialStore: ModelCredentialStore
    private let oauthClient: KimiOAuthClient

    init(
        defaults: UserDefaults = .standard,
        credentialStore: ModelCredentialStore = ModelCredentialStore(),
        oauthClient: KimiOAuthClient? = nil
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.oauthClient = oauthClient ?? KimiOAuthClient(
            deviceHeaders: .agentOne(defaults: defaults)
        )
        self.route = defaults.string(forKey: Keys.route)
            .flatMap(ModelInferenceRoute.init(rawValue:)) ?? .local
        self.auditsCloudInvocations = defaults.object(forKey: Keys.auditCloudInvocations) as? Bool ?? true
        let savedAuthentication = defaults.string(forKey: Keys.preferredCloudAuthentication)
        self.preferredCloudAuthentication = savedAuthentication == CloudAuthenticationPreference.apiKey.rawValue
            ? .apiKey
            : .kimi
        self.apiKeyBaseURL = defaults.string(forKey: Keys.apiKeyBaseURL) ?? Self.defaultAPIKeyBaseURL
        self.apiKeyModel = defaults.string(forKey: Keys.apiKeyModel) ?? Self.defaultAPIKeyModel
        self.hasKimiConnection = credentialStore.containsKimiCredential()
        self.hasAPIKey = credentialStore.containsAPIKey()
        Task { await refreshLocalModelStatus() }
    }

    enum LocalModelStatus: Equatable {
        case checking
        case serviceUnavailable
        case modelMissing
        case ready(sizeBytes: Int64?)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    func refreshLocalModelStatus() async {
        localModelStatus = .checking
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else {
            localModelStatus = .serviceUnavailable
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = root["models"] as? [[String: Any]] else {
                localModelStatus = .serviceUnavailable
                return
            }
            if let model = models.first(where: {
                (($0["name"] as? String) ?? ($0["model"] as? String)) == Self.localModel
            }) {
                let number = model["size"] as? NSNumber
                localModelStatus = .ready(sizeBytes: number?.int64Value)
            } else {
                localModelStatus = .modelMissing
            }
        } catch {
            localModelStatus = .serviceUnavailable
        }
    }

    @discardableResult
    func testLocalModel() async -> Bool {
        guard !isTestingLocalModel else { return false }
        isTestingLocalModel = true
        localModelTestMessage = "正在让本地模型说一句话…"
        defer { isTestingLocalModel = false }
        let decision = LocalInferenceResourcePolicy.evaluate(
            secondsSinceLastInteraction: .greatestFiniteMagnitude,
            minimumIdleSeconds: 0,
            userInitiated: true
        )
        guard decision.canRun else {
            localModelTestMessage = "电脑现在比较忙（\(decision.reason?.userMessage ?? "资源不足")），先不启动本地模型。"
            return false
        }
        do {
            let result = try await OpenAICompatibleModelClient(configuration: .defaultLocal).infer(
                ModelInferenceRequest(
                    purpose: "local_model_connection_test",
                    systemPrompt: "你是 AgentOne 的本地模型。",
                    userPrompt: "只回复：本地模型已醒来",
                    context: nil,
                    allowsCloudProcessing: false
                ),
                apiKey: ""
            )
            localModelStatus = .ready(sizeBytes: {
                if case .ready(let size) = localModelStatus { return size }
                return nil
            }())
            localModelTestMessage = "已真实调用 \(result.provider) / \(result.model)：\(String(result.text.prefix(80)))"
            return true
        } catch {
            localModelTestMessage = error.localizedDescription
            await refreshLocalModelStatus()
            return false
        }
    }

    @discardableResult
    func connectKimi() async -> Bool {
        guard !isConnectingKimi else { return false }
        isConnectingKimi = true
        credentialError = nil
        defer { isConnectingKimi = false }
        do {
            let credential = try await oauthClient.connect { url in
                NSWorkspace.shared.open(url)
            }
            try credentialStore.saveKimiCredential(credential)
            hasKimiConnection = true
            preferredCloudAuthentication = .kimi
            return true
        } catch is CancellationError {
            credentialError = "Kimi 登录已取消。"
            return false
        } catch {
            credentialError = error.localizedDescription
            return false
        }
    }

    func disconnectKimi() {
        do {
            try credentialStore.removeKimiCredential()
            credentialError = nil
            hasKimiConnection = false
        } catch {
            credentialError = error.localizedDescription
        }
    }

    func resolveCloudCredential() async -> ResolvedCloudCredential? {
        credentialError = nil

        if preferredCloudAuthentication == .kimi,
           let kimi = await usableKimiCredential() {
            return .kimi(
                accessToken: kimi.accessToken,
                deviceHeaders: oauthClient.deviceHeaders
            )
        }
        let apiKey = loadAPIKey()
        if !apiKey.isEmpty {
            return resolvedAPIKeyCredential(apiKey)
        }
        if preferredCloudAuthentication == .apiKey,
           let kimi = await usableKimiCredential() {
            return .kimi(
                accessToken: kimi.accessToken,
                deviceHeaders: oauthClient.deviceHeaders
            )
        }
        return nil
    }

    /// Request-time fallback used when Kimi rejects or cannot complete a wake.
    /// It does not change the user's preferred authentication setting.
    func resolveAPIKeyFallback() -> ResolvedCloudCredential? {
        let apiKey = loadAPIKey()
        return apiKey.isEmpty ? nil : resolvedAPIKeyCredential(apiKey)
    }

    private func resolvedAPIKeyCredential(_ apiKey: String) -> ResolvedCloudCredential {
        let baseURL = apiKeyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = apiKeyModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return .apiKey(
            apiKey: apiKey,
            baseURL: baseURL.isEmpty ? Self.defaultAPIKeyBaseURL : baseURL,
            model: model.isEmpty ? Self.defaultAPIKeyModel : model
        )
    }

    private func usableKimiCredential() async -> KimiOAuthCredential? {
        let stored: KimiOAuthCredential
        do {
            guard let credential = try credentialStore.loadKimiCredential() else {
                hasKimiConnection = false
                return nil
            }
            stored = credential
            hasKimiConnection = true
        } catch {
            credentialError = error.localizedDescription
            hasKimiConnection = false
            return nil
        }

        guard stored.needsRefresh() else { return stored }
        do {
            let refreshed = try await oauthClient.refresh(stored)
            try credentialStore.saveKimiCredential(refreshed)
            hasKimiConnection = true
            return refreshed
        } catch KimiOAuthError.refreshUnauthorized {
            credentialError = KimiOAuthError.refreshUnauthorized.localizedDescription
            hasKimiConnection = false
            return nil
        } catch {
            // Keep the rotating refresh token so a transient outage does not
            // silently disconnect the user. A later wake will retry.
            credentialError = error.localizedDescription
            return nil
        }
    }

    func loadAPIKey() -> String {
        do {
            credentialError = nil
            return (try credentialStore.loadAPIKey() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            credentialError = error.localizedDescription
            return ""
        }
    }

    @discardableResult
    func saveAPIKey(_ apiKey: String) -> Bool {
        do {
            try credentialStore.saveAPIKey(apiKey)
            credentialError = nil
            hasAPIKey = credentialStore.containsAPIKey()
            return true
        } catch {
            credentialError = error.localizedDescription
            return false
        }
    }

    func removeAPIKey() {
        do {
            try credentialStore.removeAPIKey()
            credentialError = nil
            hasAPIKey = false
        } catch {
            credentialError = error.localizedDescription
        }
    }

    // Compatibility aliases used by the API Key editor.
    func loadCredential() -> String { loadAPIKey() }
    @discardableResult func saveCredential(_ apiKey: String) -> Bool { saveAPIKey(apiKey) }
    func removeCredential() { removeAPIKey() }
}
