import Foundation

/// Preview categories, not sourced claims or an Agent runtime. Host analysis jobs remain pending.
@MainActor public final class LocalTopicLabeler {
    private let database:MemoryDatabase
    private var running=false
    public private(set) var status="本机标签等待转写"
    public static let topics=["work":"工作讨论","tasks":"任务安排","personal":"日常交流","learning":"学习内容","media":"媒体内容","other":"其他内容"]
    public init(database:MemoryDatabase) {self.database=database}
    public func runNext(classify:@MainActor (String) async -> RecordingDecision?) async {
        guard !running else {return};running=true;defer{running=false}
        do {
            guard let row=try database.rows("""
              SELECT s.id,s.sha256,t.revision,t.text,t.status FROM segments s JOIN transcripts t ON t.segment_id=s.id
              WHERE s.state='sealed' AND t.revision=(SELECT MAX(revision) FROM transcripts WHERE segment_id=s.id)
              AND NOT EXISTS(SELECT 1 FROM meta WHERE key='local_label:'||s.id||':'||t.revision)
              ORDER BY s.started_ms DESC LIMIT 1
              """).first,let id=row["id"],let revision=row["revision"],let hash=row["sha256"] else {status="本机标签已处理；等待新转写";return}
            let text=row["text"] ?? ""
            var label:[String:Any]
            if row["status"]=="no_speech" || text.isEmpty {
                label=["label":"未识别语音","status":"asr_no_speech","scope":"not_proof_of_silence"]
            } else {
                status="Laya 正在本机分类"
                guard let result=await classify(String(text.prefix(1600))),let topic=Self.topics[result.choice],result.confidence.isFinite,(0...1).contains(result.confidence) else {status="模型暂不可用，标签待处理；原音继续保存";return}
                label=["label":result.confidence>=0.75 ? topic:"待确认","suggested_label":topic,"confidence":result.confidence,"status":"model_inference","scope":"topic_hint_not_verified_fact"]
            }
            label["model"]=row["status"]=="no_speech" || text.isEmpty ? "apple-on-device-asr-status":"laya-multilingual";label["transcript_revision"]=Int(revision);label["source_sha256"]=hash;label["derived_at"]=ISO8601DateFormatter().string(from:Date())
            let json=String(decoding:try JSONSerialization.data(withJSONObject:label),as:UTF8.self)
            let written=try database.transaction {
                guard try database.rows("SELECT s.id FROM segments s JOIN transcripts t ON t.segment_id=s.id WHERE s.id=? AND s.state='sealed' AND s.sha256=? AND t.revision=? AND t.text=? AND t.revision=(SELECT MAX(revision) FROM transcripts WHERE segment_id=s.id)",[id,hash,revision,text]).count==1 else {return false}
                try database.execute("INSERT OR IGNORE INTO meta VALUES (?,?)",["local_label:"+id+":"+revision,json]);return true
            }
            status=written ? "本机预览标签已保存；事实与待办由 Agent 核查":"来源已更新，旧标签未写入"
        } catch {status="本机标签暂不可用；原音和宿主分析队列保留"}
    }
}
