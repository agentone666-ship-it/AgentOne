import Darwin
import Foundation
import AgentOneModelAuth

public enum ModelCredentialError: LocalizedError, Equatable {
    case unsafeAPIKeyFile
    case invalidKimiCredential

    public var errorDescription: String? {
        switch self {
        case .unsafeAPIKeyFile:
            "模型凭证文件不能是符号链接。请移除该链接后重试。"
        case .invalidKimiCredential:
            "Kimi 登录凭据已损坏，请断开后重新连接。"
        }
    }
}

/// Stores both user-supplied API keys and Kimi OAuth credentials in private
/// local files. Neither path uses Keychain, so background model wakes never
/// trigger an unrelated macOS authorization dialog.
public struct ModelCredentialStore {
    private let apiKeyFileURLProvider: @Sendable () -> URL
    private let kimiOAuthFileURLProvider: @Sendable () -> URL

    public static var defaultSecretsDirectoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("AgentOne", isDirectory: true)
            .appendingPathComponent("Secrets", isDirectory: true)
    }

    public static var defaultAPIKeyFileURL: URL {
        defaultSecretsDirectoryURL.appendingPathComponent("model-api-key", isDirectory: false)
    }

    public static var defaultKimiOAuthFileURL: URL {
        defaultSecretsDirectoryURL.appendingPathComponent("kimi-oauth.json", isDirectory: false)
    }

    public init(
        apiKeyFileURLProvider: @escaping @Sendable () -> URL = {
            ModelCredentialStore.defaultAPIKeyFileURL
        },
        kimiOAuthFileURLProvider: @escaping @Sendable () -> URL = {
            ModelCredentialStore.defaultKimiOAuthFileURL
        }
    ) {
        self.apiKeyFileURLProvider = apiKeyFileURLProvider
        self.kimiOAuthFileURLProvider = kimiOAuthFileURLProvider
    }

    public func saveAPIKey(_ apiKey: String) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            try removeAPIKey()
            return
        }
        try savePrivateData(Data(normalized.utf8), at: apiKeyFileURLProvider())
    }

    public func loadAPIKey() throws -> String? {
        guard let data = try loadPrivateData(at: apiKeyFileURLProvider()) else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func removeAPIKey() throws {
        try removePrivateFile(at: apiKeyFileURLProvider())
    }

    public func containsAPIKey() -> Bool {
        (try? loadAPIKey()) != nil
    }

    public func saveKimiCredential(_ credential: KimiOAuthCredential) throws {
        try savePrivateData(try JSONEncoder().encode(credential), at: kimiOAuthFileURLProvider())
    }

    public func loadKimiCredential() throws -> KimiOAuthCredential? {
        guard let data = try loadPrivateData(at: kimiOAuthFileURLProvider()) else { return nil }
        guard let credential = try? JSONDecoder().decode(KimiOAuthCredential.self, from: data),
              !credential.accessToken.isEmpty,
              !credential.refreshToken.isEmpty else {
            throw ModelCredentialError.invalidKimiCredential
        }
        return credential
    }

    public func removeKimiCredential() throws {
        try removePrivateFile(at: kimiOAuthFileURLProvider())
    }

    public func containsKimiCredential() -> Bool {
        (try? loadKimiCredential()) != nil
    }

    // Compatibility aliases used by the API Key editor.
    public func save(_ apiKey: String) throws { try saveAPIKey(apiKey) }
    public func load() throws -> String? { try loadAPIKey() }
    public func remove() throws { try removeAPIKey() }
    public func containsCredential() -> Bool { containsAPIKey() }

    private func savePrivateData(_ data: Data, at fileURL: URL) throws {
        try rejectSymbolicLink(at: fileURL)
        let directory = fileURL.deletingLastPathComponent()
        try rejectSymbolicLink(at: directory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try rejectSymbolicLink(at: directory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func loadPrivateData(at fileURL: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        try rejectSymbolicLink(at: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        return try Data(contentsOf: fileURL)
    }

    private func removePrivateFile(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try rejectSymbolicLink(at: fileURL)
        try FileManager.default.removeItem(at: fileURL)
    }

    private func rejectSymbolicLink(at fileURL: URL) throws {
        var fileInfo = stat()
        let status = lstat(fileURL.path, &fileInfo)
        if status != 0 {
            guard errno == ENOENT else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
            return
        }
        guard (fileInfo.st_mode & S_IFMT) != S_IFLNK else {
            throw ModelCredentialError.unsafeAPIKeyFile
        }
    }
}
