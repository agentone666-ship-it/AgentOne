import Foundation

public struct KimiOAuthCredential: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String
    public var tokenType: String
    public var expiresIn: TimeInterval

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scope: String = "",
        tokenType: String = "Bearer",
        expiresIn: TimeInterval
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
        self.expiresIn = expiresIn
    }

    public func needsRefresh(at date: Date = Date(), leeway: TimeInterval? = nil) -> Bool {
        let threshold = leeway ?? max(300, expiresIn * 0.5)
        return expiresAt.timeIntervalSince(date) <= threshold
    }
}

public struct KimiOAuthConfiguration: Equatable, Sendable {
    public var clientID: String
    public var oauthHost: URL

    /// Public device-code client used by the official Kimi Code implementation.
    public static let kimiCode = KimiOAuthConfiguration(
        clientID: "17e5f671-d194-4dfb-9706-5516cb48c098",
        oauthHost: URL(string: "https://auth.kimi.com")!
    )

    public init(clientID: String, oauthHost: URL) {
        self.clientID = clientID
        self.oauthHost = oauthHost
    }

    public var deviceAuthorizationURL: URL {
        oauthHost.appending(path: "api/oauth/device_authorization")
    }

    public var tokenURL: URL {
        oauthHost.appending(path: "api/oauth/token")
    }
}

public struct KimiDeviceHeaders: Codable, Equatable, Sendable {
    public var platform: String
    public var version: String
    public var deviceName: String
    public var deviceModel: String
    public var osVersion: String
    public var deviceID: String

    public init(
        platform: String,
        version: String,
        deviceName: String,
        deviceModel: String,
        osVersion: String,
        deviceID: String
    ) {
        self.platform = platform
        self.version = version
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.deviceID = deviceID
    }

    public static func agentOne(
        defaults: UserDefaults = .standard,
        version: String = "0.1.0"
    ) -> KimiDeviceHeaders {
        let key = "agentOne.kimi.deviceID"
        let deviceID: String
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: key)
        }
        return KimiDeviceHeaders(
            platform: "kimi_code_cli",
            version: ascii(version),
            deviceName: ascii(ProcessInfo.processInfo.hostName),
            deviceModel: ascii("macOS \(architectureName)"),
            osVersion: ascii(ProcessInfo.processInfo.operatingSystemVersionString),
            deviceID: deviceID
        )
    }

    public var httpHeaders: [String: String] {
        [
            "X-Msh-Platform": platform,
            "X-Msh-Version": version,
            "X-Msh-Device-Name": deviceName,
            "X-Msh-Device-Model": deviceModel,
            "X-Msh-Os-Version": osVersion,
            "X-Msh-Device-Id": deviceID,
        ]
    }

    private static var architectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func ascii(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value <= 0x7E
        }
        let normalized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "unknown" : normalized
    }
}

public struct KimiDeviceAuthorization: Codable, Equatable, Sendable {
    public var userCode: String
    public var deviceCode: String
    public var verificationURI: URL?
    public var verificationURIComplete: URL
    public var expiresIn: TimeInterval?
    public var interval: TimeInterval

    public init(
        userCode: String,
        deviceCode: String,
        verificationURI: URL?,
        verificationURIComplete: URL,
        expiresIn: TimeInterval?,
        interval: TimeInterval
    ) {
        self.userCode = userCode
        self.deviceCode = deviceCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

public enum KimiDevicePollResult: Equatable, Sendable {
    case success(KimiOAuthCredential)
    case pending(slowDown: Bool)
    case expired
    case denied
}

public enum KimiOAuthError: LocalizedError, Equatable {
    case invalidAuthorizationResponse
    case browserCouldNotOpen
    case authorizationTimedOut
    case authorizationExpired
    case authorizationDenied
    case requestFailed(statusCode: Int)
    case refreshUnauthorized
    case invalidTokenResponse

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationResponse:
            "Kimi 登录服务返回了不完整的设备授权信息。"
        case .browserCouldNotOpen:
            "无法打开浏览器完成 Kimi 登录。"
        case .authorizationTimedOut:
            "Kimi 登录等待超时，请重新连接。"
        case .authorizationExpired:
            "Kimi 登录码已经过期，请重新连接。"
        case .authorizationDenied:
            "Kimi 登录没有获得授权。"
        case .requestFailed(let statusCode):
            "Kimi 登录服务请求失败（状态码 \(statusCode)）。"
        case .refreshUnauthorized:
            "Kimi 登录已经失效，请重新连接。"
        case .invalidTokenResponse:
            "Kimi 登录服务返回了不完整的凭据。"
        }
    }
}

public struct KimiOAuthClient: @unchecked Sendable {
    public typealias OpenURL = @MainActor @Sendable (URL) -> Bool

    private struct DeviceResponse: Decodable {
        var userCode: String
        var deviceCode: String
        var verificationURI: String?
        var verificationURIComplete: String
        var expiresIn: Double?
        var interval: Double?

        enum CodingKeys: String, CodingKey {
            case userCode = "user_code"
            case deviceCode = "device_code"
            case verificationURI = "verification_uri"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String
        var expiresIn: Double
        var scope: String?
        var tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case tokenType = "token_type"
        }
    }

    private struct ErrorResponse: Decodable {
        var error: String?
    }

    public let configuration: KimiOAuthConfiguration
    public let deviceHeaders: KimiDeviceHeaders
    private let session: URLSession

    public init(
        configuration: KimiOAuthConfiguration = .kimiCode,
        deviceHeaders: KimiDeviceHeaders = .agentOne(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.deviceHeaders = deviceHeaders
        self.session = session
    }

    public func connect(
        timeout: TimeInterval = 15 * 60,
        openURL: OpenURL
    ) async throws -> KimiOAuthCredential {
        let authorization = try await requestDeviceAuthorization()
        guard await openURL(authorization.verificationURIComplete) else {
            throw KimiOAuthError.browserCouldNotOpen
        }

        let deadline = Date().addingTimeInterval(
            min(timeout, authorization.expiresIn ?? timeout)
        )
        var interval = max(1, authorization.interval)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(interval))
            switch try await pollDeviceToken(deviceCode: authorization.deviceCode) {
            case .success(let credential):
                return credential
            case .pending(let slowDown):
                if slowDown { interval += 5 }
            case .expired:
                throw KimiOAuthError.authorizationExpired
            case .denied:
                throw KimiOAuthError.authorizationDenied
            }
        }
        throw KimiOAuthError.authorizationTimedOut
    }

    public func requestDeviceAuthorization() async throws -> KimiDeviceAuthorization {
        let (data, response) = try await postForm(
            url: configuration.deviceAuthorizationURL,
            values: ["client_id": configuration.clientID]
        )
        guard response.statusCode == 200 else {
            throw KimiOAuthError.requestFailed(statusCode: response.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(DeviceResponse.self, from: data),
              !payload.userCode.isEmpty,
              !payload.deviceCode.isEmpty,
              let completeURL = URL(string: payload.verificationURIComplete) else {
            throw KimiOAuthError.invalidAuthorizationResponse
        }
        return KimiDeviceAuthorization(
            userCode: payload.userCode,
            deviceCode: payload.deviceCode,
            verificationURI: payload.verificationURI.flatMap(URL.init(string:)),
            verificationURIComplete: completeURL,
            expiresIn: payload.expiresIn,
            interval: max(1, payload.interval ?? 5)
        )
    }

    public func pollDeviceToken(deviceCode: String) async throws -> KimiDevicePollResult {
        let (data, response) = try await postForm(
            url: configuration.tokenURL,
            values: [
                "client_id": configuration.clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
        )
        if response.statusCode == 200 {
            return .success(try decodeCredential(data))
        }
        if response.statusCode >= 500 {
            throw KimiOAuthError.requestFailed(statusCode: response.statusCode)
        }
        let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error) ?? ""
        switch code {
        case "authorization_pending":
            return .pending(slowDown: false)
        case "slow_down":
            return .pending(slowDown: true)
        case "expired_token":
            return .expired
        case "access_denied":
            return .denied
        default:
            throw KimiOAuthError.requestFailed(statusCode: response.statusCode)
        }
    }

    public func refresh(_ credential: KimiOAuthCredential) async throws -> KimiOAuthCredential {
        let (data, response) = try await postForm(
            url: configuration.tokenURL,
            values: [
                "client_id": configuration.clientID,
                "grant_type": "refresh_token",
                "refresh_token": credential.refreshToken,
            ]
        )
        if response.statusCode == 401 || response.statusCode == 403 {
            throw KimiOAuthError.refreshUnauthorized
        }
        guard response.statusCode == 200 else {
            throw KimiOAuthError.requestFailed(statusCode: response.statusCode)
        }
        return try decodeCredential(data)
    }

    private func decodeCredential(_ data: Data) throws -> KimiOAuthCredential {
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !token.accessToken.isEmpty,
              !token.refreshToken.isEmpty,
              token.expiresIn > 0 else {
            throw KimiOAuthError.invalidTokenResponse
        }
        return KimiOAuthCredential(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(token.expiresIn),
            scope: token.scope ?? "",
            tokenType: token.tokenType ?? "Bearer",
            expiresIn: token.expiresIn
        )
    }

    private func postForm(
        url: URL,
        values: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in deviceHeaders.httpHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = Self.formEncoded(values)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KimiOAuthError.invalidTokenResponse
        }
        return (data, http)
    }

    private static func formEncoded(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}
