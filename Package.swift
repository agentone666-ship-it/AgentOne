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
        .executable(name: "AgentOne", targets: ["AgentOneApp"]),
        .executable(name: "AgentOneCoreHarness", targets: ["AgentOneCoreHarness"]),
        .executable(name: "AgentOnePiIntegrationHarness", targets: ["AgentOnePiIntegrationHarness"])
    ],
    targets: [
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
            dependencies: ["AgentOneCore", "AgentOneModelRuntime", "AgentOneModelAuth", "AgentOneCredentialStore", "AgentOnePiRuntime"],
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
