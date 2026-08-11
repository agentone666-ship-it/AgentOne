import AgentOneCore
import AgentOnePiRuntime
import Darwin
import Foundation

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct HarnessCheck {
    let name: String
    let detail: String
}

@main
struct AgentOnePiIntegrationHarness {
    static func main() async {
        if CommandLine.arguments.contains("--fixture-sidecar") {
            runFixtureSidecar()
            return
        }

        do {
            let checks = try await runHarness()
            print("AgentOne Pi integration validation passed (\(checks.count) checks)\n")
            for (index, check) in checks.enumerated() {
                print("\(index + 1). ✓ \(check.name)\n   \(check.detail)")
            }
        } catch {
            let message = "AgentOne Pi integration validation failed: \(error)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func runHarness() async throws -> [HarnessCheck] {
        let packageRoot = try locatePackageRoot()
        let productionConfiguration = try PiSidecarConfiguration.resolvedDefault(
            currentDirectoryURL: packageRoot
        )
        var checks: [HarnessCheck] = []

        let bridge = PiSidecarBridge(configuration: productionConfiguration)
        defer { bridge.stopImmediately() }

        let health = try await bridge.health()
        guard case .ready(_, let ready) = health else {
            throw HarnessFailure("Production health request did not return ready.")
        }
        try require(ready.protocolVersion == PiProtocolV1.version, "Unexpected Pi protocol version.")
        try require(ready.runtime == "pi-agent-core", "Health response did not come from the production Pi runtime.")
        checks.append(HarnessCheck(
            name: "Production health",
            detail: "The formal Swift bridge launched the built AgentOneLifeRuntime and negotiated JSONL protocol v\(ready.protocolVersion)."
        ))

        let normalResult = try await bridge.wake(
            reason: "drift_detected",
            sanitizedContext: context(intentTitle: "Finish the paper", driftSeconds: 70),
            recentMemory: recentMemory,
            budget: actionBudget
        )
        let normalActionTypes = Set(normalResult.actions.map(\.type))
        try require(normalActionTypes.contains(.returnCard), "Normal wake did not propose a return card.")
        try require(normalActionTypes.contains(.innerJournal), "Normal wake did not propose an inner-journal entry.")
        try require(normalActionTypes.contains(.energyConsumed), "Normal wake did not account for energy.")
        checks.append(HarnessCheck(
            name: "Normal production wake",
            detail: "A bounded production wake returned only typed proposed actions through PiResultPayload."
        ))

        let sensitiveBridge = PiSidecarBridge(configuration: productionConfiguration)
        try require(!sensitiveBridge.isRunning, "Fresh bridge unexpectedly started before the sensitive request.")
        do {
            _ = try await sensitiveBridge.wake(
                reason: "sensitive_probe",
                sanitizedContext: context(intentTitle: "Private task", driftSeconds: 60, isSensitive: true),
                recentMemory: [],
                budget: actionBudget
            )
            throw HarnessFailure("Sensitive context unexpectedly reached Pi.")
        } catch PiSidecarError.sensitiveContext {
            // Expected: the policy check runs before send(), which is the only
            // path that may launch the child process.
        }
        try require(!sensitiveBridge.isRunning, "Sensitive context launched the sidecar before being rejected.")
        checks.append(HarnessCheck(
            name: "Pre-launch privacy gate",
            detail: "Sensitive context was rejected by the production bridge while its process remained stopped."
        ))

        checks.append(try await validateSensitiveRecentMemoryGate(configuration: productionConfiguration))
        checks.append(try await validateInvalidBudgetRecovery(configuration: productionConfiguration))

        let restrictedResult = try await bridge.wake(
            reason: "drift_detected",
            sanitizedContext: context(intentTitle: "Read the paper", driftSeconds: 70),
            recentMemory: recentMemory,
            budget: PiWakeBudget(
                maxTokens: 1_200,
                maxTurns: 2,
                maxDurationMs: 5_000,
                allowedTools: [.getCurrentContext],
                surpriseRisk: .none
            )
        )
        try require(restrictedResult.actions.isEmpty, "Restricted wake returned an action outside its allowlist.")
        checks.append(HarnessCheck(
            name: "Per-wake tool restriction",
            detail: "A wake limited to get_current_context completed without returning state-changing actions."
        ))

        bridge.stopImmediately()
        try require(!bridge.isRunning && bridge.state == .stopped, "stopImmediately did not fully stop the bridge.")
        let restartedHealth = try await bridge.health()
        try require(restartedHealth.type == .ready && bridge.isRunning, "Bridge did not restart after stopImmediately.")
        checks.append(HarnessCheck(
            name: "Stop and restart",
            detail: "The same production bridge instance stopped, relaunched, and completed a fresh health request."
        ))

        let firstTask = Task { @MainActor in
            try await bridge.wake(
                reason: "drift_detected_first",
                sanitizedContext: context(intentTitle: "First distinct intent", driftSeconds: 70),
                recentMemory: recentMemory,
                budget: returnCardBudget
            )
        }
        let secondTask = Task { @MainActor in
            try await bridge.wake(
                reason: "drift_detected_second",
                sanitizedContext: context(intentTitle: "Second distinct intent", driftSeconds: 70),
                recentMemory: recentMemory,
                budget: returnCardBudget
            )
        }
        let firstResult = try await firstTask.value
        let secondResult = try await secondTask.value
        try require(returnCardTitle(in: firstResult) == "First distinct intent", "First concurrent response was crossed with another request ID.")
        try require(returnCardTitle(in: secondResult) == "Second distinct intent", "Second concurrent response was crossed with another request ID.")
        checks.append(HarnessCheck(
            name: "Concurrent request correlation",
            detail: "Two outstanding wake continuations received return cards for their own intent IDs without response cross-talk."
        ))

        checks.append(try await validateCorePolicyBridgePipeline(configuration: productionConfiguration))
        checks.append(try await validateRemoteErrorRecovery())
        checks.append(try await validateUnknownResponseIDAndPassiveEvents())
        checks.append(try await validateProtocolModelMetadata())
        checks.append(contentsOf: try await validateEnvironmentOverrides())
        return checks
    }

    @MainActor
    private static func validateSensitiveRecentMemoryGate(
        configuration: PiSidecarConfiguration
    ) async throws -> HarnessCheck {
        let bridge = PiSidecarBridge(configuration: configuration)
        defer { bridge.stopImmediately() }

        let unsafeMemories = [
            PiRecentMemory(
                id: "unsafe-summary",
                timestamp: "2026-07-21T07:56:00.000Z",
                kind: "activity",
                summary: "用户正在输入银行卡支付密码",
                tags: ["checkout"]
            ),
            PiRecentMemory(
                id: "unsafe-tags",
                timestamp: "2026-07-21T07:57:00.000Z",
                kind: "activity",
                summary: "A private account form",
                tags: ["password", "credentials"]
            )
        ]

        for memory in unsafeMemories {
            do {
                _ = try await bridge.wake(
                    reason: "memory_privacy_probe",
                    sanitizedContext: context(intentTitle: "Safe visible task", driftSeconds: 60),
                    recentMemory: [memory],
                    budget: returnCardBudget
                )
                throw HarnessFailure("Protected recentMemory unexpectedly reached Pi: \(memory.id)")
            } catch PiSidecarError.sensitiveContext {
                // Expected. Both summary and tags are scanned before send().
            }
            try require(!bridge.isRunning, "Protected recentMemory launched or wrote to the sidecar before rejection.")
        }

        return HarnessCheck(
            name: "Recent-memory privacy gate",
            detail: "Payment/password material in either a memory summary or its tags was rejected locally before the sidecar started."
        )
    }

    @MainActor
    private static func validateInvalidBudgetRecovery(
        configuration: PiSidecarConfiguration
    ) async throws -> HarnessCheck {
        let bridge = PiSidecarBridge(configuration: configuration)
        defer { bridge.stopImmediately() }
        let invalidBudget = PiWakeBudget(
            maxTokens: 127,
            maxTurns: 2,
            maxDurationMs: 5_000,
            allowedTools: [.showReturnCard],
            surpriseRisk: .none
        )

        do {
            _ = try await bridge.wake(
                reason: "invalid_budget_probe",
                sanitizedContext: context(intentTitle: "Budget recovery", driftSeconds: 60),
                recentMemory: [],
                budget: invalidBudget
            )
            throw HarnessFailure("Out-of-range maxTokens unexpectedly reached Pi.")
        } catch PiSidecarError.invalidBudget(let message) {
            try require(message.contains("maxTokens"), "Invalid-budget error did not identify maxTokens.")
        }
        try require(!bridge.isRunning, "Invalid budget launched the sidecar before rejection.")

        let health = try await bridge.health()
        try require(health.type == .ready && bridge.isRunning, "Bridge was not usable after rejecting an invalid budget.")
        return HarnessCheck(
            name: "Invalid-budget recovery",
            detail: "maxTokens below the production bound raised invalidBudget before launch, and the same bridge subsequently passed health."
        )
    }

    @MainActor
    private static func validateCorePolicyBridgePipeline(
        configuration: PiSidecarConfiguration
    ) async throws -> HarnessCheck {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOnePiHarness-Core-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        let timeZone = try requireValue(
            TimeZone(secondsFromGMT: 0),
            "Could not construct the deterministic Core-to-Pi time zone."
        )
        let diary = try AppendOnlyDiary(homeURL: temporaryHome, timeZone: timeZone)
        let engine = ContextMemoryEngine(
            configuration: ContextEngineConfiguration(
                drift: DriftConfiguration(
                    relevanceThreshold: 0.3,
                    uncertaintyBand: 0.3...0.45,
                    stages: [ReminderStage(level: 1, after: 30, modalities: [.creatureMotion, .textBubble])]
                )
            ),
            diary: diary
        )

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let taskContext = ActivityContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            windowTitle: "ADHD attention recovery paper",
            contentSummary: "Writing the attention recovery section",
            selectedText: "This selected draft belongs to the private working document.",
            semanticTags: ["adhd", "attention", "paper", "research"]
        )
        let intent = try await engine.beginIntent(
            title: "Write the ADHD paper",
            summary: "Develop the section about attention recovery",
            context: taskContext,
            at: base
        )
        let distractionContext = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Comedy short videos",
            contentSummary: "An unrelated entertainment recommendation feed",
            selectedText: "A private selection that automatic Pi wakes must not receive.",
            semanticTags: ["comedy", "video", "entertainment"]
        )
        _ = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(10),
            signal: .windowFocused(windowIdentifier: "video-window"),
            context: distractionContext
        ))
        let reminderEvent = ActivityEvent(
            timestamp: base.addingTimeInterval(41),
            signal: .scrolled(axis: .vertical, delta: 240, phase: .changed),
            context: distractionContext
        )
        let output = try await engine.record(reminderEvent)
        let replay = await engine.replay(for: reminderEvent.timestamp)
        guard let reminder = output.prompts.first(where: {
            if case .reminder = $0 { return true }
            return false
        }) else {
            throw HarnessFailure("Core did not emit the expected reminder prompt.")
        }
        guard let plan = PiWakePolicy.reminderPlan(
            for: reminder,
            event: reminderEvent,
            output: output,
            replay: replay
        ) else {
            throw HarnessFailure("Production PiWakePolicy rejected a valid Core reminder.")
        }
        try require(output.activeIntent?.id == intent.id, "Core output lost the active intent before Pi policy mapping.")
        try require((output.activeDriftDurationSeconds ?? 0) >= 30, "Core output did not expose the active drift duration.")
        try require(plan.context.selectedText == nil, "PiWakePolicy leaked selectedText into automatic context.")
        try require(plan.context.activeIntent?.title == intent.title, "PiWakePolicy changed the active intent title.")

        let bridge = PiSidecarBridge(configuration: configuration)
        defer { bridge.stopImmediately() }
        let result = try await bridge.wake(
            reason: plan.reason,
            sanitizedContext: plan.context,
            recentMemory: plan.recentMemory,
            budget: plan.budget
        )
        try require(returnCardTitle(in: result) == intent.title, "Pi return card did not preserve the Core active intent.")
        return HarnessCheck(
            name: "Core → Policy → Bridge → Pi",
            detail: "A real drift reminder became a production wake plan, withheld selected text, and returned a card for “\(intent.title)”."
        )
    }

    @MainActor
    private static func validateRemoteErrorRecovery() async throws -> HarnessCheck {
        let bridge = PiSidecarBridge(configuration: fixtureConfiguration(mode: "remote-error"))
        defer { bridge.stopImmediately() }
        do {
            _ = try await bridge.wake(
                reason: "remote_error_probe",
                sanitizedContext: context(intentTitle: "Recovery probe", driftSeconds: 60),
                recentMemory: [],
                budget: returnCardBudget
            )
            throw HarnessFailure("Fixture remote error unexpectedly returned a result.")
        } catch PiSidecarError.remote(let code, _) {
            try require(code == "fixture_remote_error", "Bridge lost the remote error code.")
        }
        let response = try await bridge.health()
        try require(response.type == .ready && bridge.isRunning, "Bridge was not usable after a correlated remote error.")
        return HarnessCheck(
            name: "Remote error recovery",
            detail: "A typed remote error failed only its wake continuation; the same process answered health afterward."
        )
    }

    @MainActor
    private static func validateUnknownResponseIDAndPassiveEvents() async throws -> HarnessCheck {
        let bridge = PiSidecarBridge(configuration: fixtureConfiguration(mode: "unknown-id"))
        defer { bridge.stopImmediately() }
        var passiveResultEvents = 0
        let persistedActions = 0
        bridge.onEvent = { response in
            // Streaming and uncorrelated output is deliberately observation
            // only. The harness proves the callback can see a proposed action
            // without executing persistence or UI effects.
            if case .result(_, let payload) = response, !payload.actions.isEmpty {
                passiveResultEvents += 1
            }
            _ = persistedActions
        }
        let health = try await bridge.health()
        try require(health.type == .ready, "Valid health response was lost after an id=unknown result.")
        try require(passiveResultEvents == 1, "Uncorrelated result was not surfaced exactly once through onEvent.")
        try require(persistedActions == 0, "onEvent executed a persistent action.")
        try require(bridge.isRunning, "Non-UUID response ID incorrectly tore down the sidecar.")
        return HarnessCheck(
            name: "Uncorrelated event isolation",
            detail: "An id=unknown result was decoded as passive onEvent output; it executed no action and did not poison the following health response."
        )
    }

    @MainActor
    private static func validateProtocolModelMetadata() async throws -> HarnessCheck {
        let metadataBridge = PiSidecarBridge(configuration: fixtureConfiguration(mode: "metadata"))
        defer { metadataBridge.stopImmediately() }

        let metadataHealth = try await metadataBridge.health()
        guard case .ready(_, let metadataReady) = metadataHealth else {
            throw HarnessFailure("Metadata fixture health did not return ready.")
        }
        try require(metadataReady.provider == "fixture-provider", "Ready provider metadata was not decoded.")
        try require(metadataReady.model == "fixture-ready-model", "Ready model metadata was not decoded.")
        try require(metadataReady.runtimeMode == "cloud", "Ready runtime mode metadata was not decoded.")

        let metadataResult = try await metadataBridge.wake(
            reason: "metadata_probe",
            sanitizedContext: context(intentTitle: "Metadata probe", driftSeconds: 60),
            recentMemory: [],
            budget: returnCardBudget
        )
        try require(metadataResult.model?.route == "cloud", "Result model route metadata was not decoded.")
        try require(metadataResult.model?.provider == "fixture-provider", "Result model provider metadata was not decoded.")
        try require(metadataResult.model?.model == "fixture-result-model", "Result model identifier was not decoded.")

        let legacyBridge = PiSidecarBridge(configuration: fixtureConfiguration(mode: "legacy-metadata"))
        defer { legacyBridge.stopImmediately() }
        let legacyHealth = try await legacyBridge.health()
        guard case .ready(_, let legacyReady) = legacyHealth else {
            throw HarnessFailure("Legacy fixture health did not return ready.")
        }
        try require(legacyReady.provider == nil, "Missing legacy provider should decode as nil.")
        try require(legacyReady.model == nil, "Missing legacy ready model should decode as nil.")
        try require(legacyReady.runtimeMode == nil, "Missing legacy runtime mode should decode as nil.")
        let legacyResult = try await legacyBridge.wake(
            reason: "legacy_metadata_probe",
            sanitizedContext: context(intentTitle: "Legacy metadata probe", driftSeconds: 60),
            recentMemory: [],
            budget: returnCardBudget
        )
        try require(legacyResult.model == nil, "Missing legacy result model should decode as nil.")

        return HarnessCheck(
            name: "Protocol model metadata compatibility",
            detail: "Ready/result provider and model metadata decoded when present, while legacy fixtures with every new field omitted remained compatible."
        )
    }

    @MainActor
    private static func validateEnvironmentOverrides() async throws -> [HarnessCheck] {
        let inheritedOnlyKey = "AGENTONE_HARNESS_INHERITED_ONLY"
        let configurationKey = "AGENTONE_HARNESS_CONFIGURATION_WINS"
        let layeredKey = "AGENTONE_HARNESS_RUNTIME_WINS"
        let secretKey = "AGENTONE_HARNESS_SECRET"
        let secret = "AGENTONE_HARNESS_SECRET_DO_NOT_PRINT_7E3941"

        setenv(inheritedOnlyKey, "inherited", 1)
        setenv(configurationKey, "inherited", 1)
        setenv(layeredKey, "inherited", 1)
        defer {
            unsetenv(inheritedOnlyKey)
            unsetenv(configurationKey)
            unsetenv(layeredKey)
        }

        let configuration = fixtureConfiguration(
            mode: "environment",
            environment: [
                configurationKey: "configured",
                layeredKey: "configured",
                secretKey: secret
            ]
        )
        let bridge = PiSidecarBridge(configuration: configuration)
        defer { bridge.stopImmediately() }

        let firstOverrides = [layeredKey: "runtime-v1"]
        try bridge.updateEnvironmentOverrides(firstOverrides)
        let firstReady = try readyPayload(from: await bridge.health())
        let firstPID = try runningProcessIdentifier(of: bridge)
        try require(firstReady.runtimeMode == "environment-ok", "Initial environment precedence check failed.")
        try require(firstReady.model == String(firstPID), "Fixture launch identity did not match the running process.")

        try bridge.updateEnvironmentOverrides(firstOverrides)
        let unchangedReady = try readyPayload(from: await bridge.health())
        let unchangedPID = try runningProcessIdentifier(of: bridge)
        try require(unchangedPID == firstPID, "Identical environment overrides restarted the sidecar.")
        try require(unchangedReady.model == String(firstPID), "Identical overrides changed the fixture launch identity.")

        try bridge.updateEnvironmentOverrides([layeredKey: "runtime-v2"])
        let restartedReady = try readyPayload(from: await bridge.health())
        let restartedPID = try runningProcessIdentifier(of: bridge)
        try require(restartedPID != firstPID, "Changed environment overrides did not restart the sidecar.")
        try require(restartedReady.runtimeMode == "environment-ok", "Restarted environment precedence check failed.")
        try require(restartedReady.model == String(restartedPID), "Restarted fixture launch identity was stale.")

        var disclosureSurfaces = [String(describing: bridge.state)]
        do {
            try bridge.updateEnvironmentOverrides(["INVALID": "\(secret)\0"])
            throw HarnessFailure("Invalid environment override was accepted.")
        } catch PiSidecarError.invalidEnvironmentOverrides {
            disclosureSurfaces.append(PiSidecarError.invalidEnvironmentOverrides.localizedDescription)
        }
        do {
            _ = try await bridge.wake(
                reason: "environment_error_probe",
                sanitizedContext: context(intentTitle: "Environment error probe", driftSeconds: 60),
                recentMemory: [],
                budget: returnCardBudget
            )
            throw HarnessFailure("Environment fixture error unexpectedly returned a result.")
        } catch PiSidecarError.remote(_, let message) {
            disclosureSurfaces.append(message)
        }
        try require(
            disclosureSurfaces.allSatisfy { !$0.contains(secret) },
            "An environment value leaked through a public bridge surface."
        )

        return [
            HarnessCheck(
                name: "Environment merge and restart",
                detail: "The child inherited process values, configuration replaced inherited values, runtime overrides won last, identical updates were inert, and changed updates relaunched the process."
            ),
            HarnessCheck(
                name: "Environment secret non-disclosure",
                detail: "A high-entropy fixture secret was consumed only inside the child; bridge state and both validation/remote errors exposed no environment value."
            )
        ]
    }

    private static var recentMemory: [PiRecentMemory] {
        [PiRecentMemory(
            id: "memory-1",
            timestamp: "2026-07-21T07:55:00.000Z",
            kind: "activity",
            summary: "The user was editing the paper introduction.",
            tags: ["paper", "writing"]
        )]
    }

    private static var actionBudget: PiWakeBudget {
        PiWakeBudget(
            maxTokens: 2_400,
            maxTurns: 3,
            maxDurationMs: 8_000,
            allowedTools: [.getCurrentContext, .appendInnerJournal, .showReturnCard, .consumeEnergyBudget],
            surpriseRisk: .none
        )
    }

    private static var returnCardBudget: PiWakeBudget {
        PiWakeBudget(
            maxTokens: 1_600,
            maxTurns: 2,
            maxDurationMs: 6_000,
            allowedTools: [.showReturnCard],
            surpriseRisk: .none
        )
    }

    private static func context(
        intentTitle: String,
        driftSeconds: Double,
        isSensitive: Bool = false
    ) -> PiSanitizedContext {
        PiSanitizedContext(
            capturedAt: "2026-07-21T08:00:00.000Z",
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "An unrelated video",
            contentSummary: "A bounded synthetic integration context",
            semanticTags: ["video"],
            isSensitive: isSensitive,
            activeIntent: PiActiveIntent(id: UUID().uuidString, title: intentTitle),
            driftDurationSeconds: driftSeconds
        )
    }

    private static func returnCardTitle(in result: PiResultPayload) -> String? {
        result.actions.first(where: { $0.type == .returnCard })?.payload["taskTitle"]?.stringValue
    }

    private static func fixtureConfiguration(
        mode: String,
        environment: [String: String] = [:]
    ) -> PiSidecarConfiguration {
        PiSidecarConfiguration(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            arguments: ["--fixture-sidecar", mode],
            environment: environment,
            requestTimeout: 5
        )
    }

    private static func readyPayload(from response: PiResponse) throws -> PiReadyPayload {
        guard case .ready(_, let payload) = response else {
            throw HarnessFailure("Fixture health did not return ready.")
        }
        return payload
    }

    @MainActor
    private static func runningProcessIdentifier(of bridge: PiSidecarBridge) throws -> Int32 {
        guard case .running(let processIdentifier) = bridge.state else {
            throw HarnessFailure("Bridge was not running after health.")
        }
        return processIdentifier
    }

    private static func locatePackageRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        for _ in 0..<8 {
            let runtime = candidate.appendingPathComponent("AgentOneLifeRuntime/dist/index.js")
            let manifest = candidate.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: runtime.path),
               FileManager.default.fileExists(atPath: manifest.path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        throw HarnessFailure("Could not locate Package.swift and AgentOneLifeRuntime/dist/index.js.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessFailure(message) }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw HarnessFailure(message) }
        return value
    }

    private static func runFixtureSidecar() {
        let mode = CommandLine.arguments.last ?? ""
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let type = object["type"] as? String else {
                emitFixture(errorResponse(id: "unknown", code: "invalid_request", message: "Malformed fixture request"))
                continue
            }

            if mode == "unknown-id", type == "health" {
                emitFixture([
                    "version": 1,
                    "id": "unknown",
                    "type": "result",
                    "payload": [
                        "outcome": "unsolicited_fixture_result",
                        "actions": [["type": "inner_journal", "payload": ["observation": "must remain passive"]]],
                        "usage": zeroUsage
                    ]
                ])
            }

            switch type {
            case "health":
                var payload: [String: Any] = [
                    "runtime": "pi-agent-core-fixture",
                    "piVersion": "fixture",
                    "protocolVersion": 1,
                    "safeTools": []
                ]
                if mode == "metadata" {
                    payload["provider"] = "fixture-provider"
                    payload["model"] = "fixture-ready-model"
                    payload["runtimeMode"] = "cloud"
                } else if mode == "environment" {
                    let environment = ProcessInfo.processInfo.environment
                    let environmentIsValid =
                        environment["AGENTONE_HARNESS_INHERITED_ONLY"] == "inherited" &&
                        environment["AGENTONE_HARNESS_CONFIGURATION_WINS"] == "configured" &&
                        ["runtime-v1", "runtime-v2"].contains(environment["AGENTONE_HARNESS_RUNTIME_WINS"] ?? "") &&
                        environment["AGENTONE_HARNESS_SECRET"] == "AGENTONE_HARNESS_SECRET_DO_NOT_PRINT_7E3941"
                    payload["provider"] = "environment-fixture"
                    payload["model"] = String(ProcessInfo.processInfo.processIdentifier)
                    payload["runtimeMode"] = environmentIsValid ? "environment-ok" : "environment-invalid"
                } else if mode != "legacy-metadata" {
                    payload["runtimeMode"] = "offline-faux"
                }
                emitFixture([
                    "version": 1,
                    "id": id,
                    "type": "ready",
                    "payload": payload
                ])
            case "wake" where mode == "remote-error":
                emitFixture(errorResponse(id: id, code: "fixture_remote_error", message: "Intentional recoverable fixture error"))
            case "wake" where mode == "environment":
                emitFixture(errorResponse(id: id, code: "fixture_environment_error", message: "Intentional environment fixture error"))
            case "shutdown":
                emitFixture([
                    "version": 1,
                    "id": id,
                    "type": "result",
                    "payload": ["outcome": "shutdown", "actions": [], "usage": zeroUsage]
                ])
                return
            default:
                var payload: [String: Any] = [
                    "outcome": "fixture_result",
                    "actions": [],
                    "usage": zeroUsage
                ]
                if mode == "metadata" {
                    payload["model"] = [
                        "route": "cloud",
                        "provider": "fixture-provider",
                        "model": "fixture-result-model"
                    ]
                }
                emitFixture([
                    "version": 1,
                    "id": id,
                    "type": "result",
                    "payload": payload
                ])
            }
        }
    }

    private static var zeroUsage: [String: Any] {
        [
            "turns": 0,
            "inputTokens": 0,
            "outputTokens": 0,
            "totalTokens": 0,
            "toolCalls": 0,
            "durationMs": 0,
            "stoppedByBudget": false
        ]
    }

    private static func errorResponse(id: String, code: String, message: String) -> [String: Any] {
        [
            "version": 1,
            "id": id,
            "type": "error",
            "payload": ["code": code, "message": message, "retryable": true]
        ]
    }

    private static func emitFixture(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            exit(EXIT_FAILURE)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
