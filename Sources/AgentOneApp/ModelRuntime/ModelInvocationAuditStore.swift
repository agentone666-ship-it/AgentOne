import Foundation
import AgentOneModelRuntime

/// An append-only, metadata-only ledger of model calls. It intentionally never
/// stores prompts, selected text, API keys, or raw Context values.
actor ModelInvocationAuditStore {
    private let fileURL: URL
    private let encoder: JSONEncoder

    init(rootURL: URL) {
        let directory = rootURL.appendingPathComponent("Model Invocations", isDirectory: true)
        self.fileURL = directory.appendingPathComponent("model-invocations.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func append(_ audit: ModelInvocationAudit) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var line = try encoder.encode(audit)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try line.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
