import AgentOneCore
import AppKit
import Darwin
import Foundation
import Vision

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
struct AgentOneCoreHarness {
    static func main() async {
        do {
            if CommandLine.arguments.count >= 3,
               CommandLine.arguments[1] == "--diary-stats" {
                try await printDiaryStats(
                    homePath: CommandLine.arguments[2],
                    day: CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : nil
                )
                return
            }
            if CommandLine.arguments.count >= 3,
               CommandLine.arguments[1] == "--ocr-image" {
                try printOCRImageResult(imagePath: CommandLine.arguments[2])
                return
            }
            let checks = try await run()
            print("AgentOneCore validation passed (\(checks.count) checks)\n")
            for (index, check) in checks.enumerated() {
                print("\(index + 1). ✓ \(check.name)\n   \(check.detail)")
            }
        } catch {
            let message = "AgentOneCore validation failed: \(error)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func printOCRImageResult(imagePath: String) throws {
        let imageURL = URL(fileURLWithPath: imagePath)
        guard let image = NSImage(contentsOf: imageURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw HarnessFailure("Could not decode OCR image at \(imagePath)")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation -> NormalizedOCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return NormalizedOCRLine(
                text: text,
                x: box.minX,
                y: box.minY,
                width: box.width,
                height: box.height,
                confidence: Double(candidate.confidence)
            )
        }

        let result: [String: Any] = [
            "recognizedLineCount": lines.count,
            "inferredSubmittedText": ScreenshotTextExtraction.inferredSubmittedText(from: lines) as Any,
            "recognizedLines": lines.map { line in
                [
                    "text": line.text,
                    "x": line.x,
                    "y": line.y,
                    "width": line.width,
                    "height": line.height,
                    "confidence": line.confidence
                ] as [String: Any]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func printDiaryStats(homePath: String, day: String?) async throws {
        let diary = try AppendOnlyDiary(homeURL: URL(fileURLWithPath: homePath, isDirectory: true))
        let entries = await diary.allEntries()
        let selected: [DiaryEntry]
        if let day {
            var filtered: [DiaryEntry] = []
            for entry in entries where await diary.dayKey(for: entry.timestamp) == day {
                filtered.append(entry)
            }
            selected = filtered
        } else {
            selected = entries
        }
        let replay = SemanticReplayBuilder().build(
            day: day ?? "all",
            entries: selected,
            contextEntries: entries
        )
        let activities = replay.moments.filter { $0.kind == .activity }
        let grouped = Dictionary(grouping: activities.map(\.title)) { title in
            title.split(separator: " ").first.map(String.init) ?? title
        }
        print("sourceEntries=\(selected.count)")
        print("replayMoments=\(replay.moments.count)")
        print("semanticActivitySegments=\(activities.count)")
        let replayKinds = Dictionary(grouping: replay.moments, by: \ .kind)
        for item in replayKinds.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("moment.\(item.key.rawValue)=\(item.value.count)")
        }
        for item in grouped.sorted(by: { $0.key < $1.key }) {
            print("segment.\(item.key)=\(item.value.count)")
        }
        let exactTitles = Dictionary(grouping: activities, by: \.title)
            .map { (title: $0.key, count: $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs.title < rhs.title }
                return lhs.count > rhs.count
            }
        for item in exactTitles.prefix(30) {
            print("top=\(item.count)|\(item.title)")
        }
        let nonActivityTitles = Dictionary(
            grouping: replay.moments.filter { $0.kind != .activity },
            by: { "\($0.kind.rawValue)|\($0.title)" }
        )
        .map { (label: $0.key, count: $0.value.count) }
        .sorted { lhs, rhs in
            if lhs.count == rhs.count { return lhs.label < rhs.label }
            return lhs.count > rhs.count
        }
        for item in nonActivityTitles.prefix(30) {
            print("other=\(item.count)|\(item.label)")
        }
        let habits = HabitContextExtractor().extract(from: selected)
        print("habitContexts=\(habits.count)")
        for habit in habits {
            print("habit=\(habit.title)|sessions=\(habit.supportingSessionCount)|confidence=\(String(format: "%.2f", habit.confidence))")
        }
    }

    private static func run() async throws -> [HarnessCheck] {
        var checks: [HarnessCheck] = []
        checks.append(try validatePassiveKeyboardReduction())
        checks.append(try validateSubmittedTextReconciliation())
        checks.append(try validateBrowserContextURLResolution())
        checks.append(try validateFocusedTextSubmissionExtraction())
        checks.append(try validateScreenshotSubmittedTextExtraction())
        checks.append(try validateReturnInputCaptureContract())
        checks.append(try validateReplaySurfaceSeparation())
        checks.append(try await validateSkillProgression())
        try validateHookSemantics()
        checks.append(HarnessCheck(
            name: "Hook semantics",
            detail: "Return is treated as opinion output/task submission; scrolling is reading progress; a click remains a candidate until Context changes."
        ))
        checks.append(try await validateReturnScreenshotEvidence())
        checks.append(contentsOf: try await validateContinuousActivityAndHabits())
        checks.append(contentsOf: try await validateModelEnrichedContextStability())
        checks.append(contentsOf: try await validateLateContextEnrichmentProjection())
        checks.append(contentsOf: try await validateUnifiedSemanticActivityStateMachine())
        checks.append(contentsOf: try await validateLegacyDiaryReadProjection())
        checks.append(contentsOf: try await validateNoiseGateAndShortActivityDebounce())
        checks.append(contentsOf: try await validateFocusEpisodeDebounceAndProjection())
        checks.append(contentsOf: try await validateDailyDigestAndProactivePolicy())

        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOneCoreHarness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        let timeZone = try requireValue(
            TimeZone(secondsFromGMT: 0),
            "Could not construct the deterministic harness time zone."
        )
        let diary = try AppendOnlyDiary(homeURL: temporaryHome, timeZone: timeZone)
        let driftConfiguration = DriftConfiguration(
            relevanceThreshold: 0.3,
            uncertaintyBand: 0.3...0.45,
            stages: [
                ReminderStage(level: 1, after: 30, modalities: [.creatureMotion]),
                ReminderStage(level: 2, after: 60, modalities: [.creatureMotion, .textBubble])
            ]
        )
        let engine = ContextMemoryEngine(
            configuration: ContextEngineConfiguration(drift: driftConfiguration),
            diary: diary
        )

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let taskContext = ActivityContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            windowTitle: "ADHD attention recovery paper",
            contentSummary: "Writing a research paper about ADHD and attention recovery",
            selectedText: "Reducing context-switching cost helps attention recovery.",
            semanticTags: ["adhd", "attention", "paper", "research"]
        )
        let distractionContext = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Comedy short videos",
            contentSummary: "An unrelated entertainment recommendation feed",
            semanticTags: ["comedy", "video", "entertainment"]
        )

        let intent = try await engine.beginIntent(
            title: "Write the ADHD paper",
            summary: "Develop the section about attention recovery",
            context: taskContext,
            at: base
        )
        try require(intent.state == .active, "A user-provided intent should start active.")

        _ = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(10),
            signal: .windowFocused(windowIdentifier: "video-window"),
            context: distractionContext
        ))
        let firstEscalation = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(41),
            signal: .scrolled(axis: .vertical, delta: 240, phase: .changed),
            context: distractionContext
        ))
        let secondEscalation = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(71),
            signal: .scrolled(axis: .vertical, delta: 320, phase: .momentum),
            context: distractionContext
        ))

        try require(firstEscalation.prompts.reminderLevels == [1], "Expected reminder level 1 after 30 seconds of drift.")
        try require(secondEscalation.prompts.reminderLevels == [2], "Expected reminder level 2 after 60 seconds of drift.")
        checks.append(HarnessCheck(
            name: "Intent and drift escalation",
            detail: "The active writing intention stayed stable while an unrelated video context escalated from creature motion to a text reminder."
        ))

        let returnCandidate = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(80),
            signal: .keyboard(.typingStarted),
            context: taskContext
        ))
        try require(!returnCandidate.prompts.containsReturn, "One related hook prematurely closed a drift episode.")
        let returned = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(90),
            signal: .keyboard(.typingBurst(estimatedCharacterCount: 8)),
            context: taskContext
        ))
        try require(returned.prompts.containsReturn, "Sustained writing did not close the drift episode.")
        _ = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(91),
            signal: .keyboard(.returnPressed),
            context: taskContext
        ))
        checks.append(HarnessCheck(
            name: "Return to task",
            detail: "Ten seconds of sustained writing closed the drift episode, and a subsequent Return hook preserved a key thought as evidence."
        ))

        let original = try await diary.append(
            .daySummary("AgentOne initially interpreted a research detour as distraction."),
            at: base.addingTimeInterval(90)
        )
        _ = try await diary.appendCorrection(
            to: original.id,
            text: "The detour was related research.",
            at: base.addingTimeInterval(91)
        )
        _ = try await diary.setHidden(
            true,
            entryID: original.id,
            reason: "The entry contains a sensitive detail.",
            at: base.addingTimeInterval(92)
        )
        let projection = await diary.projection()
        try require(projection.hiddenEntryIDs.contains(original.id), "The sensitive source entry was not hidden.")
        try require(
            projection.correctionsByEntryID[original.id]?.first?.correction == "The detour was related research.",
            "The appended correction was not retained."
        )
        let allEntries = await diary.allEntries()
        try require(allEntries.contains(where: { $0.id == original.id }), "Hiding must not delete or rewrite the original entry.")
        checks.append(HarnessCheck(
            name: "Append-only diary",
            detail: "The original memory remained intact; correction and hiding were represented as later immutable events."
        ))

        _ = try await engine.addAgentReflection(AgentReflection(
            timestamp: base.addingTimeInterval(100),
            observation: "The user found the thread again.",
            hypothesis: "The gentle reminder timing may have helped.",
            consideredAction: "Keep this rhythm for similar writing sessions.",
            disposition: .heldBack,
            why: "The user was already writing again, so speaking would add noise."
        ))
        let replay = await engine.replay(for: base)
        try require(replay.moments.contains(where: { $0.lane == .userActivity }), "Replay is missing the user's activity lane.")
        try require(replay.moments.contains(where: { $0.lane == .agentMind }), "Replay is missing AgentOne's inner diary lane.")
        try require(replay.moments.contains(where: { $0.kind == .returned }), "Replay is missing the return-to-task moment.")
        try require(!replay.evidence.isEmpty, "Replay is missing hook-triggered key evidence.")
        checks.append(HarnessCheck(
            name: "Two-perspective semantic replay",
            detail: "The day's review contains user activity, AgentOne's held-back thought, the successful return, and hook-triggered evidence."
        ))

        let reloadedDiary = try AppendOnlyDiary(homeURL: temporaryHome, timeZone: timeZone)
        let reloadedEntries = await reloadedDiary.allEntries()
        let day = await diary.dayKey(for: base)
        let markdownURL = temporaryHome.appendingPathComponent("Daily/\(day).md")
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        let persistedEntries = await diary.allEntries()
        try require(reloadedEntries == persistedEntries, "Reloaded entries differ from the append order written to Markdown.")
        try require(markdown.contains("Inside AgentOne"), "Human-readable Markdown is missing the Agent reflection.")
        try require(markdown.contains("agentone-json"), "Markdown is missing its reloadable structured payload.")
        checks.append(HarnessCheck(
            name: "Markdown persistence",
            detail: "The daily Markdown remained human-readable and reloaded into the same structured append order after restart."
        ))

        return checks
    }

    private static func validatePassiveKeyboardReduction() throws -> HarnessCheck {
        var reducer = KeyboardSignalReducer(
            typingSessionGap: 1.5,
            typingProgressInterval: 0.75
        )
        let start = Date(timeIntervalSince1970: 1_700_100_000)

        let first = reducer.consume(KeyboardObservation(
            timestamp: start,
            kind: .textInput(estimatedCharacterCount: 1),
            isAutorepeat: false
        ))
        try require(first == [.typingStarted], "The first physical key scheduled more than one typing signal.")

        for offset in [0.1, 0.2, 0.3, 0.4, 0.5] {
            let intermediate = reducer.consume(KeyboardObservation(
                timestamp: start.addingTimeInterval(offset),
                kind: .textInput(estimatedCharacterCount: 1),
                isAutorepeat: false
            ))
            try require(intermediate.isEmpty, "Typing was not coalesced before main-actor delivery.")
        }

        let progress = reducer.consume(KeyboardObservation(
            timestamp: start.addingTimeInterval(0.8),
            kind: .textInput(estimatedCharacterCount: 1),
            isAutorepeat: false
        ))
        try require(
            progress == [.typingProgress(estimatedCharacterCount: 7)],
            "The coalesced typing count was not preserved."
        )

        let physicalReturn = reducer.consume(KeyboardObservation(
            timestamp: start.addingTimeInterval(1),
            kind: .returnKey,
            isAutorepeat: false
        ))
        let repeatedReturn = reducer.consume(KeyboardObservation(
            timestamp: start.addingTimeInterval(1.04),
            kind: .returnKey,
            isAutorepeat: true
        ))
        try require(physicalReturn == [.returnPressed], "A physical Return did not create exactly one signal.")
        try require(repeatedReturn.isEmpty, "A macOS autorepeat Return escaped the safety reducer.")

        return HarnessCheck(
            name: "Passive keyboard safety boundary",
            detail: "One physical key creates at most one semantic transition; ordinary typing is coalesced before main-actor work and macOS autorepeat copies are ignored."
        )
    }

    private static func validateBrowserContextURLResolution() throws -> HarnessCheck {
        let candidates = [
            BrowserAddressBarCandidate(
                role: "AXLink",
                title: "Link inside article",
                url: "https://wrong.example/link"
            ),
            BrowserAddressBarCandidate(
                role: "AXTextField",
                description: "Address and search bar",
                value: "arxiv.org/abs/1706.03762"
            )
        ]
        let chromeURL = try requireValue(
            BrowserContextURLResolver.resolve(
                bundleIdentifier: "com.google.Chrome",
                applicationName: "Google Chrome",
                addressBarCandidates: candidates,
                fallbackURLs: ["https://wrong.example/page"]
            ),
            "Chrome address bar did not produce a page URL."
        )
        try require(
            chromeURL.absoluteString == "https://arxiv.org/abs/1706.03762",
            "Chrome selected a page link instead of the address-bar URL."
        )
        try require(
            BrowserContextURLResolver.resolve(
                bundleIdentifier: "com.google.Chrome",
                applicationName: "Google Chrome",
                addressBarCandidates: [
                    BrowserAddressBarCandidate(
                        role: "AXComboBox",
                        description: "Address and search bar",
                        value: "attention recovery"
                    )
                ],
                fallbackURLs: ["https://example.com/current"]
            )?.absoluteString == "https://example.com/current",
            "A search query was incorrectly persisted as a URL."
        )
        try require(
            BrowserContextURLResolver.normalizePageURL(
                "https://example.com/paper?chapter=2&access_token=secret&view=full#section"
            )?.absoluteString == "https://example.com/paper?chapter=2&view=full",
            "Sensitive URL query material was not removed."
        )
        return HarnessCheck(
            name: "Browser address-bar Context",
            detail: "Chrome/Safari-style address fields outrank page links, search text is ignored, and sensitive query state is removed before URL persistence."
        )
    }

    private static func validateReplaySurfaceSeparation() throws -> HarnessCheck {
        let timestamp = Date(timeIntervalSince1970: 1_722_787_200)
        func moment(
            _ kind: ReplayMomentKind,
            lane: ReplayLane,
            offset: TimeInterval
        ) -> ReplayMoment {
            ReplayMoment(
                timestamp: timestamp.addingTimeInterval(offset),
                lane: lane,
                kind: kind,
                title: kind.rawValue,
                sourceEntryID: UUID()
            )
        }

        let activity = moment(.activity, lane: .userActivity, offset: 0)
        let evidence = moment(.evidence, lane: .userActivity, offset: 1)
        let thought = moment(.thought, lane: .agentMind, offset: 2)
        let skill = moment(.learnedSkill, lane: .agentMind, offset: 3)
        let digest = DailyContextDigest(
            day: "2026-08-10",
            generatedAt: timestamp,
            headline: "把今天串成一条线",
            overview: "Context 日志保留事实，Agent 日记负责提炼。",
            highlights: ["回放保留事实", "日记负责总结"],
            agentNote: "原始经历和我的理解，应该各自待在合适的位置。",
            mood: "thoughtful",
            sourceContextCount: 2,
            evidenceCount: 1,
            personalizedMemoryCount: 1
        )
        let summary = ReplayMoment(
            timestamp: timestamp.addingTimeInterval(4),
            lane: .relationship,
            kind: .summary,
            title: digest.headline,
            sourceEntryID: UUID(),
            dailyDigest: digest
        )
        let replay = SemanticReplay(
            day: digest.day,
            moments: [activity, evidence, thought, skill, summary],
            evidence: []
        )

        try require(
            replay.contextLogMoments.map(\.id) == [activity.id, evidence.id],
            "Replay included Agent thoughts, summaries or learned skills instead of factual Context only."
        )
        try require(
            replay.agentJournalMoments.map(\.id) == [thought.id],
            "Agent Journal copied ordinary Context events instead of subjective reflections only."
        )
        try require(
            replay.latestDailyContextDigest == digest,
            "The daily digest was not projected into the Agent Journal summary."
        )
        let replayIDs = Set(replay.contextLogMoments.map(\.id))
        let journalIDs = Set(replay.agentJournalMoments.map(\.id))
        try require(
            replayIDs.isDisjoint(with: journalIDs),
            "Replay and Agent Journal projections shared entries."
        )

        return HarnessCheck(
            name: "Replay and Agent Journal separation",
            detail: "Replay projects only factual Context events; Agent Journal projects the daily digest and LUMA reflections with no duplicated timeline entries."
        )
    }

    private static func validateSubmittedTextReconciliation() throws -> HarnessCheck {
        let reconciled = SubmittedTextReconciler.reconcile(
            draftText: "我授权了，你看看能不能pao ton",
            screenText: """
            AgentOne 设置
            现在真实跑通的有：
            我授权了，你看看能不能跑通
            完全访问
            """
        )
        try require(
            reconciled == "我授权了，你看看能不能跑通",
            "Committed Chinese text visible in the screenshot did not replace unfinished IME pinyin."
        )
        let singleLetterIME = SubmittedTextReconciler.reconcile(
            draftText: "我给你反馈的问题都做完了？特别是s",
            screenText: """
            我给你反馈的问题都做完了？特别是识别输入框
            我给你反馈的问题都做完了？特别是识别输入框
            """
        )
        try require(
            singleLetterIME == "我给你反馈的问题都做完了？特别是识别输入框",
            "A one-letter Chinese IME draft tail was not reconciled with the committed ROI OCR text."
        )
        let ordinaryEnglish = SubmittedTextReconciler.reconcile(
            draftText: "ship the AgentOne build",
            screenText: "Recent tasks\nship the AgentOne build\nSettings"
        )
        try require(
            ordinaryEnglish == "ship the AgentOne build",
            "An exact non-IME submission was changed."
        )
        let separatedEnglishToken = SubmittedTextReconciler.reconcile(
            draftText: "这个接口使用 GPT",
            screenText: "这个接口使用通用模型\nSettings"
        )
        try require(
            separatedEnglishToken == "这个接口使用 GPT",
            "A normal separated English token was mistaken for unfinished pinyin."
        )
        let attachedEnglishSuffix = SubmittedTextReconciler.reconcile(
            draftText: "发布版本vNext",
            screenText: "发布版本五\nSettings"
        )
        try require(
            attachedEnglishSuffix == "发布版本vNext",
            "A mixed-case English suffix was mistaken for unfinished lowercase pinyin."
        )
        let unrelated = SubmittedTextReconciler.reconcile(
            draftText: "write the ADHD paper",
            screenText: "Music playlist\nVideo recommendations\nSettings"
        )
        try require(
            unrelated == "write the ADHD paper",
            "Unrelated screen OCR replaced the sampled editor text."
        )
        return HarnessCheck(
            name: "Return IME reconciliation",
            detail: "Committed Chinese glyphs visible in the key screenshot replace long or one-letter unfinished pinyin, while exact, English, and unrelated text remain unchanged."
        )
    }

    private static func validateSkillProgression() async throws -> HarnessCheck {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOneSkillProgressionHarness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }
        let timeZone = try requireValue(
            TimeZone(secondsFromGMT: 0),
            "Could not construct the Skill progression time zone."
        )
        let diary = try AppendOnlyDiary(homeURL: temporaryHome, timeZone: timeZone)
        let engine = ContextMemoryEngine(diary: diary)
        let base = Date(timeIntervalSince1970: 1_720_000_000)

        let first = try requireValue(
            try await engine.addFeedback(UserFeedback(
                timestamp: base,
                kind: .reminderHelpful
            )),
            "The first feedback did not create a Skill."
        )
        let second = try requireValue(
            try await engine.addFeedback(UserFeedback(
                timestamp: base.addingTimeInterval(60),
                kind: .reminderHelpful
            )),
            "Repeated feedback did not reinforce the Skill."
        )

        try require(first.id == second.id, "Skill reinforcement created a duplicate identity.")
        try require(second.revision == first.revision + 1, "Skill revision did not advance.")
        try require(second.sourceEntryIDs.count == 2, "Skill evidence was not accumulated.")
        try require(second.confidence > first.confidence, "Skill confidence did not grow after reinforcement.")
        try require(second.completion > first.completion, "Skill completion did not grow after reinforcement.")
        try require(second.masteryLevel >= first.masteryLevel, "Skill unlock level regressed after reinforcement.")

        let persisted = await engine.persistedSkills()
        try require(persisted.count == 1, "Persisted Skill revisions appeared as duplicate Skills.")
        try require(persisted.first?.revision == second.revision, "The latest Skill revision was not projected.")

        let reloadedDiary = try AppendOnlyDiary(homeURL: temporaryHome, timeZone: timeZone)
        let reloadedEngine = ContextMemoryEngine(diary: reloadedDiary)
        await reloadedEngine.restorePersistedSkills()
        let restored = await reloadedEngine.skills()
        try require(restored.count == 1, "The reinforced Skill did not survive restart.")
        try require(restored.first?.completion == second.completion, "Skill completion changed after restart.")

        return HarnessCheck(
            name: "Inspectable Skill progression",
            detail: "Repeated real feedback now reinforces one append-only Skill revision, increases evidence/confidence/completion, advances unlock levels, and survives restart without duplicate cards."
        )
    }

    private static func validateFocusedTextSubmissionExtraction() throws -> HarnessCheck {
        let terminalSubmission = "我觉得如果用户走神了可以让精灵的颜色变化来提醒，现在的颜色变化逻辑是什么"
        let scrollback = (0..<80)
            .map { "模型输出第 \($0) 行：这是终端历史内容，不应进入本次提交。" }
            .joined(separator: "\n")
        let terminalText = "\(scrollback)\n❯ \(terminalSubmission)"
        let terminalValue = terminalText as NSString
        let terminalRange = terminalValue.range(of: terminalSubmission)
        let terminalCaret = NSMaxRange(terminalRange)
        let extractedTerminal = FocusedTextSubmissionExtractor.extract(
            focusedText: terminalText,
            selectionRange: terminalCaret..<terminalCaret,
            applicationName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            focusedRole: "AXTextArea"
        )
        try require(
            extractedTerminal == terminalSubmission,
            "A terminal AXTextArea returned scrollback instead of only the prompt at the caret."
        )

        let documentParagraph = "这一段在解释 ADHD 用户走神后为什么很难回到原任务。\n产品需要保存任务现场，并提供一键跳回。"
        let documentText = (0..<35)
            .map { "旧段落 \($0)：这是论文里的背景材料。" }
            .joined(separator: "\n\n")
            + "\n\n\(documentParagraph)\n\n后续章节"
        let documentValue = documentText as NSString
        let documentRange = documentValue.range(of: documentParagraph)
        let documentCaret = NSMaxRange(documentRange)
        let extractedParagraph = FocusedTextSubmissionExtractor.extract(
            focusedText: documentText,
            selectionRange: documentCaret..<documentCaret,
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            focusedRole: "AXTextArea"
        )
        try require(
            extractedParagraph == documentParagraph,
            "A large document did not isolate the paragraph containing the caret (got: \(extractedParagraph ?? "nil"))."
        )

        let multilineComposer = "第一行是背景\n第二行是我准备提交的结论"
        let extractedComposer = FocusedTextSubmissionExtractor.extract(
            focusedText: multilineComposer,
            selectionRange: nil,
            applicationName: "飞书",
            bundleIdentifier: "com.bytedance.ee.larkmac",
            focusedRole: "AXTextArea"
        )
        try require(
            extractedComposer == multilineComposer,
            "A compact multi-line chat composer did not retain its complete text."
        )

        let missingCaret = FocusedTextSubmissionExtractor.extract(
            focusedText: terminalText,
            selectionRange: nil,
            applicationName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            focusedRole: "AXTextArea"
        )
        try require(
            missingCaret == nil,
            "A large terminal surface without a caret was incorrectly persisted as submitted text."
        )

        return HarnessCheck(
            name: "Caret-scoped Return extraction",
            detail: "Terminal scrollback is reduced to the current prompt, large editors retain only the caret paragraph, compact chat composers keep all lines, and missing-caret terminal text falls back to OCR."
        )
    }

    private static func validateScreenshotSubmittedTextExtraction() throws -> HarnessCheck {
        let submitted = "还是有问题，现在能截图但是不能识别到里面的内容"
        let noisyWindow = [
            NormalizedOCRLine(text: "ChatGPT", x: 0.03, y: 0.94, width: 0.12, height: 0.03),
            NormalizedOCRLine(text: "最近的页面内容", x: 0.23, y: 0.86, width: 0.30, height: 0.035),
            NormalizedOCRLine(text: "AgentOne 正在讨论 Context 识别链路", x: 0.18, y: 0.60, width: 0.55, height: 0.035),
            NormalizedOCRLine(text: submitted, x: 0.22, y: 0.095, width: 0.55, height: 0.04, confidence: 0.98),
            NormalizedOCRLine(text: "tokenhub", x: 0.06, y: 0.055, width: 0.10, height: 0.025),
            NormalizedOCRLine(text: "5.6 Sol 中", x: 0.79, y: 0.052, width: 0.11, height: 0.025),
            NormalizedOCRLine(text: "完全访问", x: 0.90, y: 0.018, width: 0.08, height: 0.02)
        ]
        let mirroredFocusRegions = [
            NormalizedOCRRegion(x: 0.18, y: 0.82, width: 0.66, height: 0.12),
            NormalizedOCRRegion(x: 0.18, y: 0.045, width: 0.66, height: 0.12)
        ]
        let focused = ScreenshotTextExtraction.text(
            in: mirroredFocusRegions,
            from: noisyWindow
        )
        try require(
            focused == submitted,
            "Focused OCR did not isolate the submitted composer text from the mirrored region and window chrome."
        )

        let inferred = ScreenshotTextExtraction.inferredSubmittedText(from: noisyWindow)
        try require(
            inferred == submitted,
            "Bottom-composer fallback did not recover the submitted text when Accessibility coordinates were absent."
        )
        try require(
            inferred?.contains("ChatGPT") == false
                && inferred?.contains("tokenhub") == false
                && inferred?.contains("5.6 Sol 中") == false,
            "Composer fallback mistook window chrome or token counters for submitted text."
        )

        let wrappedLines = [
            NormalizedOCRLine(text: "第一行说明截图已经成功，", x: 0.20, y: 0.145, width: 0.50, height: 0.035),
            NormalizedOCRLine(text: "第二行要求识别刚刚提交的原文", x: 0.20, y: 0.105, width: 0.55, height: 0.035),
            NormalizedOCRLine(text: "发送", x: 0.82, y: 0.055, width: 0.06, height: 0.025)
        ]
        let wrapped = ScreenshotTextExtraction.inferredSubmittedText(from: wrappedLines)
        try require(
            wrapped == "第一行说明截图已经成功，\n第二行要求识别刚刚提交的原文",
            "Wrapped composer text was not retained in reading order."
        )

        let terminalSubmission = "我觉得如果用户走神了可以让精灵的颜色变化来提醒，现在的颜色变化逻辑是什么"
        let terminalTUI = [
            NormalizedOCRLine(text: "上一段模型输出", x: 0.10, y: 0.48, width: 0.30, height: 0.03),
            NormalizedOCRLine(text: terminalSubmission, x: 0.097, y: 0.356, width: 0.70, height: 0.04, confidence: 0.99),
            NormalizedOCRLine(text: "Tip: shift+tab changes mode", x: 0.10, y: 0.12, width: 0.34, height: 0.025),
            NormalizedOCRLine(text: "thinking: off", x: 0.10, y: 0.085, width: 0.18, height: 0.025),
            NormalizedOCRLine(text: "82% context left", x: 0.78, y: 0.05, width: 0.15, height: 0.025)
        ]
        try require(
            ScreenshotTextExtraction.inferredSubmittedText(from: terminalTUI) == terminalSubmission,
            "Terminal text around 38% window height was not recovered above footer/status chrome."
        )

        let largeFocusedRegion = (0..<18)
            .map { "终端历史第 \($0) 行" }
            .joined(separator: "\n")
        try require(
            ScreenshotTextExtraction.preferredSubmittedText(
                focusedRegionText: largeFocusedRegion,
                inferredSubmittedText: terminalSubmission
            ) == terminalSubmission,
            "A large focus-region OCR candidate overrode the smaller inferred terminal prompt."
        )
        try require(
            ScreenshotTextExtraction.preferredSubmittedText(
                focusedRegionText: "用飞书cli去扒一下有没有ai相关的产\nNew project 2\n找一下这个电脑里的Learn Claude\nhttps://example.test/wiki",
                inferredSubmittedText: submitted
            ) == submitted,
            "A compact but multi-line Accessibility sidebar candidate overrode the one-line screenshot composer."
        )

        let codexThreeColumn = [
            NormalizedOCRLine(text: "继续完成剩余功能", x: 0.015, y: 0.066, width: 0.15, height: 0.032, confidence: 0.98),
            NormalizedOCRLine(text: "没有区别啊，还是空的，而且可选项都没了", x: 0.387, y: 0.062, width: 0.38, height: 0.04, confidence: 0.98),
            NormalizedOCRLine(text: "完全访问", x: 0.91, y: 0.018, width: 0.07, height: 0.02)
        ]
        try require(
            ScreenshotTextExtraction.inferredSubmittedText(from: codexThreeColumn)
                == "没有区别啊，还是空的，而且可选项都没了",
            "The bottom-center Codex composer lost to unrelated text in the left task list."
        )

        let realCodexGeometry = [
            NormalizedOCRLine(text: "用飞书cli去扒一下有没有ai相关的产", x: 0.020, y: 0.188, width: 0.115, height: 0.016, confidence: 1),
            NormalizedOCRLine(text: "找一下这个电脑里的Learn Claude", x: 0.020, y: 0.093, width: 0.113, height: 0.016, confidence: 1),
            NormalizedOCRLine(text: "• AI查价没有把附近回收商、行情、分享等计划全部写成二上线；", x: 0.381, y: 0.118, width: 0.214, height: 0.019, confidence: 0.5),
            NormalizedOCRLine(text: "企业知识治理是wiki知识库啊", x: 0.387, y: 0.077, width: 0.094, height: 0.016, confidence: 1),
            NormalizedOCRLine(text: "+ ◎完全访问", x: 0.388, y: 0.028, width: 0.055, height: 0.015, confidence: 0.3),
            NormalizedOCRLine(text: "5.6 Sol高 0", x: 0.708, y: 0.023, width: 0.051, height: 0.023, confidence: 0.3)
        ]
        try require(
            ScreenshotTextExtraction.inferredSubmittedText(from: realCodexGeometry)
                == "企业知识治理是wiki知识库啊",
            "A long document line or decorated footer overrode the real Codex composer text."
        )

        let fullText = ScreenshotTextExtraction.fullText(from: noisyWindow)
        try require(
            fullText?.contains("最近的页面内容") == true
                && fullText?.contains(submitted) == true
                && fullText?.contains("ChatGPT") == true,
            "Full-window OCR was truncated to the composer instead of retaining page Context."
        )

        return HarnessCheck(
            name: "Return screenshot text extraction",
            detail: "Focused and no-Accessibility text selectors remain available for bounded ROI OCR tests; full-window OCR is now intentionally kept out of the Return submission path."
        )
    }

    private static func validateReturnInputCaptureContract() throws -> HarnessCheck {
        let window = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let input = CGRect(x: 240, y: 680, width: 720, height: 72)
        let focusedRegions = ReturnInputCaptureContract.regions(
            focusedFrame: input,
            caretFrame: nil,
            windowFrame: window
        )
        try require(
            focusedRegions.contains(where: { $0.source == .focusedInput }),
            "A compact AX input frame did not produce a focused-input crop."
        )
        try require(
            focusedRegions.allSatisfy { $0.area < 0.55 },
            "Focused Return ROI grew back into a window-sized crop."
        )

        let largeEditor = CGRect(x: 0, y: 0, width: 1_200, height: 760)
        let caret = CGRect(x: 560, y: 642, width: 2, height: 20)
        let caretRegions = ReturnInputCaptureContract.regions(
            focusedFrame: largeEditor,
            caretFrame: caret,
            windowFrame: window
        )
        try require(
            caretRegions.contains(where: { $0.source == .caretNeighborhood })
                && !caretRegions.contains(where: { $0.source == .focusedInput }),
            "A document-sized focus frame was not reduced to a caret neighborhood."
        )

        let fallbackRegions = ReturnInputCaptureContract.regions(
            focusedFrame: nil,
            caretFrame: nil,
            windowFrame: window
        )
        try require(
            fallbackRegions.allSatisfy { $0.source == .inferredComposerRegion && $0.area <= 0.30 },
            "The no-Accessibility fallback was allowed to become full-window OCR."
        )

        let userOpinion = "回车应该只识别当前输入框里的观点"
        let candidates = [
            ReturnInputOCRCandidate(
                id: 0,
                source: .focusedInput,
                recognizedText: "侧栏旧任务\n历史聊天噪音",
                submittedText: "侧栏旧任务\n历史聊天噪音",
                recognizedLineCount: 2,
                averageConfidence: 0.98
            ),
            ReturnInputOCRCandidate(
                id: 1,
                source: .focusedInput,
                recognizedText: userOpinion,
                submittedText: userOpinion,
                recognizedLineCount: 1,
                averageConfidence: 0.92
            )
        ]
        let selected = try requireValue(
            ReturnInputCaptureContract.selectOCRCandidate(candidates, referenceText: userOpinion),
            "The Return OCR selector returned no candidate."
        )
        try require(selected.id == 1, "Sidebar/history OCR beat the text from the actual input box.")

        let clearedComposer = [
            ReturnInputOCRCandidate(
                id: 2,
                source: .focusedInput,
                recognizedText: nil,
                submittedText: nil,
                recognizedLineCount: 0,
                averageConfidence: 0
            ),
            ReturnInputOCRCandidate(
                id: 3,
                source: .focusedInput,
                recognizedText: "侧栏很长的历史内容",
                submittedText: "侧栏很长的历史内容",
                recognizedLineCount: 1,
                averageConfidence: 0.99
            )
        ]
        let clearedSelection = try requireValue(
            ReturnInputCaptureContract.selectOCRCandidate(clearedComposer, referenceText: userOpinion),
            "The selector failed to keep an empty composer crop after Return cleared it."
        )
        try require(clearedSelection.id == 2, "Mirrored window noise replaced the cleared input-box evidence.")

        let modelText = try requireValue(
            ReturnInputCaptureContract.modelScreenText(from: userOpinion),
            "The model screenText contract did not create an input-region payload."
        )
        try require(modelText.contains("回车输入区域 OCR") && !modelText.contains("侧栏"), "The model payload still carried window noise.")

        // Full-display OCR must refine a compact focused composer, never jump
        // to the just-sent bubble/history row that happens to contain the same
        // words. Vision coordinates use a lower-left origin; the contract must
        // still choose the mirrored candidate that overlaps the AX input box.
        let compactInput = CGRect(x: 240, y: 680, width: 720, height: 72)
        let duplicateHistory = "这是用户刚刚在输入框里写下的观点，需要被准确捕获"
        let fullScreenLines = [
            NormalizedOCRLine(
                text: "网安群 208条 历史消息",
                x: 0.03, y: 0.30, width: 0.18, height: 0.025, confidence: 0.99
            ),
            NormalizedOCRLine(
                text: duplicateHistory,
                x: 0.38, y: 0.30, width: 0.44, height: 0.035, confidence: 0.99
            ),
            NormalizedOCRLine(
                text: duplicateHistory,
                x: 0.38, y: 0.10, width: 0.44, height: 0.035, confidence: 0.96
            ),
            NormalizedOCRLine(
                text: "发送",
                x: 0.86, y: 0.07, width: 0.06, height: 0.025, confidence: 0.98
            )
        ]
        let locatedRegions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: fullScreenLines,
            focusedFrame: compactInput,
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: duplicateHistory
        )
        try require(!locatedRegions.isEmpty, "Full-screen OCR could not locate the compact composer.")
        try require(
            locatedRegions.contains { region in
                region.source == .focusedInput
                    && region.x > 0.15
                    && region.x < 0.48
                    && region.y > 0.72
                    && region.y < 0.98
            },
            "The full-screen locator returned a history/sidebar crop instead of the focused composer."
        )
        try require(
            locatedRegions.allSatisfy { $0.x > 0.12 && $0.width < 0.80 },
            "The locator leaked the left sidebar into the input ROI."
        )

        // Electron/chat apps may expose no useful AX input at all. Even when a
        // sidebar and history bubble contain exactly the same sentence, the
        // OCR line nearest the click that began the typing burst must win.
        let clickAnchoredLines = [
            NormalizedOCRLine(
                text: duplicateHistory,
                x: 0.03, y: 0.62, width: 0.18, height: 0.035, confidence: 0.99
            ),
            NormalizedOCRLine(
                text: duplicateHistory,
                x: 0.35, y: 0.40, width: 0.44, height: 0.035, confidence: 0.99
            ),
            NormalizedOCRLine(
                text: duplicateHistory,
                x: 0.35, y: 0.065, width: 0.44, height: 0.035, confidence: 0.94
            )
        ]
        let clickAnchoredRegions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: clickAnchoredLines,
            focusedFrame: nil,
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: duplicateHistory,
            interactionPoint: CGPoint(x: 720, y: 80)
        )
        try require(!clickAnchoredRegions.isEmpty, "Click-anchored OCR produced no input ROI without Accessibility.")
        try require(
            clickAnchoredRegions.allSatisfy { $0.x > 0.25 && $0.width < 0.60 },
            "Duplicate sidebar/history text escaped the click-anchor gate."
        )
        try require(
            clickAnchoredRegions.contains(where: { $0.y < 0.20 })
                && clickAnchoredRegions.contains(where: { $0.y > 0.70 }),
            "The locator did not retain safe direct/mirrored crops around the clicked composer."
        )

        // A compact AX element is not trustworthy when it conflicts with the
        // last click before typing (for example WeChat exposing its search box
        // while the user is composing at the bottom of the conversation).
        let conflictingAXRegions = ReturnInputCaptureContract.regions(
            focusedFrame: CGRect(x: 28, y: 24, width: 280, height: 48),
            caretFrame: nil,
            windowFrame: window,
            interactionPoint: CGPoint(x: 720, y: 80),
            interactionCoordinateFrame: window
        )
        try require(
            !conflictingAXRegions.isEmpty
                && conflictingAXRegions.allSatisfy { $0.source == .caretNeighborhood },
            "A compact but click-conflicting AX frame still outranked the composer fallback."
        )
        try require(
            conflictingAXRegions.allSatisfy { $0.area < 0.22 && $0.x > 0.10 },
            "The click fallback expanded into a window/sidebar-sized region."
        )

        // Global AppKit points and ScreenCaptureKit frames use opposite Y
        // conventions. Mirroring must include a non-zero display origin so a
        // secondary display does not shift the ROI by displayFrame.minY.
        let offsetDisplay = CGRect(x: 0, y: 100, width: 1_600, height: 900)
        let offsetWindow = CGRect(x: 200, y: 650, width: 1_200, height: 300)
        let offsetRegions = ReturnInputCaptureContract.regions(
            focusedFrame: nil,
            caretFrame: nil,
            windowFrame: offsetWindow,
            interactionPoint: CGPoint(x: 900, y: 180),
            interactionCoordinateFrame: offsetDisplay
        )
        try require(
            offsetRegions.contains(where: { $0.y > 0.70 }),
            "The click mirror ignored the display's non-zero Y origin."
        )
        try require(
            offsetRegions.allSatisfy { $0.area < 0.30 },
            "A no-OCR click fallback became a full-window crop."
        )

        // Long multi-line drafts should become one crop, not one hook/OCR
        // record per line. The vertical tolerance is proportional to the
        // window, so Retina/large-display captures keep all wrapped lines.
        let multilineLines = [
            NormalizedOCRLine(text: "第一行：先记录整屏定位结果", x: 0.38, y: 0.145, width: 0.40, height: 0.03),
            NormalizedOCRLine(text: "第二行：再裁剪输入框做二次 OCR", x: 0.38, y: 0.105, width: 0.43, height: 0.03),
            NormalizedOCRLine(text: "第三行：只把裁剪结果交给静默分析", x: 0.38, y: 0.065, width: 0.43, height: 0.03)
        ]
        let multilineRegions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: multilineLines,
            focusedFrame: CGRect(x: 240, y: 620, width: 720, height: 132),
            caretFrame: nil,
            windowFrame: window,
            displayFrame: window,
            referenceText: "第一行：先记录整屏定位结果\n第二行：再裁剪输入框做二次 OCR\n第三行：只把裁剪结果交给静默分析"
        )
        try require(!multilineRegions.isEmpty, "A multi-line composer was not located from the full-screen pass.")
        try require(
            multilineRegions.contains(where: { $0.height >= 0.14 }),
            "The multi-line composer was reduced to a single-line crop."
        )

        // A large AX editor needs the caret as an anchor; a matching line far
        // from the caret is document/history context, not the submitted line.
        let editorCaret = CGRect(x: 560, y: 642, width: 2, height: 20)
        let editorLines = [
            NormalizedOCRLine(text: duplicateHistory, x: 0.38, y: 0.70, width: 0.44, height: 0.035, confidence: 0.99),
            NormalizedOCRLine(text: "这是光标附近刚刚提交的段落", x: 0.38, y: 0.17, width: 0.30, height: 0.035, confidence: 0.96)
        ]
        let editorRegions = ReturnInputCaptureContract.regionsFromFullScreenOCR(
            lines: editorLines,
            focusedFrame: CGRect(x: 0, y: 0, width: 1_200, height: 760),
            caretFrame: editorCaret,
            windowFrame: window,
            displayFrame: window,
            referenceText: "这是光标附近刚刚提交的段落"
        )
        try require(!editorRegions.isEmpty, "Caret-anchored full-screen OCR returned no editor ROI.")
        try require(
            editorRegions.contains(where: { $0.y > 0.60 }),
            "The caret-near editor line was not retained after full-screen location."
        )

        return HarnessCheck(
            name: "Return input ROI contract",
            detail: "Full-display OCR now follows the last focus click without AX, rejects duplicate history/sidebar text and click-conflicting AX frames, handles offset-display mirroring, groups wrapped lines into one ROI, uses the caret for large editors, and keeps model payloads ROI-only."
        )
    }

    private static func validateModelEnrichedContextStability() async throws -> [HarnessCheck] {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOneEnrichmentHarness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        let diary = try AppendOnlyDiary(homeURL: temporaryHome)
        let engine = ContextMemoryEngine(diary: diary)
        let base = Date(timeIntervalSince1970: 1_700_050_000)
        let rawContext = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Attention Is All You Need",
            windowIdentifier: "paper-window",
            url: URL(string: "https://arxiv.org/abs/1706.03762"),
            contentSummary: "Provided proper attribution is provided, Google hereby grants permission to reproduce the tables and figures in this paper.",
            semanticTags: ["paper", "research"]
        )

        for index in 0..<450 {
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 0.05),
                signal: .scrolled(
                    axis: .vertical,
                    delta: 12,
                    phase: index == 0 ? .began : .changed
                ),
                context: rawContext
            ))
        }

        var enrichedContext = rawContext
        enrichedContext.contentSummary = "阅读 Transformer 论文中自注意力与多头注意力机制的章节"
        enrichedContext.semanticTags.insert(ActivityContext.modelEnrichedSummaryTag)
        enrichedContext.semanticTags.insert("transformer")
        let acceptedMatchingEnrichment = await engine.enrichPendingActivityContext(
            enrichedContext,
            matching: rawContext
        )
        try require(
            acceptedMatchingEnrichment,
            "The active paper session rejected a matching semantic enrichment."
        )

        // More raw AX snapshots arrive after the model response. They must be
        // absorbed as observations without replacing the semantic summary.
        for index in 450..<900 {
            var laterRawContext = rawContext
            laterRawContext.contentSummary = "Scaled Dot-Product Attention Multi-Head Attention positional encoding layer normalization"
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 0.05),
                signal: .scrolled(
                    axis: .vertical,
                    delta: 10,
                    phase: index == 899 ? .ended : .changed
                ),
                context: laterRawContext
            ))
        }

        _ = try await engine.flushPendingActivity(
            at: base.addingTimeInterval(46),
            reason: .explicitFlush
        )
        let entries = await diary.allEntries()
        let sessions = entries.compactMap { entry -> ActivitySessionSummary? in
            guard case .activity(let record) = entry.payload else { return nil }
            return record.session
        }
        try require(sessions.count == 1, "900 scroll hooks did not collapse into exactly one activity session.")
        try require(sessions[0].eventCount == 900, "The collapsed reading session lost raw hook accounting.")
        try require(
            sessions[0].context.contentSummary == "阅读 Transformer 论文中自注意力与多头注意力机制的章节",
            "A later raw Accessibility sample overwrote the model-enriched diary summary."
        )

        let replay = SemanticReplayBuilder().build(day: "model-enrichment", entries: entries)
        let activities = replay.moments.filter { $0.kind == .activity }
        try require(activities.count == 1, "Replay expanded one reading state back into duplicate moments.")
        try require(
            activities[0].title.contains("Transformer") || activities[0].detail?.contains("Transformer") == true,
            "Replay did not expose the concrete paper topic."
        )
        try require(
            activities[0].detail?.contains("已合并 900 个底层信号") != true,
            "Replay still foregrounded implementation hook counts instead of user context."
        )

        let unrelatedContext = ActivityContext(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            windowTitle: "Shopping list",
            windowIdentifier: "notes-window",
            contentSummary: "Writing a grocery list"
        )
        _ = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(60),
            signal: .keyboard(.typingStarted),
            context: unrelatedContext
        ))
        let acceptedStaleEnrichment = await engine.enrichPendingActivityContext(
            enrichedContext,
            matching: rawContext
        )
        try require(
            acceptedStaleEnrichment == false,
            "A slow model response from the paper page contaminated a later Notes session."
        )

        return [HarnessCheck(
            name: "Model-enriched Context stability",
            detail: "900 reading hooks became one paper-specific activity; later raw AX samples could not overwrite its semantic summary, and a slow response could not cross into a new context."
        )]
    }

    private static func validateLateContextEnrichmentProjection() async throws -> [HarnessCheck] {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOneLateEnrichmentHarness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        let timeZone = try requireValue(TimeZone(secondsFromGMT: 0), "Could not create UTC.")
        let diary = try AppendOnlyDiary(homeURL: temporaryHome, timeZone: timeZone)
        let engine = ContextMemoryEngine(diary: diary)
        let base = Date(timeIntervalSince1970: 1_720_100_000)
        let rawContext = ActivityContext(
            applicationName: "Google Chrome",
            windowTitle: "zloop 主文档",
            windowIdentifier: "feishu-zloop",
            url: URL(string: "https://zhuanspirit.feishu.cn/wiki/example"),
            contentSummary: "飞书文档"
        )
        let firstEvent = ActivityEvent(
            timestamp: base,
            signal: .scrolled(axis: .vertical, delta: 30, phase: .began),
            context: rawContext
        )
        _ = try await engine.record(firstEvent)
        for index in 1..<5 {
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 30, phase: .changed),
                context: rawContext
            ))
        }
        _ = try await engine.flushPendingActivity(reason: .explicitFlush)

        let before = await diary.allEntries()
        let originalActivity = try requireValue(
            before.first(where: { if case .activity = $0.payload { return true }; return false }),
            "The reading session did not persist before the late model result."
        )
        var enrichedContext = rawContext
        enrichedContext.contentSummary = "阅读 zloop 的业务背景，了解 Runtime、APIHub 与企业 Context 挂接方案"
        enrichedContext.selectedText = "zloop 是一套企业级解决方案"
        let application = try await engine.applyContextEnrichment(
            targetEventID: firstEvent.id,
            enrichedContext: enrichedContext,
            activityTitle: "阅读 zloop 企业级解决方案",
            summary: enrichedContext.contentSummary ?? "",
            tags: ["zloop", "runtime", "apihub"],
            matching: rawContext,
            at: base.addingTimeInterval(15)
        )
        guard case .appended(let appendedEntry) = application else {
            throw HarnessFailure("A late semantic result did not become an append-only enrichment fact.")
        }

        let after = await diary.allEntries()
        try require(after.first(where: { $0.id == originalActivity.id }) == originalActivity, "Late enrichment rewrote the original activity.")
        try require(after.contains(where: { $0.id == appendedEntry.id }), "The enrichment audit fact was not persisted.")
        let replay = await engine.replay(for: base)
        let activities = replay.moments.filter { $0.kind == .activity }
        try require(activities.count == 1, "Late enrichment appeared as a duplicate activity moment.")
        try require(activities.first?.title == "阅读 zloop 企业级解决方案", "Replay did not project the concrete model title.")
        try require(activities.first?.detail?.contains("Runtime、APIHub") == true, "Replay did not project the concrete model summary.")
        try require(activities.first?.detail?.contains("https://zhuanspirit.feishu.cn/wiki/example") == true, "Replay lost the source URL.")

        let day = await diary.dayKey(for: base)
        let markdown = try String(
            contentsOf: temporaryHome.appendingPathComponent("Daily/\(day).md"),
            encoding: .utf8
        )
        try require(markdown.contains("Context understood"), "Markdown lacks the enrichment audit section.")
        try require(markdown.contains(originalActivity.id.uuidString), "Markdown lacks the target activity association.")

        let reloaded = try AppendOnlyDiary(homeURL: temporaryHome, timeZone: timeZone)
        let reloadedEntries = await reloaded.allEntries()
        try require(reloadedEntries == after, "The enrichment did not survive diary reload.")
        let reloadedReplay = SemanticReplayBuilder().build(day: day, entries: reloadedEntries)
        try require(reloadedReplay.moments.filter { $0.kind == .activity }.count == 1, "Reloaded Replay duplicated the enriched activity.")

        return [HarnessCheck(
            name: "Append-only late Context enrichment",
            detail: "A slow model result appended an auditable semantic fact, preserved the original activity byte-for-byte, survived reload, and projected as one concrete Replay moment with its URL."
        )]
    }

    private static func validateHookSemantics() throws {
        let returnEvent = ActivityEvent(signal: .keyboard(.returnPressed))
        try require(returnEvent.semantics.contains(.opinionOutput), "Return was not mapped to opinion output.")
        try require(returnEvent.semantics.contains(.taskSubmission), "Return was not mapped to task submission.")

        let scrollEvent = ActivityEvent(signal: .scrolled(axis: .vertical, delta: 120, phase: .changed))
        try require(scrollEvent.semantics.contains(.readingProgress), "Scroll was not mapped to reading progress.")

        let clickEvent = ActivityEvent(signal: .mouseClicked(
            button: .left,
            count: 1,
            location: ScreenPoint(x: 420, y: 260)
        ))
        try require(
            clickEvent.semantics == [.selectionOrActivation],
            "A left click was falsely treated as navigation before a Context transition was observed."
        )
    }

    private static func validateReturnScreenshotEvidence() async throws -> HarnessCheck {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(diary: diary)
        let timestamp = Date(timeIntervalSince1970: 1_720_000_000)
        let screenshotPath = "/tmp/agentone-return-evidence.png"
        let returnEvent = ActivityEvent(
            timestamp: timestamp,
            signal: .keyboard(.returnPressed),
            context: ActivityContext(
                applicationName: "ChatGPT",
                bundleIdentifier: "com.openai.chat",
                windowTitle: "AgentOne product discussion",
                contentSummary: "The user asked AgentOne to make concrete Context capture work.",
                submittedText: "重新修一下，让这些功能真正落地。",
                screenText: "ChatGPT AgentOne product discussion",
                screenshotResourcePath: screenshotPath
            )
        )
        _ = try await engine.record(returnEvent)
        _ = try await engine.addAgentReflection(AgentReflection(
            timestamp: timestamp.addingTimeInterval(1),
            observation: "用户在验证回车是否真实记录了输出。",
            hypothesis: "这是一条面向 AgentOne 的真实功能反馈。",
            consideredAction: "关联原文与截图，让用户可以直接核验。",
            disposition: .observationOnly,
            why: "具体证据比只有一段模型摘要更可信。",
            uncertainty: 0.05,
            relatedEventIDs: [returnEvent.id]
        ))

        let entries = await diary.allEntries()
        let evidence = try requireValue(
            entries.compactMap { entry -> KeyEvidence? in
                guard case .evidence(let item) = entry.payload else { return nil }
                return item
            }.first,
            "Return did not create screenshot evidence."
        )
        try require(evidence.kind == .screenshot, "Return evidence was not typed as a screenshot.")
        try require(evidence.localResourcePath == screenshotPath, "Screenshot path was not retained.")
        try require(
            evidence.submittedText == "重新修一下，让这些功能真正落地。",
            "The submitted editor text was not retained with the key evidence."
        )
        let activity = try requireValue(
            entries.compactMap { entry -> ActivityDiaryRecord? in
                guard case .activity(let record) = entry.payload else { return nil }
                return record
            }.first,
            "Return did not finalize a composing activity."
        )
        try require(
            activity.evidenceIDs == [evidence.id],
            "The screenshot evidence was not embedded in its activity."
        )
        let replay = await engine.replay(for: timestamp)
        try require(
            replay.moments.filter { $0.kind == .evidence }.isEmpty,
            "Embedded screenshot evidence appeared as a duplicate Replay moment."
        )
        try require(
            replay.moments.contains { $0.evidenceIDs == [evidence.id] },
            "Replay lost the screenshot association."
        )
        let thought = try requireValue(
            replay.moments.first {
                $0.kind == .thought && $0.title == "用户在验证回车是否真实记录了输出。"
            },
            "The model thought was not projected into Replay."
        )
        try require(
            thought.submittedText == "重新修一下，让这些功能真正落地。",
            "The Agent thought was not joined back to the submitted Return text."
        )
        try require(
            thought.evidenceIDs == [evidence.id],
            "The Agent thought was not joined back to the Return screenshot."
        )
        return HarnessCheck(
            name: "Return Context evidence",
            detail: "Submitted editor text and its local screenshot path survived append-only persistence, appeared once in Replay, and were joined to the related Agent thought."
        )
    }

    private static func validateContinuousActivityAndHabits() async throws -> [HarnessCheck] {
        let diary = try AppendOnlyDiary(timeZone: try requireValue(TimeZone(secondsFromGMT: 0), "Could not create UTC."))
        let engine = ContextMemoryEngine(diary: diary)
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let firstContext = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "ADHD attention paper",
            windowIdentifier: "paper-a",
            url: URL(string: "https://example.com/paper-a"),
            contentSummary: "Research about sustained attention"
        )

        for index in 0..<50 {
            let phase: ScrollPhase = index == 0 ? .began : (index == 49 ? .ended : .changed)
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 24, phase: phase),
                context: firstContext
            ))
        }
        let beforeFlush = await diary.allEntries().compactMap { entry -> ActivityDiaryRecord? in
            guard case .activity(let record) = entry.payload else { return nil }
            return record
        }
        try require(beforeFlush.isEmpty, "Raw scroll hooks leaked into the diary before the reading session ended.")

        _ = try await engine.flushPendingActivity(reason: .explicitFlush)
        let firstRecords = await diary.allEntries().compactMap { entry -> ActivityDiaryRecord? in
            guard case .activity(let record) = entry.payload else { return nil }
            return record
        }
        try require(firstRecords.count == 1, "Fifty scroll hooks should produce exactly one activity record.")
        try require(firstRecords[0].session?.eventCount == 50, "The reading session did not retain its merged hook count.")
        try require(
            firstRecords[0].session?.context.url?.absoluteString == "https://example.com/paper-a",
            "The continuous reading session lost the browser page URL from its Context."
        )
        let replay = await engine.replay(for: base)
        let readingReplayCount = replay.moments.filter { $0.kind == .activity && $0.title.hasPrefix("Read ") }.count
        try require(readingReplayCount == 1, "Replay repeated the continuous reading session.")

        var checks = [HarnessCheck(
            name: "Continuous reading aggregation",
            detail: "50 began/changed/ended scroll hooks remained available to Core but became one immutable reading session and one replay moment."
        )]

        let secondContext = ActivityContext(
            applicationName: "Preview",
            windowTitle: "Second paper.pdf",
            windowIdentifier: "paper-b",
            documentPath: "/papers/second.pdf"
        )
        _ = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(600),
            signal: .scrolled(axis: .vertical, delta: 100, phase: .began),
            context: secondContext
        ))
        _ = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(675),
            signal: .scrolled(axis: .vertical, delta: 120, phase: .momentum),
            context: secondContext
        ))
        _ = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(680),
            signal: .keyboard(.typingStarted),
            context: secondContext
        ))
        let allRecords = await diary.allEntries().compactMap { entry -> ActivityDiaryRecord? in
            guard case .activity(let record) = entry.payload else { return nil }
            return record
        }
        let sessions = allRecords.compactMap(\.session)
        try require(sessions.count == 2, "Typing should have closed the second reading session exactly once.")
        try require(sessions.last?.duration == 75, "A short reading pause should remain inside the same session.")
        try require(sessions.last?.endReason == .activityChanged, "The reading-to-writing transition was not recorded.")
        checks.append(HarnessCheck(
            name: "Reading lifecycle boundaries",
            detail: "A 75-second pause stayed in one reading state; beginning to type closed it with an explicit activityChanged boundary."
        ))

        let habits = await engine.habitContexts()
        let readingHabit = try requireValue(habits.first, "No user-visible reading habit was produced.")
        try require(readingHabit.supportingSessionCount == 2, "Habit evidence count did not match the two reading sessions.")
        try require(readingHabit.evidenceEntryIDs.count == 2, "Habit context is not traceable to both source diary entries.")
        checks.append(HarnessCheck(
            name: "Visible habit context",
            detail: "The public habit query explains the learned reading rhythm, confidence, supporting-session count, and immutable diary evidence IDs."
        ))

        let sensitiveDiary = try AppendOnlyDiary()
        let sensitiveEngine = ContextMemoryEngine(diary: sensitiveDiary)
        let sensitive = ActivityContext(applicationName: "Bank", windowTitle: "Payment password", isSensitive: true)
        _ = try await sensitiveEngine.record(ActivityEvent(
            timestamp: base,
            signal: .scrolled(axis: .vertical, delta: 20, phase: .changed),
            context: sensitive
        ))
        _ = try await sensitiveEngine.flushPendingActivity()
        let sensitiveEntries = await sensitiveDiary.allEntries()
        let sensitiveHabits = await sensitiveEngine.habitContexts()
        try require(!sensitiveEntries.contains(where: { if case .activity = $0.payload { return true }; return false }), "Sensitive reading entered the diary.")
        try require(sensitiveHabits.isEmpty, "Sensitive reading entered the habit model.")
        checks.append(HarnessCheck(
            name: "Sensitive-session privacy gate",
            detail: "A sensitive reading hook created neither an activity session nor a learned habit."
        ))

        return checks
    }

    private static func validateUnifiedSemanticActivityStateMachine() async throws -> [HarnessCheck] {
        let timeZone = try requireValue(TimeZone(secondsFromGMT: 0), "Could not create UTC.")
        let base = Date(timeIntervalSince1970: 1_710_500_000)
        let context = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "ADHD recovery research workspace",
            windowIdentifier: "semantic-workspace",
            url: URL(string: "https://example.com/adhd-recovery"),
            contentSummary: "Researching and drafting an ADHD attention recovery paper",
            semanticTags: ["adhd", "attention", "paper", "research"]
        )
        let events = makeTwoHundredMixedHooks(base: base, context: context)
        try require(events.count == 200, "The mixed-hook fixture must contain exactly 200 events.")

        let liveDiary = try AppendOnlyDiary(timeZone: timeZone)
        let liveEngine = ContextMemoryEngine(diary: liveDiary)
        _ = try await liveEngine.beginIntent(
            title: "Write the ADHD recovery paper",
            summary: "Read sources, draft the argument, and preserve the task state",
            context: context,
            at: base.addingTimeInterval(-1)
        )
        for event in events {
            _ = try await liveEngine.record(event)
        }

        let liveEntries = await liveDiary.allEntries()
        let liveActivities = liveEntries.compactMap { entry -> ActivityDiaryRecord? in
            guard case .activity(let record) = entry.payload else { return nil }
            return record
        }
        try require(liveActivities.count == 4, "Two hundred live hooks should become four semantic activity segments, not an event log.")
        let liveKinds = liveActivities.compactMap { $0.session?.kind }
        try require(liveKinds == [.reading, .composing, .researching, .idle], "The live state machine produced the wrong semantic activity sequence: \(liveKinds).")
        try require(liveActivities.compactMap { $0.session?.eventCount }.reduce(0, +) == 200, "The semantic segments lost raw-hook provenance counts.")
        try require(liveActivities.allSatisfy { $0.session != nil }, "A live low-level hook leaked into the diary without a semantic segment.")

        let thoughtEvidence = liveEntries.compactMap { entry -> KeyEvidence? in
            guard case .evidence(let evidence) = entry.payload,
                  evidence.title == "A thought was expressed" else { return nil }
            return evidence
        }
        try require(thoughtEvidence.count == 1, "The Return milestone did not remain as one independent thought evidence item.")
        let liveReplay = await liveEngine.replay(for: base)
        try require(liveReplay.moments.filter { $0.kind == .activity }.count == 4, "Live Replay did not consume the four semantic segments.")

        let habits = await liveEngine.habitContexts()
        let habitTitles = Set(habits.map(\.title))
        try require(habitTitles.contains("连续滚动通常代表你正在阅读"), "Reading context was not exposed as a visible habit.")
        try require(habitTitles.contains("你的连续写作节奏"), "Writing context was not exposed as a visible habit.")
        try require(habitTitles.contains("你查资料时的探索节奏"), "Research context was not exposed as a visible habit.")

        let sensitiveCountBefore = liveActivities.count
        _ = try await liveEngine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(300),
            signal: .keyboard(.typingBurst(estimatedCharacterCount: 10)),
            context: ActivityContext(applicationName: "Password Manager", isSensitive: true)
        ))
        _ = try await liveEngine.flushPendingActivity(reason: .explicitFlush)
        let sensitiveCountAfter = await liveDiary.allEntries().filter {
            if case .activity = $0.payload { return true }
            return false
        }.count
        try require(sensitiveCountAfter == sensitiveCountBefore, "Sensitive context entered the semantic activity diary.")

        let legacyDiary = try AppendOnlyDiary(timeZone: timeZone)
        for event in events {
            _ = try await legacyDiary.append(.activity(ActivityDiaryRecord(
                event: event,
                narrative: "Legacy low-level input"
            )), at: event.timestamp)
        }
        let immutableLegacyEntries = await legacyDiary.allEntries()
        let legacyReplay = SemanticReplayBuilder().build(day: "mixed-legacy", entries: immutableLegacyEntries)
        let legacySegments = legacyReplay.moments.filter { $0.kind == .activity }
        try require(legacySegments.count == 4, "Two hundred immutable legacy hooks projected to \(legacySegments.count) segments: \(legacySegments.map(\.title)).")
        try require(
            legacySegments.allSatisfy {
                $0.detail?.contains("Researching and drafting an ADHD attention recovery paper") == true
                    && $0.detail?.contains("已合并") != true
            },
            "Legacy Replay did not replace hook-count bookkeeping with concrete context."
        )
        let legacyEntryCountAfterProjection = await legacyDiary.allEntries().count
        try require(legacyEntryCountAfterProjection == 200, "The read-only semantic projection modified the append-only legacy source.")

        return [
            HarnessCheck(
                name: "Unified semantic activity state machine",
                detail: "200 mixed live hooks became reading, composing, researching, and idle segments; Return evidence and sensitive blocking remained intact."
            ),
            HarnessCheck(
                name: "General legacy semantic projection",
                detail: "200 immutable pre-fix hook rows became the same four Replay segments without deleting or rewriting source memory."
            ),
            HarnessCheck(
                name: "Visible multi-activity habit context",
                detail: "Reading, writing, and research rhythms are now user-visible, evidence-backed memory cards instead of an internal-only inference."
            )
        ]
    }

    private static func makeTwoHundredMixedHooks(base: Date, context: ActivityContext) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        var offset: TimeInterval = 0
        func append(_ signal: ActivitySignal) {
            events.append(ActivityEvent(
                timestamp: base.addingTimeInterval(offset),
                signal: signal,
                context: context
            ))
            offset += 0.5
        }

        append(.applicationActivated(bundleIdentifier: context.bundleIdentifier))
        for index in 0..<89 {
            if index.isMultiple(of: 2) {
                append(.scrolled(axis: .vertical, delta: 24, phase: index == 0 ? .began : .changed))
            } else {
                append(.mouseClicked(button: .left, count: 1, location: nil))
            }
        }
        for index in 0..<79 {
            if index == 78 {
                append(.keyboard(.returnPressed))
            } else if index.isMultiple(of: 2) {
                append(.keyboard(.typingBurst(estimatedCharacterCount: 4)))
            } else {
                append(.contentChanged)
            }
        }
        for _ in 0..<29 {
            append(.mouseClicked(button: .left, count: 1, location: nil))
        }
        append(.idleStarted)
        offset += 240
        append(.idleEnded)
        return events
    }

    private static func validateLegacyDiaryReadProjection() async throws -> [HarnessCheck] {
        let diary = try AppendOnlyDiary(timeZone: try requireValue(TimeZone(secondsFromGMT: 0), "Could not create UTC."))
        let base = Date(timeIntervalSince1970: 1_711_000_000)
        let firstContext = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Legacy ADHD attention paper",
            windowIdentifier: "legacy-paper-a",
            url: URL(string: "https://example.com/legacy-paper-a"),
            contentSummary: "A paper about attention recovery"
        )

        for index in 0..<50 {
            let phase: ScrollPhase
            switch index {
            case 0: phase = .began
            case 49: phase = .ended
            case 35...48: phase = .momentum
            default: phase = .changed
            }
            let event = ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 24, phase: phase),
                context: firstContext
            )
            _ = try await diary.append(.activity(ActivityDiaryRecord(
                event: event,
                narrative: "Continued reading in Safari",
                session: nil
            )), at: event.timestamp)
        }

        let immutableLegacyEntries = await diary.allEntries()
        try require(immutableLegacyEntries.count == 50, "The legacy source fixture did not retain all 50 entries.")
        try require(immutableLegacyEntries.allSatisfy { entry in
            guard case .activity(let record) = entry.payload else { return false }
            return record.session == nil
        }, "The read projection mutated a legacy source entry.")

        let firstReplay = SemanticReplayBuilder().build(day: "legacy", entries: immutableLegacyEntries)
        let firstReadingMoments = firstReplay.moments.filter {
            $0.kind == .activity && $0.title.hasPrefix("Read ")
        }
        try require(firstReadingMoments.count == 1, "Fifty immutable legacy scroll entries did not collapse to one Replay segment.")
        try require(firstReadingMoments.first?.detail?.contains("A paper about attention recovery") == true, "Replay did not preserve the concrete legacy reading context.")
        try require(firstReadingMoments.first?.detail?.contains("已合并") != true, "Replay foregrounded implementation hook counts instead of reading context.")

        let firstHabits = HabitContextExtractor().extract(from: immutableLegacyEntries)
        try require(firstHabits.first?.supportingSessionCount == 1, "Fifty legacy hooks were incorrectly counted as fifty habit observations.")

        let typing = ActivityEvent(
            timestamp: base.addingTimeInterval(110),
            signal: .keyboard(.typingStarted),
            context: firstContext
        )
        _ = try await diary.append(.activity(ActivityDiaryRecord(
            event: typing,
            narrative: "Started writing in Safari",
            session: nil
        )), at: typing.timestamp)

        let secondContext = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Legacy ADHD follow-up paper",
            windowIdentifier: "legacy-paper-b",
            url: URL(string: "https://example.com/legacy-paper-b")
        )
        for index in 0..<8 {
            let event = ActivityEvent(
                timestamp: base.addingTimeInterval(120 + Double(index) * 2),
                signal: .scrolled(
                    axis: .vertical,
                    delta: 30,
                    phase: index == 0 ? .began : (index == 7 ? .ended : .changed)
                ),
                context: secondContext
            )
            _ = try await diary.append(.activity(ActivityDiaryRecord(
                event: event,
                narrative: "Continued reading in Safari",
                session: nil
            )), at: event.timestamp)
        }

        let entriesWithBoundary = await diary.allEntries()
        let replayWithBoundary = SemanticReplayBuilder().build(day: "legacy", entries: entriesWithBoundary)
        let projectedReadingMoments = replayWithBoundary.moments.filter {
            $0.kind == .activity && $0.title.hasPrefix("Read ")
        }
        try require(projectedReadingMoments.count == 2, "Typing and a context change did not form a second legacy reading boundary.")
        let habitsWithBoundary = HabitContextExtractor().extract(from: entriesWithBoundary)
        try require(habitsWithBoundary.first?.supportingSessionCount == 2, "The habit projection did not count the two independent legacy sessions.")

        let ownContext = ActivityContext(
            applicationName: "AgentOne",
            bundleIdentifier: "life.agentone.desktop",
            windowTitle: "AgentOne"
        )
        for index in 0..<20 {
            let event = ActivityEvent(
                timestamp: base.addingTimeInterval(150 + Double(index)),
                signal: .scrolled(axis: .vertical, delta: 20, phase: index == 0 ? .began : (index == 19 ? .ended : .changed)),
                context: ownContext
            )
            _ = try await diary.append(.activity(ActivityDiaryRecord(
                event: event,
                narrative: "Continued reading in AgentOne"
            )), at: event.timestamp)
        }
        let entriesWithHistoricalSelfCapture = await diary.allEntries()
        let replayWithoutSelfCapture = SemanticReplayBuilder().build(day: "legacy", entries: entriesWithHistoricalSelfCapture)
        try require(replayWithoutSelfCapture.moments.filter {
            $0.title.contains("AgentOne") || ($0.detail?.contains("AgentOne") ?? false)
        }.isEmpty, "Historical AgentOne self-capture leaked into Replay.")
        try require(replayWithoutSelfCapture.moments.filter {
            $0.title.hasPrefix("Read ")
        }.count == 2, "Historical self-capture created a false reading segment.")
        try require(HabitContextExtractor().extract(from: entriesWithHistoricalSelfCapture).first?.supportingSessionCount == 2, "Historical AgentOne self-capture polluted habit evidence.")
        try require(entriesWithHistoricalSelfCapture.count == 79, "Suppressing historical self-capture modified the append-only source.")

        return [HarnessCheck(
            name: "Legacy diary read projection",
            detail: "50 immutable legacy scroll entries became one reading segment, boundaries remained accurate, and historical AgentOne self-capture stayed in the source but disappeared from Replay and habits."
        )]
    }

    private static func validateNoiseGateAndShortActivityDebounce() async throws -> [HarnessCheck] {
        let timeZone = try requireValue(
            TimeZone(secondsFromGMT: 0),
            "Could not construct the deterministic noise-gate time zone."
        )
        let base = Date(timeIntervalSince1970: 1_719_000_000)

        let noiseDiary = try AppendOnlyDiary(timeZone: timeZone)
        let noiseEngine = ContextMemoryEngine(diary: noiseDiary)
        let loginOutput = try await noiseEngine.record(ActivityEvent(
            timestamp: base,
            signal: .applicationActivated(bundleIdentifier: "com.apple.loginwindow"),
            context: ActivityContext(
                applicationName: "loginwindow",
                bundleIdentifier: "com.apple.loginwindow",
                windowTitle: "loginwindow"
            )
        ))
        try require(loginOutput.activeIntent == nil, "loginwindow became the user's inferred intent.")
        try require(loginOutput.relevance == nil, "loginwindow entered relevance scoring.")
        try require(loginOutput.appendedDiaryEntryIDs.isEmpty, "loginwindow wrote semantic diary state.")
        let entriesAfterLoginWindow = await noiseDiary.allEntries()
        try require(entriesAfterLoginWindow.isEmpty, "System noise entered the append-only diary.")

        let realContext = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "ADHD attention recovery paper",
            contentSummary: "Reading a paper about ADHD attention recovery"
        )
        let realOutput = try await noiseEngine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(1),
            signal: .windowFocused(windowIdentifier: "paper"),
            context: realContext
        ))
        try require(realOutput.activeIntent != nil, "The first real user context did not infer an intent after loginwindow.")
        let noiseEntries = await noiseDiary.allEntries()
        try require(noiseEntries.filter { if case .intentStarted = $0.payload { return true }; return false }.count == 1, "The real context did not become the sole inferred intent.")

        let activityDiary = try AppendOnlyDiary(timeZone: timeZone)
        let activityEngine = ContextMemoryEngine(diary: activityDiary)
        _ = try await activityEngine.beginIntent(
            title: "Read attention research",
            summary: "Compare two useful sources",
            context: realContext,
            at: base
        )
        let shortContext = ActivityContext(
            applicationName: "Chrome",
            bundleIdentifier: "com.google.Chrome",
            windowTitle: "Transient result",
            windowIdentifier: "short-result",
            url: URL(string: "https://example.com/short")
        )
        for index in 0..<40 {
            _ = try await activityEngine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 0.1),
                signal: .scrolled(axis: .vertical, delta: 8, phase: index == 0 ? .began : .changed),
                context: shortContext
            ))
        }

        let stableContext = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Sustained source",
            windowIdentifier: "stable-source",
            url: URL(string: "https://example.com/stable")
        )
        for index in 0..<10 {
            _ = try await activityEngine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(6 + Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 24, phase: index == 0 ? .began : .changed),
                context: stableContext
            ))
        }
        _ = try await activityEngine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(25),
            signal: .windowFocused(windowIdentifier: "next-window"),
            context: ActivityContext(
                applicationName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                windowTitle: "Next task",
                windowIdentifier: "next-window"
            )
        ))
        let activities = await activityDiary.allEntries().compactMap { entry -> ActivitySessionSummary? in
            guard case .activity(let record) = entry.payload else { return nil }
            return record.session
        }
        try require(activities.count == 1, "A four-second scroll-hook storm became a Continuous activity row.")
        try require(activities.first?.context.windowIdentifier == "stable-source", "The sustained reading segment was not the sole activity projection.")

        return [HarnessCheck(
            name: "System-noise gate and short-session debounce",
            detail: "loginwindow cannot infer intent or drift state; 40 scroll hooks in four seconds disappear while an 18-second reading segment remains once."
        )]
    }

    private static func validateFocusEpisodeDebounceAndProjection() async throws -> [HarnessCheck] {
        let timeZone = try requireValue(
            TimeZone(secondsFromGMT: 0),
            "Could not construct the deterministic focus test time zone."
        )
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let taskContext = ActivityContext(
            applicationName: "Notes",
            windowTitle: "ADHD draft",
            contentSummary: "Writing an ADHD attention recovery draft",
            semanticTags: ["adhd", "attention", "writing"]
        )
        let distractionContext = ActivityContext(
            applicationName: "Safari",
            windowTitle: "Unrelated short videos",
            contentSummary: "Entertainment clips",
            semanticTags: ["video", "entertainment"]
        )

        let liveDiary = try AppendOnlyDiary(timeZone: timeZone)
        let liveEngine = ContextMemoryEngine(diary: liveDiary)
        _ = try await liveEngine.beginIntent(
            title: "Write the ADHD draft",
            summary: "Continue the attention recovery section",
            context: taskContext,
            at: base
        )

        _ = try await liveEngine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(10),
            signal: .windowFocused(windowIdentifier: "short-detour"),
            context: distractionContext
        ))
        let shortReturn = try await liveEngine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(20),
            signal: .keyboard(.typingStarted),
            context: taskContext
        ))
        try require(!shortReturn.prompts.containsReturn, "A ten-second relevance flicker was presented as a real return-to-task event.")

        _ = try await liveEngine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(40),
            signal: .windowFocused(windowIdentifier: "sustained-detour"),
            context: distractionContext
        ))
        _ = try await liveEngine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(75),
            signal: .scrolled(axis: .vertical, delta: 180, phase: .changed),
            context: distractionContext
        ))
        let firstReturnCandidate = try await liveEngine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(80),
            signal: .keyboard(.typingBurst(estimatedCharacterCount: 4)),
            context: taskContext
        ))
        try require(!firstReturnCandidate.prompts.containsReturn, "One related hook closed a sustained drift immediately.")
        _ = try await liveEngine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(85),
            signal: .scrolled(axis: .vertical, delta: 80, phase: .changed),
            context: distractionContext
        ))
        _ = try await liveEngine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(90),
            signal: .keyboard(.typingStarted),
            context: taskContext
        ))
        let sustainedReturn = try await liveEngine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(101),
            signal: .keyboard(.typingBurst(estimatedCharacterCount: 6)),
            context: taskContext
        ))
        try require(sustainedReturn.prompts.containsReturn, "A sustained drift did not produce a return-to-task transition.")

        let liveEntries = await liveDiary.allEntries()
        let liveDrifts = liveEntries.filter { if case .driftStarted = $0.payload { return true }; return false }
        let liveReturns = liveEntries.filter { if case .returnedToIntent = $0.payload { return true }; return false }
        try require(liveDrifts.count == 1 && liveReturns.count == 1, "Brief classifier flicker leaked into the live append-only diary.")
        let liveReplay = SemanticReplayBuilder().build(day: "focus-live", entries: liveEntries)
        try require(liveReplay.moments.filter { $0.kind == .drift || $0.kind == .returned }.count == 1, "One sustained live detour became multiple Replay rows.")
        try require(liveReplay.moments.contains(where: { $0.kind == .returned }), "The sustained live detour did not become one completed focus episode.")

        let legacyDiary = try AppendOnlyDiary(timeZone: timeZone)
        let inferredIntent = IntentSession(
            startedAt: base,
            title: "Current activity",
            summary: "Continue working in Safari",
            origin: .inferred,
            confidence: 0.62,
            state: .proposed,
            contextTerms: ["safari"]
        )
        _ = try await legacyDiary.append(.intentStarted(inferredIntent), at: base)
        _ = try await legacyDiary.append(.intentConfirmed(intentSessionID: inferredIntent.id), at: base.addingTimeInterval(1))
        _ = try await legacyDiary.append(.driftStarted(DriftEpisode(
            intentSessionID: inferredIntent.id,
            beganAt: base.addingTimeInterval(10),
            lastObservedAt: base.addingTimeInterval(10),
            minimumRelevance: 0.1
        )), at: base.addingTimeInterval(10))
        _ = try await legacyDiary.append(.reminder(.reminder(
            stage: ReminderStage(level: 1, after: 5, modalities: [.creatureMotion]),
            text: "We were working on “Current activity”. Want me to take you back to that thread?",
            canReturn: true
        )), at: base.addingTimeInterval(15))
        _ = try await legacyDiary.append(.returnedToIntent(intentSessionID: inferredIntent.id), at: base.addingTimeInterval(20))

        _ = try await legacyDiary.append(.agentReflection(AgentReflection(
            timestamp: base.addingTimeInterval(21),
            observation: "因为「drift_reminder_level_1」醒来时，我看见用户在 Safari，当前意图是「Current activity」。"
        )), at: base.addingTimeInterval(21))

        let explicitIntent = IntentSession(
            startedAt: base.addingTimeInterval(30),
            title: "Write the ADHD draft",
            summary: "Continue the attention recovery section",
            origin: .userProvided,
            confidence: 1,
            state: .active,
            contextTerms: ["adhd", "writing"]
        )
        _ = try await legacyDiary.append(.intentStarted(explicitIntent), at: base.addingTimeInterval(30))
        _ = try await legacyDiary.append(.driftStarted(DriftEpisode(
            intentSessionID: explicitIntent.id,
            beganAt: base.addingTimeInterval(40),
            lastObservedAt: base.addingTimeInterval(75),
            minimumRelevance: 0.05
        )), at: base.addingTimeInterval(40))
        _ = try await legacyDiary.append(.reminder(.curiousQuestion(
            text: "Does this page still help with the ADHD draft?"
        )), at: base.addingTimeInterval(55))
        _ = try await legacyDiary.append(.returnedToIntent(intentSessionID: explicitIntent.id), at: base.addingTimeInterval(80))

        // Old versions could alternate drift/return every few seconds for the
        // same intent. Replay should tell this as one human-scale detour.
        _ = try await legacyDiary.append(.driftStarted(DriftEpisode(
            intentSessionID: explicitIntent.id,
            beganAt: base.addingTimeInterval(85),
            lastObservedAt: base.addingTimeInterval(110),
            minimumRelevance: 0.08
        )), at: base.addingTimeInterval(85))
        _ = try await legacyDiary.append(.reminder(.reminder(
            stage: ReminderStage(level: 1, after: 30, modalities: [.creatureMotion]),
            text: "We were working on “Write the ADHD draft”. Want me to take you back?",
            canReturn: true
        )), at: base.addingTimeInterval(100))
        _ = try await legacyDiary.append(.returnedToIntent(intentSessionID: explicitIntent.id), at: base.addingTimeInterval(120))
        _ = try await legacyDiary.append(.agentReflection(AgentReflection(
            timestamp: base.addingTimeInterval(121),
            observation: "因为「drift_reminder_level_1」醒来时，我看见用户在 Safari，当前意图是「Write the ADHD draft」。",
            hypothesis: "这可能是一段与当前意图冲突的偏航，但还需要用户行为继续验证。"
        )), at: base.addingTimeInterval(121))

        // Historical selections can begin after an intent was already active,
        // leaving a prompt without its matching intent/drift rows in this day.
        // Replay must still treat that delivery record as internal mechanics.
        _ = try await legacyDiary.append(.reminder(.reminder(
            stage: ReminderStage(level: 1, after: 60, modalities: [.creatureMotion]),
            text: "We were working on “Current activity”. Want me to take you back?",
            canReturn: true
        )), at: base.addingTimeInterval(130))

        let duplicateSkill = AgentSkill(
            createdAt: base.addingTimeInterval(140),
            name: "Recognize this distraction pattern",
            domain: .driftDetection,
            guidance: "Lower relevance for this repeated pattern.",
            confidence: 0.62
        )
        _ = try await legacyDiary.append(.skillLearned(duplicateSkill), at: base.addingTimeInterval(140))
        _ = try await legacyDiary.append(.skillLearned(AgentSkill(
            createdAt: base.addingTimeInterval(141),
            name: duplicateSkill.name,
            domain: duplicateSkill.domain,
            guidance: duplicateSkill.guidance,
            confidence: duplicateSkill.confidence
        )), at: base.addingTimeInterval(141))

        let immutableLegacyEntries = await legacyDiary.allEntries()
        let legacyReplay = SemanticReplayBuilder().build(day: "focus-legacy", entries: immutableLegacyEntries)
        try require(immutableLegacyEntries.count == 17, "The legacy focus projection modified its append-only source.")
        try require(legacyReplay.moments.filter { $0.kind == .intent }.count == 1, "The Replay did not distinguish an explicit intent from an inferred Current activity placeholder.")
        try require(legacyReplay.moments.filter { $0.kind == .reminder || $0.kind == .thought }.isEmpty, "Prompt delivery mechanics or their mechanical wake logs remained visible.")
        try require(legacyReplay.moments.filter { $0.kind == .drift || $0.kind == .returned }.count == 1, "Legacy drift/return jitter did not collapse into one focus episode.")
        try require(legacyReplay.moments.filter { $0.kind == .learnedSkill }.count == 1, "Duplicate skill revisions appeared as repeated day-review moments.")

        let afterMidnightEntries = immutableLegacyEntries.filter { $0.timestamp > base }
        let crossDayReplay = SemanticReplayBuilder().build(
            day: "focus-cross-day",
            entries: afterMidnightEntries,
            contextEntries: immutableLegacyEntries
        )
        try require(
            crossDayReplay.moments.filter { $0.kind == .drift || $0.kind == .returned || $0.kind == .reminder }.count == 1,
            "A placeholder intent that began before the selected day leaked classifier jitter into Replay."
        )

        return [HarnessCheck(
            name: "Focus episode debounce and projection",
            detail: "Brief relevance flicker stays live-only; sustained detours become one Replay episode, and historical Current activity/confirm/drift/return noise remains immutable but hidden from the day review."
        )]
    }

    private static func validateDailyDigestAndProactivePolicy() async throws -> [HarnessCheck] {
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOneDailyDigestHarness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }
        let utc = try requireValue(TimeZone(secondsFromGMT: 0), "Could not create UTC.")
        let diary = try AppendOnlyDiary(homeURL: temporaryHome, timeZone: utc)
        let engine = ContextMemoryEngine(diary: diary)
        let time = Date(timeIntervalSince1970: 1_722_787_200)
        let day = await diary.dayKey(for: time)
        let digest = DailyContextDigest(
            day: day,
            generatedAt: time,
            headline: "把三条散线拧成一根",
            overview: "今天把 Context 日记、主动陪伴和 LUMA 个性串成了一条产品主线。",
            highlights: ["明确日记必须提炼一天", "要求 Agent 主动出现"],
            rhythm: "从可见问题追到运行机制。",
            unfinishedThread: "继续验证真实触达。",
            agentNote: "我记住了你不接受只有壳子的功能。",
            invitation: "我把今天串好了，要看两分钟吗？",
            mood: "thoughtful",
            sourceContextCount: 9,
            evidenceCount: 2,
            personalizedMemoryCount: 4
        )
        _ = try await engine.addDailyContextDigest(digest, at: time)
        let replay = await engine.replay(for: time)
        try require(replay.moments.last?.dailyDigest == digest, "Replay lost the structured daily digest.")
        let markdown = try String(
            contentsOf: temporaryHome.appendingPathComponent("Daily/\(day).md"),
            encoding: .utf8
        )
        try require(markdown.contains("Daily Context distilled"), "The daily digest did not enter Markdown.")
        try require(markdown.contains("LUMA 留下的一句话"), "The digest omitted LUMA's personal note.")
        let reloaded = try AppendOnlyDiary(homeURL: temporaryHome, timeZone: utc)
        let reloadedEntries = await reloaded.allEntries()
        try require(reloadedEntries.count == 1, "Reload changed the append-only digest count.")
        guard case .dailyContextDigest(let restored) = reloadedEntries[0].payload else {
            throw HarnessFailure("Reload did not preserve the structured daily digest payload.")
        }
        try require(restored == digest, "Reload changed the daily digest payload.")

        let policy = ProactiveCompanionPolicy()
        let timeZone = try requireValue(TimeZone(secondsFromGMT: 8 * 3600), "Could not create Shanghai offset.")
        let busy = ProactiveCompanionSnapshot(
            now: time,
            secondsSinceLastInteraction: 5,
            hasDailyDigest: true,
            alreadyInvitedForDigest: false,
            timeZone: timeZone
        )
        try require(policy.opportunity(for: busy) == nil, "LUMA interrupted active input.")
        var idle = busy
        idle.secondsSinceLastInteraction = 120
        try require(policy.opportunity(for: idle) == .inviteDailyReview, "LUMA missed a genuine idle review opportunity.")
        idle.alreadyInvitedForDigest = true
        try require(policy.opportunity(for: idle) == nil, "The same digest invitation repeated after dismissal.")
        var leisure = busy
        leisure.leisureContextDuration = 6 * 60
        try require(policy.opportunity(for: leisure) == .inviteDailyReview, "Leisure context did not create a low-friction invitation opportunity.")
        leisure.isSensitiveContext = true
        try require(policy.opportunity(for: leisure) == nil, "Sensitive context allowed a proactive interruption.")

        return [
            HarnessCheck(
                name: "Daily Context distillation",
                detail: "A structured living diary persisted headline, concrete highlights, rhythm, unfinished thread and LUMA's personal note without rewriting source Context."
            ),
            HarnessCheck(
                name: "Proactive companionship boundary",
                detail: "LUMA waits for idle or sustained leisure, never repeats the same digest invitation, and stays silent on sensitive surfaces."
            )
        ]
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessFailure(message) }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw HarnessFailure(message) }
        return value
    }
}

private extension Array where Element == AgentPrompt {
    var reminderLevels: [Int] {
        compactMap { prompt in
            if case .reminder(let stage, _, _) = prompt { return stage.level }
            return nil
        }
    }

    var containsReturn: Bool {
        contains { prompt in
            if case .returnedToIntent = prompt { return true }
            return false
        }
    }
}
