import Foundation

public enum PiSidecarError: Error, LocalizedError {
    case runtimeNotFound([String])
    case launchFailed(String)
    case processUnavailable
    case requestTimedOut(UUID)
    case processExited(status: Int32, standardError: String)
    case malformedResponse(String)
    case remote(code: String?, message: String)
    case sensitiveContext
    case invalidBudget(String)
    case invalidEnvironmentOverrides
    case unexpectedResponse(PiResponseType)

    public var errorDescription: String? {
        switch self {
        case .runtimeNotFound(let paths):
            return "AgentOneLifeRuntime/dist/index.js was not found. Checked: \(paths.joined(separator: ", "))"
        case .launchFailed(let message):
            return "Pi sidecar could not start: \(message)"
        case .processUnavailable:
            return "Pi sidecar is not running."
        case .requestTimedOut(let id):
            return "Pi request \(id.uuidString) timed out."
        case .processExited(let status, _):
            return "Pi sidecar exited with status \(status)."
        case .malformedResponse:
            return "Pi sidecar returned invalid JSONL."
        case .remote(let code, let message):
            return [code, message].compactMap { $0 }.joined(separator: ": ")
        case .sensitiveContext:
            return "Sensitive context is never sent to or used to launch Pi."
        case .invalidBudget(let message):
            return "Invalid Pi budget: \(message)"
        case .invalidEnvironmentOverrides:
            return "Pi environment overrides are invalid."
        case .unexpectedResponse(let type):
            return "Unexpected Pi response type: \(type.rawValue)"
        }
    }
}

@MainActor
public final class PiSidecarBridge {
    public enum State: Equatable {
        case stopped
        case starting
        case running(processIdentifier: Int32)
        case failed(String)
    }

    public typealias EventHandler = @MainActor (PiResponse) -> Void

    private struct PendingRequest {
        let continuation: CheckedContinuation<PiResponse, Error>
        let timeoutTask: Task<Void, Never>
    }

    private static let maximumBufferedOutputBytes = 2 * 1_024 * 1_024
    private static let maximumStandardErrorBytes = 16 * 1_024

    private var configuration: PiSidecarConfiguration?
    private var environmentOverrides: [String: String] = [:]
    private var process: Process?
    private var standardInputHandle: FileHandle?
    private var standardOutputHandle: FileHandle?
    private var standardErrorHandle: FileHandle?
    private var outputBuffer = Data()
    private var standardErrorBuffer = Data()
    private var pendingRequests: [UUID: PendingRequest] = [:]

    public private(set) var state: State = .stopped
    public var onEvent: EventHandler?

    /// A nil configuration resolves the bundled/development runtime lazily.
    /// Merely constructing this bridge never starts Pi and never sends a wake.
    public init(configuration: PiSidecarConfiguration? = nil) {
        self.configuration = configuration
    }

    /// Tests can inject an executable fixture directly, without Node or a
    /// packaged JavaScript runtime.
    public convenience init(
        executableURL: URL,
        arguments: [String] = [],
        workingDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        requestTimeout: TimeInterval = 15
    ) {
        self.init(
            configuration: PiSidecarConfiguration(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectoryURL: workingDirectoryURL,
                environment: environment,
                requestTimeout: requestTimeout
            )
        )
    }

    public var isRunning: Bool {
        process?.isRunning == true
    }

    /// Replaces the process-scoped environment overrides. Environment values
    /// remain private to the bridge and are never surfaced through State.
    /// Changing an active bridge is a process boundary: pending requests fail
    /// with processUnavailable and the sidecar is relaunched with the new
    /// environment. Reapplying identical overrides is a no-op.
    public func updateEnvironmentOverrides(_ overrides: [String: String]) throws {
        guard Self.areValidEnvironmentOverrides(overrides) else {
            throw PiSidecarError.invalidEnvironmentOverrides
        }
        guard overrides != environmentOverrides else { return }

        let shouldRestart = isRunning
        if shouldRestart {
            cleanUpProcess(terminalError: nil, terminateIfRunning: true)
        }
        environmentOverrides = overrides
        if shouldRestart {
            try start()
        }
    }

    public func start() throws {
        guard !isRunning else { return }

        let resolvedConfiguration: PiSidecarConfiguration
        do {
            if let configuration {
                resolvedConfiguration = configuration
            } else {
                let resolved = try PiSidecarConfiguration.resolvedDefault()
                configuration = resolved
                resolvedConfiguration = resolved
            }
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = resolvedConfiguration.executableURL
        process.arguments = resolvedConfiguration.arguments
        process.currentDirectoryURL = resolvedConfiguration.workingDirectoryURL
        let configuredEnvironment = ProcessInfo.processInfo.environment.merging(
            resolvedConfiguration.environment,
            uniquingKeysWith: { _, injected in injected }
        )
        process.environment = configuredEnvironment.merging(
            environmentOverrides,
            uniquingKeysWith: { _, override in override }
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputBuffer.removeAll(keepingCapacity: true)
        standardErrorBuffer.removeAll(keepingCapacity: true)
        standardInputHandle = inputPipe.fileHandleForWriting
        standardOutputHandle = outputPipe.fileHandleForReading
        standardErrorHandle = errorPipe.fileHandleForReading

        standardOutputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.consumeStandardOutput(data)
            }
        }
        standardErrorHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.consumeStandardError(data)
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleProcessExit(status: status)
            }
        }

        self.process = process
        state = .starting
        do {
            try process.run()
            state = .running(processIdentifier: process.processIdentifier)
        } catch {
            cleanUpProcess(terminalError: nil, terminateIfRunning: false)
            let sidecarError = PiSidecarError.launchFailed(error.localizedDescription)
            state = .failed(sidecarError.localizedDescription)
            throw sidecarError
        }
    }

    public func health(timeout: TimeInterval? = nil) async throws -> PiResponse {
        let response = try await send(.health(), timeout: timeout, startIfNeeded: true)
        switch response {
        case .ready, .result:
            return response
        case .event, .error:
            throw PiSidecarError.unexpectedResponse(response.type)
        }
    }

    public func wake(
        reason: String,
        sanitizedContext: PiSanitizedContext,
        recentMemory: [PiRecentMemory],
        contextHistory: [PiContextRecord] = [],
        budget: PiWakeBudget,
        timeout: TimeInterval? = nil
    ) async throws -> PiResultPayload {
        // These checks intentionally happen before send(), because send() is
        // the point at which a missing process would be launched.
        guard sanitizedContext.isSafeForPi,
              recentMemory.allSatisfy(Self.isSafeForPi),
              await Self.isSafeHistory(contextHistory) else {
            throw PiSidecarError.sensitiveContext
        }
        try Self.validate(budget: budget)

        var payload = PiWakePayload(
            reason: reason,
            sanitizedContext: sanitizedContext,
            recentMemory: recentMemory,
            budget: budget
        )
        payload.contextHistory = contextHistory
        let response = try await send(.wake(payload: payload), timeout: timeout, startIfNeeded: true)
        guard case .result(_, let result) = response else {
            throw PiSidecarError.unexpectedResponse(response.type)
        }
        return result
    }

    public func chat(
        purpose: PiChatPurpose = .conversation,
        messages: [PiChatMessage],
        sanitizedContext: PiSanitizedContext?,
        recentMemory: [PiRecentMemory],
        contextHistory: [PiContextRecord] = [],
        maxTokens: Int = 2_400,
        maxDurationMs: Int = 30_000,
        timeout: TimeInterval? = nil
    ) async throws -> PiResultPayload {
        guard !messages.isEmpty,
              messages.count <= 20,
              messages.allSatisfy({ !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              sanitizedContext?.isSafeForPi != false,
              recentMemory.allSatisfy(Self.isSafeForPi),
              await Self.isSafeHistory(contextHistory) else {
            throw PiSidecarError.sensitiveContext
        }
        guard (128...16_000).contains(maxTokens),
              (500...60_000).contains(maxDurationMs) else {
            throw PiSidecarError.invalidBudget("Chat budget is outside the supported range.")
        }

        var payload = PiChatPayload(
            purpose: purpose,
            messages: messages,
            sanitizedContext: sanitizedContext,
            recentMemory: recentMemory,
            maxTokens: maxTokens,
            maxDurationMs: maxDurationMs
        )
        payload.contextHistory = contextHistory
        let response = try await send(.chat(payload: payload), timeout: timeout, startIfNeeded: true)
        guard case .result(_, let result) = response else {
            throw PiSidecarError.unexpectedResponse(response.type)
        }
        return result
    }

    public func shutdown(timeout: TimeInterval? = nil) async throws {
        guard isRunning else {
            cleanUpProcess(terminalError: nil, terminateIfRunning: false)
            return
        }

        do {
            let response = try await send(.shutdown(), timeout: timeout, startIfNeeded: false)
            guard response.type == .result || response.type == .ready else {
                throw PiSidecarError.unexpectedResponse(response.type)
            }
            cleanUpProcess(terminalError: nil, terminateIfRunning: true)
        } catch {
            cleanUpProcess(terminalError: error, terminateIfRunning: true)
            throw error
        }
    }

    public func stopImmediately() {
        cleanUpProcess(terminalError: nil, terminateIfRunning: true)
    }

    private static func isSafeHistory(_ records: [PiContextRecord]) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            records.allSatisfy { $0.context.isSafeForPi }
        }.value
    }

    private func send(
        _ request: PiRequestEnvelope,
        timeout: TimeInterval?,
        startIfNeeded: Bool
    ) async throws -> PiResponse {
        if startIfNeeded {
            try start()
        }
        guard isRunning, let standardInputHandle else {
            throw PiSidecarError.processUnavailable
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var encoded = try encoder.encode(request)
        encoded.append(0x0A)

        let requestTimeout = max(0.05, timeout ?? configuration?.requestTimeout ?? 15)
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { @MainActor [weak self] in
                let nanoseconds = UInt64(min(requestTimeout, 86_400) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self?.failPendingRequest(
                    id: request.id,
                    error: PiSidecarError.requestTimedOut(request.id)
                )
            }
            pendingRequests[request.id] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            do {
                try standardInputHandle.write(contentsOf: encoded)
            } catch {
                failPendingRequest(id: request.id, error: error)
            }
        }
    }

    private func consumeStandardOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        outputBuffer.append(data)
        guard outputBuffer.count <= Self.maximumBufferedOutputBytes else {
            let error = PiSidecarError.malformedResponse("line exceeded 2 MiB")
            state = .failed(error.localizedDescription)
            cleanUpProcess(terminalError: error, terminateIfRunning: true)
            return
        }

        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            var line = Data(outputBuffer[..<newlineIndex])
            outputBuffer.removeSubrange(...newlineIndex)
            if line.last == 0x0D {
                line.removeLast()
            }
            guard !line.isEmpty else { continue }
            decodeResponseLine(line)
        }
    }

    private func consumeStandardError(_ data: Data) {
        guard !data.isEmpty else { return }
        standardErrorBuffer.append(data)
        if standardErrorBuffer.count > Self.maximumStandardErrorBytes {
            standardErrorBuffer.removeFirst(
                standardErrorBuffer.count - Self.maximumStandardErrorBytes
            )
        }
    }

    private func decodeResponseLine(_ line: Data) {
        do {
            let response = try JSONDecoder().decode(PiResponse.self, from: line)
            handle(response)
        } catch {
            let protocolError = PiSidecarError.malformedResponse("invalid response")
            state = .failed(protocolError.localizedDescription)
            cleanUpProcess(terminalError: protocolError, terminateIfRunning: true)
        }
    }

    private func handle(_ response: PiResponse) {
        if case .event = response {
            onEvent?(response)
            return
        }

        guard let id = response.id, let pending = pendingRequests.removeValue(forKey: id) else {
            onEvent?(response)
            return
        }
        pending.timeoutTask.cancel()

        if case .error(_, let payload) = response {
            pending.continuation.resume(
                throwing: PiSidecarError.remote(
                    code: redactEnvironmentContent(in: payload.code),
                    message: redactEnvironmentContent(in: payload.message)
                )
            )
        } else {
            pending.continuation.resume(returning: response)
        }
    }

    private func failPendingRequest(id: UUID, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func handleProcessExit(status: Int32) {
        if !outputBuffer.isEmpty {
            let trailingLine = outputBuffer
            outputBuffer.removeAll(keepingCapacity: true)
            decodeResponseLine(trailingLine)
        }

        // stderr may contain provider diagnostics that repeat API keys or
        // injected environment values. It is intentionally never attached to
        // a public error or State value.
        let error = PiSidecarError.processExited(status: status, standardError: "")
        if status == 0 && pendingRequests.isEmpty {
            cleanUpProcess(terminalError: nil, terminateIfRunning: false)
        } else {
            state = .failed(error.localizedDescription)
            cleanUpProcess(terminalError: error, terminateIfRunning: false)
        }
    }

    private func cleanUpProcess(terminalError: Error?, terminateIfRunning: Bool) {
        let activeProcess = process
        activeProcess?.terminationHandler = nil
        standardOutputHandle?.readabilityHandler = nil
        standardErrorHandle?.readabilityHandler = nil

        if terminateIfRunning, activeProcess?.isRunning == true {
            activeProcess?.terminate()
        }

        try? standardInputHandle?.close()
        try? standardOutputHandle?.close()
        try? standardErrorHandle?.close()
        process = nil
        standardInputHandle = nil
        standardOutputHandle = nil
        standardErrorHandle = nil
        outputBuffer.removeAll(keepingCapacity: false)
        standardErrorBuffer.removeAll(keepingCapacity: false)

        let pending = pendingRequests
        pendingRequests.removeAll()
        for request in pending.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: terminalError ?? PiSidecarError.processUnavailable)
        }

        if let terminalError {
            state = .failed(terminalError.localizedDescription)
        } else {
            state = .stopped
        }
    }

    private static func validate(budget: PiWakeBudget) throws {
        guard (128...16_000).contains(budget.maxTokens) else {
            throw PiSidecarError.invalidBudget("maxTokens must be between 128 and 16000")
        }
        guard (1...12).contains(budget.maxTurns) else {
            throw PiSidecarError.invalidBudget("maxTurns must be between 1 and 12")
        }
        guard (500...60_000).contains(budget.maxDurationMs) else {
            throw PiSidecarError.invalidBudget("maxDurationMs must be between 500 and 60000")
        }
    }

    private static func areValidEnvironmentOverrides(_ overrides: [String: String]) -> Bool {
        overrides.allSatisfy { key, value in
            !key.isEmpty &&
                !key.contains("=") &&
                !key.unicodeScalars.contains(where: { $0.value == 0 }) &&
                !value.unicodeScalars.contains(where: { $0.value == 0 })
        }
    }

    private func redactEnvironmentContent(in text: String?) -> String? {
        text.map(redactEnvironmentContent(in:))
    }

    private func redactEnvironmentContent(in text: String) -> String {
        let protectedFragments = (configuration?.environment ?? [:])
            .merging(environmentOverrides, uniquingKeysWith: { _, override in override })
            .flatMap { [$0.key, $0.value] }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        return protectedFragments.reduce(text) { redacted, fragment in
            redacted.replacingOccurrences(of: fragment, with: "[redacted]")
        }
    }

    private static func isSafeForPi(_ memory: PiRecentMemory) -> Bool {
        let normalized = "\(memory.summary) \(memory.tags.joined(separator: " "))".lowercased()
        let blockedTags: Set<String> = [
            "password", "passcode", "credential", "credentials",
            "payment", "checkout", "otp", "verification-code"
        ]
        let normalizedTags = Set(memory.tags.map {
            $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        })
        guard normalizedTags.isDisjoint(with: blockedTags) else { return false }
        let protectedTerms = [
            "1password", "bitwarden", "keepass", "支付密码",
            "银行卡支付", "bank login", "网银"
        ]
        guard !protectedTerms.contains(where: { normalized.contains($0) }) else {
            return false
        }
        let patterns = [
            #"(?i)\b(?:sk|pk|rk|ak)[-_][A-Za-z0-9_-]{16,}\b"#,
            #"(?i)\bAIza[0-9A-Za-z_-]{20,}\b"#,
            #"(?i)\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}\b"#,
            #"(?i)(?:api[_ -]?key|access[_ -]?token|secret|密钥)\s*[:=：]\s*[^\s]{8,}"#,
            #"(?i)(?:password|密码)\s*[:=：]\s*[^\s]{4,}"#,
            #"(?i)(?:银行卡号|card number)\D{0,8}\d{6,19}"#,
            #"(?i)(?:验证码|one[ -]?time code|\botp\b)\D{0,12}\d{4,8}\b"#,
            #"\b[0-9a-fA-F]{32,}\b"#
        ]
        return !patterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }
}
