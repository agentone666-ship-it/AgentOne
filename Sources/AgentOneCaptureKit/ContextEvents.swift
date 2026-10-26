import AgentOneCore
import CryptoKit
import Foundation

public struct ContextEventRecord: Codable, Sendable {
    public var id: String
    public var started: Date
    public var ended: Date
    public var kind: String
    public var application: String?
    public var title: String?
    public var url: String?
    public var text: String
    public var place: String?
    public var provenance: String
    public var sourceRef: String
    public init(id: String = UUID().uuidString,started: Date,ended: Date? = nil,kind: String,application: String? = nil,title: String? = nil,url: String? = nil,text: String,place: String? = nil,provenance: String = "native_event",sourceRef: String? = nil) {
        self.id=id;self.started=started;self.ended=ended ?? started;self.kind=kind;self.application=application;self.title=title;self.url=url;self.text=text;self.place=place;self.provenance=provenance;self.sourceRef=sourceRef ?? "native-event://\(id)"
    }
    public var isSafe: Bool {
        !SensitiveContextPolicy.isProtectedSurface(bundleIdentifier: application,windowTitle: title)
        && !SensitiveContextPolicy.containsActualSecret(title,url,text)
    }
}

public extension MemoryDatabase {
    func saveEvent(_ record: ContextEventRecord) throws {
        guard record.isSafe else { return }
        try persistPreparedEvent(record)
    }
    internal func persistPreparedEvent(_ record: ContextEventRecord) throws {
        let fields=[record.id,Self.ms(record.started),Self.ms(record.ended),record.kind,record.application ?? "",record.title ?? "",record.url ?? "",record.text,record.place ?? "",record.provenance,record.sourceRef]
        let material="event-v1"+fields.map {"\($0.utf8.count):\($0)"}.joined()
        let digest=SHA256.hash(data: Data(material.utf8)).map { String(format:"%02x",$0) }.joined()
        try execute("""
        INSERT INTO context_events(id,started_ms,ended_ms,kind,application,title,url,text,place,provenance,source_ref,source_sha256,hidden,created_ms)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0,?) ON CONFLICT(id) DO UPDATE SET started_ms=excluded.started_ms,ended_ms=excluded.ended_ms,
        kind=excluded.kind,application=excluded.application,title=excluded.title,url=excluded.url,text=excluded.text,place=excluded.place,
        provenance=excluded.provenance,source_ref=excluded.source_ref,source_sha256=excluded.source_sha256,hidden=0
        """,[record.id,Self.ms(record.started),Self.ms(record.ended),record.kind,record.application,record.title,record.url,record.text,record.place,record.provenance,record.sourceRef,digest,Self.ms(record.started)])
    }
}

public struct LegacyEventImportReport: Sendable {
    public var imported=0
    public var skippedFiles=0
    public var malformedEntries=0
}

/// Reads immutable Diary comments; no rewriting, migration of credentials or model calls.
public struct LegacyEventImporter: Sendable {
    public let database: MemoryDatabase
    public init(database: MemoryDatabase) { self.database=database }
    public func sync(diaryRoot: URL) throws -> LegacyEventImportReport {
        let daily=diaryRoot.appendingPathComponent("Daily")
        guard FileManager.default.fileExists(atPath: daily.path) else { return LegacyEventImportReport() }
        guard daily.resolvingSymlinksInPath().path == daily.standardizedFileURL.path else { throw CaptureFailure.message("旧 Diary 路径不能是符号链接") }
        let files=try FileManager.default.contentsOfDirectory(at: daily,includingPropertiesForKeys: [.isSymbolicLinkKey,.fileSizeKey]).filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#,options:.regularExpression) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var report=LegacyEventImportReport()
        var loaded: [(DiaryEntry,String)]=[]
        for file in files {
            let attributes=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey])
            guard attributes.isSymbolicLink != true,(attributes.fileSize ?? 0) <= 64*1024*1024 else { report.skippedFiles += 1;continue }
            let markdown=try String(contentsOf:file,encoding:.utf8)
            for line in markdown.split(separator:"\n") {
                let prefix="<!-- agentone-json: ",suffix=" -->",text=String(line)
                guard text.hasPrefix(prefix),text.hasSuffix(suffix) else { continue }
                let encoded=String(text.dropFirst(prefix.count).dropLast(suffix.count))
                guard let data=Data(base64Encoded:encoded),let entry=try? JSONDecoder().decode(DiaryEntry.self,from:data) else { report.malformedEntries += 1;continue }
                loaded.append((entry,"Diary/Daily/\(file.lastPathComponent)#\(entry.id.uuidString)"))
            }
        }
        loaded.sort { $0.0.timestamp < $1.0.timestamp }
        let projection=DiaryProjection(entries:loaded.map(\.0))
        var enrichmentByEvent:[UUID:ActivityContextEnrichment]=[:],enrichmentByEntry:[UUID:ActivityContextEnrichment]=[:]
        for (entry,_) in loaded where !projection.hiddenEntryIDs.contains(entry.id) {
            if case .contextEnrichment(let value)=entry.payload {
                enrichmentByEvent[value.targetEventID]=value
                if let id=value.targetActivityEntryID { enrichmentByEntry[id]=value }
            }
        }
        var records:[ContextEventRecord]=[]
            for (entry,reference) in loaded where !projection.hiddenEntryIDs.contains(entry.id) {
                guard case .activity(let activity)=entry.payload else { continue }
                let enrichment=enrichmentByEntry[entry.id] ?? enrichmentByEvent[activity.event.id]
                let context=enrichment?.context ?? activity.session?.context ?? activity.event.context
                guard !context.isSensitive,!activity.event.context.isSensitive,activity.session?.context.isSensitive != true else { continue }
                let corrections=projection.correctionsByEntryID[entry.id,default:[]].map { "用户更正："+$0.correction }
                let text=([activity.narrative,context.contentSummary,context.selectedText,context.submittedText,context.screenText,context.interactionTarget,context.contextTransition,enrichment?.summary].compactMap {$0} + corrections).joined(separator:"\n")
                let record=ContextEventRecord(id:"legacy:"+entry.id.uuidString,started:activity.session?.startedAt ?? activity.event.timestamp,ended:activity.session?.endedAt ?? activity.event.timestamp,
                    kind:activity.session?.kind.rawValue ?? "activity",application:context.applicationName,title:enrichment?.activityTitle ?? context.windowTitle,url:context.url?.absoluteString,text:text,provenance:"legacy_diary",sourceRef:reference)
                guard record.isSafe else { continue }
                records.append(record)
            }
        try database.transaction {
            try database.execute("UPDATE context_events SET hidden=1,text='',title=NULL,url=NULL,place=NULL WHERE provenance='legacy_diary'")
            for record in records {try database.persistPreparedEvent(record)}
            report.imported=records.count
            try database.execute("INSERT INTO meta VALUES ('legacy_event_sync',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[MemoryDatabase.now])
        }
        return report
    }
}
