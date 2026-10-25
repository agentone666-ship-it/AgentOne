import Foundation
import AgentOneCore

/// A local-only search snapshot. Never inserted wholesale into model messages.
public struct PiContextRecord: Codable, Equatable, Sendable {
    public var id: String
    public var eventID: String
    public var timestamp: String
    public var kind: String
    public var context: PiSanitizedContext
}

public enum PiContextHistory {
    public static func records(from entries: [DiaryEntry]) -> [PiContextRecord] {
        let projection = DiaryProjection(entries: entries)
        var byEntry: [UUID: ActivityContextEnrichment] = [:]
        var byEvent: [UUID: ActivityContextEnrichment] = [:]
        for entry in projection.visibleEntries.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard case .contextEnrichment(let value) = entry.payload else { continue }
            if let id = value.targetActivityEntryID { byEntry[id] = value }
            byEvent[value.targetEventID] = value
        }
        let visibleCorrections = DiaryProjection(entries: projection.visibleEntries).correctionsByEntryID
        let formatter = ISO8601DateFormatter()
        return projection.visibleEntries.compactMap { entry in
            guard case .activity(let record) = entry.payload,
                  !record.event.context.isSensitive else { return nil }
            let enrichment = byEntry[entry.id] ?? byEvent[record.event.id]
                ?? record.session?.eventIDs.reversed().compactMap { byEvent[$0] }.first
            let source = enrichment?.context ?? record.session?.context ?? record.event.context
            let timestamp = formatter.string(from: record.event.timestamp)
            let context = PiSanitizedContext(
                capturedAt: timestamp,
                applicationName: source.applicationName,
                bundleIdentifier: source.bundleIdentifier,
                windowTitle: source.windowTitle,
                url: source.url?.absoluteString,
                documentPath: source.documentPath,
                contentSummary: ([source.contentSummary, enrichment?.summary, record.narrative]
                    .compactMap { $0 } + (visibleCorrections[entry.id] ?? []).map(\.correction))
                    .joined(separator: "\n"),
                selectedText: source.selectedText,
                submittedText: source.submittedText,
                screenText: source.screenText,
                interactionTarget: source.interactionTarget,
                contextTransition: source.contextTransition,
                semanticTags: Array(source.semanticTags.union(record.event.semantics.map(\.rawValue))
                    .union(enrichment?.tags ?? [])).sorted(),
                isSensitive: source.isSensitive
            )
            guard context.isSafeForPi else { return nil }
            return PiContextRecord(id: entry.id.uuidString, eventID: record.event.id.uuidString,
                timestamp: timestamp, kind: record.session?.kind.rawValue ?? "activity", context: context)
        }
    }
}
