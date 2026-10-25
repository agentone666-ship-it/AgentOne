import AgentOneCore
import Foundation

/// A narrow, native-authored wake plan. Pi never decides when it may wake or
/// which capabilities are available; it only reasons inside this envelope.
public struct PiReminderWakePlan: Sendable {
    public let eventID: UUID
    public let intentID: UUID
    public let reminderStage: ReminderStage
    public let nativeFallback: AgentPrompt
    public let context: PiSanitizedContext
    public let recentMemory: [PiRecentMemory]
    public let budget: PiWakeBudget

    public var reason: String {
        "drift_reminder_level_\(reminderStage.level)"
    }

    public var deduplicationKey: String {
        "\(intentID.uuidString):\(reminderStage.level)"
    }
}

public enum PiWakePolicy {
    private static let maximumRecentMemories = 12
    private static let maximumMemorySummaryCharacters = 640

    public static func reminderPlan(
        for prompt: AgentPrompt,
        event: ActivityEvent,
        output: ContextEngineOutput,
        replay: SemanticReplay
    ) -> PiReminderWakePlan? {
        guard case .reminder(let stage, _, _) = prompt,
              let intent = output.activeIntent,
              !event.context.isSensitive,
              let driftDuration = output.activeDriftDurationSeconds,
              driftDuration >= 0 else {
            return nil
        }

        // Selected text is deliberately withheld from automatic wakes. It can
        // contain credentials, private chat, source code or other material that
        // is not identifiable from the app/window title privacy gate alone.
        let context = PiSanitizedContext(
            capturedAt: iso8601String(from: event.timestamp),
            applicationName: bounded(event.context.applicationName, limit: 160),
            bundleIdentifier: bounded(event.context.bundleIdentifier, limit: 200),
            windowTitle: bounded(event.context.windowTitle, limit: 400),
            contentSummary: bounded(event.context.contentSummary, limit: 600),
            selectedText: nil,
            semanticTags: Array(
                event.context.semanticTags
                    .union(event.semantics.map(\.rawValue))
                    .sorted()
                    .prefix(32)
            ),
            isSensitive: false,
            activeIntent: PiActiveIntent(
                id: intent.id.uuidString,
                title: bounded(intent.title, limit: 240) ?? "当前任务",
                summary: bounded(intent.summary, limit: 600)
            ),
            driftDurationSeconds: driftDuration
        )
        guard context.isSafeForPi else { return nil }

        return PiReminderWakePlan(
            eventID: event.id,
            intentID: intent.id,
            reminderStage: stage,
            nativeFallback: prompt,
            context: context,
            recentMemory: makeRecentMemory(from: replay),
            budget: PiWakeBudget(
                // Include headroom for the historical search schema and a result.
                maxTokens: 4_800,
                maxTurns: 3,
                maxDurationMs: 8_000,
                allowedTools: [
                    .getCurrentContext,
                    .searchContext,
                    .readRecentDiary,
                    .appendInnerJournal,
                    .showReturnCard,
                    .consumeEnergyBudget
                ],
                surpriseRisk: .none
            )
        )
    }

    private static func makeRecentMemory(from replay: SemanticReplay) -> [PiRecentMemory] {
        replay.moments
            .lazy
            .filter { !$0.isHidden && $0.kind != .evidence }
            .compactMap { moment -> PiRecentMemory? in
                let summary = [moment.title, moment.detail]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " — ")
                guard !summary.isEmpty, isSafeStructuredMemory(summary) else { return nil }

                return PiRecentMemory(
                    id: moment.sourceEntryID.uuidString,
                    timestamp: iso8601String(from: moment.timestamp),
                    kind: moment.kind.rawValue,
                    summary: String(summary.prefix(maximumMemorySummaryCharacters)),
                    tags: [moment.lane.rawValue, moment.kind.rawValue]
                )
            }
            .suffix(maximumRecentMemories)
    }

    private static func isSafeStructuredMemory(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let protectedTerms = [
            "1password", "bitwarden", "keepass", "password", "passcode",
            "密码", "验证码", "payment", "checkout", "支付", "银行卡", "bank"
        ]
        return !protectedTerms.contains { normalized.contains($0) }
    }

    private static func bounded(_ value: String?, limit: Int) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(limit))
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public extension PiJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }
}
