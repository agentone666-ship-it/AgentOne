import AgentOneCore
import AgentOneModelRuntime
import Foundation

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

private final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        capturedRequests = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        Self.lock.lock()
        Self.capturedRequests.append(captured)
        Self.lock.unlock()

        let analysis = """
        {
          "activity_title": "阅读 Transformer 论文中的多头注意力章节",
          "summary": "用户正在阅读《Attention Is All You Need》中自注意力与多头注意力机制，并选中了缩放点积注意力的定义。",
          "observation": "他在围绕注意力机制连续阅读，没有迹象表明已经偏离论文任务。",
          "hypothesis": "他可能正在为自己的论文整理 Transformer 的核心概念。",
          "considered_action": "先保持安静，等他完成这一段后再提供概念对照。",
          "why": "连续滚动和选中文本都与当前论文主题一致，打断的收益较低。",
          "tags": ["transformer", "attention", "paper"],
          "evidence_title": "缩放点积注意力定义",
          "evidence_summary": "选中了 Scaled Dot-Product Attention 的关键定义。",
          "disposition": "heldBack",
          "uncertainty": 0.12
        }
        """
        let body = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": analysis]]]
        ])
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct AgentOneModelRuntimeHarness {
    static func main() async {
        do {
            try await run()
            print("AgentOne model-runtime interface validation passed")
            print("1. ✓ OpenAI-compatible request carried concrete Context and kept the API Key in the Authorization header only.")
            print("2. ✓ The semantic response decoded into a concrete activity plus a held-back Agent thought.")
            print("3. ✓ Sensitive Context was blocked before any network request.")
            print("4. ✓ Fenced JSON, invalid dispositions, field bounds, and tag deduplication were handled deterministically.")
            print("5. ✓ Daily Context digest JSON preserved concrete highlights, a personal LUMA note, and bounded proactive invitation copy.")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("AgentOne model-runtime interface validation failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        CapturingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let baseURL = try require(URL(string: "https://mock.agentone.test/v1"), "Could not create mock endpoint.")
        let client = OpenAICompatibleModelClient(
            configuration: .init(baseURL: baseURL, model: "mock-context-model", providerName: "mock-provider"),
            session: session
        )
        let apiKey = "interface-test-secret"
        let context = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Attention Is All You Need",
            windowIdentifier: "paper-window",
            url: URL(string: "https://arxiv.org/abs/1706.03762"),
            documentPath: "/Users/example/Papers/attention-is-all-you-need.pdf",
            contentSummary: "Scaled Dot-Product Attention computes the dot products of the query with all keys.",
            selectedText: "Multi-head attention allows the model to jointly attend to information from different representation subspaces.",
            submittedText: "回车时只记录当前输入框里的观点",
            screenText: "回车输入区域 OCR：\n回车时只记录当前输入框里的观点",
            semanticTags: ["paper", "research"]
        )
        let inference = try await client.infer(
            ModelInferenceRequest(
                purpose: "context_enrichment",
                systemPrompt: "Return one JSON object.",
                userPrompt: "用户持续滚动阅读。",
                context: context,
                allowsCloudProcessing: true
            ),
            apiKey: apiKey
        )

        let requests = CapturingURLProtocol.requests()
        try check(requests.count == 1, "Expected exactly one model request.")
        let request = requests[0]
        try check(request.url?.path == "/v1/chat/completions", "The client used the wrong Chat Completions path.")
        try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)", "Authorization header was missing.")
        let requestBody = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        try check(!requestBody.contains(apiKey), "The API Key leaked into the request body.")
        let requestObject = try require(
            try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any],
            "The request body was not valid JSON."
        )
        let messages = try require(requestObject["messages"] as? [[String: Any]], "The request body omitted messages.")
        let authorizedContextMessage = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        let marker = "[AgentOne authorized context]\n"
        let contextJSON = try require(
            authorizedContextMessage.range(of: marker).map { String(authorizedContextMessage[$0.upperBound...]) },
            "The user message omitted the authorized Context envelope."
        )
        let contextPayload = try require(
            try JSONSerialization.jsonObject(with: Data(contextJSON.utf8)) as? [String: Any],
            "The authorized Context envelope was not valid JSON."
        )
        try check(contextPayload["url"] as? String == "https://arxiv.org/abs/1706.03762", "The model request omitted the page URL.")
        try check(contextPayload["documentPath"] as? String == "/Users/example/Papers/attention-is-all-you-need.pdf", "The model request omitted the document path.")
        try check((contextPayload["contentSummary"] as? String)?.contains("Scaled Dot-Product Attention") == true, "The model request omitted visible page text.")
        try check((contextPayload["selectedText"] as? String)?.contains("Multi-head attention allows") == true, "The model request omitted selected text.")
        try check((contextPayload["screenText"] as? String)?.contains("回车输入区域 OCR") == true, "The model request omitted the Return input-region OCR marker.")
        try check((contextPayload["screenText"] as? String)?.contains("侧栏") != true, "The model request carried sidebar noise in screenText.")
        try check(Set(inference.sentContextFields).isSuperset(of: ["url", "documentPath", "contentSummary", "selectedText"]), "The audit field list omitted concrete Context fields.")

        let analysis = try require(ContextSemanticAnalyzer.decode(inference.text), "The production semantic decoder rejected valid model JSON.")
        try check(analysis.activityTitle.contains("Transformer"), "The decoded activity title was not concrete.")
        try check(analysis.disposition == .heldBack, "The Agent thought disposition was not preserved.")
        try check(analysis.consideredAction?.contains("保持安静") == true, "The Agent's considered-but-unspoken action was lost.")

        var sensitive = context
        sensitive.isSensitive = true
        do {
            _ = try await client.infer(
                ModelInferenceRequest(
                    purpose: "context_enrichment",
                    systemPrompt: "Never reached",
                    userPrompt: "Never reached",
                    context: sensitive,
                    allowsCloudProcessing: true
                ),
                apiKey: apiKey
            )
            throw HarnessFailure(description: "Sensitive Context unexpectedly reached the model client.")
        } catch ModelInferenceError.sensitiveContextBlocked {
            // Expected.
        }
        try check(CapturingURLProtocol.requests().count == 1, "Sensitive Context created a network request.")

        let longText = String(repeating: "很长的字段 ", count: 100)
        let fenced = """
        ```json
        {"summary":"\(longText)","observation":"观察","tags":["paper","paper","attention"],"disposition":"not-valid","uncertainty":4}
        ```
        """
        let bounded = try require(ContextSemanticAnalyzer.decode(fenced), "Fenced JSON was not decoded.")
        try check(bounded.summary.count <= 240, "Summary length bound failed.")
        try check(Set(bounded.tags).count == bounded.tags.count, "Tags were not deduplicated.")
        try check(bounded.disposition == .observationOnly, "Invalid disposition did not fall back safely.")
        try check(bounded.uncertainty == 1, "Uncertainty was not clamped.")
        try check(ContextSemanticAnalyzer.decode("{\"observation\":\"missing summary\"}") == nil, "Missing summary should fail decoding.")

        let digestJSON = """
        {
          "headline": "把三条散线拧成一根",
          "overview": "今天围绕日记总结、主动陪伴和 LUMA 个性继续推进。",
          "highlights": ["要求日记提炼具体 Context", "要求 Agent 在合适时机主动出现"],
          "rhythm": "从可见缺口一路追到运行机制。",
          "unfinished_thread": "继续验证真实浮窗触达。",
          "agent_note": "我记住了你不接受只有壳子的功能；这次追问仍然在守同一个方向。",
          "invitation": "我把今天的三条散线串好了，要看两分钟吗？",
          "mood": "thoughtful"
        }
        """
        let digest = try require(
            DailyContextDigestAnalyzer.decode(digestJSON),
            "The daily Context digest decoder rejected valid JSON."
        )
        try check(digest.highlights.count == 2, "Daily digest highlights were lost.")
        try check(digest.agentNote.contains("不接受只有壳子"), "The personalized LUMA note was lost.")
        try check(digest.invitation?.contains("两分钟") == true, "The proactive invitation was lost.")
        let digestPrompt = DailyContextDigestAnalyzer.userPrompt(
            day: "2026-08-04",
            contextMemories: ["要求把 Context 提炼成日记"],
            personalMemories: ["用户不接受只做冒烟演示"]
        )
        try check(digestPrompt.contains("Context 提炼成日记"), "Daily Context was omitted from the digest prompt.")
        try check(digestPrompt.contains("不接受只做冒烟演示"), "Relationship memory was omitted from the digest prompt.")

        CapturingURLProtocol.reset()
        let localClient = OpenAICompatibleModelClient(
            configuration: .init(
                baseURL: baseURL,
                model: "llama3.2:3b",
                providerName: "ollama",
                route: .local,
                requiresAPIKey: false,
                enforcesResourcePolicy: false
            ),
            session: session
        )
        _ = try await localClient.infer(
            ModelInferenceRequest(
                purpose: "local_context_enrichment",
                systemPrompt: "Return one JSON object.",
                userPrompt: "只在本机分析。",
                context: context,
                allowsCloudProcessing: false
            ),
            apiKey: ""
        )
        let localRequest = try require(CapturingURLProtocol.requests().first, "Local inference did not reach the configured endpoint.")
        try check(localRequest.value(forHTTPHeaderField: "Authorization") == nil, "Local inference unexpectedly sent an Authorization header.")

        let safeSnapshot = LocalInferenceResourceSnapshot(
            memoryPressureLevel: 1,
            availableMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
            compressedMemoryBytes: 512 * 1_024 * 1_024,
            swapUsedBytes: 0,
            physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
            oneMinuteLoadAverage: 2,
            logicalProcessorCount: 10,
            thermalState: 0,
            isLowPowerModeEnabled: false
        )
        try check(
            LocalInferenceResourcePolicy.evaluate(
                snapshot: safeSnapshot,
                secondsSinceLastInteraction: 20,
                minimumIdleSeconds: 8,
                userInitiated: false
            ).canRun,
            "A safe, idle Mac was incorrectly blocked from local inference."
        )
        var pressuredSnapshot = safeSnapshot
        pressuredSnapshot.memoryPressureLevel = 2
        try check(
            LocalInferenceResourcePolicy.evaluate(
                snapshot: pressuredSnapshot,
                secondsSinceLastInteraction: 20,
                minimumIdleSeconds: 8,
                userInitiated: false
            ).reason == .memoryPressure,
            "Memory pressure did not hard-block local inference."
        )
        var compressedSnapshot = safeSnapshot
        compressedSnapshot.compressedMemoryBytes = 5 * 1_024 * 1_024 * 1_024
        try check(
            LocalInferenceResourcePolicy.evaluate(
                snapshot: compressedSnapshot,
                secondsSinceLastInteraction: 20,
                minimumIdleSeconds: 8,
                userInitiated: false
            ).reason == .memoryCompression,
            "Heavy memory compression did not hard-block local inference."
        )
        var swappedSnapshot = safeSnapshot
        swappedSnapshot.swapUsedBytes = 5 * 1_024 * 1_024 * 1_024
        try check(
            LocalInferenceResourcePolicy.evaluate(
                snapshot: swappedSnapshot,
                secondsSinceLastInteraction: 20,
                minimumIdleSeconds: 8,
                userInitiated: false
            ).reason == .swapUsage,
            "Heavy swap usage did not hard-block local inference."
        )
        try check(
            LocalInferenceResourcePolicy.evaluate(
                snapshot: safeSnapshot,
                secondsSinceLastInteraction: 2,
                minimumIdleSeconds: 8,
                userInitiated: false
            ).reason == .foregroundActivity,
            "Foreground activity did not defer background local inference."
        )
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessFailure(description: message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw HarnessFailure(description: message) }
        return value
    }
}
