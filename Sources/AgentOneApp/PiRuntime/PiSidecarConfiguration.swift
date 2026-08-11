import Foundation

public struct PiSidecarConfiguration: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectoryURL: URL?
    public var environment: [String: String]
    public var requestTimeout: TimeInterval

    public init(
        executableURL: URL,
        arguments: [String] = [],
        workingDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        requestTimeout: TimeInterval = 15
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
        self.requestTimeout = requestTimeout
    }

    public static func resolvedDefault(
        bundle: Bundle = .main,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> PiSidecarConfiguration {
        if let executableURL = PiSidecarLocator.resolveStandaloneExecutableURL(bundle: bundle) {
            return PiSidecarConfiguration(
                executableURL: executableURL,
                workingDirectoryURL: executableURL.deletingLastPathComponent(),
                environment: ["AGENTONE_PI_PROTOCOL_VERSION": String(PiProtocolV1.version)]
            )
        }

        let scriptURL = try PiSidecarLocator.resolveScriptURL(
            bundle: bundle,
            currentDirectoryURL: currentDirectoryURL
        )
        return PiSidecarConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", scriptURL.path],
            workingDirectoryURL: scriptURL.deletingLastPathComponent(),
            environment: ["AGENTONE_PI_PROTOCOL_VERSION": String(PiProtocolV1.version)]
        )
    }
}

public enum PiSidecarLocator {
    public static func resolveStandaloneExecutableURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            bundle.resourceURL?.appendingPathComponent("AgentOneLifeRuntime/agentone-life-runtime"),
            bundle.resourceURL?.appendingPathComponent("agentone-life-runtime")
        ].compactMap { $0 }

        return candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        })?.standardizedFileURL
    }

    public static func resolveScriptURL(
        bundle: Bundle = .main,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        fileManager: FileManager = .default
    ) throws -> URL {
        let resourceCandidates = [
            bundle.resourceURL?.appendingPathComponent("AgentOneLifeRuntime/dist/index.js"),
            bundle.resourceURL?.appendingPathComponent("dist/index.js"),
            bundle.resourceURL?.appendingPathComponent("index.js")
        ].compactMap { $0 }

        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceRoot = sourceDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var developmentCandidates = [
            sourceRoot.appendingPathComponent("AgentOneLifeRuntime/dist/index.js"),
            currentDirectoryURL.appendingPathComponent("AgentOneLifeRuntime/dist/index.js")
        ]

        var ancestor = currentDirectoryURL.standardizedFileURL
        for _ in 0..<8 {
            developmentCandidates.append(ancestor.appendingPathComponent("AgentOneLifeRuntime/dist/index.js"))
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            ancestor = parent
        }

        let candidates = resourceCandidates + developmentCandidates
        if let resolved = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return resolved.standardizedFileURL
        }

        throw PiSidecarError.runtimeNotFound(candidates.map(\.path))
    }
}
