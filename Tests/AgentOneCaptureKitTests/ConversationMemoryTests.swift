@testable import AgentOneCaptureKit
import AVFoundation
import Foundation
import Testing

private final class DiscussionFixture {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let db:MemoryDatabase
    let store:ConversationMemory
    let base:Int64=1_790_000_000_000
    init() throws {db=try MemoryDatabase(root:root);store=ConversationMemory(database:db)}
    deinit {try? FileManager.default.removeItem(at:root)}
    func add(_ id:String,second:Int,text:String?="讨论一个完整的产品需求",speechFrom:Int=0,speechTo:Int=30) throws {
        let start=base+Int64(second)*1000
        try db.execute("INSERT INTO segments VALUES (?,?,'mixed',?,?,'UTC',0,0,'synthetic',48000,2,?,?,'sealed',NULL,'{}',?)",[id,"fixture",String(start),String(start+60_000),"Audio/\(id).m4a",String(repeating:"a",count:64),String(start)])
        if let text {try transcript(id,text:text,revision:1,speechFrom:speechFrom,speechTo:speechTo)}
    }
    func transcript(_ id:String,text:String,revision:Int,speechFrom:Int=0,speechTo:Int=30) throws {
        let words=text.isEmpty ? []:[["start_ms":speechFrom*1000,"end_ms":speechTo*1000,"text":text]] as [[String:Any]]
        let encoded=String(decoding:try JSONSerialization.data(withJSONObject:words),as:UTF8.self)
        try db.execute("INSERT INTO transcripts VALUES (?,?,?,?,?,?,?)",[id,String(revision),text,encoded,text.isEmpty ? "no_speech":"succeeded",revision==1 ? "apple-on-device:zh-CN":"apple-on-device-windowed-v2:zh-CN",String(base+Int64(revision))])
    }
}
struct ConversationMemoryTests {
    @Test func searchMatchesChineseAcrossASRWordSpaces() throws {
        let f=try DiscussionFixture();try f.add("spaced",second:0,text:"每个人 都有 自己的 数字 员工")
        try f.store.refresh(now:f.base+500_000,force:true)
        #expect(try f.store.recent(query:"数字员工").count==1)
        #expect(try f.store.recent(query:"不存在的内容").isEmpty)
    }
    @Test func legacyTailOnlyASRDoesNotTrimAwayTheSourceBeginning() throws {
        let f=try DiscussionFixture()
        try f.add("tail-only",second:0,speechFrom:42,speechTo:50)
        try f.store.refresh(now:f.base+500_000,force:true)
        let row=try #require(f.store.recent().first)
        #expect(row["started_ms"]==String(f.base))
        #expect(row["ended_ms"]==String(f.base+60_000))
    }
    @Test func minuteBoundariesAndNaturalPauseRemainOneDiscussion() throws {
        let f=try DiscussionFixture()
        try f.add("first",second:0,speechFrom:5,speechTo:30)
        try f.add("quiet",second:60,text:"")
        try f.add("second",second:120,text:"现在讨论下一个方案和后续交付",speechFrom:10,speechTo:50)
        try f.add("tail",second:180,text:"")
        try f.store.refresh(now:f.base+500_000,force:true)
        let row=try #require(f.store.recent().first)
        #expect(try f.store.recent().count==1)
        #expect(row["segment_count"]=="4")
        #expect(row["missing_ms"]=="0")
        #expect(row["state"]=="ended")
        #expect(row["transcript_text"]?.contains("后续交付")==true)
    }
    @Test func longPauseSplitsAndActualMissingTimeStaysVisible() throws {
        let f=try DiscussionFixture()
        try f.add("a",second:0,speechFrom:5,speechTo:20)
        try f.add("b",second:120,speechFrom:0,speechTo:20)
        try f.add("c",second:400,speechFrom:0,speechTo:20)
        try f.store.refresh(now:f.base+800_000,force:true)
        let rows=try f.store.recent()
        #expect(rows.count==2)
        #expect(rows.contains {$0["segment_count"]=="2" && $0["missing_ms"]=="60000"})
    }
    @Test func pendingASRDelaysCompletionAndNewRevisionInvalidatesTheOldSnapshot() throws {
        let f=try DiscussionFixture()
        try f.add("a",second:0,speechFrom:0,speechTo:20)
        try f.add("b",second:60,text:nil)
        try f.store.refresh(now:f.base+500_000,force:true)
        #expect(try f.store.recent().first?["state"]=="processing")
        try f.transcript("b",text:"",revision:1)
        try f.store.refresh(now:f.base+500_001,force:true)
        let first=try #require(f.store.recent().first),id=try #require(first["id"])
        #expect(first["state"]=="ended")
        #expect(try f.store.retranscribe(id:id)==1)
        try f.store.refresh(now:f.base+500_002,force:true)
        #expect(try f.store.recent().first?["state"]=="processing")
        try f.transcript("a",text:"完整转写补回开头的需求讨论",revision:2)
        try f.db.execute("UPDATE jobs SET state='succeeded'")
        try f.store.refresh(now:f.base+500_003,force:true)
        #expect(try f.store.recent().first?["input_digest"] != first["input_digest"])
        #expect(try f.store.recent().first?["transcript_text"]?.contains("补回开头")==true)
    }
    @Test func liveDiscussionWaitsThroughPauseAndDeletionClearsTranscriptAndPlayback() throws {
        let f=try DiscussionFixture();try f.add("a",second:0,speechFrom:0,speechTo:30)
        try f.store.refresh(now:f.base+120_000,force:true)
        var row=try #require(f.store.recent().first)
        #expect(row["state"]=="open")
        try f.store.refresh(now:f.base+250_000,force:true)
        row=try #require(f.store.recent().first);let id=try #require(row["id"])
        let cache=f.root.appendingPathComponent("ConversationPlayback").appendingPathComponent(id)
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        try Data("derived audio".utf8).write(to:cache.appendingPathComponent("playback.m4a"))
        try f.db.deleteSegment("a")
        #expect(try f.store.recent().isEmpty)
        #expect(try f.db.rows("SELECT transcript_text FROM conversations WHERE id=?",[id]).first?["transcript_text"]=="")
        #expect(!FileManager.default.fileExists(atPath:cache.path))
    }
}

struct BoundedTranscriptionTests {
    @Test func rollingFinalSnapshotDoesNotEraseEarlierPartialWords() {
        var s=SpeechTranscriptAccumulator()
        s.ingest([AudioUtterance(start_ms:0,end_ms:1000,text:"开头",speaker_local_id:nil),AudioUtterance(start_ms:10_000,end_ms:11_000,text:"中段猜测",speaker_local_id:nil)])
        s.ingest([AudioUtterance(start_ms:10_000,end_ms:11_000,text:"中段修正",speaker_local_id:nil)])
        #expect(s.utterances.map(\.text)==["开头","中段修正"])
        s.ingest([AudioUtterance(start_ms:20_000,end_ms:21_000,text:"最后一句",speaker_local_id:nil)])
        #expect(s.utterances.map(\.text)==["开头","中段修正","最后一句"])
    }
    @Test func overlapDeduplicatesTimedWordsWithoutDroppingRepeatedLaterWords() {
        let first=[AudioUtterance(start_ms:0,end_ms:1000,text:"需求",speaker_local_id:nil),AudioUtterance(start_ms:22_000,end_ms:23_000,text:"确认",speaker_local_id:nil)]
        let next=[AudioUtterance(start_ms:100,end_ms:1100,text:"确认",speaker_local_id:nil),AudioUtterance(start_ms:2000,end_ms:3000,text:"确认",speaker_local_id:nil)]
        let merged=BoundedTranscription.merge([(0,first),(22_000,next)],durationMilliseconds:25_000)
        #expect(merged.map(\.text)==["需求","确认","确认"])
        #expect(merged.last?.start_ms==24_000)
    }
    @Test func realMinuteAudioBecomesOverlappingBoundedWindows() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let input=root.appendingPathComponent("minute.caf")
        let format=try #require(AVAudioFormat(standardFormatWithSampleRate:16_000,channels:1))
        do {
            let file=try AVAudioFile(forWriting:input,settings:format.settings)
            let pcm=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:960_000));pcm.frameLength=960_000
            pcm.floatChannelData![0].update(repeating:0.01,count:960_000);try file.write(from:pcm)
        }
        let windows=try BoundedTranscription.windows(for:input,directory:root.appendingPathComponent("windows"))
        #expect(windows.map(\.offsetMilliseconds)==[0,22_000,44_000])
        let seconds=try windows.map {let f=try AVAudioFile(forReading:$0.url);return Double(f.length)/f.processingFormat.sampleRate}
        #expect(seconds==[24,24,16])
    }
}

struct VoiceprintTests {
    @Test func participationIsConservativeAndNeverDeletesSources() throws {
        let f=try DiscussionFixture();try f.add("a",second:0);try f.add("b",second:60)
        try f.store.refresh(now:f.base+500_000,force:true)
        let service=VoiceprintStore(database:f.db)
        #expect(try service.decorate(f.store.recent()).first?["voice_presence"]=="not_enrolled")
        try f.db.execute("INSERT INTO meta VALUES ('voiceprint_profile','fixture-profile')")
        #expect(try service.decorate(f.store.recent()).first?["voice_presence"]=="pending")
        for id in ["a","b"] {try f.db.execute("INSERT INTO voice_matches VALUES (?,'fixture-profile',?,'not_detected',0.1,'[]',0)",[id,String(repeating:"a",count:64)])}
        #expect(try service.decorate(f.store.recent()).first?["voice_presence"]=="not_detected")
        #expect(try f.db.rows("SELECT id FROM segments WHERE state='sealed'").count==2)
        try f.db.execute("UPDATE voice_matches SET status='uncertain' WHERE segment_id='a'")
        #expect(try service.decorate(f.store.recent()).first?["voice_presence"]=="uncertain")
        try f.db.execute("UPDATE voice_matches SET status='detected' WHERE segment_id='a'")
        #expect(try service.decorate(f.store.recent()).first?["voice_presence"]=="detected")
        try f.db.execute("UPDATE voice_matches SET source_hash='changed' WHERE segment_id='a'")
        #expect(try service.decorate(f.store.recent()).first?["voice_presence"]=="pending")
        try f.db.execute("UPDATE meta SET value='new-profile' WHERE key='voiceprint_profile'")
        #expect(try service.decorate(f.store.recent()).first?["voice_presence"]=="pending")
    }
    @Test func gapsAndShortEvidenceCannotProduceAnAbsenceClaim() {
        #expect(VoiceprintStore.presence(profile:true,statuses:["not_detected"],missing:true)=="uncertain")
        #expect(VoiceprintStore.presence(profile:true,statuses:[],missing:false)=="pending")
        #expect(VoiceprintStore.presence(profile:true,statuses:["detected","pending"],missing:true)=="detected")
    }
    @Test func retentionRequiresUserActionAndDeletionClearsVoiceEvidence() throws {
        let f=try DiscussionFixture();try f.add("a",second:0);try f.store.refresh(now:f.base+500_000,force:true)
        let id=try #require(f.store.recent().first?["id"]),store=VoiceprintStore(database:f.db)
        try store.keep(id);#expect(try store.decorate(f.store.recent()).first?["retention_choice"]=="keep")
        try f.db.execute("INSERT INTO voice_matches VALUES ('a','fixture',?,'detected',0.9,'[]',0)",[String(repeating:"a",count:64)])
        var refused=false
        do {try store.delete(id,expectedDigest:"stale")}catch{refused=true}
        #expect(refused)
        #expect(try f.db.rows("SELECT state FROM segments").first?["state"]=="sealed")
        try store.delete(id)
        #expect(try f.db.rows("SELECT * FROM voice_matches").isEmpty)
        #expect(try f.db.rows("SELECT state FROM segments").first?["state"]=="deleted")
    }
    @Test func nativeConversionProducesBoundedMonoSixteenKilohertzWav() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.caf"),wav=root.appendingPathComponent("out.wav")
        let format=try #require(AVAudioFormat(standardFormatWithSampleRate:48000,channels:2))
        do {let file=try AVAudioFile(forWriting:source,settings:format.settings);let pcm=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:96000));pcm.frameLength=96000;for lane in 0..<2 {pcm.floatChannelData![lane].update(repeating:0.01,count:96000)};try file.write(from:pcm)}
        try VoiceprintAudio.convert(source,to:wav)
        let result=try AVAudioFile(forReading:wav)
        #expect(result.processingFormat.sampleRate==16000);#expect(result.processingFormat.channelCount==1)
        #expect(abs(Double(result.length)/16000-2)<0.01)
    }
}
