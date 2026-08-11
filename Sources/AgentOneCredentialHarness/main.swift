import Foundation
import AgentOneCredentialStore
import AgentOneModelAuth

private enum HarnessFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): message
        }
    }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw HarnessFailure.assertion(message) }
}

private let fixtureSecret = "fixture-secret-never-log-7F4D9A"

private func withTemporaryStore(
    _ body: (ModelCredentialStore, URL, URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentOneCredentialHarness-\(UUID().uuidString)", isDirectory: true)
    let secrets = root.appendingPathComponent("Secrets", isDirectory: true)
    let keyURL = secrets.appendingPathComponent("model-api-key", isDirectory: false)
    let kimiURL = secrets.appendingPathComponent("kimi-oauth.json", isDirectory: false)
    let store = ModelCredentialStore(
        apiKeyFileURLProvider: { keyURL },
        kimiOAuthFileURLProvider: { kimiURL }
    )

    defer { try? FileManager.default.removeItem(at: root) }
    try body(store, keyURL, kimiURL)
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let permissions = attributes[.posixPermissions] as? NSNumber else {
        throw HarnessFailure.assertion("POSIX permissions were unavailable")
    }
    return permissions.intValue & 0o777
}

private func testAPIKeyRoundTripUsesPrivateFile() throws {
    try withTemporaryStore { store, keyURL, _ in
        try store.saveAPIKey("  \(fixtureSecret)  ")

        let loaded = try store.loadAPIKey()
        let directoryPermissions = try permissions(at: keyURL.deletingLastPathComponent())
        let filePermissions = try permissions(at: keyURL)
        try expect(loaded == fixtureSecret, "API Key should round-trip after normalization")
        try expect(store.containsAPIKey(), "containsAPIKey should detect the private file")
        try expect(directoryPermissions == 0o700, "Secrets directory must be 0700")
        try expect(filePermissions == 0o600, "API Key file must be 0600")
    }
}

private func testAPIKeyUpdateAndRemoval() throws {
    try withTemporaryStore { store, keyURL, _ in
        try store.saveAPIKey("first-fixture-value")
        try store.saveAPIKey("second-fixture-value")
        try expect(try store.loadAPIKey() == "second-fixture-value", "saving again should replace the private file")

        try store.removeAPIKey()
        try expect(!FileManager.default.fileExists(atPath: keyURL.path), "remove should delete the private API Key file")
        try expect(!store.containsAPIKey(), "containsAPIKey should be false after removal")
    }
}

private func testEmptyAPIKeyRemovesPrivateFile() throws {
    try withTemporaryStore { store, keyURL, _ in
        try store.saveAPIKey("temporary-value")
        try store.saveAPIKey("  \n  ")
        try expect(!FileManager.default.fileExists(atPath: keyURL.path), "an empty API Key should remove the private file")
    }
}

private func testPrivateFileRepairsPermissions() throws {
    try withTemporaryStore { store, keyURL, _ in
        try store.saveAPIKey("temporary-value")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyURL.path)
        _ = try store.loadAPIKey()
        try expect(try permissions(at: keyURL) == 0o600, "loading should repair private file permissions to 0600")
    }
}

private func testSymbolicLinkTargetsAreRejectedWithoutSecretLeakage() throws {
    try withTemporaryStore { store, keyURL, _ in
        let outsideURL = keyURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("outside-target")
        try FileManager.default.createDirectory(
            at: keyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("outside-value".utf8).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(at: keyURL, withDestinationURL: outsideURL)

        do {
            try store.saveAPIKey(fixtureSecret)
            throw HarnessFailure.assertion("symbolic-link API Key target must be rejected")
        } catch let error as ModelCredentialError {
            try expect(error == .unsafeAPIKeyFile, "symbolic-link rejection should use the safe typed error")
            try expect(!error.localizedDescription.contains(fixtureSecret), "credential errors must not contain the API Key")
        }
        try expect(
            try String(contentsOf: outsideURL, encoding: .utf8) == "outside-value",
            "symbolic-link rejection must not modify its destination"
        )
    }
}

private func testKimiOAuthRoundTripUsesPrivateFile() throws {
    try withTemporaryStore { store, _, kimiURL in
        let credential = KimiOAuthCredential(
            accessToken: "kimi-access-fixture",
            refreshToken: "kimi-refresh-fixture",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            scope: "openid",
            tokenType: "Bearer",
            expiresIn: 3600
        )
        try store.saveKimiCredential(credential)
        let loaded = try store.loadKimiCredential()

        try expect(loaded == credential, "Kimi OAuth credential should round-trip")
        try expect(store.containsKimiCredential(), "containsKimiCredential should detect the private file")
        try expect(try permissions(at: kimiURL) == 0o600, "Kimi OAuth file must be 0600")
        try expect(
            try permissions(at: kimiURL.deletingLastPathComponent()) == 0o700,
            "Kimi OAuth directory must be 0700"
        )

        try store.removeKimiCredential()
        try expect(!FileManager.default.fileExists(atPath: kimiURL.path), "Kimi disconnect should remove its private file")
    }
}

private func testCorruptKimiOAuthFailsClosed() throws {
    try withTemporaryStore { store, _, kimiURL in
        try FileManager.default.createDirectory(
            at: kimiURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"access_token\":\"truncated\"}".utf8).write(to: kimiURL)
        do {
            _ = try store.loadKimiCredential()
            throw HarnessFailure.assertion("Corrupt Kimi credential was accepted")
        } catch let error as ModelCredentialError {
            try expect(error == .invalidKimiCredential, "Corrupt Kimi credential should fail with a typed error")
        }
    }
}

let tests: [(String, () throws -> Void)] = [
    ("API Key private-file round trip", testAPIKeyRoundTripUsesPrivateFile),
    ("API Key private-file update and removal", testAPIKeyUpdateAndRemoval),
    ("empty API Key removes private file", testEmptyAPIKeyRemovesPrivateFile),
    ("private-file permission repair", testPrivateFileRepairsPermissions),
    ("symbolic-link rejection", testSymbolicLinkTargetsAreRejectedWithoutSecretLeakage),
    ("Kimi OAuth private-file round trip", testKimiOAuthRoundTripUsesPrivateFile),
    ("corrupt Kimi OAuth fails closed", testCorruptKimiOAuthFailsClosed),
]

do {
    for (name, test) in tests {
        try test()
        print("PASS: \(name)")
    }
    print("AgentOneCredentialHarness: \(tests.count) checks passed")
} catch {
    let safeDescription = String(describing: error).replacingOccurrences(of: fixtureSecret, with: "[REDACTED]")
    fputs("FAIL: \(safeDescription)\n", stderr)
    exit(1)
}
