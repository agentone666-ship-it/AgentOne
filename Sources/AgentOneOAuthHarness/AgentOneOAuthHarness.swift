import Foundation
import AgentOneModelAuth

private enum HarnessFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw HarnessFailure.failed("Mock handler missing")
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@main
@MainActor
private struct AgentOneOAuthHarness {
    private static var checks: [(String, String)] = []

    static func main() async {
        do {
            try officialConfigurationAndStableIdentity()
            try await deviceAuthorizationContract()
            try await automaticBrowserLoginAndPolling()
            try await refreshTokenRotation()
            try await providerErrorRedaction()
            print("AgentOne Kimi OAuth validation passed (\(checks.count) checks)\n")
            for (index, check) in checks.enumerated() {
                print("\(index + 1). ✓ \(check.0)\n   \(check.1)")
            }
        } catch {
            fputs("AgentOne Kimi OAuth validation failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func officialConfigurationAndStableIdentity() throws {
        let config = KimiOAuthConfiguration.kimiCode
        try expect(
            config.clientID == "17e5f671-d194-4dfb-9706-5516cb48c098",
            "Kimi Code public client ID mismatch"
        )
        try expect(
            config.deviceAuthorizationURL.absoluteString == "https://auth.kimi.com/api/oauth/device_authorization",
            "Device authorization endpoint mismatch"
        )
        try expect(
            config.tokenURL.absoluteString == "https://auth.kimi.com/api/oauth/token",
            "Token endpoint mismatch"
        )

        let suite = "AgentOneOAuthHarness-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite), "Could not create isolated defaults")
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = KimiDeviceHeaders.agentOne(defaults: defaults, version: "0.1.0")
        let second = KimiDeviceHeaders.agentOne(defaults: defaults, version: "0.1.0")
        try expect(first.deviceID == second.deviceID, "Kimi device ID must be stable")
        try expect(first.platform == "kimi_code_cli", "Kimi platform identity mismatch")
        try expect(first.httpHeaders.count == 6, "Kimi device headers are incomplete")
        checks.append((
            "Official device-code configuration",
            "The official Kimi OAuth host/client ID and a stable six-header device identity are preserved."
        ))
    }

    private static func deviceAuthorizationContract() async throws {
        let (client, host) = mockClient()
        var captured: URLRequest?
        MockURLProtocol.handler = { request in
            captured = request
            return (
                response(url: request.url!, status: 200),
                json([
                    "user_code": "ABCD-EFGH",
                    "device_code": "device-code-canary",
                    "verification_uri": "https://auth.kimi.com/activate",
                    "verification_uri_complete": "https://auth.kimi.com/activate?user_code=ABCD-EFGH",
                    "expires_in": 900,
                    "interval": 5,
                ])
            )
        }
        defer { MockURLProtocol.handler = nil }

        let authorization = try await client.requestDeviceAuthorization()
        let request = try require(captured, "Device request was not captured")
        let form = formValues(request)
        try expect(request.url == host.appending(path: "api/oauth/device_authorization"), "Wrong device endpoint")
        try expect(request.httpMethod == "POST", "Device authorization must use POST")
        try expect(form["client_id"] == "test-client", "Device authorization omitted client_id")
        try expect(request.value(forHTTPHeaderField: "X-Msh-Device-Id") == "device-id-test", "Device ID header missing")
        try expect(request.value(forHTTPHeaderField: "X-Msh-Platform") == "kimi_code_cli", "Platform header missing")
        try expect(authorization.userCode == "ABCD-EFGH", "User code mismatch")
        try expect(authorization.deviceCode == "device-code-canary", "Device code mismatch")
        checks.append((
            "Device authorization HTTP contract",
            "Form encoding, official endpoint, browser URL, polling metadata, and X-Msh device headers crossed URLSession."
        ))
    }

    private static func automaticBrowserLoginAndPolling() async throws {
        let (client, _) = mockClient()
        var openedURL: URL?
        var tokenPolls = 0
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/device_authorization") == true {
                return (
                    response(url: request.url!, status: 200),
                    json([
                        "user_code": "AUTO-CODE",
                        "device_code": "auto-device-code",
                        "verification_uri_complete": "https://auth.kimi.com/activate?user_code=AUTO-CODE",
                        "expires_in": 30,
                        "interval": 1,
                    ])
                )
            }
            tokenPolls += 1
            let form = formValues(request)
            guard form["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code" else {
                throw HarnessFailure.failed("Auto-login used the wrong token grant")
            }
            if tokenPolls == 1 {
                return (
                    response(url: request.url!, status: 400),
                    json(["error": "authorization_pending"])
                )
            }
            return (
                response(url: request.url!, status: 200),
                tokenJSON(
                    access: "kimi-auto-access-canary",
                    refresh: "kimi-auto-refresh-canary"
                )
            )
        }
        defer { MockURLProtocol.handler = nil }

        let credential = try await client.connect(timeout: 10) { url in
            openedURL = url
            return true
        }
        try expect(openedURL?.absoluteString.contains("AUTO-CODE") == true, "Browser did not receive complete verification URL")
        try expect(tokenPolls == 2, "Auto-login did not poll pending state through success")
        try expect(credential.accessToken == "kimi-auto-access-canary", "Auto-login access token mismatch")
        checks.append((
            "Automatic browser login",
            "The complete Kimi activation URL opened once and the RFC 8628 pending state was polled through success."
        ))
    }

    private static func refreshTokenRotation() async throws {
        let (client, _) = mockClient()
        var capturedForm: [String: String] = [:]
        MockURLProtocol.handler = { request in
            capturedForm = formValues(request)
            return (
                response(url: request.url!, status: 200),
                tokenJSON(
                    access: "kimi-refreshed-access-canary",
                    refresh: "kimi-rotated-refresh-canary"
                )
            )
        }
        defer { MockURLProtocol.handler = nil }

        let original = KimiOAuthCredential(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: .distantPast,
            expiresIn: 3600
        )
        let refreshed = try await client.refresh(original)
        try expect(capturedForm["grant_type"] == "refresh_token", "Refresh grant missing")
        try expect(capturedForm["refresh_token"] == "old-refresh", "Refresh token missing")
        try expect(refreshed.accessToken == "kimi-refreshed-access-canary", "Refreshed access token mismatch")
        try expect(refreshed.refreshToken == "kimi-rotated-refresh-canary", "Rotated refresh token was not retained")
        checks.append((
            "Refresh-token rotation",
            "The official refresh grant produced and retained both rotated Kimi tokens."
        ))
    }

    private static func providerErrorRedaction() async throws {
        let (client, _) = mockClient()
        let canary = "provider-secret-body-must-never-escape"
        MockURLProtocol.handler = { request in
            (
                response(url: request.url!, status: 401),
                Data("{\"error\":\"\(canary)\"}".utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        do {
            _ = try await client.requestDeviceAuthorization()
            throw HarnessFailure.failed("Provider error was accepted")
        } catch {
            try expect(!error.localizedDescription.contains(canary), "OAuth error leaked provider response body")
        }
        checks.append((
            "OAuth error redaction",
            "A credential-shaped provider body became a status-only local error."
        ))
    }

    private static func mockClient() -> (KimiOAuthClient, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let host = URL(string: "https://mock.agentone.invalid")!
        let headers = KimiDeviceHeaders(
            platform: "kimi_code_cli",
            version: "0.1.0",
            deviceName: "AgentOne-Test",
            deviceModel: "macOS arm64",
            osVersion: "15.0",
            deviceID: "device-id-test"
        )
        return (
            KimiOAuthClient(
                configuration: KimiOAuthConfiguration(clientID: "test-client", oauthHost: host),
                deviceHeaders: headers,
                session: session
            ),
            host
        )
    }

    nonisolated private static func formValues(_ request: URLRequest) -> [String: String] {
        let data = request.httpBody ?? request.httpBodyStream.flatMap(readAll)
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var components = URLComponents()
        components.percentEncodedQuery = body
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    nonisolated private static func readAll(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    nonisolated private static func response(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    nonisolated private static func tokenJSON(access: String, refresh: String) -> Data {
        json([
            "access_token": access,
            "refresh_token": refresh,
            "expires_in": 3600,
            "scope": "openid",
            "token_type": "Bearer",
        ])
    }

    nonisolated private static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw HarnessFailure.failed(message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw HarnessFailure.failed(message) }
        return value
    }
}
