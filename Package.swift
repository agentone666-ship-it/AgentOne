// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AgentOne",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentOneCore", targets: ["AgentOneCore"]),
        .library(name: "AgentOneModelRuntime", targets: ["AgentOneModelRuntime"]),
        .library(name: "AgentOneModelAuth", targets: ["AgentOneModelAuth"]),
        .library(name: "AgentOneCredentialStore", targets: ["AgentOneCredentialStore"]),
        .library(name: "AgentOnePiRuntime", targets: ["AgentOnePiRuntime"]),
        .executable(name: "AgentOne", targets: ["AgentOneCaptureApp"]),
        .executable(name: "AgentOneRecorder", targets: ["AgentOneRecorder"]),
        .executable(name: "AgentOneLegacy", targets: ["AgentOneApp"]),
        .library(name: "AgentOneCaptureKit", targets: ["AgentOneCaptureKit"]),
        .executable(name: "AgentOneAudioHarness", targets: ["AgentOneAudioHarness"]),
        .executable(name: "AgentOneCoreHarness", targets: ["AgentOneCoreHarness"]),
        .executable(name: "AgentOnePiIntegrationHarness", targets: ["AgentOnePiIntegrationHarness"])
    ],
    targets: [
        .target(name: "AgentOneCaptureKit", dependencies: ["AgentOneCore"], resources: [.process("Resources")]),
        .executableTarget(name: "AgentOneCaptureApp", dependencies: ["AgentOneCaptureKit"]),
        .executableTarget(name: "AgentOneRecorder", dependencies: ["AgentOneCaptureKit"]),
        .executableTarget(name: "AgentOneAudioHarness", dependencies: ["AgentOneCaptureKit"]),
        .testTarget(name: "AgentOneCaptureKitTests", dependencies: ["AgentOneCaptureKit"]),
        .testTarget(name: "AgentOneIslandTests", dependencies: ["AgentOneCaptureApp"]),
        .target(name: "AgentOneCore"),
        .target(name: "AgentOneModelAuth"),
        .target(
            name: "AgentOneModelRuntime",
            dependencies: ["AgentOneCore"],
            path: "Sources/AgentOneApp/ModelRuntime",
            exclude: ["AgentModelSettings.swift", "ModelInvocationAuditStore.swift"],
            sources: ["ModelInference.swift", "ContextSemanticAnalyzer.swift"]
        ),
        .target(
            name: "AgentOneCredentialStore",
            dependencies: ["AgentOneModelAuth"]
        ),
        .target(
            name: "AgentOnePiRuntime",
            dependencies: ["AgentOneCore"],
            path: "Sources/AgentOneApp/PiRuntime"
        ),
        .executableTarget(
            name: "AgentOneApp",
            dependencies: ["AgentOneCore", "AgentOneCaptureKit", "AgentOneModelRuntime", "AgentOneModelAuth", "AgentOneCredentialStore", "AgentOnePiRuntime"],
            exclude: [
                "PiRuntime",
                "ModelRuntime/ModelInference.swift",
                "ModelRuntime/ContextSemanticAnalyzer.swift"
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "AgentOneCoreHarness",
            dependencies: ["AgentOneCore"]
        ),
        .executableTarget(
            name: "AgentOnePiIntegrationHarness",
            dependencies: ["AgentOneCore", "AgentOnePiRuntime"]
        ),
        .executableTarget(
            name: "AgentOneOAuthHarness",
            dependencies: ["AgentOneModelAuth"]
        ),
        .executableTarget(
            name: "AgentOneCredentialHarness",
            dependencies: ["AgentOneCredentialStore", "AgentOneModelAuth"]
        ),
        .executableTarget(
            name: "AgentOneModelRuntimeHarness",
            dependencies: ["AgentOneCore", "AgentOneModelRuntime"]
        ),
        .testTarget(
            name: "AgentOnePiRuntimeTests",
            dependencies: ["AgentOneCore", "AgentOnePiRuntime"]
        ),
        .testTarget(
            name: "AgentOneCoreTests",
            dependencies: ["AgentOneCore"]
        ),
        .testTarget(
            name: "AgentOneAppCaptureTests",
            dependencies: ["AgentOneApp", "AgentOneCore"]
        )
    ]
)
