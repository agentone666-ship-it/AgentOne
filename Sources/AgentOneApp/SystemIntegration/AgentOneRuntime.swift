import AppKit
import Foundation
import AgentOneCore
import AgentOneModelRuntime
import AgentOnePiRuntime

@MainActor
final class AgentOneRuntime: ObservableObject {
    private struct InputFocusHint: Sendable {
        let point: CGPoint
        let bundleIdentifier: String?
        let capturedAt: Date
    }

    private struct DeferredContextAnalysis: Sendable {
        let event: ActivityEvent
        let analysisKey: String
    }

    private enum ReturnInputAnchorSource: String, Sendable {
        case typingBurst = "typing_burst"
        case retainedSession = "retained_session"
        case recentClick = "recent_click"
        case axFocus = "ax_focus"
        case none
    }

    let shellModel = AgentOneShellViewModel()
    let companion = FloatingCompanionController()
    let systemMonitor = SystemSignalMonitor()
    let piSidecar = PiSidecarBridge()
    // Interactive chat owns its process; capture/digest cancellation must never stop it.
    let chatSidecar = PiSidecarBridge()
    private var activeChatRequestID: UUID?

    private(set) var engine: ContextMemoryEngine?
    private var configuredDiaryURL: URL?
    private var hasStarted = false
    private var lastEventID: UUID?
    private var recordingTask: Task<Void, Never>?
    private var piWakeTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var eventPreparationTask: Task<Void, Never>?
    private var contextAnalysisTask: Task<Void, Never>?
    private var contextAnalysisID: UUID?
    private var activeContextAnalysis: DeferredContextAnalysis?
    private var deferredContextAnalysis: DeferredContextAnalysis?
    private var dailyDigestTask: Task<Void, Never>?
    private var dailyDigestTaskID: UUID?
    private var proactiveTimer: Timer?
    private var leisureContextKey: String?
    private var leisureContextStartedAt: Date?
    private var chatContextSnapshot: ActivityContext?
    private var runtimeGeneration = UUID()
    private var processedPiWakeEventIDs: Set<UUID> = []
    private var lastPiWakeAtByKey: [String: Date] = [:]
    private var cachedReadingContext: ActiveApplicationContext?
    private var cachedDraftContext: ActiveApplicationContext?
    /// The last click that preceded a typing burst. Some Electron/web apps
    /// expose the whole chat surface as the focused AX element, so this point
    /// is the only reliable focus anchor available at Return time.
    private var lastPrimaryClickHint: InputFocusHint?
    private var cachedDraftInputHint: InputFocusHint?
    private var cachedDraftInputAnchorSource: ReturnInputAnchorSource?
    private var retainedInputSessionAnchor: ReturnInputSessionAnchor?
    private let preReturnInputEvidenceBuffer = PreReturnInputEvidenceBuffer()
    private var lastExternalChatContext: ActiveApplicationContext?
    private var isIgnoringAgentOneContext = false
    private var modelAuditStore = ModelInvocationAuditStore(rootURL: AgentHomePreferences.rootURL)
    private var returnCaptureDiagnosticStore = ReturnCaptureDiagnosticStore(
        rootURL: AgentHomePreferences.rootURL
    )
    private let contextSemanticAnalyzer = ContextSemanticAnalyzer()
    private let dailyContextDigestAnalyzer = DailyContextDigestAnalyzer()
    private let proactivePolicy = ProactiveCompanionPolicy()
    private let companionPreferences = CompanionPreferences()
    private var lastSemanticAnalysisAtByKey: [String: Date] = [:]
    private let readingContextRefreshInterval: TimeInterval = 60
    private let chatContextCarryoverInterval: TimeInterval = 15 * 60
    private static let ownBundleIdentifier = "life.agentone.desktop"

    init() {
        if DocumentationDemo.isEnabled {
            DocumentationDemo.configure(shellModel)
            return
        }

        let diaryURL = AgentHomePreferences.diaryURL
        do {
            let diary = try AppendOnlyDiary(homeURL: diaryURL)
            engine = ContextMemoryEngine(diary: diary)
            configuredDiaryURL = diaryURL
        } catch {
            // The UI still runs with its bundled semantic replay if the chosen
            // Agent Home is temporarily unavailable.
            engine = nil
        }

        companion.chat.observeVisibility { [weak self] isOpen in
            guard let self else { return }
            self.shellModel.isConversationMode = isOpen
            if isOpen {
                self.refreshChatContextSnapshot()
            }
        }
        companion.chat.onSend = { [weak self] request in
            self?.sendChat(request)
        }
        companion.chat.onCancel = { [weak self] requestID in
            self?.cancelChat(requestID: requestID)
        }
    }

    func start() {
        guard !DocumentationDemo.isEnabled else { return }
        guard !hasStarted else { return }
        configureEngineForCurrentAgentHome()
        AgentOneRuntimeHealthStore.shared.refreshFromDisk()
        runtimeGeneration = UUID()
        processedPiWakeEventIDs.removeAll(keepingCapacity: true)
        lastPiWakeAtByKey.removeAll(keepingCapacity: true)
        cachedReadingContext = nil
        cachedDraftContext = nil
        lastPrimaryClickHint = nil
        cachedDraftInputHint = nil
        cachedDraftInputAnchorSource = nil
        retainedInputSessionAnchor = nil
        preReturnInputEvidenceBuffer.clear()
        lastExternalChatContext = nil
        isIgnoringAgentOneContext = false
        hasStarted = true
        companion.show()
        companion.life.currentTaskName = shellModel.currentIntent.title

        systemMonitor.onSignal = { [weak self] signal in
            self?.record(signal, immediateInputContext: Self.immediateInputContext(for: signal))
        }
        systemMonitor.start()
        proactiveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runCompanionMaintenance()
            }
        }

        if let engine {
            let priorRecording = recordingTask
            recordingTask = Task { [weak self] in
                await priorRecording?.value
                await engine.restorePersistedSkills()
                let replays = await engine.allReplays()
                let habits = await engine.habitContexts()
                let skills = await engine.persistedSkills()
                self?.shellModel.consumePersistedLibrary(replays, habits: habits, skills: skills)
                AgentOneRuntimeHealthStore.shared.refreshFromDisk()
                self?.runCompanionMaintenance()
            }
        }
    }

    func stop() {
        runtimeGeneration = UUID()
        piWakeTask?.cancel()
        piWakeTask = nil
        chatTask?.cancel()
        chatTask = nil
        activeChatRequestID = nil
        chatSidecar.stopImmediately()
        eventPreparationTask?.cancel()
        eventPreparationTask = nil
        contextAnalysisTask?.cancel()
        contextAnalysisTask = nil
        contextAnalysisID = nil
        activeContextAnalysis = nil
        deferredContextAnalysis = nil
        dailyDigestTask?.cancel()
        dailyDigestTask = nil
        dailyDigestTaskID = nil
        proactiveTimer?.invalidate()
        proactiveTimer = nil
        leisureContextKey = nil
        leisureContextStartedAt = nil
        systemMonitor.stop()
        preReturnInputEvidenceBuffer.clear()
        piSidecar.stopImmediately()
        companion.stop()
        hasStarted = false
        if let engine {
            let priorRecording = recordingTask
            recordingTask = Task {
                await priorRecording?.value
                do {
                    let appended = try await engine.flushPendingActivity(reason: .runtimeStopped)
                    if !appended.isEmpty {
                        AgentOneRuntimeHealthStore.shared.markDiaryPersisted()
                    }
                } catch {
                    AgentOneRuntimeHealthStore.shared.markDiaryPersistenceFailed(
                        Self.persistenceErrorCode(error)
                    )
                }
            }
        }
    }

    private func refreshChatContextSnapshot() {
        let foreground = ActiveContextReader.read()
        let active: ActiveApplicationContext?
        if foreground?.bundleIdentifier?.lowercased() == Self.ownBundleIdentifier {
            active = lastExternalChatContext.flatMap {
                Date().timeIntervalSince($0.capturedAt) <= chatContextCarryoverInterval ? $0 : nil
            }
        } else {
            active = foreground
        }

        guard let active else {
            chatContextSnapshot = nil
            companion.chat.updateContextAvailability(label: nil, isSensitive: false)
            return
        }
        let sensitive = active.isSecureInput || Self.isNeverCollectContext(
            bundleIdentifier: active.bundleIdentifier,
            windowTitle: active.windowTitle
        )
        let context = ActivityContext(
            applicationName: active.applicationName,
            bundleIdentifier: active.bundleIdentifier,
            windowTitle: sensitive ? nil : active.windowTitle,
            windowIdentifier: sensitive ? nil : active.windowIdentifier,
            url: sensitive ? nil : active.url,
            documentPath: sensitive ? nil : active.documentPath,
            contentSummary: sensitive ? nil : Self.boundedContextText(
                active.focusedText ?? active.visibleText,
                limit: 6_000
            ),
            selectedText: sensitive ? nil : active.selectedText,
            semanticTags: Self.semanticTags(
                application: active.applicationName,
                title: sensitive ? nil : active.windowTitle
            ),
            isSensitive: sensitive
        )
        chatContextSnapshot = context
        let label = [active.applicationName, sensitive ? nil : active.windowTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        companion.chat.updateContextAvailability(
            label: label.isEmpty ? nil : String(label.prefix(120)),
            isSensitive: sensitive
        )
    }

    private func sendChat(_ request: AgentChatSendRequest) {
        chatTask?.cancel()
        piWakeTask?.cancel()
        piWakeTask = nil
        invalidatePendingPiReminder()
        chatSidecar.stopImmediately()

        activeChatRequestID = request.id
        let context = request.includeCurrentContext ? chatContextSnapshot : nil
        let contextLabel = request.includeCurrentContext ? companion.chat.contextLabel : nil
        companion.life.transition(to: .thinking)
        chatTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeChatRequestID == request.id {
                    self.activeChatRequestID = nil
                    self.chatTask = nil
                }
            }
            let route = await self.currentPiModelRoute()
            let memory = await self.chatMemory()
            do {
                let result = try await self.runPiChat(
                    request,
                    context: context,
                    memory: memory,
                    environment: route.environment
                )
                guard !Task.isCancelled else { return }
                self.companion.chat.receive(
                    result.spokenText ?? "我在，只是这次没有顺利组织出回答。",
                    for: request.id,
                    contextLabel: contextLabel
                )
                self.companion.life.transition(to: .curious)
                await self.recordChatInvocation(
                    route: route,
                    result: result,
                    usedContext: context,
                    error: nil
                )
            } catch {
                guard !Task.isCancelled else { return }
                let finalError: Error = error

                let message: String
                switch finalError {
                case PiSidecarError.sensitiveContext:
                    message = "这段内容碰到了隐私边界，我没有把它交给模型。你可以关掉「引用此刻」再问我。"
                case PiSidecarError.requestTimedOut:
                    message = "我想得有点久，被自己的口粮钟叫停了。再试一次，或者把问题说短一点。"
                case ModelInferenceError.sensitiveContextBlocked:
                    message = "这段内容碰到了隐私边界，我没有把它交给模型。你可以关掉「引用此刻」再问我。"
                case let modelError as ModelInferenceError:
                    message = "模型连接没有完成：\(modelError.localizedDescription)"
                case PiSidecarError.processUnavailable:
                    message = "聊天进程被中断了，请重试。这不是云端凭证或连接测试失败。"
                case PiSidecarError.remote(_, let detail):
                    message = "模型请求没有完成：\(detail)"
                default:
                    if route.usesCloud {
                        message = "云端模型这次没有接通。我没有泄露你的凭证或 Context；可以到模型设置里检查连接。"
                    } else if route.usesModel {
                        message = "本地模型这次没有醒来。可以到模型设置里检查 Ollama 和本地模型状态。"
                    } else {
                        message = "我现在还没有模型口粮，但我在。你可以先把想法放在这里。"
                    }
                }
                self.companion.chat.receiveError(message, for: request.id)
                self.companion.life.transition(to: .curious)
                await self.recordChatInvocation(
                    route: route,
                    result: nil,
                    usedContext: context,
                    error: finalError
                )
            }
        }
    }

    private func cancelChat(requestID: UUID) {
        guard activeChatRequestID == requestID else { return }
        activeChatRequestID = nil
        chatTask?.cancel()
        chatTask = nil
        chatSidecar.stopImmediately()
        companion.life.transition(to: .curious)
    }

    private func runPiChat(
        _ request: AgentChatSendRequest,
        context: ActivityContext?,
        memory: [PiRecentMemory],
        environment: [String: String]
    ) async throws -> PiResultPayload {
        try Task.checkCancellation()
        let history = await contextToolHistory()
        try Task.checkCancellation()
        try chatSidecar.updateEnvironmentOverrides(environment)
        _ = try await chatSidecar.health(timeout: 3)
        try Task.checkCancellation()
        return try await chatSidecar.chat(
            messages: request.history.compactMap { message in
                guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return PiChatMessage(
                    role: message.role == .user ? .user : .assistant,
                    content: String(message.content.prefix(8_000))
                )
            },
            sanitizedContext: context.flatMap(Self.piChatContext),
            recentMemory: memory,
            contextHistory: history,
            maxTokens: 12_000,
            maxDurationMs: 30_000,
            timeout: 35
        )
    }

    private func chatMemory() async -> [PiRecentMemory] {
        guard let engine else { return [] }
        let replay = await engine.replay(for: Date())
        return replay.moments
            .filter { !$0.isHidden && $0.kind != .evidence }
            .suffix(12)
            .compactMap { moment -> PiRecentMemory? in
                let summary = [moment.title, moment.detail]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " — ")
                guard !summary.isEmpty else { return nil }
                let memory = PiRecentMemory(
                    id: moment.sourceEntryID.uuidString,
                    timestamp: Self.iso8601String(from: moment.timestamp),
                    kind: moment.kind.rawValue,
                    summary: String(summary.prefix(600)),
                    tags: [moment.lane.rawValue, moment.kind.rawValue]
                )
                return Self.isSafeChatMemory(memory) ? memory : nil
            }
    }

    private func contextToolHistory() async -> [PiContextRecord] {
        guard let engine else { return [] }
        let entries = await engine.diary.allEntries()
        return await Task.detached(priority: .userInitiated) {
            PiContextHistory.records(from: entries).filter { record in
                let context = record.context
                let text = [context.applicationName, context.windowTitle, context.url, context.documentPath,
                    context.contentSummary, context.screenText, context.submittedText, context.selectedText,
                    context.interactionTarget, context.contextTransition, context.semanticTags.joined(separator: " ")]
                    .compactMap { $0 }.joined(separator: "\n")
                return !SensitiveContextPolicy.isProtectedSurface(
                    bundleIdentifier: context.bundleIdentifier, windowTitle: text
                ) && !SensitiveContextPolicy.containsActualSecret(text)
            }
        }.value
    }

    private static func piChatContext(_ context: ActivityContext) -> PiSanitizedContext? {
        guard !context.isSensitive else { return nil }
        let value = PiSanitizedContext(
            capturedAt: Self.iso8601String(from: Date()),
            applicationName: context.applicationName.map { String($0.prefix(160)) },
            bundleIdentifier: context.bundleIdentifier.map { String($0.prefix(200)) },
            windowTitle: context.windowTitle.map { String($0.prefix(400)) },
            url: context.url?.absoluteString.prefix(1_500).description,
            documentPath: context.documentPath.map { String($0.prefix(1_500)) },
            contentSummary: context.contentSummary.map { String($0.prefix(8_000)) },
            selectedText: context.selectedText.map { String($0.prefix(1_500)) },
            submittedText: context.submittedText.map { String($0.prefix(8_000)) },
            screenText: context.screenText.map { String($0.prefix(8_000)) },
            interactionTarget: context.interactionTarget.map { String($0.prefix(600)) },
            contextTransition: context.contextTransition.map { String($0.prefix(1_000)) },
            semanticTags: Array(context.semanticTags.sorted().prefix(32)),
            isSensitive: false
        )
        return value.isSafeForPi ? value : nil
    }

    private static func isSafeChatMemory(_ memory: PiRecentMemory) -> Bool {
        let text = "\(memory.kind) \(memory.summary) \(memory.tags.joined(separator: " "))"
        return !SensitiveContextPolicy.isProtectedSurface(
            bundleIdentifier: nil,
            windowTitle: text
        ) && !SensitiveContextPolicy.containsActualSecret(text)
    }

    private func recordChatInvocation(
        route: PiModelRoute,
        result: PiResultPayload?,
        compatibleResult: ModelInferenceResult? = nil,
        usedContext: ActivityContext?,
        fallback: String? = nil,
        error: Error?
    ) async {
        guard route.usesModel, AgentModelSettings.shared.auditsCloudInvocations else { return }
        let usage = result.map {
            ModelInvocationAudit.Usage(
                inputTokens: $0.usage.inputTokens,
                outputTokens: $0.usage.outputTokens,
                totalTokens: $0.usage.totalTokens,
                turns: $0.usage.turns,
                toolCalls: $0.usage.toolCalls,
                durationMs: $0.usage.durationMs
            )
        }
        let audit = ModelInvocationAudit(
            timestamp: Date(),
            purpose: "user_chat",
            route: route.inferenceRoute,
            provider: result?.model?.provider ?? compatibleResult?.provider ?? route.provider,
            model: result?.model?.model ?? compatibleResult?.model ?? route.model,
            sentContextFields: Self.sentContextFields(in: usedContext),
            usage: usage,
            succeeded: (result != nil || compatibleResult != nil) && error == nil,
            fallback: fallback,
            errorCode: Self.modelErrorCode(error)
        )
        try? await modelAuditStore.append(audit)
    }

    func markCurrentDetourAsRelated() {
        guard let engine, let lastEventID else { return }
        invalidatePendingPiReminder()
        Task { [weak self] in
            _ = try? await engine.addFeedback(
                UserFeedback(kind: .eventWasRelated, eventID: lastEventID)
            )
            await self?.refreshPersistedLibrary(for: Date())
        }
        companion.life.settle()
    }

    func markCurrentDetourAsDistraction() {
        guard let engine, let lastEventID else { return }
        Task { [weak self] in
            _ = try? await engine.addFeedback(
                UserFeedback(kind: .eventWasDistraction, eventID: lastEventID)
            )
            await self?.refreshPersistedLibrary(for: Date())
        }
    }

    /// Refreshes the local read model after an action that may have appended a
    /// feedback, Skill, or other durable memory fact. This runs without any
    /// network call and keeps the UI current without an app restart.
    private func refreshPersistedLibrary(for date: Date? = nil) async {
        guard let engine else { return }
        let replays = await engine.allReplays()
        let habits = await engine.habitContexts()
        let skills = await engine.persistedSkills()
        shellModel.consumePersistedLibrary(replays, habits: habits, skills: skills)
        if let date {
            let day = await engine.diary.dayKey(for: date)
            if shellModel.persistedReplaysByDay[day] != nil {
                shellModel.selectReplayDay(day)
            }
        }
    }

    private func record(
        _ signal: SystemActivitySignal,
        immediateInputContext: ActiveApplicationContext? = nil
    ) {
        if signal.kind == .applicationChanged {
            cachedDraftContext = nil
            cachedDraftInputHint = nil
            cachedDraftInputAnchorSource = nil
            retainedInputSessionAnchor = nil
            lastPrimaryClickHint = nil
            preReturnInputEvidenceBuffer.clear()
        }

        if signal.kind == .primaryClick,
           let point = Self.screenPoint(from: signal.metadata) {
            // A click starts a new focus hypothesis. Invalidate the previous
            // composer immediately so a click on a WeChat/Feishu conversation
            // row cannot inherit the last input box for the next Return.
            cachedDraftContext = nil
            cachedDraftInputHint = nil
            cachedDraftInputAnchorSource = nil
            retainedInputSessionAnchor = nil
            preReturnInputEvidenceBuffer.clear()
            lastPrimaryClickHint = InputFocusHint(
                point: CGPoint(x: point.x, y: point.y),
                bundleIdentifier: signal.bundleIdentifier,
                capturedAt: signal.timestamp
            )
            // Prime the in-memory frame stream from the click that activated
            // the composer. This covers very short submissions whose first key
            // and Return arrive before a new ScreenCaptureKit stream could
            // otherwise deliver its first frame.
            if let active = ActiveContextReader.read(scope: .focusedElement),
               !active.isSecureInput,
               active.bundleIdentifier?.lowercased() != Self.ownBundleIdentifier,
               Self.clickSupportsInputContext(
                    CGPoint(x: point.x, y: point.y),
                    active: active
               ) {
                let profile = ReturnInputComposerProfile.resolve(
                    bundleIdentifier: active.bundleIdentifier,
                    applicationName: active.applicationName
                )
                preReturnInputEvidenceBuffer.update(
                    active: active,
                    interactionPoint: CGPoint(x: point.x, y: point.y),
                    profile: profile,
                    signalTimestamp: signal.timestamp,
                    startsNewSubmission: true
                )
            }
        }

        // Preserve the last pre-Return AX snapshot synchronously. The diary
        // preparation task is intentionally cancelled when Return arrives, so
        // caching this only inside that task loses short/fast submissions and
        // leaves OCR with a stale one- or two-character draft.
        if signal.kind == .typingStarted || signal.kind == .typingProgress {
            updateDraftCache(from: immediateInputContext, for: signal)
        }

        if signal.kind != .idle {
            pauseBackgroundLocalInferenceForLiveActivity()
        }

        // Return is latency-sensitive: the target app may clear its composer
        // as soon as it receives the key event. Freeze the newest frame whose
        // capture timestamp is no later than Return *before* creating any async
        // task. Reading `latest` later races the target app and can silently
        // replace the draft with an already-cleared, post-submit frame.
        if signal.kind == .returnPressed {
            let frozenPreReturnEvidence = preReturnInputEvidenceBuffer.evidence(
                at: signal.timestamp,
                bundleIdentifier: immediateInputContext?.bundleIdentifier
                    ?? cachedDraftContext?.bundleIdentifier
                    ?? signal.bundleIdentifier,
                windowIdentifier: immediateInputContext?.windowIdentifier
                    ?? cachedDraftContext?.windowIdentifier
            )
            preReturnInputEvidenceBuffer.finishSubmission()
            eventPreparationTask?.cancel()
            eventPreparationTask = Task { [weak self] in
                guard let self, self.hasStarted else { return }
                let event = await self.prepareReturnEvent(
                    from: signal,
                    immediateInputContext: immediateInputContext,
                    frozenPreReturnEvidence: frozenPreReturnEvidence
                )
                guard !Task.isCancelled else { return }
                self.recordPrepared(event, from: signal)
            }
            return
        }

        let priorPreparation = eventPreparationTask
        eventPreparationTask = Task { [weak self] in
            await priorPreparation?.value
            guard let self, !Task.isCancelled, self.hasStarted else { return }
            let event = await self.prepareActivityEvent(
                from: signal,
                immediateInputContext: immediateInputContext
            )
            guard !Task.isCancelled else { return }
            self.recordPrepared(event, from: signal)
        }
    }

    private func recordPrepared(
        _ event: ActivityEvent,
        from signal: SystemActivitySignal
    ) {
        guard let engine else { return }

        // Never let the diary observe its own UI. Otherwise scrolling Replay or
        // Memory creates another scroll entry, which redraws the UI and forms a
        // self-amplifying capture loop. Entering AgentOne still closes an
        // external reading session once, but its own interactions are ignored.
        if Self.isOwnContext(event.context) {
            cachedReadingContext = nil
            guard !isIgnoringAgentOneContext else { return }
            isIgnoringAgentOneContext = true
            let priorRecording = recordingTask
            recordingTask = Task { [weak self] in
                await priorRecording?.value
                guard let self else { return }
                do {
                    let appended = try await engine.flushPendingActivity(
                        at: signal.timestamp,
                        reason: .contextChanged
                    )
                    guard !appended.isEmpty else { return }
                    AgentOneRuntimeHealthStore.shared.markDiaryPersisted(at: signal.timestamp)
                    let replay = await engine.replay(for: signal.timestamp)
                    let habits = await engine.habitContexts()
                    self.shellModel.consumePersistedReplay(replay, habits: habits)
                } catch {
                    AgentOneRuntimeHealthStore.shared.markDiaryPersistenceFailed(
                        Self.persistenceErrorCode(error),
                        at: signal.timestamp
                    )
                }
            }
            return
        }

        isIgnoringAgentOneContext = false
        lastEventID = event.id
        let priorRecording = recordingTask

        recordingTask = Task { [weak self] in
            await priorRecording?.value
            guard let self else { return }
            do {
                let output = try await engine.record(event)
                // Raw hooks still feed intent and drift in real time, but a
                // continuous scroll does not mutate the diary. Rebuilding the
                // full-day Replay and Habit projection for every wheel delta is
                // both wasteful and, with a large legacy diary, visibly noisy.
                let diaryChanged = !output.appendedDiaryEntryIDs.isEmpty
                if diaryChanged {
                    AgentOneRuntimeHealthStore.shared.markDiaryPersisted(at: event.timestamp)
                }
                let replay = diaryChanged ? await engine.replay(for: event.timestamp) : nil
                let habits = diaryChanged ? await engine.habitContexts() : nil
                self.apply(output, event: event, replay: replay, habits: habits)
                self.scheduleContextAnalysis(for: event, engine: engine)
            } catch {
                AgentOneRuntimeHealthStore.shared.markDiaryPersistenceFailed(
                    Self.persistenceErrorCode(error),
                    at: event.timestamp
                )
            }
        }
    }

    private func prepareActivityEvent(
        from signal: SystemActivitySignal,
        immediateInputContext: ActiveApplicationContext? = nil
    ) async -> ActivityEvent {
        switch signal.kind {
        case .primaryClick:
            let before = ActiveContextReader.read()
            let point = Self.screenPoint(from: signal.metadata)
            let target = point.flatMap {
                ActiveContextReader.interactionTarget(at: CGPoint(x: $0.x, y: $0.y))?.summary
            }
            try? await Task.sleep(nanoseconds: 550_000_000)
            let after = ActiveContextReader.read()
            let transition = Self.describeContextTransition(
                from: before,
                to: after,
                target: target
            )
            var event = makeActivityEvent(
                from: signal,
                activeOverride: after ?? before,
                interactionTarget: target,
                contextTransition: transition
            )
            if transition != nil {
                event.semantics.insert(.navigation)
            }
            return event

        case .returnPressed:
            return await prepareReturnEvent(from: signal)

        case .typingStarted, .typingProgress:
            // Typing must remain invisible to the foreground app. Sampling only
            // the focused control avoids traversing hundreds of browser/WeChat
            // accessibility nodes while the user is composing text.
            let active = immediateInputContext ?? ActiveContextReader.read(scope: .focusedElement)
            return makeActivityEvent(from: signal, activeOverride: active)

        default:
            return makeActivityEvent(from: signal)
        }
    }

    private func prepareReturnEvent(
        from signal: SystemActivitySignal,
        immediateInputContext: ActiveApplicationContext? = nil,
        frozenPreReturnEvidence: PreReturnInputEvidence? = nil
    ) async -> ActivityEvent {
        // Capture the focused control first without a full AX-tree walk. A full
        // traversal here can stall the foreground app long enough for macOS key
        // repeat events to accumulate, and it also delays the screenshot until
        // after the composer has been cleared.
        let foreground = immediateInputContext ?? ActiveContextReader.read(scope: .focusedElement)
        let draft = cachedDraftContext.flatMap { cached -> ActiveApplicationContext? in
            guard signal.timestamp.timeIntervalSince(cached.capturedAt) <= 5 * 60 else { return nil }
            let signalBundle = foreground?.bundleIdentifier ?? signal.bundleIdentifier
            guard cached.bundleIdentifier == signalBundle || signalBundle == nil else { return nil }
            return cached
        }
        cachedDraftContext = nil
        let active = Self.richerActiveContext(draft, foreground) ?? foreground ?? draft
        let trustedForeground = foreground.flatMap { Self.isTrustedInputContext($0) ? $0 : nil }
        let captureContext = Self.richerActiveContext(draft, trustedForeground)
            ?? draft
            ?? trustedForeground
        let composerProfile = ReturnInputComposerProfile.resolve(
            bundleIdentifier: captureContext?.bundleIdentifier ?? active?.bundleIdentifier ?? signal.bundleIdentifier,
            applicationName: captureContext?.applicationName ?? active?.applicationName ?? signal.applicationName
        )
        let currentBundleIdentifier = captureContext?.bundleIdentifier
            ?? active?.bundleIdentifier
            ?? signal.bundleIdentifier
        let currentWindowIdentifier = captureContext?.windowIdentifier
            ?? active?.windowIdentifier
        let currentWindowFrame = captureContext?.windowFrame
            ?? active?.windowFrame
        let currentFocusedFrame = captureContext?.focusedFrame
            ?? active?.focusedFrame
        let currentCaretFrame = draft?.focusedCaretFrame
            ?? trustedForeground?.focusedCaretFrame
            ?? captureContext?.focusedCaretFrame
            ?? active?.focusedCaretFrame

        // The current typing burst is strongest. If it did not start with a
        // fresh click, reuse the composer location previously validated in the
        // same app/window. This is what keeps the second and third consecutive
        // WeChat, Codex and Feishu submissions anchored without forcing another
        // click into the input box.
        var anchorSource = cachedDraftInputAnchorSource ?? .none
        var interactionPoint: CGPoint? = cachedDraftInputHint.flatMap { hint -> CGPoint? in
            guard signal.timestamp.timeIntervalSince(hint.capturedAt) <= 30 else { return nil }
            guard hint.bundleIdentifier == nil
                || currentBundleIdentifier == nil
                || hint.bundleIdentifier == currentBundleIdentifier else { return nil }
            return hint.point
        }
        if interactionPoint == nil,
           let retainedInputSessionAnchor,
           let currentWindowFrame {
            interactionPoint = retainedInputSessionAnchor.resolvedPoint(
                bundleIdentifier: currentBundleIdentifier,
                windowIdentifier: currentWindowIdentifier,
                windowFrame: currentWindowFrame,
                focusedFrame: currentFocusedFrame,
                caretFrame: currentCaretFrame,
                profile: composerProfile,
                at: signal.timestamp
            )
            if interactionPoint != nil {
                anchorSource = .retainedSession
            }
        }
        if interactionPoint == nil,
           let recentClick = lastPrimaryClickHint,
           signal.timestamp.timeIntervalSince(recentClick.capturedAt) <= 15,
           recentClick.bundleIdentifier == nil
                || currentBundleIdentifier == nil
                || recentClick.bundleIdentifier == currentBundleIdentifier,
           let active,
           Self.clickSupportsInputContext(recentClick.point, active: active) {
            interactionPoint = recentClick.point
            anchorSource = .recentClick
            if let currentWindowFrame {
                retainedInputSessionAnchor = ReturnInputSessionAnchor(
                    point: recentClick.point,
                    bundleIdentifier: currentBundleIdentifier,
                    windowIdentifier: currentWindowIdentifier,
                    windowFrame: currentWindowFrame,
                    capturedAt: signal.timestamp
                )
            }
            lastPrimaryClickHint = nil
        }
        if interactionPoint == nil,
           anchorSource == .none,
           captureContext.map(Self.isTrustedInputContext) == true {
            anchorSource = .axFocus
        }
        cachedDraftInputHint = nil
        cachedDraftInputAnchorSource = nil
        let diagnosticBundleIdentifier = captureContext?.bundleIdentifier
            ?? active?.bundleIdentifier
            ?? signal.bundleIdentifier
        let diagnosticFocusedRole = captureContext?.focusedRole ?? active?.focusedRole
        let diagnosticFocusedFrame = captureContext?.focusedFrame
        let diagnosticCaretFrame = draft?.focusedCaretFrame
            ?? trustedForeground?.focusedCaretFrame
        let surfaceIsSensitive = active?.isSecureInput == true
            || SensitiveContextPolicy.isProtectedSurface(
                bundleIdentifier: active?.bundleIdentifier ?? signal.bundleIdentifier,
                windowTitle: active?.windowTitle,
                focusedRole: active?.focusedRole
            )

        guard !surfaceIsSensitive,
              active?.bundleIdentifier?.lowercased() != Self.ownBundleIdentifier else {
            try? await returnCaptureDiagnosticStore.append(.init(
                timestamp: signal.timestamp,
                profile: composerProfile,
                bundleIdentifier: diagnosticBundleIdentifier,
                focusedRole: diagnosticFocusedRole,
                focusedFrame: diagnosticFocusedFrame,
                caretFrame: diagnosticCaretFrame,
                interactionPoint: interactionPoint,
                anchorSource: anchorSource.rawValue,
                metadata: nil,
                submittedTextPresent: false,
                failureReason: surfaceIsSensitive ? "sensitive_surface" : "agentone_surface"
            ))
            return makeActivityEvent(from: signal, activeOverride: active, forceSensitive: surfaceIsSensitive)
        }

        let sampledSubmittedText = Self.focusedSubmittedText(from: captureContext)
        var submittedText = sampledSubmittedText
        var screenText: String?
        var screenshotPath: String?
        var evidencePhase = ReturnSubmissionEvidencePhase.postSubmission
        do {
            let capture: CapturedKeyMoment
            if let bufferedEvidence = frozenPreReturnEvidence {
                evidencePhase = .preSubmission
                let bufferedCapture = try WindowContextCapture.captureBufferedInputRegion(
                    bufferedEvidence.image,
                    windowFrame: bufferedEvidence.windowFrame,
                    region: bufferedEvidence.inputRegion,
                    referenceText: sampledSubmittedText,
                    profile: bufferedEvidence.profile
                )
                guard let bufferedCandidate = Self.meaningfulSubmittedText(
                    bufferedCapture.submittedTextCandidate
                        ?? bufferedCapture.recognizedText,
                    active: active
                ),
                ReturnSubmissionEvidenceSelector.supportsPreSubmissionEvidence(
                    evidenceText: bufferedCandidate,
                    referenceText: sampledSubmittedText
                ) else {
                    throw WindowContextCaptureError.noInputRegion(bufferedCapture.diagnosticMetadata)
                }
                capture = bufferedCapture
            } else {
                capture = try await WindowContextCapture.captureFrontmostWindow(
                    focusedFrame: captureContext?.focusedFrame,
                    caretFrame: draft?.focusedCaretFrame
                        ?? trustedForeground?.focusedCaretFrame,
                    referenceText: sampledSubmittedText,
                    interactionPoint: interactionPoint,
                    profile: composerProfile
                )
            }
            let inputRegionText = capture.recognizedText
            let screenSubmittedText = Self.meaningfulSubmittedText(
                capture.submittedTextCandidate,
                active: active
            )
            let preferredSubmittedDraft = ScreenshotTextExtraction.preferredSubmittedText(
                focusedRegionText: sampledSubmittedText,
                inferredSubmittedText: screenSubmittedText
            )
            submittedText = SubmittedTextReconciler.reconcile(
                draftText: preferredSubmittedDraft,
                screenText: inputRegionText
            )
            if SensitiveContextPolicy.containsActualSecret(
                sampledSubmittedText,
                submittedText,
                inputRegionText,
                active?.selectedText
            ) {
                AgentOneRuntimeHealthStore.shared.markScreenshotDiscardedSensitive(at: signal.timestamp)
                try? await returnCaptureDiagnosticStore.append(.init(
                    timestamp: signal.timestamp,
                    profile: composerProfile,
                    bundleIdentifier: diagnosticBundleIdentifier,
                    focusedRole: diagnosticFocusedRole,
                    focusedFrame: diagnosticFocusedFrame,
                    caretFrame: diagnosticCaretFrame,
                    interactionPoint: interactionPoint,
                    anchorSource: anchorSource.rawValue,
                    evidencePhase: evidencePhase.rawValue,
                    metadata: capture.diagnosticMetadata,
                    submittedTextPresent: false,
                    failureReason: "sensitive_content_discarded"
                ))
                return makeActivityEvent(
                    from: signal,
                    activeOverride: active,
                    forceSensitive: true
                )
            }
            screenText = ReturnInputCaptureContract.modelScreenText(
                from: inputRegionText,
                limit: 8_000
            )
            screenshotPath = try WindowContextCapture.persist(
                capture,
                under: AgentHomePreferences.rootURL,
                at: signal.timestamp
            )
            AgentOneRuntimeHealthStore.shared.markScreenshotCaptured(
                recognizedLineCount: capture.recognizedLineCount,
                fullScreenOCRLineCount: capture.fullScreenOCRLineCount,
                recognizedSubmittedText: submittedText != nil,
                source: capture.source,
                cropPixelWidth: capture.cropPixelWidth,
                cropPixelHeight: capture.cropPixelHeight,
                at: signal.timestamp
            )
            try? await returnCaptureDiagnosticStore.append(.init(
                timestamp: signal.timestamp,
                profile: composerProfile,
                bundleIdentifier: diagnosticBundleIdentifier,
                focusedRole: diagnosticFocusedRole,
                focusedFrame: diagnosticFocusedFrame,
                caretFrame: diagnosticCaretFrame,
                interactionPoint: interactionPoint,
                anchorSource: anchorSource.rawValue,
                evidencePhase: evidencePhase.rawValue,
                metadata: capture.diagnosticMetadata,
                submittedTextPresent: submittedText != nil,
                failureReason: nil
            ))
        } catch let captureError as WindowContextCaptureError {
            AgentOneRuntimeHealthStore.shared.markScreenshotUnavailable(
                reason: captureError.diagnosticReason,
                at: signal.timestamp
            )
            try? await returnCaptureDiagnosticStore.append(.init(
                timestamp: signal.timestamp,
                profile: composerProfile,
                bundleIdentifier: diagnosticBundleIdentifier,
                focusedRole: diagnosticFocusedRole,
                focusedFrame: diagnosticFocusedFrame,
                caretFrame: diagnosticCaretFrame,
                interactionPoint: interactionPoint,
                anchorSource: anchorSource.rawValue,
                evidencePhase: evidencePhase.rawValue,
                metadata: captureError.attemptMetadata,
                submittedTextPresent: submittedText != nil,
                failureReason: captureError.diagnosticReason
            ))
        } catch {
            AgentOneRuntimeHealthStore.shared.markScreenshotUnavailable(
                reason: "capture_failed",
                at: signal.timestamp
            )
            try? await returnCaptureDiagnosticStore.append(.init(
                timestamp: signal.timestamp,
                profile: composerProfile,
                bundleIdentifier: diagnosticBundleIdentifier,
                focusedRole: diagnosticFocusedRole,
                focusedFrame: diagnosticFocusedFrame,
                caretFrame: diagnosticCaretFrame,
                interactionPoint: interactionPoint,
                anchorSource: anchorSource.rawValue,
                evidencePhase: evidencePhase.rawValue,
                metadata: nil,
                submittedTextPresent: submittedText != nil,
                failureReason: "capture_failed"
            ))
        }

        return makeActivityEvent(
            from: signal,
            activeOverride: active,
            submittedText: submittedText,
            screenText: screenText,
            screenshotResourcePath: screenshotPath
        )
    }

    private func apply(
        _ output: ContextEngineOutput,
        event: ActivityEvent,
        replay: SemanticReplay?,
        habits: [HabitContext]?
    ) {
        shellModel.consumeRuntime(event: event, output: output, replay: replay, habits: habits)

        if let intent = output.activeIntent {
            companion.life.currentTaskName = intent.title
        }

        for prompt in output.prompts {
            switch prompt {
            case .curiousQuestion(let text):
                shellModel.mood = .curious
                companion.ask(text)
            case .reminder:
                if let replay,
                   let plan = PiWakePolicy.reminderPlan(
                    for: prompt,
                    event: event,
                    output: output,
                    replay: replay
                ) {
                    enqueuePiReminder(plan, engine: engine)
                } else {
                    applyNative(prompt, activeIntent: output.activeIntent)
                }
            case .returnedToIntent:
                invalidatePendingPiReminder()
                shellModel.mood = .delighted
                companion.life.celebrate()
            }
        }
    }

    private func enqueuePiReminder(
        _ plan: PiReminderWakePlan,
        engine: ContextMemoryEngine?
    ) {
        guard let engine else {
            applyNative(plan.nativeFallback, activeIntent: nil)
            return
        }
        guard !processedPiWakeEventIDs.contains(plan.eventID) else {
            applyNative(plan.nativeFallback, activeIntent: nil)
            return
        }

        let now = Date()
        if let lastWakeAt = lastPiWakeAtByKey[plan.deduplicationKey],
           now.timeIntervalSince(lastWakeAt) < 120 {
            applyNative(plan.nativeFallback, activeIntent: nil)
            return
        }
        processedPiWakeEventIDs.insert(plan.eventID)
        lastPiWakeAtByKey[plan.deduplicationKey] = now

        let generation = runtimeGeneration
        let priorWake = piWakeTask
        piWakeTask = Task { [weak self] in
            await priorWake?.value
            guard let self,
                  !Task.isCancelled,
                  self.hasStarted,
                  self.runtimeGeneration == generation else {
                return
            }

            do {
                let route = await self.currentPiModelRoute()
                if route.inferenceRoute == .local {
                    let decision = LocalInferenceResourcePolicy.evaluate(
                        secondsSinceLastInteraction: self.systemMonitor.secondsSinceLastInteraction,
                        minimumIdleSeconds: 15,
                        userInitiated: false
                    )
                    guard decision.canRun else {
                        AgentOneRuntimeHealthStore.shared.markModelAnalysisSkipped(
                            reason: "local_resources_\(decision.reason?.rawValue ?? "unknown")"
                        )
                        self.applyNative(plan.nativeFallback, activeIntent: nil)
                        return
                    }
                }
                let result: PiResultPayload
                do {
                    result = try await self.runPiWake(plan, environment: route.environment)
                    if route.usesModel {
                        await self.recordModelInvocation(
                            plan: plan,
                            attemptedRoute: route,
                            result: result,
                            fallback: nil,
                            error: nil
                        )
                    }
                } catch {
                    guard route.usesModel else { throw error }
                    if route.provider == "kimi-coding",
                       let apiKeyCredential = AgentModelSettings.shared.resolveAPIKeyFallback() {
                        let apiKeyRoute = self.piModelRoute(for: apiKeyCredential)
                        await self.recordModelInvocation(
                            plan: plan,
                            attemptedRoute: route,
                            result: nil,
                            fallback: apiKeyRoute.provider,
                            error: error
                        )
                        do {
                            result = try await self.runPiWake(plan, environment: apiKeyRoute.environment)
                            await self.recordModelInvocation(
                                plan: plan,
                                attemptedRoute: apiKeyRoute,
                                result: result,
                                fallback: nil,
                                error: nil
                            )
                        } catch {
                            await self.recordModelInvocation(
                                plan: plan,
                                attemptedRoute: apiKeyRoute,
                                result: nil,
                                fallback: "agentone-offline",
                                error: error
                            )
                            result = try await self.runPiWake(
                                plan,
                                environment: ["AGENTONE_MODEL_ROUTE": "offline"]
                            )
                        }
                    } else {
                        await self.recordModelInvocation(
                            plan: plan,
                            attemptedRoute: route,
                            result: nil,
                            fallback: "agentone-offline",
                            error: error
                        )
                        result = try await self.runPiWake(
                            plan,
                            environment: ["AGENTONE_MODEL_ROUTE": "offline"]
                        )
                    }
                }
                guard !Task.isCancelled,
                      self.hasStarted,
                      self.runtimeGeneration == generation else {
                    return
                }

                let showedReminder = await self.applyPiResult(
                    result,
                    for: plan,
                    engine: engine
                )
                if !showedReminder {
                    self.applyNative(plan.nativeFallback, activeIntent: nil)
                }
            } catch {
                guard !Task.isCancelled,
                      self.hasStarted,
                      self.runtimeGeneration == generation else {
                    return
                }
                self.applyNative(plan.nativeFallback, activeIntent: nil)
            }
        }
    }

    private struct PiModelRoute {
        var environment: [String: String]
        var inferenceRoute: ModelInferenceRoute
        var usesModel: Bool
        var usesCloud: Bool
        var provider: String
        var model: String
        var apiKeyFallback: APIKeyChatFallback?
        var prefersCompatibleChat: Bool
    }

    private struct APIKeyChatFallback {
        var apiKey: String
        var baseURL: URL
        var model: String
        var provider: String = "openai-compatible-completions"
        var inferenceRoute: ModelInferenceRoute = .cloud
        var requiresAPIKey: Bool = true
    }

    private func currentPiModelRoute() async -> PiModelRoute {
        let settings = AgentModelSettings.shared
        switch settings.route {
        case .local:
            return localPiModelRoute()
        case .automatic:
            if await Self.isLocalModelReady() {
                return localPiModelRoute()
            }
            guard let credential = await settings.resolveCloudCredential() else {
                return unavailablePiModelRoute(inferenceRoute: .automatic)
            }
            return piModelRoute(for: credential)
        case .cloud:
            guard let credential = await settings.resolveCloudCredential() else {
                return unavailablePiModelRoute(inferenceRoute: .cloud)
            }
            return piModelRoute(for: credential)
        }
    }

    private func localPiModelRoute() -> PiModelRoute {
        PiModelRoute(
            environment: [
                "AGENTONE_MODEL_ROUTE": "local",
                "AGENTONE_MODEL_PROVIDER": "ollama",
                "AGENTONE_MODEL_ID": AgentModelSettings.localModel,
                "AGENTONE_OLLAMA_BASE_URL": AgentModelSettings.localBaseURL
            ],
            inferenceRoute: .local,
            usesModel: true,
            usesCloud: false,
            provider: "ollama",
            model: AgentModelSettings.localModel,
            apiKeyFallback: APIKeyChatFallback(
                apiKey: "",
                baseURL: URL(string: AgentModelSettings.localBaseURL)!,
                model: AgentModelSettings.localModel,
                provider: "ollama",
                inferenceRoute: .local,
                requiresAPIKey: false
            ),
            prefersCompatibleChat: true
        )
    }

    private func unavailablePiModelRoute(inferenceRoute: ModelInferenceRoute) -> PiModelRoute {
        PiModelRoute(
            environment: ["AGENTONE_MODEL_ROUTE": "offline"],
            inferenceRoute: inferenceRoute,
            usesModel: false,
            usesCloud: false,
            provider: "agentone-offline",
            model: "agentone-policy-v1",
            apiKeyFallback: nil,
            prefersCompatibleChat: false
        )
    }

    private static func isLocalModelReady() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = root["models"] as? [[String: Any]] else {
                return false
            }
            return models.contains { model in
                let name = (model["name"] as? String) ?? (model["model"] as? String) ?? ""
                return name == AgentModelSettings.localModel
            }
        } catch {
            return false
        }
    }

    private func piModelRoute(for credential: ResolvedCloudCredential) -> PiModelRoute {
        switch credential {
        case .kimi(let accessToken, let deviceHeaders):
            return PiModelRoute(
                environment: [
                    "AGENTONE_MODEL_ROUTE": "cloud",
                    "AGENTONE_MODEL_PROVIDER": "kimi-coding",
                    "AGENTONE_MODEL_ID": credential.model,
                    "AGENTONE_KIMI_ACCESS_TOKEN": accessToken,
                    "AGENTONE_KIMI_BASE_URL": "https://api.kimi.com/coding",
                    "AGENTONE_KIMI_PLATFORM": deviceHeaders.platform,
                    "AGENTONE_KIMI_VERSION": deviceHeaders.version,
                    "AGENTONE_KIMI_DEVICE_NAME": deviceHeaders.deviceName,
                    "AGENTONE_KIMI_DEVICE_MODEL": deviceHeaders.deviceModel,
                    "AGENTONE_KIMI_OS_VERSION": deviceHeaders.osVersion,
                    "AGENTONE_KIMI_DEVICE_ID": deviceHeaders.deviceID
                ],
                inferenceRoute: .cloud,
                usesModel: true,
                usesCloud: true,
                provider: credential.provider,
                model: credential.model,
                apiKeyFallback: nil,
                prefersCompatibleChat: false
            )
        case .apiKey(let apiKey, let baseURL, let model):
            let parsedBaseURL = URL(string: baseURL)
            return PiModelRoute(
                environment: [
                    "AGENTONE_MODEL_ROUTE": "cloud",
                    "AGENTONE_MODEL_PROVIDER": "openai-compatible-completions",
                    "AGENTONE_MODEL_ID": model,
                    "AGENTONE_OPENAI_BASE_URL": baseURL,
                    "OPENAI_API_KEY": apiKey
                ],
                inferenceRoute: .cloud,
                usesModel: true,
                usesCloud: true,
                provider: credential.provider,
                model: model,
                apiKeyFallback: parsedBaseURL.map {
                    APIKeyChatFallback(apiKey: apiKey, baseURL: $0, model: model)
                },
                // The configured Zhuan model gateway currently completes
                // non-streaming Chat Completions correctly but leaves Pi's
                // streaming request open until its budget expires.
                prefersCompatibleChat: parsedBaseURL?.host?.lowercased() == "algoagent.zhuaninc.com"
            )
        }
    }

    private func runPiWake(
        _ plan: PiReminderWakePlan,
        environment: [String: String]
    ) async throws -> PiResultPayload {
        try piSidecar.updateEnvironmentOverrides(environment)
        _ = try await piSidecar.health(timeout: 3)
        return try await piSidecar.wake(
            reason: plan.reason,
            sanitizedContext: plan.context,
            recentMemory: plan.recentMemory,
            contextHistory: await contextToolHistory(),
            budget: plan.budget,
            timeout: 10
        )
    }

    private func recordModelInvocation(
        plan: PiReminderWakePlan,
        attemptedRoute: PiModelRoute,
        result: PiResultPayload?,
        fallback: String?,
        error: Error?
    ) async {
        guard AgentModelSettings.shared.auditsCloudInvocations else { return }
        let model = result?.model
        let usage = result.map {
            ModelInvocationAudit.Usage(
                inputTokens: $0.usage.inputTokens,
                outputTokens: $0.usage.outputTokens,
                totalTokens: $0.usage.totalTokens,
                turns: $0.usage.turns,
                toolCalls: $0.usage.toolCalls,
                durationMs: $0.usage.durationMs
            )
        }
        let audit = ModelInvocationAudit(
            timestamp: Date(),
            purpose: plan.reason,
            route: attemptedRoute.inferenceRoute,
            provider: model?.provider ?? attemptedRoute.provider,
            model: model?.model ?? attemptedRoute.model,
            sentContextFields: Self.sentContextFields(in: plan.context),
            usage: usage,
            succeeded: result != nil && error == nil,
            fallback: fallback,
            errorCode: Self.modelErrorCode(error)
        )
        try? await modelAuditStore.append(audit)
    }

    private static func sentContextFields(in context: PiSanitizedContext) -> [String] {
        var fields: [String] = ["capturedAt"]
        if context.applicationName != nil { fields.append("applicationName") }
        if context.bundleIdentifier != nil { fields.append("bundleIdentifier") }
        if context.windowTitle != nil { fields.append("windowTitle") }
        if context.url != nil { fields.append("url") }
        if context.documentPath != nil { fields.append("documentPath") }
        if context.contentSummary != nil { fields.append("contentSummary") }
        if context.selectedText != nil { fields.append("selectedText") }
        if context.submittedText != nil { fields.append("submittedText") }
        if context.screenText != nil { fields.append("screenText") }
        if context.interactionTarget != nil { fields.append("interactionTarget") }
        if context.contextTransition != nil { fields.append("contextTransition") }
        if !context.semanticTags.isEmpty { fields.append("semanticTags") }
        if context.activeIntent != nil { fields.append("activeIntent") }
        if context.driftDurationSeconds != nil { fields.append("driftDurationSeconds") }
        return fields
    }

    private static func sentContextFields(in context: ActivityContext?) -> [String] {
        guard let context else { return [] }
        var fields: [String] = []
        if context.applicationName != nil { fields.append("applicationName") }
        if context.bundleIdentifier != nil { fields.append("bundleIdentifier") }
        if context.windowTitle != nil { fields.append("windowTitle") }
        if context.url != nil { fields.append("url") }
        if context.documentPath != nil { fields.append("documentPath") }
        if context.contentSummary != nil { fields.append("contentSummary") }
        if context.selectedText != nil { fields.append("selectedText") }
        if context.submittedText != nil { fields.append("submittedText") }
        if context.screenText != nil { fields.append("screenText") }
        if context.interactionTarget != nil { fields.append("interactionTarget") }
        if context.contextTransition != nil { fields.append("contextTransition") }
        if !context.semanticTags.isEmpty { fields.append("semanticTags") }
        return fields
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func modelErrorCode(_ error: Error?) -> String? {
        guard let error else { return nil }
        if let modelError = error as? ModelInferenceError {
            switch modelError {
            case .missingCredential: return "missing_credential"
            case .cloudProcessingDisabled: return "cloud_processing_disabled"
            case .sensitiveContextBlocked: return "sensitive_context_blocked"
            case .localModelUnavailable: return "local_model_unavailable"
            case .localResourcesConstrained(let reason): return "local_resources_\(reason)"
            case .invalidServerResponse: return "invalid_server_response"
            case .server(let statusCode, _): return "model_server_\(statusCode)"
            }
        }
        if let analyzerError = error as? ContextSemanticAnalyzerError {
            switch analyzerError {
            case .unsupportedCredential: return "unsupported_credential"
            case .invalidAnalysis: return "invalid_context_analysis"
            }
        }
        if case PiSidecarError.remote(let code, _) = error {
            return code ?? "remote_error"
        }
        if error is CancellationError { return "cancelled" }
        switch error {
        case PiSidecarError.requestTimedOut:
            return "request_timed_out"
        case PiSidecarError.processExited:
            return "process_exited"
        case PiSidecarError.processUnavailable:
            return "process_unavailable"
        default:
            return "runtime_error"
        }
    }

    private static func persistenceErrorCode(_ error: Error) -> String {
        let nsError = error as NSError
        let domain = nsError.domain
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return domain.isEmpty
            ? "diary_write_failed_\(nsError.code)"
            : "\(domain)_\(nsError.code)"
    }

    private func applyPiResult(
        _ result: PiResultPayload,
        for plan: PiReminderWakePlan,
        engine: ContextMemoryEngine
    ) async -> Bool {
        var showedReminder = false
        var appendedReflection = false

        for action in result.actions {
            switch action.type {
            case .innerJournal:
                guard let reflection = makeReflection(from: action, plan: plan) else { continue }
                do {
                    _ = try await engine.addAgentReflection(reflection)
                    appendedReflection = true
                } catch {
                    // A journal write failure must not suppress a useful,
                    // already-policy-checked return card.
                }

            case .returnCard:
                guard !showedReminder,
                      let taskTitle = action.payload["taskTitle"]?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !taskTitle.isEmpty else {
                    continue
                }
                let note = action.payload["note"]?.stringValue.map {
                    String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
                }
                shellModel.mood = .curious
                companion.showReturnCard(
                    taskName: String(taskTitle.prefix(240)),
                    note: note,
                    level: plan.reminderStage.level
                )
                showedReminder = true

            case .curiosityPrompt,
                 .workingIntention,
                 .contextClassification,
                 .savedDetour,
                 .surpriseProposal,
                 .energyConsumed:
                // These are either not granted in this wake budget or require
                // a richer native authority model before automatic execution.
                continue
            }
        }

        if appendedReflection {
            let replay = await engine.replay(for: Date())
            shellModel.consumePersistedReplay(replay)
        }
        return showedReminder
    }

    private func makeReflection(
        from action: PiRuntimeAction,
        plan: PiReminderWakePlan
    ) -> AgentReflection? {
        guard let observation = action.payload["observation"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !observation.isEmpty else {
            return nil
        }

        let disposition = action.payload["disposition"]?.stringValue
            .flatMap(AgentThoughtDisposition.init(rawValue:)) ?? .observationOnly
        return AgentReflection(
            timestamp: Date(),
            observation: String(observation.prefix(800)),
            hypothesis: boundedPiText(action.payload["hypothesis"]?.stringValue, limit: 800),
            consideredAction: boundedPiText(action.payload["consideredAction"]?.stringValue, limit: 500),
            finalAction: boundedPiText(action.payload["finalAction"]?.stringValue, limit: 500),
            disposition: disposition,
            why: boundedPiText(action.payload["why"]?.stringValue, limit: 500),
            uncertainty: action.payload["uncertainty"]?.doubleValue ?? 0.5,
            relatedEventIDs: [plan.eventID]
        )
    }

    private func boundedPiText(_ value: String?, limit: Int) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(limit))
    }

    private func applyNative(_ prompt: AgentPrompt, activeIntent: IntentSession?) {
        guard case .reminder(let stage, _, _) = prompt else { return }
        shellModel.mood = .curious
        companion.remindAboutDistraction(
            level: stage.level,
            taskName: activeIntent?.title ?? companion.life.currentTaskName
        )
    }

    private func invalidatePendingPiReminder() {
        runtimeGeneration = UUID()
    }

    private func scheduleContextAnalysis(
        for event: ActivityEvent,
        engine: ContextMemoryEngine
    ) {
        let trigger: String
        let delayNanoseconds: UInt64
        let cooldown: TimeInterval
        switch event.signal {
        case .keyboard(.returnPressed):
            trigger = "submitted_output"
            delayNanoseconds = 150_000_000
            cooldown = 8
        case .scrolled:
            trigger = "reading_checkpoint"
            delayNanoseconds = 2_500_000_000
            cooldown = 60
        case .applicationActivated, .windowFocused:
            trigger = "context_opened"
            delayNanoseconds = 1_200_000_000
            cooldown = 45
        case .keyboard(.typingStarted), .keyboard(.typingBurst), .contentChanged:
            trigger = "composition_checkpoint"
            delayNanoseconds = 3_000_000_000
            cooldown = 45
        case .mouseClicked:
            trigger = "context_interaction"
            delayNanoseconds = 2_000_000_000
            cooldown = 60
        default:
            return
        }

        guard !Self.isOwnContext(event.context) else { return }
        guard !event.context.isSensitive else {
            AgentOneRuntimeHealthStore.shared.markModelAnalysisSkipped(
                reason: "sensitive_context_blocked",
                at: event.timestamp
            )
            return
        }
        guard Self.hasConcreteContext(event.context) else {
            AgentOneRuntimeHealthStore.shared.markModelAnalysisSkipped(
                reason: "no_concrete_context",
                at: event.timestamp
            )
            return
        }

        if trigger == "submitted_output" {
            // Return Context is more valuable than a passive drift reminder.
            // Stop the reminder process before the enrichment starts so an
            // environment-route restart cannot invalidate the pending Return
            // request with `processUnavailable`.
            piWakeTask?.cancel()
            piWakeTask = nil
            invalidatePendingPiReminder()
            piSidecar.stopImmediately()
        }

        let fingerprint = Self.semanticFingerprint(for: event.context)
        let analysisKey = "\(fingerprint)|\(trigger)"
        let now = Date()
        if let last = lastSemanticAnalysisAtByKey[analysisKey],
           now.timeIntervalSince(last) < cooldown {
            return
        }

        // A Return/submit checkpoint is more valuable than a pending passive
        // reading checkpoint. Passive hooks never keep rescheduling the same
        // model call, so continuous scrolling still creates one bounded wake.
        if contextAnalysisTask != nil {
            guard trigger == "submitted_output" else { return }
            contextAnalysisTask?.cancel()
        }

        lastSemanticAnalysisAtByKey[analysisKey] = now
        if lastSemanticAnalysisAtByKey.count > 500 {
            lastSemanticAnalysisAtByKey = lastSemanticAnalysisAtByKey.filter {
                now.timeIntervalSince($0.value) < 24 * 60 * 60
            }
        }

        let analysisID = UUID()
        contextAnalysisID = analysisID
        activeContextAnalysis = DeferredContextAnalysis(
            event: event,
            analysisKey: analysisKey
        )
        contextAnalysisTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            // Always release the analysis slot, including cancellation and
            // decoding failures. Otherwise one interrupted passive analysis
            // can make every later context checkpoint look permanently busy.
            defer { self.finishContextAnalysis(id: analysisID) }

            let route = await self.currentPiModelRoute()
            guard route.usesModel else {
                await self.recordPiContextAnalysisInvocation(
                    route: route,
                    result: nil,
                    context: event.context,
                    error: ModelInferenceError.missingCredential
                )
                AgentOneRuntimeHealthStore.shared.markModelAnalysisSkipped(
                    reason: "missing_credential"
                )
                return
            }

            if route.inferenceRoute == .local {
                let minimumIdleSeconds: TimeInterval = trigger == "submitted_output" ? 8 : 20
                let decision = LocalInferenceResourcePolicy.evaluate(
                    secondsSinceLastInteraction: self.systemMonitor.secondsSinceLastInteraction,
                    minimumIdleSeconds: minimumIdleSeconds,
                    userInitiated: false
                )
                guard decision.canRun else {
                    self.deferredContextAnalysis = DeferredContextAnalysis(
                        event: event,
                        analysisKey: analysisKey
                    )
                    self.lastSemanticAnalysisAtByKey.removeValue(forKey: analysisKey)
                    AgentOneRuntimeHealthStore.shared.markModelAnalysisSkipped(
                        reason: "local_resources_\(decision.reason?.rawValue ?? "unknown")"
                    )
                    return
                }
            }

            AgentOneRuntimeHealthStore.shared.markModelAnalysisStarted()
            do {
                let analysis: ContextSemanticAnalysis
                let provider: String
                let model: String
                let personalMemory = await self.personalMemory(for: engine)
                if route.provider == "kimi-coding" {
                    let piResult = try await self.runPiContextAnalysis(
                        for: event,
                        environment: route.environment,
                        recentMemory: personalMemory
                    )
                    guard let text = piResult.spokenText,
                          let decoded = ContextSemanticAnalyzer.decode(text) else {
                        throw ContextSemanticAnalyzerError.invalidAnalysis
                    }
                    analysis = decoded
                    provider = piResult.model?.provider ?? route.provider
                    model = piResult.model?.model ?? route.model
                    await self.recordPiContextAnalysisInvocation(
                        route: route,
                        result: piResult,
                        context: event.context,
                        error: nil
                    )
                } else {
                    guard let fallback = route.apiKeyFallback else {
                        throw ContextSemanticAnalyzerError.unsupportedCredential
                    }
                    let direct = try await self.contextSemanticAnalyzer.analyze(
                        context: event.context,
                        signalDescription: Self.semanticSignalDescription(for: event),
                        personalMemory: personalMemory.map(\.summary),
                        apiKey: fallback.apiKey,
                        baseURL: fallback.baseURL,
                        model: fallback.model,
                        provider: fallback.provider,
                        route: fallback.inferenceRoute,
                        requiresAPIKey: fallback.requiresAPIKey
                    )
                    analysis = direct.0
                    provider = direct.1.provider
                    model = direct.1.model
                    await self.recordContextAnalysisInvocation(
                        route: route,
                        inference: direct.1,
                        context: event.context,
                        error: nil
                    )
                }
                guard !Task.isCancelled else { return }
                await self.persistContextAnalysis(
                    analysis,
                    for: event,
                    engine: engine
                )
                AgentOneRuntimeHealthStore.shared.markModelAnalysisSucceeded(
                    provider: provider,
                    model: model
                )
                if self.deferredContextAnalysis?.event.id == event.id {
                    self.deferredContextAnalysis = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await self.recordPiContextAnalysisInvocation(
                    route: route,
                    result: nil,
                    context: event.context,
                    error: error
                )
                AgentOneRuntimeHealthStore.shared.markModelAnalysisFailed(
                    errorCode: Self.modelErrorCode(error) ?? "unknown_model_error"
                )
            }
        }
    }

    private func runPiContextAnalysis(
        for event: ActivityEvent,
        environment: [String: String],
        recentMemory: [PiRecentMemory]
    ) async throws -> PiResultPayload {
        guard let context = Self.piChatContext(event.context) else {
            throw PiSidecarError.sensitiveContext
        }
        var didRetryUnavailable = false
        while true {
            do {
                try piSidecar.updateEnvironmentOverrides(environment)
                _ = try await piSidecar.health(timeout: 3)
                return try await piSidecar.chat(
                    purpose: .contextEnrichment,
                    messages: [
                        PiChatMessage(
                            role: .user,
                            content: Self.semanticSignalDescription(for: event)
                        )
                    ],
                    sanitizedContext: context,
                    recentMemory: recentMemory,
                    maxTokens: 1_600,
                    maxDurationMs: 30_000,
                    timeout: 35
                )
            } catch PiSidecarError.processUnavailable where !didRetryUnavailable {
                didRetryUnavailable = true
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func finishContextAnalysis(id: UUID) {
        guard contextAnalysisID == id else { return }
        contextAnalysisTask = nil
        contextAnalysisID = nil
        activeContextAnalysis = nil
    }

    private func persistContextAnalysis(
        _ analysis: ContextSemanticAnalysis,
        for event: ActivityEvent,
        engine: ContextMemoryEngine
    ) async {
        var enriched = event.context
        enriched.contentSummary = analysis.summary
        enriched.semanticTags.insert(ActivityContext.modelEnrichedSummaryTag)
        enriched.semanticTags.formUnion(analysis.tags.map { $0.lowercased() })
        var persistedSomething = false
        do {
            let application = try await engine.applyContextEnrichment(
                targetEventID: event.id,
                enrichedContext: enriched,
                activityTitle: analysis.activityTitle,
                summary: analysis.summary,
                tags: analysis.tags,
                matching: event.context,
                at: Date()
            )
            switch application {
            case .mergedIntoPending:
                break
            case .appended:
                persistedSomething = true
            case .targetNotFound:
                AgentOneRuntimeHealthStore.shared.markDiaryPersistenceFailed(
                    "context_enrichment_target_not_found"
                )
            case .rejectedSensitive:
                AgentOneRuntimeHealthStore.shared.markModelAnalysisSkipped(
                    reason: "sensitive_context_blocked"
                )
            }
        } catch {
            AgentOneRuntimeHealthStore.shared.markDiaryPersistenceFailed(
                Self.persistenceErrorCode(error)
            )
        }

        let reflection = AgentReflection(
            timestamp: Date(),
            observation: analysis.observation,
            hypothesis: analysis.hypothesis,
            consideredAction: analysis.consideredAction,
            finalAction: nil,
            disposition: analysis.disposition,
            why: analysis.why,
            uncertainty: analysis.uncertainty,
            relatedEventIDs: [event.id]
        )
        do {
            _ = try await engine.addAgentReflection(reflection)
            persistedSomething = true
        } catch {
            AgentOneRuntimeHealthStore.shared.markDiaryPersistenceFailed(
                Self.persistenceErrorCode(error)
            )
        }

        let isMilestone = event.semantics.contains(.opinionOutput)
            || event.semantics.contains(.taskSubmission)
            || event.context.selectedText != nil
        if event.context.screenshotResourcePath == nil,
           isMilestone || analysis.evidenceTitle != nil || analysis.evidenceSummary != nil {
            let kind: EvidenceKind
            if event.context.selectedText != nil {
                kind = .selectedText
            } else if event.context.url != nil {
                kind = .pageReference
            } else if event.context.documentPath != nil {
                kind = .documentReference
            } else {
                kind = .taskSceneCard
            }
            let evidence = KeyEvidence(
                capturedAt: event.timestamp,
                kind: kind,
                title: analysis.evidenceTitle ?? analysis.activityTitle,
                summary: analysis.evidenceSummary ?? analysis.summary,
                localResourcePath: event.context.documentPath,
                url: event.context.url,
                selectedText: event.context.selectedText,
                submittedText: event.context.submittedText,
                windowTitle: event.context.windowTitle,
                eventID: event.id
            )
            do {
                _ = try await engine.addEvidence(evidence)
                persistedSomething = true
            } catch {
                AgentOneRuntimeHealthStore.shared.markDiaryPersistenceFailed(
                    Self.persistenceErrorCode(error)
                )
            }
        }

        if persistedSomething {
            AgentOneRuntimeHealthStore.shared.markDiaryPersisted()
        }

        let replay = await engine.replay(for: event.timestamp)
        let habits = await engine.habitContexts()
        shellModel.consumePersistedReplay(replay, habits: habits)
        shellModel.mood = .curious
    }

    private func runCompanionMaintenance() {
        guard hasStarted else { return }
        updateLeisureContextState()
        retryDeferredContextAnalysisIfPossible()
        if systemMonitor.secondsSinceLastInteraction >= 45 {
            scheduleDailyDigestIfNeeded()
        }
        evaluateProactiveOpportunity()
    }

    private func retryDeferredContextAnalysisIfPossible() {
        guard contextAnalysisTask == nil,
              let pending = deferredContextAnalysis,
              let engine else { return }
        let decision = LocalInferenceResourcePolicy.evaluate(
            secondsSinceLastInteraction: systemMonitor.secondsSinceLastInteraction,
            minimumIdleSeconds: 8,
            userInitiated: false
        )
        guard decision.canRun else { return }
        deferredContextAnalysis = nil
        lastSemanticAnalysisAtByKey.removeValue(forKey: pending.analysisKey)
        scheduleContextAnalysis(for: pending.event, engine: engine)
    }

    private func cancelDailyDigestForLiveActivity() {
        guard dailyDigestTask != nil else { return }
        dailyDigestTask?.cancel()
        dailyDigestTask = nil
        dailyDigestTaskID = nil
        // Daily synthesis is the only maintenance task that owns the sidecar
        // while this slot is non-nil. Live input always wins that ownership.
        piSidecar.stopImmediately()
    }

    /// Foreground input always wins over passive local inference. Context has
    /// already been written before enrichment starts, so cancellation loses no
    /// evidence: the newest interrupted analysis is retained for a later idle
    /// retry. Explicit AgentOne chat is not cancelled here.
    private func pauseBackgroundLocalInferenceForLiveActivity() {
        cancelDailyDigestForLiveActivity()
        guard AgentModelSettings.shared.route != .cloud else { return }

        var stoppedSidecarWork = false
        if let pending = activeContextAnalysis {
            deferredContextAnalysis = pending
            lastSemanticAnalysisAtByKey.removeValue(forKey: pending.analysisKey)
            contextAnalysisTask?.cancel()
            contextAnalysisTask = nil
            contextAnalysisID = nil
            activeContextAnalysis = nil
            stoppedSidecarWork = true
        }
        if piWakeTask != nil {
            piWakeTask?.cancel()
            piWakeTask = nil
            invalidatePendingPiReminder()
            stoppedSidecarWork = true
        }

        if stoppedSidecarWork, chatTask == nil {
            piSidecar.stopImmediately()
        }
    }

    private func scheduleDailyDigestIfNeeded() {
        guard dailyDigestTask == nil,
              contextAnalysisTask == nil,
              piWakeTask == nil,
              chatTask == nil,
              !companion.chat.isOpen,
              let engine else { return }

        if AgentModelSettings.shared.route != .cloud {
            let decision = LocalInferenceResourcePolicy.evaluate(
                secondsSinceLastInteraction: systemMonitor.secondsSinceLastInteraction,
                minimumIdleSeconds: 60,
                userInitiated: false
            )
            guard decision.canRun else { return }
        }

        let taskID = UUID()
        dailyDigestTaskID = taskID
        dailyDigestTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishDailyDigest(id: taskID) }
            guard let target = await self.dailyDigestTarget(engine: engine) else { return }
            await self.generateDailyDigest(
                for: target.date,
                isFinal: target.isFinal,
                engine: engine
            )
        }
    }

    private func finishDailyDigest(id: UUID) {
        guard dailyDigestTaskID == id else { return }
        dailyDigestTask = nil
        dailyDigestTaskID = nil
    }

    private func dailyDigestTarget(
        engine: ContextMemoryEngine,
        now: Date = Date()
    ) async -> (date: Date, isFinal: Bool)? {
        let todayKey = await engine.diary.dayKey(for: now)
        let todayReplay = await engine.replay(for: now)
        let todayCount = Self.meaningfulDigestMoments(in: todayReplay).count
        let todayDigest = await engine.latestDailyContextDigest(for: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let hour = calendar.component(.hour, from: now)
        let todayNeedsDigest: Bool
        if let todayDigest {
            let enoughNewContext = todayCount >= todayDigest.sourceContextCount + 4
            let oldEnough = now.timeIntervalSince(todayDigest.generatedAt) >= 2 * 60 * 60
            let needsFinal = hour >= 23 && !todayDigest.isFinal
            todayNeedsDigest = (enoughNewContext && oldEnough) || needsFinal
        } else {
            todayNeedsDigest = todayCount >= 3
        }
        if todayNeedsDigest {
            return (now, hour >= 23)
        }

        for day in await engine.recordedDays().reversed() where day < todayKey {
            guard let date = Self.date(fromDayKey: day),
                  await engine.latestDailyContextDigest(for: date) == nil else {
                continue
            }
            let replay = await engine.replay(for: date)
            if Self.meaningfulDigestMoments(in: replay).count >= 3 {
                return (date, true)
            }
        }
        return nil
    }

    private func generateDailyDigest(
        for date: Date,
        isFinal: Bool,
        engine: ContextMemoryEngine
    ) async {
        let replay = await engine.replay(for: date)
        let dailyMemories = Self.dailyDigestMemories(from: replay)
        guard dailyMemories.count >= 3, !Task.isCancelled else { return }
        let personalMemories = await personalMemory(for: engine, excludingDay: replay.day)
        let route = await currentPiModelRoute()
        guard route.usesModel else { return }

        let analysis: DailyContextDigestAnalysis
        var piResult: PiResultPayload?
        var directResult: ModelInferenceResult?
        do {
            if route.provider == "kimi-coding" {
                try piSidecar.updateEnvironmentOverrides(route.environment)
                _ = try await piSidecar.health(timeout: 3)
                let result = try await piSidecar.chat(
                    purpose: .dailyDigest,
                    messages: [
                        PiChatMessage(
                            role: .user,
                            content: "请把 \(replay.day) 收集到的 Context 提炼成今天的活日记。"
                        )
                    ],
                    sanitizedContext: nil,
                    recentMemory: Array((dailyMemories + personalMemories).suffix(64)),
                    maxTokens: 2_200,
                    maxDurationMs: 45_000,
                    timeout: 50
                )
                guard let text = result.spokenText,
                      let decoded = DailyContextDigestAnalyzer.decode(text) else {
                    throw DailyContextDigestAnalyzerError.invalidAnalysis
                }
                analysis = decoded
                piResult = result
            } else {
                guard let fallback = route.apiKeyFallback else { return }
                let result = try await dailyContextDigestAnalyzer.analyze(
                    day: replay.day,
                    contextMemories: dailyMemories.map(\.summary),
                    personalMemories: personalMemories.map(\.summary),
                    apiKey: fallback.apiKey,
                    baseURL: fallback.baseURL,
                    model: fallback.model,
                    provider: fallback.provider,
                    route: fallback.inferenceRoute,
                    requiresAPIKey: fallback.requiresAPIKey
                )
                analysis = result.0
                directResult = result.1
            }
        } catch {
            await recordDailyDigestInvocation(
                route: route,
                piResult: nil,
                directResult: nil,
                dailyContextCount: dailyMemories.count,
                personalMemoryCount: personalMemories.count,
                error: error
            )
            return
        }
        guard !Task.isCancelled else { return }

        let digest = DailyContextDigest(
            day: replay.day,
            generatedAt: Date(),
            isFinal: isFinal,
            headline: analysis.headline,
            overview: analysis.overview,
            highlights: analysis.highlights,
            rhythm: analysis.rhythm,
            unfinishedThread: analysis.unfinishedThread,
            agentNote: analysis.agentNote,
            invitation: analysis.invitation,
            mood: analysis.mood,
            sourceContextCount: dailyMemories.count,
            evidenceCount: replay.evidence.count,
            personalizedMemoryCount: personalMemories.count
        )
        do {
            _ = try await engine.addDailyContextDigest(
                digest,
                at: Self.digestEntryTimestamp(for: date, isFinal: isFinal)
            )
            AgentOneRuntimeHealthStore.shared.markDiaryPersisted()
            await recordDailyDigestInvocation(
                route: route,
                piResult: piResult,
                directResult: directResult,
                dailyContextCount: dailyMemories.count,
                personalMemoryCount: personalMemories.count,
                error: nil
            )
            let currentDayKey = await engine.diary.dayKey(for: Date())
            if replay.day == currentDayKey {
                let updatedReplay = await engine.replay(for: Date())
                let habits = await engine.habitContexts()
                shellModel.consumePersistedReplay(updatedReplay, habits: habits)
                shellModel.mood = Self.agentMood(for: analysis.mood)
            }
        } catch {
            AgentOneRuntimeHealthStore.shared.markDiaryPersistenceFailed(
                Self.persistenceErrorCode(error)
            )
        }
    }

    private func personalMemory(
        for engine: ContextMemoryEngine,
        excludingDay: String? = nil
    ) async -> [PiRecentMemory] {
        var result: [PiRecentMemory] = []
        for habit in await engine.habitContexts() {
            let memory = PiRecentMemory(
                id: habit.id,
                timestamp: Self.iso8601String(from: habit.lastObservedAt),
                kind: "habit_context",
                summary: String("\(habit.title) — \(habit.summary)".prefix(600)),
                tags: ["relationship-memory", habit.kind.rawValue]
            )
            if Self.isSafeChatMemory(memory) { result.append(memory) }
        }

        let entries = await engine.diary.allEntries()
        for entry in entries.reversed() {
            if let excludingDay,
               await engine.diary.dayKey(for: entry.timestamp) == excludingDay {
                continue
            }
            let memory: PiRecentMemory?
            switch entry.payload {
            case .dailyContextDigest(let digest):
                memory = PiRecentMemory(
                    id: entry.id.uuidString,
                    timestamp: Self.iso8601String(from: entry.timestamp),
                    kind: "daily_digest",
                    summary: String("\(digest.headline) — \(digest.overview) — LUMA: \(digest.agentNote)".prefix(600)),
                    tags: ["relationship-memory", "daily-digest"]
                )
            case .daySummary(let summary):
                memory = PiRecentMemory(
                    id: entry.id.uuidString,
                    timestamp: Self.iso8601String(from: entry.timestamp),
                    kind: "day_summary",
                    summary: String(summary.prefix(600)),
                    tags: ["relationship-memory", "day-summary"]
                )
            case .skillLearned(let skill):
                memory = PiRecentMemory(
                    id: entry.id.uuidString,
                    timestamp: Self.iso8601String(from: entry.timestamp),
                    kind: "learned_skill",
                    summary: String("\(skill.name) — \(skill.guidance)".prefix(600)),
                    tags: ["relationship-memory", "learned-skill"]
                )
            case .activity(let record):
                let context = record.session?.context ?? record.event.context
                guard !context.isSensitive,
                      let summary = context.contentSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !summary.isEmpty else {
                    memory = nil
                    break
                }
                memory = PiRecentMemory(
                    id: entry.id.uuidString,
                    timestamp: Self.iso8601String(from: entry.timestamp),
                    kind: "remembered_activity",
                    summary: String("\(record.narrative) — \(summary)".prefix(600)),
                    tags: ["relationship-memory", record.session?.kind.rawValue ?? "activity"]
                )
            default:
                memory = nil
            }
            if let memory, Self.isSafeChatMemory(memory) {
                result.append(memory)
            }
            if result.count >= 20 { break }
        }
        return Array(result.prefix(20))
    }

    private static func meaningfulDigestMoments(
        in replay: SemanticReplay
    ) -> [AgentOneCore.ReplayMoment] {
        replay.moments.filter { moment in
            guard !moment.isHidden else { return false }
            switch moment.kind {
            case .activity, .evidence, .returned, .learnedSkill:
                return true
            case .thought:
                return moment.thoughtDisposition != .observationOnly
            case .intent, .drift, .reminder, .correction, .summary:
                return false
            }
        }
    }

    private static func dailyDigestMemories(
        from replay: SemanticReplay
    ) -> [PiRecentMemory] {
        var seen: Set<String> = []
        var result: [PiRecentMemory] = []
        for moment in meaningfulDigestMoments(in: replay) {
            let summary = [moment.title, moment.detail]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
            guard !summary.isEmpty else { continue }
            let fingerprint = String(summary.lowercased().prefix(180))
            guard seen.insert(fingerprint).inserted else { continue }
            let memory = PiRecentMemory(
                id: moment.sourceEntryID.uuidString,
                timestamp: Self.iso8601String(from: moment.timestamp),
                kind: "daily_context",
                summary: String(summary.prefix(700)),
                tags: ["daily-context", moment.lane.rawValue, moment.kind.rawValue]
            )
            if Self.isSafeChatMemory(memory) { result.append(memory) }
        }
        return Array(result.suffix(48))
    }

    private func recordDailyDigestInvocation(
        route: PiModelRoute,
        piResult: PiResultPayload?,
        directResult: ModelInferenceResult?,
        dailyContextCount: Int,
        personalMemoryCount: Int,
        error: Error?
    ) async {
        guard AgentModelSettings.shared.auditsCloudInvocations else { return }
        let usage = piResult.map {
            ModelInvocationAudit.Usage(
                inputTokens: $0.usage.inputTokens,
                outputTokens: $0.usage.outputTokens,
                totalTokens: $0.usage.totalTokens,
                turns: $0.usage.turns,
                toolCalls: $0.usage.toolCalls,
                durationMs: $0.usage.durationMs
            )
        }
        let audit = ModelInvocationAudit(
            timestamp: Date(),
            purpose: "daily_context_digest",
            route: route.inferenceRoute,
            provider: piResult?.model?.provider ?? directResult?.provider ?? route.provider,
            model: piResult?.model?.model ?? directResult?.model ?? route.model,
            sentContextFields: [
                "dailyContext[\(dailyContextCount)]",
                "relationshipMemory[\(personalMemoryCount)]"
            ],
            usage: usage,
            succeeded: (piResult != nil || directResult != nil) && error == nil,
            fallback: nil,
            errorCode: Self.modelErrorCode(error)
        )
        try? await modelAuditStore.append(audit)
    }

    private func updateLeisureContextState(now: Date = Date()) {
        let active = ActiveContextReader.read()
        let key = [active?.bundleIdentifier, active?.applicationName, active?.windowTitle]
            .compactMap { $0?.lowercased() }
            .joined(separator: "|")
        guard Self.isLeisureContext(active) else {
            leisureContextKey = nil
            leisureContextStartedAt = nil
            return
        }
        if leisureContextKey != key {
            leisureContextKey = key
            leisureContextStartedAt = now
        }
    }

    private func evaluateProactiveOpportunity(now: Date = Date()) {
        guard let digest = shellModel.dailyDigest else { return }
        let active = ActiveContextReader.read()
        guard active?.bundleIdentifier?.lowercased() != Self.ownBundleIdentifier else { return }
        let sensitive = active?.isSecureInput == true || Self.isNeverCollectContext(
            bundleIdentifier: active?.bundleIdentifier,
            windowTitle: active?.windowTitle
        )
        let leisureDuration = leisureContextStartedAt.map {
            max(0, now.timeIntervalSince($0))
        } ?? 0
        let snapshot = ProactiveCompanionSnapshot(
            now: now,
            secondsSinceLastInteraction: systemMonitor.secondsSinceLastInteraction,
            leisureContextDuration: leisureDuration,
            hasDailyDigest: true,
            alreadyInvitedForDigest: companionPreferences.lastDailyInvitationDigestID == digest.id,
            invitationsEnabled: companionPreferences.journalInvitationsEnabled,
            isChatOpen: companion.chat.isOpen,
            hasVisiblePrompt: companion.life.prompt != nil,
            isSensitiveContext: sensitive,
            lastInvitationAt: companionPreferences.lastProactiveInvitationAt,
            timeZone: .current
        )
        guard proactivePolicy.opportunity(for: snapshot) == .inviteDailyReview else { return }

        let customInvitation = digest.invitation?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (customInvitation?.isEmpty == false ? customInvitation : nil)
            ?? (digest.agentNote.isEmpty
                ? "我把今天散落的线索串起来了，要看一眼吗？"
                : "我刚把今天串起来了，有一处让我挺想和你聊聊。")
        let detail = digest.highlights.first.map { first in
            "\(digest.headline) · \(first)"
        } ?? digest.overview
        companion.inviteToReview(
            title: title,
            detail: detail
        )
        shellModel.mood = .curious
        companionPreferences.lastDailyInvitationDigestID = digest.id
        companionPreferences.lastProactiveInvitationAt = now

        guard let engine else { return }
        Task { [weak self] in
            guard let self else { return }
            let reflection = AgentReflection(
                timestamp: now,
                observation: digest.agentNote,
                hypothesis: digest.rhythm,
                consideredAction: "我想主动探头，邀请你用两分钟看看今天，而不是等你自己想起日记。",
                finalAction: title,
                disposition: .spoken,
                why: leisureDuration > 0
                    ? "你在轻松浏览，我判断这比专注输入时更适合开口。"
                    : "你已经停下来一会儿，而且我手里有具体的今日总结，不是为了刷存在感。",
                uncertainty: 0.12
            )
            _ = try? await engine.addAgentReflection(reflection)
            let replay = await engine.replay(for: now)
            self.shellModel.consumePersistedReplay(replay)
        }
    }

    private static func isLeisureContext(_ context: ActiveApplicationContext?) -> Bool {
        guard let context else { return false }
        let text = [context.applicationName, context.bundleIdentifier, context.windowTitle]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let terms = [
            "douyin", "抖音", "bilibili", "哔哩哔哩", "youtube",
            "xiaohongshu", "小红书", "netflix", "music", "音乐", "podcast"
        ]
        return terms.contains { text.contains($0) }
    }

    private static func digestEntryTimestamp(for date: Date, isFinal: Bool) -> Date {
        guard isFinal else { return Date() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? date
        return calendar.date(byAdding: .second, value: -1, to: next) ?? date
    }

    private static func date(fromDayKey day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    private static func agentMood(for value: String) -> AgentMood {
        switch value.lowercased() {
        case "proud", "playful": .delighted
        case "gentle": .resting
        case "warm", "curious", "thoughtful": .curious
        default: .curious
        }
    }

    private func recordContextAnalysisInvocation(
        route: PiModelRoute,
        inference: ModelInferenceResult?,
        context: ActivityContext,
        error: Error?
    ) async {
        guard AgentModelSettings.shared.auditsCloudInvocations else { return }
        let audit = ModelInvocationAudit(
            timestamp: Date(),
            purpose: "context_enrichment",
            route: inference?.route ?? route.inferenceRoute,
            provider: inference?.provider ?? route.provider,
            model: inference?.model ?? route.model,
            sentContextFields: inference?.sentContextFields ?? Self.sentContextFields(in: context),
            usage: nil,
            succeeded: inference != nil && error == nil,
            fallback: nil,
            errorCode: Self.modelErrorCode(error)
        )
        try? await modelAuditStore.append(audit)
    }

    private func recordPiContextAnalysisInvocation(
        route: PiModelRoute,
        result: PiResultPayload?,
        context: ActivityContext,
        error: Error?
    ) async {
        guard AgentModelSettings.shared.auditsCloudInvocations else { return }
        let usage = result.map {
            ModelInvocationAudit.Usage(
                inputTokens: $0.usage.inputTokens,
                outputTokens: $0.usage.outputTokens,
                totalTokens: $0.usage.totalTokens,
                turns: $0.usage.turns,
                toolCalls: $0.usage.toolCalls,
                durationMs: $0.usage.durationMs
            )
        }
        let audit = ModelInvocationAudit(
            timestamp: Date(),
            purpose: "context_enrichment",
            route: route.inferenceRoute,
            provider: result?.model?.provider ?? route.provider,
            model: result?.model?.model ?? route.model,
            sentContextFields: Self.sentContextFields(in: context),
            usage: usage,
            succeeded: result != nil && error == nil,
            fallback: nil,
            errorCode: Self.modelErrorCode(error)
        )
        try? await modelAuditStore.append(audit)
    }

    private static func hasConcreteContext(_ context: ActivityContext) -> Bool {
        context.url != nil
            || context.documentPath != nil
            || (context.selectedText?.count ?? 0) >= 2
            || (context.submittedText?.count ?? 0) >= 2
            || (context.screenText?.count ?? 0) >= 20
            || (context.interactionTarget?.count ?? 0) >= 2
            || (context.contextTransition?.count ?? 0) >= 2
            || (context.contentSummary?.count ?? 0) >= 20
            || (context.windowTitle?.count ?? 0) >= 4
    }

    private static func semanticFingerprint(for context: ActivityContext) -> String {
        [
            context.bundleIdentifier,
            context.url?.absoluteString,
            context.documentPath,
            context.windowIdentifier,
            context.windowTitle,
            context.interactionTarget,
            context.contextTransition,
            context.submittedText.map { String($0.prefix(120)) },
            context.applicationName
        ]
        .compactMap { $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    private static func semanticSignalDescription(for event: ActivityEvent) -> String {
        if event.semantics.contains(.opinionOutput) {
            return event.context.submittedText == nil
                ? "用户在输入后按下回车；请从关键截图 OCR 和页面正文判断具体提交内容"
                : "用户在输入后按下回车；submittedText 是提交前编辑器正文"
        }
        if event.semantics.contains(.compositionStarted) { return "用户开始输入内容" }
        if event.semantics.contains(.readingProgress) { return "用户持续滚动阅读，当前是一个持续状态检查点" }
        if event.semantics.contains(.contextSwitch) { return "用户切换到这个 Context" }
        if event.semantics.contains(.selectionOrActivation) {
            if let transition = event.context.contextTransition {
                return "用户点击后发生真实 Context 变化：\(String(transition.prefix(500)))"
            }
            if let target = event.context.interactionTarget {
                return "用户点击了候选目标「\(String(target.prefix(300)))」，但尚无证据证明发生导航"
            }
            return "用户点击或选择了当前内容，但目标未知"
        }
        return "用户继续处理当前 Context"
    }

    private func makeActivityEvent(
        from signal: SystemActivitySignal,
        activeOverride: ActiveApplicationContext? = nil,
        submittedText: String? = nil,
        screenText: String? = nil,
        interactionTarget: String? = nil,
        contextTransition: String? = nil,
        screenshotResourcePath: String? = nil,
        forceSensitive: Bool = false
    ) -> ActivityEvent {
        let active: ActiveApplicationContext?
        if let activeOverride {
            active = activeOverride
            if signal.kind == .scroll { cachedReadingContext = activeOverride }
        } else if signal.kind == .scroll,
           let cachedReadingContext,
           signal.timestamp.timeIntervalSince(cachedReadingContext.capturedAt) < readingContextRefreshInterval,
           cachedReadingContext.bundleIdentifier == signal.bundleIdentifier || signal.bundleIdentifier == nil {
            active = cachedReadingContext
        } else {
            active = ActiveContextReader.read()
            cachedReadingContext = signal.kind == .scroll ? active : nil
        }
        let sensitive = forceSensitive
            || active?.isSecureInput == true
            || Self.isNeverCollectContext(
                bundleIdentifier: active?.bundleIdentifier ?? signal.bundleIdentifier,
                windowTitle: active?.windowTitle
            )
            || SensitiveContextPolicy.containsActualSecret(
                active?.focusedText,
                active?.selectedText,
                submittedText,
                screenText
            )
        if let active,
           active.bundleIdentifier?.lowercased() != Self.ownBundleIdentifier {
            lastExternalChatContext = active
        }

        let capturedText: String?
        if signal.kind == .returnPressed {
            capturedText = Self.joinedContextText(
                submittedText,
                screenText,
                active?.focusedText,
                active?.visibleText
            )
        } else {
            capturedText = active?.visibleText ?? active?.focusedText
        }
        let context = ActivityContext(
            applicationName: active?.applicationName ?? signal.applicationName,
            bundleIdentifier: active?.bundleIdentifier ?? signal.bundleIdentifier,
            windowTitle: sensitive ? nil : active?.windowTitle,
            windowIdentifier: sensitive ? nil : active?.windowIdentifier,
            url: sensitive ? nil : active?.url,
            documentPath: sensitive ? nil : active?.documentPath,
            contentSummary: sensitive ? nil : Self.boundedContextText(capturedText, limit: 8_000),
            selectedText: sensitive ? nil : active?.selectedText,
            submittedText: sensitive ? nil : submittedText,
            screenText: sensitive ? nil : screenText,
            interactionTarget: sensitive ? nil : interactionTarget,
            contextTransition: sensitive ? nil : contextTransition,
            screenshotResourcePath: sensitive ? nil : screenshotResourcePath,
            semanticTags: Self.semanticTags(
                application: active?.applicationName ?? signal.applicationName,
                title: sensitive ? nil : Self.joinedContextText(
                    active?.windowTitle,
                    active?.url?.host,
                    active?.documentPath
                )
            ),
            isSensitive: sensitive
        )

        return ActivityEvent(
            timestamp: signal.timestamp,
            signal: activitySignal(for: signal),
            context: context
        )
    }

    private func activitySignal(for signal: SystemActivitySignal) -> ActivitySignal {
        switch signal.kind {
        case .primaryClick:
            return .mouseClicked(
                button: .left,
                count: 1,
                location: Self.screenPoint(from: signal.metadata)
            )
        case .secondaryClick:
            return .mouseClicked(
                button: .right,
                count: 1,
                location: Self.screenPoint(from: signal.metadata)
            )
        case .scroll:
            let phase = ScrollPhase(rawValue: signal.metadata["phase"] ?? "") ?? .changed
            return .scrolled(axis: .vertical, delta: signal.magnitude, phase: phase)
        case .typingStarted:
            return .keyboard(.typingStarted)
        case .typingProgress:
            return .keyboard(.typingBurst(estimatedCharacterCount: max(1, Int(signal.magnitude))))
        case .returnPressed:
            return .keyboard(.returnPressed)
        case .deletionBurst:
            return .keyboard(.deletePressed(repeatCount: max(1, Int(signal.magnitude))))
        case .shortcut:
            return .keyboard(.shortcut(name: signal.metadata["modifierPattern"] ?? "shortcut"))
        case .applicationChanged:
            return .applicationActivated(bundleIdentifier: signal.bundleIdentifier)
        case .idle:
            return .idleStarted
        case .resumed:
            return .idleEnded
        }
    }

    private func configureEngineForCurrentAgentHome() {
        let diaryURL = AgentHomePreferences.diaryURL
        guard configuredDiaryURL?.standardizedFileURL != diaryURL.standardizedFileURL else { return }
        do {
            let diary = try AppendOnlyDiary(homeURL: diaryURL)
            engine = ContextMemoryEngine(diary: diary)
            configuredDiaryURL = diaryURL
            modelAuditStore = ModelInvocationAuditStore(rootURL: AgentHomePreferences.rootURL)
            returnCaptureDiagnosticStore = ReturnCaptureDiagnosticStore(
                rootURL: AgentHomePreferences.rootURL
            )
        } catch {
            engine = nil
            configuredDiaryURL = nil
        }
    }

    private static func semanticTags(application: String?, title: String?) -> Set<String> {
        let joined = [application, title].compactMap { $0 }.joined(separator: " ")
        let tokens = joined
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return Set(tokens.prefix(16))
    }

    private static func joinedContextText(_ values: String?...) -> String? {
        let joined = values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
            .joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func boundedContextText(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }

    private static func screenPoint(from metadata: [String: String]) -> ScreenPoint? {
        guard let rawX = metadata["screenX"],
              let rawY = metadata["screenY"],
              let x = Double(rawX),
              let y = Double(rawY) else {
            return nil
        }
        return ScreenPoint(x: x, y: y)
    }

    private static func meaningfulSubmittedText(
        _ value: String?,
        active: ActiveApplicationContext?
    ) -> String? {
        guard let text = boundedContextText(value, limit: 8_000), text.count >= 2 else {
            return nil
        }
        guard !ReturnInputCaptureContract.isLikelyInterfaceChrome(text) else { return nil }
        let normalized = text.lowercased()
        let generic = [
            active?.applicationName,
            active?.windowTitle,
            active?.url?.absoluteString
        ]
            .compactMap { $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !generic.contains(normalized) else { return nil }
        return text
    }

    private static func focusedSubmittedText(
        from active: ActiveApplicationContext?
    ) -> String? {
        guard let active, isTrustedInputContext(active) else { return nil }
        let extracted = FocusedTextSubmissionExtractor.extract(
            focusedText: active.focusedText,
            selectionRange: active.focusedSelectionRange,
            applicationName: active.applicationName,
            bundleIdentifier: active.bundleIdentifier,
            focusedRole: active.focusedRole
        )
        return meaningfulSubmittedText(extracted, active: active)
    }

    private static func isTrustedInputContext(_ active: ActiveApplicationContext) -> Bool {
        guard !active.isSecureInput else { return false }
        let role = active.focusedRole?.lowercased() ?? ""
        let profile = ReturnInputComposerProfile.resolve(
            bundleIdentifier: active.bundleIdentifier,
            applicationName: active.applicationName
        )
        let directInput = role.contains("textfield")
            || role.contains("textarea")
            || role.contains("combobox")
        if directInput {
            if profile == .generic { return true }
            guard let windowFrame = active.windowFrame,
                  let focusedFrame = active.focusedFrame else {
                return false
            }
            return profile.acceptsTrustedInputGeometry(focusedFrame, in: windowFrame)
        }

        // AXWebArea/AXDocument are common wrappers in Electron, but they are
        // also used for chat history, sidebars and entire documents. Trust them
        // only when macOS exposes a concrete caret/selection inside the text.
        let wrapper = role.contains("webarea") || role.contains("document")
        guard wrapper,
              active.focusedSelectionRange != nil,
              let caretFrame = active.focusedCaretFrame else {
            return false
        }
        if profile == .generic { return true }
        guard let windowFrame = active.windowFrame else { return false }
        return profile.acceptsTrustedInputGeometry(caretFrame, in: windowFrame)
    }

    private static func clickSupportsInputContext(
        _ point: CGPoint,
        active: ActiveApplicationContext
    ) -> Bool {
        let profile = ReturnInputComposerProfile.resolve(
            bundleIdentifier: active.bundleIdentifier,
            applicationName: active.applicationName
        )
        if profile != .generic {
            guard let windowFrame = active.windowFrame,
                  profile.validatesTypingAnchor(
                    point,
                    focusedFrame: active.focusedFrame,
                    caretFrame: active.focusedCaretFrame,
                    in: windowFrame
                  ) else {
                return false
            }
            return true
        }
        if let frame = active.focusedFrame {
            let padding = max(12, min(30, frame.height * 0.30))
            return frame.insetBy(dx: -padding, dy: -padding).contains(point)
        } else if let caret = active.focusedCaretFrame {
            return caret.insetBy(dx: -120, dy: -48).contains(point)
        }
        return false
    }

    private func updateDraftCache(
        from active: ActiveApplicationContext?,
        for signal: SystemActivitySignal
    ) {
        guard let active,
              !active.isSecureInput,
              active.bundleIdentifier?.lowercased() != Self.ownBundleIdentifier,
              !SensitiveContextPolicy.isProtectedSurface(
                bundleIdentifier: active.bundleIdentifier,
                windowTitle: active.windowTitle,
                focusedRole: active.focusedRole
              ) else {
            cachedDraftContext = nil
            cachedDraftInputHint = nil
            cachedDraftInputAnchorSource = nil
            retainedInputSessionAnchor = nil
            lastPrimaryClickHint = nil
            return
        }

        let validatedHint = lastPrimaryClickHint.flatMap { hint -> InputFocusHint? in
            guard signal.timestamp.timeIntervalSince(hint.capturedAt) <= 15,
                  hint.bundleIdentifier == nil
                    || active.bundleIdentifier == nil
                    || hint.bundleIdentifier == active.bundleIdentifier,
                  Self.clickSupportsInputContext(hint.point, active: active) else {
                return nil
            }
            return hint
        }
        let profile = ReturnInputComposerProfile.resolve(
            bundleIdentifier: active.bundleIdentifier,
            applicationName: active.applicationName
        )
        let retainedHint: InputFocusHint? = {
            guard validatedHint == nil,
                  let retainedInputSessionAnchor,
                  let windowFrame = active.windowFrame,
                  let point = retainedInputSessionAnchor.resolvedPoint(
                    bundleIdentifier: active.bundleIdentifier,
                    windowIdentifier: active.windowIdentifier,
                    windowFrame: windowFrame,
                    focusedFrame: active.focusedFrame,
                    caretFrame: active.focusedCaretFrame,
                    profile: profile,
                    at: signal.timestamp
                  ) else {
                return nil
            }
            return InputFocusHint(
                point: point,
                bundleIdentifier: active.bundleIdentifier,
                capturedAt: signal.timestamp
            )
        }()

        if let validatedHint {
            cachedDraftContext = active
            cachedDraftInputHint = validatedHint
            cachedDraftInputAnchorSource = .typingBurst
            if let windowFrame = active.windowFrame {
                retainedInputSessionAnchor = ReturnInputSessionAnchor(
                    point: validatedHint.point,
                    bundleIdentifier: active.bundleIdentifier,
                    windowIdentifier: active.windowIdentifier,
                    windowFrame: windowFrame,
                    capturedAt: signal.timestamp
                )
            }
            // This click has been promoted into a validated input-session
            // anchor. It must no longer be reconsidered as generic navigation.
            lastPrimaryClickHint = nil
        } else if let retainedHint {
            cachedDraftContext = active
            cachedDraftInputHint = retainedHint
            cachedDraftInputAnchorSource = .retainedSession
        } else if Self.isTrustedInputContext(active) {
            // A concrete AX editor supersedes an old chat composer. This matters
            // in Feishu where the user can move from the bottom chat box to a
            // document/comment editor without changing applications.
            retainedInputSessionAnchor = nil
            cachedDraftContext = active
            cachedDraftInputHint = nil
            cachedDraftInputAnchorSource = .axFocus
        } else {
            cachedDraftContext = nil
            cachedDraftInputHint = nil
            cachedDraftInputAnchorSource = nil
        }

        if let cachedDraftContext {
            preReturnInputEvidenceBuffer.update(
                active: cachedDraftContext,
                interactionPoint: cachedDraftInputHint?.point,
                profile: profile,
                signalTimestamp: signal.timestamp,
                startsNewSubmission: signal.kind == .typingStarted
            )
        } else {
            preReturnInputEvidenceBuffer.clear()
        }
    }

    /// Input geometry is sampled synchronously while the global listen-only
    /// key callback is still being delivered to the main actor. It remains a
    /// read-only AX lookup, but it cannot be lost when a following Return
    /// cancels the slower diary preparation task.
    private static func immediateInputContext(
        for signal: SystemActivitySignal
    ) -> ActiveApplicationContext? {
        switch signal.kind {
        case .typingStarted, .typingProgress, .returnPressed:
            return ActiveContextReader.read(scope: .focusedElement)
        default:
            return nil
        }
    }

    private static func richerActiveContext(
        _ cached: ActiveApplicationContext?,
        _ current: ActiveApplicationContext?
    ) -> ActiveApplicationContext? {
        guard let cached else { return current }
        guard let current else { return cached }
        let cachedFocused = focusedSubmittedText(from: cached)
        let currentFocused = focusedSubmittedText(from: current)
        if (cachedFocused?.count ?? 0) >= (currentFocused?.count ?? 0) {
            return cached
        }
        return current
    }

    private static func describeContextTransition(
        from before: ActiveApplicationContext?,
        to after: ActiveApplicationContext?,
        target: String?
    ) -> String? {
        guard let before, let after else { return nil }
        let beforePlace = joinedContextText(
            before.applicationName,
            before.windowTitle,
            before.url?.absoluteString
        )
        let afterPlace = joinedContextText(
            after.applicationName,
            after.windowTitle,
            after.url?.absoluteString
        )
        if beforePlace != afterPlace, let beforePlace, let afterPlace {
            let action = target.map { "点击「\(String($0.prefix(180)))」后" } ?? "点击后"
            return "\(action)，从 \(String(beforePlace.prefix(240))) 前往 \(String(afterPlace.prefix(240)))"
        }

        let beforeFocus = [before.focusedRole, before.selectedText]
            .compactMap { $0 }
            .joined(separator: " · ")
        let afterFocus = [after.focusedRole, after.selectedText]
            .compactMap { $0 }
            .joined(separator: " · ")
        if beforeFocus != afterFocus, !afterFocus.isEmpty {
            let action = target.map { "点击「\(String($0.prefix(180)))」" } ?? "点击"
            return "\(action)后激活 \(String(afterFocus.prefix(260)))"
        }
        return nil
    }

    private static func isNeverCollectContext(bundleIdentifier: String?, windowTitle: String?) -> Bool {
        SensitiveContextPolicy.isProtectedSurface(
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle
        )
    }

    private static func isOwnContext(_ context: ActivityContext) -> Bool {
        context.bundleIdentifier?.lowercased() == ownBundleIdentifier
    }
}
