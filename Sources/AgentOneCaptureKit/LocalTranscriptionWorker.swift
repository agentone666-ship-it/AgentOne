import Foundation
@preconcurrency import Speech

public struct AudioUtterance: Codable, Sendable {
    public let start_ms: Int
    public let end_ms: Int
    public let text: String
    public let speaker_local_id: String? // Native ASR does not identify people.
}

/// A bounded ASR worker, not an Agent runtime. It never silently falls back to
/// server-side Speech recognition; pending work remains available through MCP.
@MainActor public final class LocalTranscriptionWorker {
    private let database: MemoryDatabase
    private var running = false
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    public private(set) var status = "本机转写未启用；MCP 可领取待处理片段"
    public var enabled = false
    public var localeIdentifier = "zh-CN"

    public init(database: MemoryDatabase) { self.database = database }
    public func requestAuthorization() async -> Bool {
        let result = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        enabled = result
        status = result ? "本机转写已启用" : "语音识别未授权，片段仍保留在队列"
        return result
    }

    public func runNext() async {
        guard enabled, !running else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            status = "本机识别当前不可用；原音保留，等待 MCP 处理"
            return
        }
        running = true; defer { running = false }
        let token = UUID().uuidString
        var job: [String: String]?
        do {
            job = try database.transaction {
                let now = MemoryDatabase.now
                guard let row = try database.rows("SELECT j.*,s.relative_path FROM jobs j JOIN segments s ON s.id=j.segment_id WHERE j.stage='transcribe' AND s.state='sealed' AND j.attempts<3 AND (j.state='pending' OR (j.state='leased' AND j.lease_until_ms<?)) AND (j.attempts=0 OR j.updated_ms<?) ORDER BY j.created_ms LIMIT 1", [now,String(Int64(now)! - 60_000)]).first else { return nil }
                try database.execute("UPDATE jobs SET state='leased',lease_token=?,lease_owner='native-local-asr',lease_until_ms=?,attempts=attempts+1,updated_ms=? WHERE id=?", [token,String(Int64(now)! + 120_000),now,row["id"]])
                return row
            }
            guard let job, let id = job["id"], let segmentID = job["segment_id"] else { return }
            status = "正在本机转写"
            let (text, utterances) = try await transcribe(database.verifiedAudioURL(segmentID), with: recognizer)
            let data = try JSONEncoder().encode(utterances)
            let encoded = String(decoding: data, as: UTF8.self)
            try database.transaction {
                guard try database.rows("SELECT j.id FROM jobs j JOIN segments s ON s.id=j.segment_id WHERE j.id=? AND j.lease_token=? AND j.state='leased' AND j.lease_until_ms>? AND s.state='sealed' AND s.sha256=j.source_hash", [id,token,MemoryDatabase.now]).count == 1 else { return }
                let revision = (Int(try database.rows("SELECT COALESCE(MAX(revision),0) AS revision FROM transcripts WHERE segment_id=?", [segmentID]).first?["revision"] ?? "0") ?? 0) + 1
                try database.execute("INSERT INTO transcripts VALUES (?,?,?,?,?,?,?)", [segmentID,String(revision),text,encoded,text.isEmpty ? "no_speech" : "succeeded","apple-on-device:\(localeIdentifier)",MemoryDatabase.now])
                try database.execute("UPDATE jobs SET state='succeeded',lease_token=NULL,lease_until_ms=NULL,last_error=NULL,updated_ms=? WHERE id=?", [MemoryDatabase.now,id])
                try database.execute("INSERT OR IGNORE INTO jobs (id,segment_id,stage,source_hash,input_revision,state,created_ms,updated_ms) VALUES (?,?,'analyze',?,?,'pending',?,?)", [UUID().uuidString,segmentID,job["source_hash"],String(revision),MemoryDatabase.now,MemoryDatabase.now])
            }
            status = "转写已保存；标签等待宿主 Agent 处理"
        } catch {
            if let id = job?["id"] {
                _ = try? database.execute("UPDATE jobs SET state='pending',lease_token=NULL,lease_until_ms=NULL,last_error='local_asr_failed',updated_ms=? WHERE id=? AND lease_token=?", [MemoryDatabase.now,id,token])
            }
            status = "本机转写失败，原音和待处理任务已保留"
        }
    }

    private func transcribe(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> (String, [AudioUtterance]) {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                let final = result?.isFinal == true
                let text = result?.bestTranscription.formattedString ?? ""
                let utterances = result?.bestTranscription.segments.map { segment in
                    AudioUtterance(start_ms: Int(segment.timestamp * 1000), end_ms: Int((segment.timestamp + segment.duration) * 1000), text: segment.substring, speaker_local_id: nil)
                } ?? []
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard !finished, final || failed else { return }
                    finished = true; self?.timeout?.cancel(); self?.timeout = nil
                    if final { continuation.resume(returning: (text,utterances)) }
                    else { continuation.resume(throwing: CaptureFailure.message("本机转写失败")) }
                    self?.recognitionTask = nil
                }
            }
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(75)) } catch { return }
                guard !finished else { return }
                finished = true; self?.recognitionTask?.cancel(); self?.recognitionTask = nil
                continuation.resume(throwing: CaptureFailure.message("本机转写超时"))
            }
        }
    }
}
