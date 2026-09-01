import Foundation
import Testing
@testable import AgentOneCore

@Suite(.serialized)
struct ContextMemoryEngineTests {
    @Test
    func testHookSemanticsTreatReturnAsOpinionOutputWithoutCapturingText() {
        let event = ActivityEvent(signal: .keyboard(.returnPressed))

        #expect(event.semantics.contains(.opinionOutput))
        #expect(event.semantics.contains(.taskSubmission))
        #expect(!(event.semantics.contains(.compositionContinued)))
    }

    @Test
    func testScrollAndTypingMapToReadingAndComposition() {
        let scroll = ActivityEvent(signal: .scrolled(axis: .vertical, delta: 120, phase: .changed))
        let typing = ActivityEvent(signal: .keyboard(.typingBurst(estimatedCharacterCount: 24)))

        #expect(scroll.semantics == [.readingProgress, .navigation])
        #expect(typing.semantics == [.compositionContinued])
    }

    @Test
    func testPrimaryClickIsOnlyCandidateIntentUntilContextActuallyChanges() {
        let click = ActivityEvent(signal: .mouseClicked(
            button: .left,
            count: 1,
            location: ScreenPoint(x: 420, y: 260)
        ))

        #expect(click.semantics == [.selectionOrActivation])
        #expect(!(click.semantics.contains(.navigation)))
    }

    @Test
    func testReturnPersistsSubmittedTextAndScreenshotAsEmbeddedEvidence() async throws {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(diary: diary)
        let timestamp = Date(timeIntervalSince1970: 1_720_000_000)
        let screenshotPath = "/tmp/agentone-return-evidence.png"
        let event = ActivityEvent(
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

        _ = try await engine.record(event)
        _ = try await engine.addAgentReflection(AgentReflection(
            timestamp: timestamp.addingTimeInterval(1),
            observation: "用户正在验证回车 Context。",
            disposition: .observationOnly,
            relatedEventIDs: [event.id]
        ))
        let entries = await diary.allEntries()
        let evidence = entries.compactMap { entry -> KeyEvidence? in
            guard case .evidence(let item) = entry.payload else { return nil }
            return item
        }
        #expect(evidence.count == 1)
        #expect(evidence.first?.kind == .screenshot)
        #expect(evidence.first?.localResourcePath == screenshotPath)
        #expect(evidence.first?.submittedText == "重新修一下，让这些功能真正落地。")

        let activity = entries.compactMap { entry -> ActivityDiaryRecord? in
            guard case .activity(let record) = entry.payload else { return nil }
            return record
        }.first
        #expect(activity?.evidenceIDs == [evidence[0].id])

        let replay = await engine.replay(for: timestamp)
        #expect(replay.moments.filter { $0.kind == .evidence }.count == 0)
        #expect(replay.moments.contains { $0.evidenceIDs == [evidence[0].id] })
        let thought = replay.moments.first {
            $0.kind == .thought && $0.title == "用户正在验证回车 Context。"
        }
        #expect(thought?.submittedText == "重新修一下，让这些功能真正落地。")
        #expect(thought?.evidenceIDs == [evidence[0].id])
    }

    @Test
    func testFiftyScrollHooksBecomeOneReadingSessionAndOneReplayMoment() async throws {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(diary: diary)
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let context = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Attention Is All You Need",
            windowIdentifier: "paper-window",
            url: URL(string: "https://arxiv.org/abs/1706.03762"),
            contentSummary: "Transformer research paper"
        )

        for index in 0..<50 {
            let phase: ScrollPhase = index == 0 ? .began : (index == 49 ? .ended : .changed)
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 24, phase: phase),
                context: context
            ))
        }

        _ = try await engine.flushPendingActivity(at: base.addingTimeInterval(100))
        let activityRecords = await activityRecords(in: diary)
        #expect(activityRecords.count == 1)
        #expect(activityRecords.first?.session?.eventCount == 50)
        #expect(activityRecords.first?.session?.totalMagnitude == 1_200)

        let replay = await engine.replay(for: base)
        let readingMoments = replay.moments.filter { $0.kind == .activity && $0.title.hasPrefix("Read ") }
        #expect(readingMoments.count == 1)
        #expect(readingMoments.first?.detail?.contains("Attention Is All You Need") == true)
        #expect(readingMoments.first?.detail?.contains("已合并") != true)
    }

    @Test
    func testLegacyScrollEntriesRemainImmutableButProjectAsReadingSessions() async throws {
        let diary = try AppendOnlyDiary()
        let base = Date(timeIntervalSince1970: 1_711_000_000)
        let firstContext = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Legacy paper A",
            windowIdentifier: "legacy-a",
            url: URL(string: "https://example.com/legacy-a")
        )

        for index in 0..<50 {
            let phase: ScrollPhase = index == 0 ? .began : (index == 49 ? .ended : (index > 35 ? .momentum : .changed))
            let event = ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 20, phase: phase),
                context: firstContext
            )
            _ = try await diary.append(.activity(ActivityDiaryRecord(
                event: event,
                narrative: "Continued reading in Safari",
                session: nil
            )), at: event.timestamp)
        }

        let original = await diary.allEntries()
        #expect(original.count == 50)
        #expect(original.allSatisfy { entry in
            guard case .activity(let record) = entry.payload else { return false }
            return record.session == nil
        })

        let replay = SemanticReplayBuilder().build(day: "legacy", entries: original)
        let readingMoments = replay.moments.filter { $0.kind == .activity && $0.title.hasPrefix("Read ") }
        #expect(readingMoments.count == 1)
        #expect(readingMoments.first?.detail?.contains("Legacy paper A") == true)
        #expect(readingMoments.first?.detail?.contains("已合并") != true)
        #expect(HabitContextExtractor().extract(from: original).first?.supportingSessionCount == 1)

        let typing = ActivityEvent(
            timestamp: base.addingTimeInterval(110),
            signal: .keyboard(.typingStarted),
            context: firstContext
        )
        _ = try await diary.append(.activity(ActivityDiaryRecord(
            event: typing,
            narrative: "Started writing in Safari"
        )), at: typing.timestamp)

        let secondContext = ActivityContext(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Legacy paper B",
            windowIdentifier: "legacy-b",
            url: URL(string: "https://example.com/legacy-b")
        )
        for index in 0..<8 {
            let event = ActivityEvent(
                timestamp: base.addingTimeInterval(120 + Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 25, phase: index == 0 ? .began : (index == 7 ? .ended : .changed)),
                context: secondContext
            )
            _ = try await diary.append(.activity(ActivityDiaryRecord(
                event: event,
                narrative: "Continued reading in Safari"
            )), at: event.timestamp)
        }

        let withBoundary = await diary.allEntries()
        let replayWithBoundary = SemanticReplayBuilder().build(day: "legacy", entries: withBoundary)
        #expect(replayWithBoundary.moments.filter { $0.kind == .activity && $0.title.hasPrefix("Read ") }.count == 2)
        #expect(HabitContextExtractor().extract(from: withBoundary).first?.supportingSessionCount == 2)
        #expect(withBoundary.count == 59)

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
        let withHistoricalSelfCapture = await diary.allEntries()
        let replayWithoutSelfCapture = SemanticReplayBuilder().build(day: "legacy", entries: withHistoricalSelfCapture)
        #expect(
            !(replayWithoutSelfCapture.moments.contains {
                $0.title.contains("AgentOne") || ($0.detail?.contains("AgentOne") ?? false)
            }))
        #expect(replayWithoutSelfCapture.moments.filter { $0.kind == .activity && $0.title.hasPrefix("Read ") }.count == 2)
        #expect(HabitContextExtractor().extract(from: withHistoricalSelfCapture).first?.supportingSessionCount
                == 2)
        #expect(withHistoricalSelfCapture.count == 79)
    }

    @Test
    func testShortReadingPauseRemainsSameSession() async throws {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(diary: diary)
        let base = Date(timeIntervalSince1970: 1_710_100_000)
        let context = ActivityContext(applicationName: "Preview", windowTitle: "ADHD-study.pdf", documentPath: "/papers/ADHD-study.pdf")

        _ = try await engine.record(ActivityEvent(timestamp: base, signal: .scrolled(axis: .vertical, delta: 80, phase: .began), context: context))
        _ = try await engine.record(ActivityEvent(timestamp: base.addingTimeInterval(75), signal: .scrolled(axis: .vertical, delta: 100, phase: .changed), context: context))
        _ = try await engine.flushPendingActivity()

        let sessions = await activityRecords(in: diary).compactMap(\.session)
        #expect(sessions.count == 1)
        #expect(sessions.first?.eventCount == 2)
        #expect(sessions.first?.duration == 75)
    }

    @Test
    func testContextChangeClosesReadingAndStartsAnotherSession() async throws {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(diary: diary)
        let base = Date(timeIntervalSince1970: 1_710_200_000)
        let first = ActivityContext(
            applicationName: "Safari",
            windowTitle: "Paper A",
            windowIdentifier: "a",
            url: URL(string: "https://example.com/a")
        )
        let second = ActivityContext(
            applicationName: "Safari",
            windowTitle: "Paper B",
            windowIdentifier: "b",
            url: URL(string: "https://example.com/b")
        )

        for index in 0..<5 {
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 60, phase: index == 0 ? .began : .changed),
                context: first
            ))
        }
        let switched = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(10),
            signal: .scrolled(axis: .vertical, delta: 70, phase: .began),
            context: second
        ))
        #expect(!(switched.appendedDiaryEntryIDs.isEmpty))
        for index in 1..<5 {
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(10 + Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 70, phase: index == 4 ? .ended : .changed),
                context: second
            ))
        }
        _ = try await engine.flushPendingActivity()

        let sessions = await activityRecords(in: diary).compactMap(\.session)
        #expect(sessions.count == 2)
        #expect(sessions.map { $0.context.windowTitle } == ["Paper A", "Paper B"])
        #expect(sessions.first?.endReason == .contextChanged)
    }

    @Test
    func testTypingAndIdleCloseReadingWhileReturnKeepsIndependentEvidence() async throws {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(diary: diary)
        let base = Date(timeIntervalSince1970: 1_710_300_000)
        let context = ActivityContext(
            applicationName: "Notes",
            windowTitle: "Research notes",
            contentSummary: "A complete product opinion"
        )

        for index in 0..<5 {
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 90, phase: index == 0 ? .began : .changed),
                context: context
            ))
        }
        _ = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(10),
            signal: .keyboard(.typingStarted),
            context: context
        ))
        for index in 0..<5 {
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(20 + Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 40, phase: index == 0 ? .began : .changed),
                context: context
            ))
        }
        _ = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(30),
            signal: .idleStarted,
            context: context
        ))
        _ = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(35),
            signal: .keyboard(.returnPressed),
            context: context
        ))

        let records = await activityRecords(in: diary)
        let sessions = records.compactMap(\.session)
        #expect(sessions.count == 4)
        #expect(sessions.map(\.endReason) == [.activityChanged, .activityChanged, .becameIdle, .semanticMilestone])
        #expect(records.allSatisfy { $0.session != nil })
        let entries = await diary.allEntries()
        #expect(entries.contains { entry in
            guard case .evidence(let evidence) = entry.payload else { return false }
            return evidence.title == "A thought was expressed"
        })
    }

    @Test
    func testEveryScrollStillFeedsDriftStateMachineWhileDiaryIsDeduplicated() async throws {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(
            configuration: ContextEngineConfiguration(drift: DriftConfiguration(
                relevanceThreshold: 0.4,
                uncertaintyBand: 0.4...0.5,
                stages: [ReminderStage(level: 1, after: 20, modalities: [.textBubble])]
            )),
            diary: diary
        )
        let base = Date(timeIntervalSince1970: 1_710_400_000)
        let writing = ActivityContext(windowTitle: "Paper draft", semanticTags: ["paper", "writing"])
        let detour = ActivityContext(windowTitle: "Short videos", semanticTags: ["video", "comedy"])
        _ = try await engine.beginIntent(title: "Write paper", summary: "paper writing", context: writing, at: base)

        var reminderOutput: ContextEngineOutput?
        var finalOutput: ContextEngineOutput?
        for (index, offset) in [1.0, 3.5, 6.0, 8.5, 11.0, 13.5, 16.0, 18.5, 21.0, 25.0].enumerated() {
            let output = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(offset),
                signal: .scrolled(
                    axis: .vertical,
                    delta: 10,
                    phase: index == 0 ? .began : (index == 9 ? .ended : .changed)
                ),
                context: detour
            ))
            if !output.prompts.reminderLevels.isEmpty { reminderOutput = output }
            finalOutput = output
        }
        let reminder = try #require(reminderOutput)
        let final = try #require(finalOutput)

        #expect(reminder.prompts.reminderLevels == [1])
        #expect(final.activeDriftDurationSeconds == 24)
        let beforeFlush = await activityRecords(in: diary)
        #expect(beforeFlush.count == 0)
        _ = try await engine.flushPendingActivity()
        let afterFlush = await activityRecords(in: diary)
        #expect(afterFlush.count == 1)
    }

    @Test
    func testSensitiveReadingNeverBecomesSessionOrHabit() async throws {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(diary: diary)
        let context = ActivityContext(
            applicationName: "Bank",
            windowTitle: "Payment password",
            contentSummary: "sensitive",
            isSensitive: true
        )

        for index in 0..<5 {
            _ = try await engine.record(ActivityEvent(
                timestamp: Date(timeIntervalSince1970: 1_710_500_000 + Double(index)),
                signal: .scrolled(axis: .vertical, delta: 20, phase: .changed),
                context: context
            ))
        }
        _ = try await engine.flushPendingActivity()

        let records = await activityRecords(in: diary)
        let habits = await engine.habitContexts()
        #expect(records.count == 0)
        #expect(habits.isEmpty)
    }

    @Test
    func testHabitContextIsVisibleAfterSessionsAndConfidenceGrowsWithEvidence() async throws {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(diary: diary)
        let base = Date(timeIntervalSince1970: 1_710_600_000)
        let context = ActivityContext(
            applicationName: "Safari",
            windowTitle: "Research paper",
            url: URL(string: "https://example.com/paper")
        )

        for index in 0..<5 {
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 50, phase: index == 0 ? .began : .changed),
                context: context
            ))
        }
        _ = try await engine.flushPendingActivity()
        let emergingHabits = await engine.habitContexts()
        let emerging = try #require(emergingHabits.first)
        #expect(emerging.supportingSessionCount == 1)
        #expect(emerging.confidence < 0.5)

        for index in 0..<5 {
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(600 + Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 70, phase: index == 0 ? .began : .changed),
                context: context
            ))
        }
        _ = try await engine.flushPendingActivity()
        let learnedHabits = await engine.habitContexts()
        let learned = try #require(learnedHabits.first)
        #expect(learned.supportingSessionCount == 2)
        #expect(learned.confidence > emerging.confidence)
        #expect(learned.evidenceEntryIDs.count == 2)
        #expect(learned.summary.contains("2 段独立阅读"))
    }

    @Test
    func testDriftReminderEscalatesUsingConfiguredDurationsThenRecordsReturn() async throws {
        let diary = try AppendOnlyDiary(timeZone: TimeZone(secondsFromGMT: 0)!)
        let drift = DriftConfiguration(
            relevanceThreshold: 0.3,
            uncertaintyBand: 0.3...0.45,
            stages: [
                ReminderStage(level: 1, after: 30, modalities: [.creatureMotion]),
                ReminderStage(level: 2, after: 60, modalities: [.textBubble])
            ]
        )
        let engine = ContextMemoryEngine(
            configuration: ContextEngineConfiguration(drift: drift),
            diary: diary
        )
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let writing = ActivityContext(
            applicationName: "Notes",
            windowTitle: "ADHD paper",
            contentSummary: "Writing an ADHD attention recovery paper",
            semanticTags: ["adhd", "attention", "paper"]
        )
        let video = ActivityContext(
            applicationName: "Safari",
            windowTitle: "Comedy shorts",
            contentSummary: "Unrelated funny video feed",
            semanticTags: ["comedy", "video"]
        )
        _ = try await engine.beginIntent(
            title: "Write ADHD paper",
            summary: "Develop the section about attention recovery",
            context: writing,
            at: base
        )

        _ = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(10),
            signal: .windowFocused(windowIdentifier: "video"),
            context: video
        ))
        let levelOne = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(41),
            signal: .scrolled(axis: .vertical, delta: 200, phase: .changed),
            context: video
        ))
        let levelTwo = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(71),
            signal: .scrolled(axis: .vertical, delta: 200, phase: .changed),
            context: video
        ))
        let returnCandidate = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(80),
            signal: .keyboard(.typingStarted),
            context: writing
        ))
        let returned = try await engine.record(ActivityEvent(
            timestamp: base.addingTimeInterval(90),
            signal: .keyboard(.typingBurst(estimatedCharacterCount: 8)),
            context: writing
        ))

        #expect(levelOne.prompts.reminderLevels == [1])
        #expect(levelTwo.prompts.reminderLevels == [2])
        #expect(
            !(returnCandidate.prompts.contains { prompt in
                if case .returnedToIntent = prompt { return true }
                return false
            }))
        #expect(returned.prompts.contains { prompt in
            if case .returnedToIntent = prompt { return true }
            return false
        })

        let entries = await diary.allEntries()
        #expect(entries.contains {
            if case .driftStarted = $0.payload { return true }
            return false
        })
        #expect(entries.contains {
            if case .returnedToIntent = $0.payload { return true }
            return false
        })
    }

    @Test
    func testFeedbackCreatesSkillAndChangesFutureRelevance() async throws {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(diary: diary)
        let base = Date(timeIntervalSince1970: 1_700_100_000)
        let task = ActivityContext(
            windowTitle: "Research draft",
            contentSummary: "Writing research about focus",
            semanticTags: ["research", "focus"]
        )
        let detour = ActivityContext(
            windowTitle: "Special source portal",
            contentSummary: "specialsource material",
            semanticTags: ["specialsource"]
        )
        _ = try await engine.beginIntent(title: "Write research", summary: "Focus research", context: task, at: base)

        let firstEvent = ActivityEvent(timestamp: base.addingTimeInterval(1), signal: .windowFocused(windowIdentifier: "source"), context: detour)
        let before = try await engine.record(firstEvent)
        let skill = try await engine.addFeedback(UserFeedback(
            timestamp: base.addingTimeInterval(2),
            kind: .eventWasRelated,
            eventID: firstEvent.id,
            intentSessionID: before.activeIntent?.id
        ))
        let after = try await engine.record(ActivityEvent(timestamp: base.addingTimeInterval(3), signal: .contentChanged, context: detour))

        #expect(skill != nil)
        #expect(skill?.domain == .intentDetection)
        #expect(after.relevance ?? 0 > before.relevance ?? 1)
        let skills = await engine.skills()
        #expect(skills.count == 1)
    }

    @Test
    func testAppendOnlyDiaryPreservesOriginalWhileCorrectionAndHideAreAppended() async throws {
        let diary = try AppendOnlyDiary()
        let original = try await diary.append(.daySummary("Agent initially misunderstood the activity."))

        let correction = try await diary.appendCorrection(
            to: original.id,
            text: "It was related research, not distraction.",
            at: original.timestamp.addingTimeInterval(1)
        )
        let hidden = try await diary.setHidden(
            true,
            entryID: original.id,
            reason: "Contains a sensitive detail",
            at: original.timestamp.addingTimeInterval(2)
        )

        let all = await diary.allEntries()
        let projection = await diary.projection()
        #expect(all.count == 3)
        #expect(all.first == original)
        #expect(correction.id != original.id)
        #expect(hidden.id != original.id)
        #expect(projection.hiddenEntryIDs.contains(original.id))
        #expect(projection.correctionsByEntryID[original.id]?.first?.correction
                == "It was related research, not distraction.")
        #expect(!(projection.visibleEntries.contains(where: { $0.id == original.id })))
    }

    @Test
    func testContextEnrichmentMergesIntoPendingActivityWithoutExtraDiaryRow() async throws {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(diary: diary)
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let rawContext = ActivityContext(
            applicationName: "Safari",
            windowTitle: "Attention Is All You Need",
            windowIdentifier: "paper-window",
            url: URL(string: "https://arxiv.org/abs/1706.03762"),
            contentSummary: "Paper page"
        )
        let firstEvent = ActivityEvent(
            timestamp: base,
            signal: .scrolled(axis: .vertical, delta: 20, phase: .began),
            context: rawContext
        )
        _ = try await engine.record(firstEvent)
        for index in 1..<5 {
            _ = try await engine.record(ActivityEvent(
                timestamp: base.addingTimeInterval(Double(index) * 2),
                signal: .scrolled(axis: .vertical, delta: 20, phase: .changed),
                context: rawContext
            ))
        }

        var enrichedContext = rawContext
        enrichedContext.contentSummary = "阅读 Transformer 论文中自注意力与多头注意力机制的章节"
        let result = try await engine.applyContextEnrichment(
            targetEventID: firstEvent.id,
            enrichedContext: enrichedContext,
            activityTitle: "阅读 Transformer 的自注意力章节",
            summary: enrichedContext.contentSummary!,
            tags: ["Transformer", "Attention"],
            matching: rawContext,
            at: base.addingTimeInterval(9)
        )
        #expect(result == .mergedIntoPending)

        _ = try await engine.flushPendingActivity(reason: .explicitFlush)
        let entries = await diary.allEntries()
        #expect(
            !(entries.contains {
                if case .contextEnrichment = $0.payload { return true }
                return false
            }))
        let record = entries.compactMap { entry -> ActivityDiaryRecord? in
            guard case .activity(let record) = entry.payload else { return nil }
            return record
        }.first
        #expect(record?.session?.context.contentSummary == enrichedContext.contentSummary)
        #expect(record?.session?.context.semanticTags.contains("transformer") == true)
    }

    @Test
    func testLateContextEnrichmentAppendsAuditFactAndProjectsOntoOriginalReplayMoment() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOneLateEnrichmentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let utc = TimeZone(secondsFromGMT: 0)!
        let diary = try AppendOnlyDiary(homeURL: temporary, timeZone: utc)
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

        let originalEntries = await diary.allEntries()
        let originalActivity = try #require(
            originalEntries.first {
                if case .activity = $0.payload { return true }
                return false
            })
        var enrichedContext = rawContext
        enrichedContext.contentSummary = "阅读 zloop 的业务背景，了解 Runtime、APIHub 与企业 Context 挂接方案"
        enrichedContext.selectedText = "zloop 是一套企业级解决方案"
        let result = try await engine.applyContextEnrichment(
            targetEventID: firstEvent.id,
            enrichedContext: enrichedContext,
            activityTitle: "阅读 zloop 企业级解决方案",
            summary: enrichedContext.contentSummary!,
            tags: ["zloop", "runtime", "apihub"],
            matching: rawContext,
            at: base.addingTimeInterval(15)
        )
        guard case .appended(let enrichmentEntry) = result else {
            Issue.record("Late enrichment was not appended: \(result)")
            return
        }

        let persistedEntries = await diary.allEntries()
        #expect(persistedEntries.first(where: { $0.id == originalActivity.id }) == originalActivity)
        #expect(persistedEntries.contains(where: { $0.id == enrichmentEntry.id }))
        let enrichment = try #require(persistedEntries.compactMap { entry -> ActivityContextEnrichment? in
            guard case .contextEnrichment(let enrichment) = entry.payload else { return nil }
            return enrichment
        }.first)
        #expect(enrichment.targetActivityEntryID == originalActivity.id)
        #expect(enrichment.targetEventID == firstEvent.id)

        let replay = await engine.replay(for: base)
        let activities = replay.moments.filter { $0.kind == .activity }
        #expect(activities.count == 1)
        #expect(activities.first?.title == "阅读 zloop 企业级解决方案")
        #expect(activities.first?.detail?.contains("Runtime、APIHub") == true)
        #expect(activities.first?.detail?.contains("https://zhuanspirit.feishu.cn/wiki/example") == true)

        let day = await diary.dayKey(for: base)
        let markdown = try String(contentsOf: temporary.appendingPathComponent("Daily/\(day).md"), encoding: .utf8)
        #expect(markdown.contains("Context understood"))
        #expect(markdown.contains(originalActivity.id.uuidString))
        #expect(markdown.contains("阅读 zloop 企业级解决方案"))

        let reloaded = try AppendOnlyDiary(homeURL: temporary, timeZone: utc)
        let reloadedEntries = await reloaded.allEntries()
        #expect(reloadedEntries == persistedEntries)
        let reloadedReplay = SemanticReplayBuilder().build(day: day, entries: reloadedEntries)
        #expect(reloadedReplay.moments.filter { $0.kind == .activity }.count == 1)
        #expect(reloadedReplay.moments.first(where: { $0.kind == .activity })?.title == "阅读 zloop 企业级解决方案")
    }

    @Test
    func testSensitiveContextEnrichmentIsRejectedWithoutPersistence() async throws {
        let diary = try AppendOnlyDiary()
        let engine = ContextMemoryEngine(diary: diary)
        let sensitive = ActivityContext(applicationName: "Bank", contentSummary: "payment password", isSensitive: true)
        let result = try await engine.applyContextEnrichment(
            targetEventID: UUID(),
            enrichedContext: sensitive,
            activityTitle: "Sensitive",
            summary: "Must never persist",
            matching: sensitive
        )
        #expect(result == .rejectedSensitive)
        let entries = await diary.allEntries()
        #expect(entries.isEmpty)
    }

    @Test
    func testMarkdownPersistenceAndSemanticReplayExposeBothUserAndAgentLanes() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOneCoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let utc = TimeZone(secondsFromGMT: 0)!
        let diary = try AppendOnlyDiary(homeURL: temporary, timeZone: utc)
        let engine = ContextMemoryEngine(diary: diary)
        let time = Date(timeIntervalSince1970: 1_700_200_000)
        let context = ActivityContext(
            applicationName: "Notes",
            windowTitle: "Idea",
            contentSummary: "A product idea",
            selectedText: "Context should create proactive value"
        )
        _ = try await engine.record(ActivityEvent(timestamp: time, signal: .keyboard(.returnPressed), context: context))
        _ = try await engine.addAgentReflection(AgentReflection(
            timestamp: time.addingTimeInterval(1),
            observation: "A clear product opinion was expressed.",
            hypothesis: "This may be an important principle.",
            consideredAction: "Keep it as evidence for tonight's review.",
            disposition: .heldBack
        ))

        let replay = await engine.replay(for: time)
        let day = await diary.dayKey(for: time)
        let markdownURL = temporary.appendingPathComponent("Daily/\(day).md")
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)

        #expect(markdown.contains("A thought was expressed"))
        #expect(markdown.contains("Inside AgentOne"))
        #expect(markdown.contains("agentone-json"))
        #expect(replay.moments.contains(where: { $0.lane == .userActivity }))
        #expect(replay.moments.contains(where: { $0.lane == .agentMind }))
        #expect(replay.evidence.contains(where: { $0.kind == .selectedText }))

        let reloadedDiary = try AppendOnlyDiary(homeURL: temporary, timeZone: utc)
        let reloadedEntries = await reloadedDiary.allEntries()
        let originalEntries = await diary.allEntries()
        #expect(reloadedEntries == originalEntries)
    }

    @Test
    func testWeeklyAggregationSkeletonCountsCoreOutcomes() async throws {
        let diary = try AppendOnlyDiary()
        let start = Date(timeIntervalSince1970: 1_700_300_000)
        _ = try await diary.append(.daySummary("Made meaningful progress."), at: start)
        _ = try await diary.append(.returnedToIntent(intentSessionID: UUID()), at: start.addingTimeInterval(60))
        let skill = AgentSkill(createdAt: start, name: "Gentle timing", domain: .reminderTiming, guidance: "Wait and ask softly.", confidence: 0.8)
        _ = try await diary.append(.skillLearned(skill), at: start.addingTimeInterval(120))

        let aggregate = DiaryAggregator().aggregate(
            entries: await diary.allEntries(),
            period: .week,
            identifier: "2023-W46",
            start: start.addingTimeInterval(-1),
            end: start.addingTimeInterval(3600)
        )

        #expect(aggregate.successfulReturns == 1)
        #expect(aggregate.learnedSkillCount == 1)
        #expect(aggregate.highlights.contains("Made meaningful progress."))
    }

    @Test
    func testDailyContextDigestPersistsAsStructuredAppendOnlyMemory() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOneDigestTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let utc = TimeZone(secondsFromGMT: 0)!
        let diary = try AppendOnlyDiary(homeURL: temporary, timeZone: utc)
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
        #expect(replay.moments.last?.dailyDigest == digest)
        let latestDigest = await engine.latestDailyContextDigest(for: time)
        #expect(latestDigest == digest)
        let markdown = try String(
            contentsOf: temporary.appendingPathComponent("Daily/\(day).md"),
            encoding: .utf8
        )
        #expect(markdown.contains("Daily Context distilled"))
        #expect(markdown.contains("LUMA 留下的一句话"))
        #expect(markdown.contains("我记住了你不接受只有壳子的功能"))

        let reloaded = try AppendOnlyDiary(homeURL: temporary, timeZone: utc)
        let reloadedEntry = await reloaded.allEntries().last
        guard case .dailyContextDigest(let reloadedDigest) = reloadedEntry?.payload else {
            Issue.record("Structured daily digest did not survive reload")
            return
        }
        #expect(reloadedDigest == digest)
    }

    @Test
    func testAllReplaysAndPersistedSkillsRestoreAcrossDays() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOneLibraryProjectionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let utc = TimeZone(secondsFromGMT: 0)!
        let firstDay = Date(timeIntervalSince1970: 1_722_700_000)
        let secondDay = firstDay.addingTimeInterval(86_400)
        let diary = try AppendOnlyDiary(homeURL: temporary, timeZone: utc)
        let firstDayKey = await diary.dayKey(for: firstDay)
        let secondDayKey = await diary.dayKey(for: secondDay)
        _ = try await diary.append(.daySummary("First day remains available."), at: firstDay)
        _ = try await diary.append(.daySummary("Second day remains available."), at: secondDay)
        let skill = AgentSkill(
            createdAt: secondDay,
            name: "Remember the user's reading rhythm",
            domain: .intentDetection,
            guidance: "Treat a continuous reading session as one Context segment.",
            confidence: 0.9,
            sourceEntryIDs: [UUID()],
            revision: 2
        )
        _ = try await diary.append(.skillLearned(skill), at: secondDay.addingTimeInterval(1))

        let engine = ContextMemoryEngine(diary: diary)
        let replays = await engine.allReplays()
        #expect(replays.map(\.day) == [firstDayKey, secondDayKey])
        #expect(replays.count == 2)

        let reloadedDiary = try AppendOnlyDiary(homeURL: temporary, timeZone: utc)
        let reloadedEngine = ContextMemoryEngine(diary: reloadedDiary)
        await reloadedEngine.restorePersistedSkills()
        let restoredSkills = await reloadedEngine.persistedSkills()
        #expect(restoredSkills.map(\.name) == [skill.name])
        #expect(restoredSkills.first?.revision == 2)
        #expect(await reloadedEngine.recordedDays() == [firstDayKey, secondDayKey])
    }

    @Test
    func testProactiveCompanionWaitsForARealLowInterruptionOpportunity() {
        let now = Date(timeIntervalSince1970: 1_722_830_400)
        let policy = ProactiveCompanionPolicy()
        let busy = ProactiveCompanionSnapshot(
            now: now,
            secondsSinceLastInteraction: 5,
            hasDailyDigest: true,
            alreadyInvitedForDigest: false,
            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!
        )
        #expect(policy.opportunity(for: busy) == nil)

        var idle = busy
        idle.secondsSinceLastInteraction = 120
        #expect(policy.opportunity(for: idle) == .inviteDailyReview)

        idle.alreadyInvitedForDigest = true
        #expect(policy.opportunity(for: idle) == nil)

        var leisure = busy
        leisure.leisureContextDuration = 6 * 60
        #expect(policy.opportunity(for: leisure) == .inviteDailyReview)

        leisure.isSensitiveContext = true
        #expect(policy.opportunity(for: leisure) == nil)
    }
}

private func activityRecords(in diary: AppendOnlyDiary) async -> [ActivityDiaryRecord] {
    await diary.allEntries().compactMap { entry in
        guard case .activity(let record) = entry.payload else { return nil }
        return record
    }
}

extension Array where Element == AgentPrompt {
    fileprivate var reminderLevels: [Int] {
        compactMap { prompt in
            if case .reminder(let stage, _, _) = prompt { return stage.level }
            return nil
        }
    }
}
