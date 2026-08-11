import Foundation

public struct DiaryAggregate: Codable, Hashable, Sendable {
    public enum Period: String, Codable, Hashable, Sendable {
        case week
        case month
    }

    public var period: Period
    public var identifier: String
    public var start: Date
    public var end: Date
    public var activityCount: Int
    public var driftCount: Int
    public var successfulReturns: Int
    public var learnedSkillCount: Int
    public var highlights: [String]

    public init(
        period: Period,
        identifier: String,
        start: Date,
        end: Date,
        activityCount: Int,
        driftCount: Int,
        successfulReturns: Int,
        learnedSkillCount: Int,
        highlights: [String]
    ) {
        self.period = period
        self.identifier = identifier
        self.start = start
        self.end = end
        self.activityCount = activityCount
        self.driftCount = driftCount
        self.successfulReturns = successfulReturns
        self.learnedSkillCount = learnedSkillCount
        self.highlights = highlights
    }
}

public struct DiaryAggregator: Sendable {
    public init() {}

    public func aggregate(
        entries: [DiaryEntry],
        period: DiaryAggregate.Period,
        identifier: String,
        start: Date,
        end: Date
    ) -> DiaryAggregate {
        let selected = entries.filter { $0.timestamp >= start && $0.timestamp < end }
        var activityCount = 0
        var driftCount = 0
        var successfulReturns = 0
        var learnedSkillCount = 0
        var highlights: [String] = []

        for entry in selected {
            switch entry.payload {
            case .activity(let record):
                activityCount += 1
                if record.event.semantics.contains(.opinionOutput) {
                    highlights.append(record.narrative)
                }
            case .driftStarted:
                driftCount += 1
            case .returnedToIntent:
                successfulReturns += 1
            case .skillLearned(let skill):
                learnedSkillCount += 1
                highlights.append("AgentOne learned: \(skill.name)")
            case .daySummary(let summary):
                highlights.append(summary)
            case .dailyContextDigest(let digest):
                highlights.append(digest.overview)
            default:
                break
            }
        }

        return DiaryAggregate(
            period: period,
            identifier: identifier,
            start: start,
            end: end,
            activityCount: activityCount,
            driftCount: driftCount,
            successfulReturns: successfulReturns,
            learnedSkillCount: learnedSkillCount,
            highlights: Array(highlights.prefix(12))
        )
    }
}

public actor AppendOnlyDiary {
    private var entries: [DiaryEntry] = []
    private let homeURL: URL?
    private let calendar: Calendar

    public init(homeURL: URL? = nil, timeZone: TimeZone = .current) throws {
        self.homeURL = homeURL
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        if let homeURL {
            try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
            self.entries = try Self.loadEntries(from: homeURL)
        }
    }

    @discardableResult
    public func append(_ payload: DiaryEntryPayload, at timestamp: Date = Date()) throws -> DiaryEntry {
        let entry = DiaryEntry(timestamp: timestamp, payload: payload)
        entries.append(entry)
        if let homeURL {
            try appendMarkdown(entry, homeURL: homeURL)
        }
        return entry
    }

    public func allEntries() -> [DiaryEntry] {
        entries
    }

    public func projection() -> DiaryProjection {
        DiaryProjection(entries: entries)
    }

    public func dayKey(for date: Date) -> String {
        Self.dayKey(for: date, calendar: calendar)
    }

    @discardableResult
    public func appendCorrection(
        to targetEntryID: UUID,
        text: String,
        at timestamp: Date = Date()
    ) throws -> DiaryEntry {
        try append(.correction(DiaryCorrection(targetEntryID: targetEntryID, correction: text)), at: timestamp)
    }

    @discardableResult
    public func setHidden(
        _ hidden: Bool,
        entryID: UUID,
        reason: String? = nil,
        at timestamp: Date = Date()
    ) throws -> DiaryEntry {
        try append(.visibilityChanged(DiaryVisibilityChange(targetEntryID: entryID, isHidden: hidden, reason: reason)), at: timestamp)
    }

    public func persist(_ aggregate: DiaryAggregate) throws -> URL? {
        guard let homeURL else { return nil }
        let directoryName = aggregate.period == .week ? "Weekly" : "Monthly"
        let directory = homeURL.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(aggregate.identifier).md")
        let markdown = Self.render(aggregate: aggregate)
        try Data(markdown.utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func appendMarkdown(_ entry: DiaryEntry, homeURL: URL) throws {
        let day = Self.dayKey(for: entry.timestamp, calendar: calendar)
        let dailyDirectory = homeURL.appendingPathComponent("Daily", isDirectory: true)
        try FileManager.default.createDirectory(at: dailyDirectory, withIntermediateDirectories: true)
        let fileURL = dailyDirectory.appendingPathComponent("\(day).md")
        let newFile = !FileManager.default.fileExists(atPath: fileURL.path)
        if newFile {
            let header = "# AgentOne Diary — \(day)\n\n> Append-only semantic memory. Corrections and visibility changes appear as later events.\n\n"
            try Data(header.utf8).write(to: fileURL, options: .atomic)
        }

        let data = Data(Self.render(entry: entry, calendar: calendar).utf8)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func timeText(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private static func render(entry: DiaryEntry, calendar: Calendar) -> String {
        let time = timeText(for: entry.timestamp, calendar: calendar)
        let (title, body) = markdownContent(for: entry.payload)
        let encoded = (try? JSONEncoder().encode(entry).base64EncodedString()) ?? ""
        return "## \(time) · \(title)\n\n\(body)\n\n<!-- entry-id: \(entry.id.uuidString) -->\n<!-- agentone-json: \(encoded) -->\n\n"
    }

    private static func loadEntries(from homeURL: URL) throws -> [DiaryEntry] {
        let dailyDirectory = homeURL.appendingPathComponent("Daily", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dailyDirectory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: dailyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "md" }
        var loaded: [DiaryEntry] = []
        let prefix = "<!-- agentone-json: "
        let suffix = " -->"

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let markdown = try String(contentsOf: file, encoding: .utf8)
            for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { continue }
                let start = text.index(text.startIndex, offsetBy: prefix.count)
                let end = text.index(text.endIndex, offsetBy: -suffix.count)
                let encoded = String(text[start..<end])
                guard let data = Data(base64Encoded: encoded),
                      let entry = try? JSONDecoder().decode(DiaryEntry.self, from: data) else { continue }
                loaded.append(entry)
            }
        }
        // Files are visited by day and entries by append order. Keeping that order also
        // preserves causality when several hook events share the same timestamp.
        return loaded
    }

    private static func markdownContent(for payload: DiaryEntryPayload) -> (String, String) {
        switch payload {
        case .activity(let record):
            if let session = record.session {
                let duration = Int(session.duration.rounded())
                let place = session.context.windowTitle
                    ?? session.context.url?.absoluteString
                    ?? session.context.applicationName
                    ?? "unknown"
                return (
                    "Continuous activity",
                    "\(record.narrative)\n\n- Kind: \(session.kind.rawValue)\n- Context: \(place)\n- Duration: \(duration) seconds\n- Raw hooks merged: \(session.eventCount)\n- End reason: \(session.endReason.rawValue)"
                )
            }
            let semantic = record.event.semantics.map(\.rawValue).sorted().joined(separator: ", ")
            return ("User activity", "\(record.narrative)\n\n- Hooks: \(semantic.isEmpty ? "none" : semantic)\n- Window: \(record.event.context.windowTitle ?? "unknown")")
        case .contextEnrichment(let enrichment):
            var lines = [
                "**\(enrichment.activityTitle)**",
                enrichment.summary,
                "- Target event: `\(enrichment.targetEventID.uuidString)`"
            ]
            if let targetActivityEntryID = enrichment.targetActivityEntryID {
                lines.append("- Target activity: `\(targetActivityEntryID.uuidString)`")
            }
            if let windowTitle = enrichment.context.windowTitle {
                lines.append("- Window: \(windowTitle)")
            }
            if let url = enrichment.context.url {
                lines.append("- URL: \(url.absoluteString)")
            }
            if let documentPath = enrichment.context.documentPath {
                lines.append("- Document: \(documentPath)")
            }
            if let selectedText = enrichment.context.selectedText {
                lines.append("- Selected text: \(selectedText)")
            }
            if let submittedText = enrichment.context.submittedText {
                lines.append("- Submitted text: \(submittedText)")
            }
            if let interactionTarget = enrichment.context.interactionTarget {
                lines.append("- Click target: \(interactionTarget)")
            }
            if let transition = enrichment.context.contextTransition {
                lines.append("- Context transition: \(transition)")
            }
            if !enrichment.tags.isEmpty {
                lines.append("- Tags: \(enrichment.tags.joined(separator: ", "))")
            }
            return ("Context understood", lines.joined(separator: "\n\n"))
        case .intentStarted(let intent):
            return ("Intent inferred", "**\(intent.title)** — \(intent.summary)\n\nConfidence: \(Int(intent.confidence * 100))%")
        case .intentConfirmed:
            return ("Intent confirmed", "The current intention was accepted by the user or confirmed by continued behavior.")
        case .driftStarted(let drift):
            return ("Possible drift", "AgentOne observed a conflict with the active intention. Minimum relevance: \(Int(drift.minimumRelevance * 100))%.")
        case .reminder(let prompt):
            return ("Agent intervention", prompt.replayText)
        case .returnedToIntent:
            return ("Returned", "The user returned to the earlier intention.")
        case .feedback(let feedback):
            return ("User feedback", String(describing: feedback.kind))
        case .correction(let correction):
            return ("Correction appended", "Correction for `\(correction.targetEntryID.uuidString)`: \(correction.correction)")
        case .visibilityChanged(let change):
            return (change.isHidden ? "Sensitive memory hidden" : "Memory revealed", "Target entry: `\(change.targetEntryID.uuidString)`\(change.reason.map { " — \($0)" } ?? "")")
        case .agentReflection(let reflection):
            var lines = ["**I noticed:** \(reflection.observation)"]
            if let hypothesis = reflection.hypothesis { lines.append("**I guessed:** \(hypothesis)") }
            if let action = reflection.consideredAction { lines.append("**I considered:** \(action)") }
            if let why = reflection.why { lines.append("**Why:** \(why)") }
            lines.append("**Disposition:** \(reflection.disposition.rawValue)")
            return ("Inside AgentOne", lines.joined(separator: "\n\n"))
        case .evidence(let evidence):
            var lines = ["**\(evidence.title)**\(evidence.summary.map { " — \($0)" } ?? "")"]
            if let submittedText = evidence.submittedText {
                lines.append("- Submitted text: \(submittedText)")
            }
            if let localResourcePath = evidence.localResourcePath {
                lines.append("- Local evidence: \(localResourcePath)")
            }
            if let url = evidence.url {
                lines.append("- URL: \(url.absoluteString)")
            }
            return ("Key evidence", lines.joined(separator: "\n\n"))
        case .skillLearned(let skill):
            return ("Skill evolved", "**\(skill.name)** — \(skill.guidance)\n\nConfidence: \(Int(skill.confidence * 100))%")
        case .daySummary(let summary):
            return ("Day in review", summary)
        case .dailyContextDigest(let digest):
            var lines = [
                "# \(digest.headline)",
                digest.overview,
                "## 今天真正发生的事",
                digest.highlights.isEmpty
                    ? "- 还没有足够具体的 Context"
                    : digest.highlights.map { "- \($0)" }.joined(separator: "\n")
            ]
            if let rhythm = digest.rhythm {
                lines.append("## 我看到的节奏\n\(rhythm)")
            }
            if let unfinished = digest.unfinishedThread {
                lines.append("## 留到明天的一根线\n\(unfinished)")
            }
            lines.append("## LUMA 留下的一句话\n\(digest.agentNote)")
            lines.append(
                "- Context sources: \(digest.sourceContextCount)\n" +
                "- Evidence: \(digest.evidenceCount)\n" +
                "- Personalized memories used: \(digest.personalizedMemoryCount)\n" +
                "- Snapshot: \(digest.isFinal ? "final" : "living")"
            )
            return ("Daily Context distilled", lines.joined(separator: "\n\n"))
        }
    }

    private static func render(aggregate: DiaryAggregate) -> String {
        let title = aggregate.period == .week ? "Weekly Memory" : "Monthly Memory"
        let highlights = aggregate.highlights.isEmpty ? "- No highlights yet" : aggregate.highlights.map { "- \($0)" }.joined(separator: "\n")
        return """
        # \(title) — \(aggregate.identifier)

        - Activity moments: \(aggregate.activityCount)
        - Drift episodes: \(aggregate.driftCount)
        - Successful returns: \(aggregate.successfulReturns)
        - Skills learned: \(aggregate.learnedSkillCount)

        ## Highlights

        \(highlights)
        """
    }
}

private extension AgentPrompt {
    var replayText: String {
        switch self {
        case .curiousQuestion(let text):
            return text
        case .reminder(let stage, let text, let canReturn):
            return "Level \(stage.level): \(text)\(canReturn ? " A return action was offered." : "")"
        case .returnedToIntent:
            return "AgentOne noticed that the user returned."
        }
    }
}
