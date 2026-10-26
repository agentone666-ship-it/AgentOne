@testable import AgentOneCaptureKit
import AVFoundation
import CoreMedia
import Foundation
import SQLite3
import Testing

struct MixedAudioTests {
    private func tone(rate:Double,channels:AVAudioChannelCount,seconds:Double,frequency:Float,amplitude:Float = 0.3) throws -> AVAudioPCMBuffer {
        let format=try #require(AVAudioFormat(standardFormatWithSampleRate:rate,channels:channels))
        let frames=AVAudioFrameCount((seconds*rate).rounded())
        let buffer=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames));buffer.frameLength=frames
        for channel in 0..<Int(channels) {for frame in 0..<Int(frames) {buffer.floatChannelData![channel][frame]=amplitude*sin(Float(frame)*2 * .pi*frequency/Float(rate))}}
        return buffer
    }
    private func magnitude(_ buffer:AVAudioPCMBuffer,frequency:Double,from:Double,to:Double,channel:Int = 0) -> Double {
        let first=Int(from*buffer.format.sampleRate),end=min(Int(to*buffer.format.sampleRate),Int(buffer.frameLength))
        var re=0.0,im=0.0
        for i in first..<end {let phase=Double(i)*2 * Double.pi*frequency/buffer.format.sampleRate,v=Double(buffer.floatChannelData![channel][i]);re += v*cos(phase);im += v*sin(phase)}
        return 2*hypot(re,im)/Double(end-first)
    }
    @Test func mixedAACContainsBothInputsAndPreservesDelayedMicrophone() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let db=try MemoryDatabase(root:root),host=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let mixer=MixedAudioWriter(database:db,sessionID:"mixed-test",wallAnchor:Date(),hostAnchor:host)
        // Deliver microphone first, then the earlier stereo packet: scheduling order is not time order.
        try mixer.append(tone(rate:44100,channels:1,seconds:1,frequency:880),source:"microphone",presentationSeconds:host+0.25)
        let system=try tone(rate:48000,channels:2,seconds:1.5,frequency:440)
        for frame in 0..<Int(system.frameLength) {system.floatChannelData![1][frame]=0.3*sin(Float(frame)*2 * .pi*660/48000)}
        try mixer.append(system,source:"system_audio",presentationSeconds:host)
        try mixer.finish()
        let rows=try db.rows("SELECT * FROM segments")
        #expect(rows.count==1)
        let row=try #require(rows.first)
        #expect(row["source"]=="mixed");#expect(row["channels"]=="2")
        let url=try db.verifiedAudioURL(try #require(row["id"]))
        let file=try AVAudioFile(forReading:url)
        let pcm=try #require(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)))
        try file.read(into:pcm)
        #expect(abs(Double(pcm.frameLength)/pcm.format.sampleRate-1.5)<0.06)
        let earlyMic=magnitude(pcm,frequency:880,from:0.06,to:0.18)
        let laterMic=magnitude(pcm,frequency:880,from:0.4,to:0.9)
        let laterSystem=magnitude(pcm,frequency:440,from:0.4,to:0.9)
        #expect(laterMic>0.07);#expect(laterSystem>0.07);#expect(earlyMic<laterMic*0.2)
        #expect(magnitude(pcm,frequency:660,from:0.4,to:0.9,channel:1)>0.07)
        #expect(magnitude(pcm,frequency:880,from:0.4,to:0.9,channel:1)>0.07)
        #expect(try db.rows("SELECT * FROM jobs").count==1)
        let context=try #require(row["context_json"])
        #expect(context.contains("mixed"));#expect(context.contains("session_cumulative"))
    }
    @Test func missingInputPadsTimeInsteadOfConcatenatingAndLateInputIsReported() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let db=try MemoryDatabase(root:root),host=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let mixer=MixedAudioWriter(database:db,sessionID:"gaps",wallAnchor:Date(),hostAnchor:host)
        try mixer.append(tone(rate:48000,channels:1,seconds:0.1,frequency:880),source:"microphone",presentationSeconds:host)
        try mixer.flush(throughHostSeconds:host+0.3)
        try mixer.append(tone(rate:48000,channels:2,seconds:0.1,frequency:440),source:"system_audio",presentationSeconds:host) // Arrives after the emitted window.
        try mixer.append(tone(rate:48000,channels:1,seconds:0.1,frequency:880),source:"microphone",presentationSeconds:host+0.3)
        try mixer.finish();try mixer.finish()
        try mixer.append(tone(rate:48000,channels:1,seconds:0.1,frequency:880),source:"microphone",presentationSeconds:host+0.4) // Fenced after close.
        let row=try #require(db.rows("SELECT * FROM segments").first)
        let elapsed=(Double(try #require(row["ended_ms"]))! - Double(try #require(row["started_ms"]))!)/1000
        #expect(abs(elapsed-0.4)<0.002)
        #expect(try db.rows("SELECT * FROM segments").count==1)
        let json=try #require(row["context_json"])
        let context=try #require(JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any])
        let mixing=try #require(context["mixing"] as? [String:Any]),late=try #require(mixing["late_frames"] as? [String:Int])
        #expect((late["system_audio"] ?? 0)>=4799)
        #expect(try db.rows("SELECT * FROM coverage WHERE source='microphone' AND reason='mixed_input_no_samples'").count==1)
    }
    @Test func automaticQuietStartupAndUnknownModelDecisionsCreateNoAudioFiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let db=try MemoryDatabase(root:root),host=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let status=RecordingDecisionStatus()
        let mixer=MixedAudioWriter(database:db,sessionID:"quiet-start",wallAnchor:Date(),hostAnchor:host,decisionStatus:status)
        let silence=try tone(rate:48000,channels:1,seconds:1,frequency:880,amplitude:0)
        for second in 0..<6 {
            try mixer.append(silence,source:"microphone",presentationSeconds:host+Double(second))
            try mixer.flush(throughHostSeconds:host+Double(second+1))
            try mixer.applyDecision(RecordingDecision(choice:"record",confidence:0.99),quietSeconds:712,inputsReady:false,soundConfirmed:false)
        }
        try mixer.finish()
        #expect(!status.snapshot.saving)
        #expect(try db.rows("SELECT * FROM segments").isEmpty)
        #expect(try db.rows("SELECT * FROM jobs").isEmpty)
        #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("Audio").path))
        #expect(try db.rows("SELECT * FROM coverage WHERE reason='automatic_wait'").count==1)
    }
    @Test func actualMixedAACRetainsPreRollAndLabelsIntentionalGaps() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let db=try MemoryDatabase(root:root),host=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let status=RecordingDecisionStatus()
        let mixer=MixedAudioWriter(database:db,sessionID:"gated-aac",wallAnchor:Date(),hostAnchor:host,decisionStatus:status)
        let input=try tone(rate:48000,channels:1,seconds:1,frequency:880)
        for second in 0..<16 {
            try mixer.append(input,source:"microphone",presentationSeconds:host+Double(second))
            try mixer.flush(throughHostSeconds:host+Double(second+1))
            if second==2 || second==4 {try mixer.applyDecision(RecordingDecision(choice:"record",confidence:0.9),quietSeconds:0,inputsReady:true,soundConfirmed:true)}
        }
        for _ in 0..<2 {try mixer.applyDecision(RecordingDecision(choice:"wait",confidence:0.95),quietSeconds:20,inputsReady:true,soundConfirmed:false)}
        #expect(!status.snapshot.saving)
        #expect(try db.rows("SELECT * FROM segments").count==1)
        for second in 16..<29 {
            try mixer.append(input,source:"microphone",presentationSeconds:host+Double(second))
            try mixer.flush(throughHostSeconds:host+Double(second+1))
        }
        try mixer.applyDecision(RecordingDecision(choice:"record",confidence:0.9),quietSeconds:0,inputsReady:true,soundConfirmed:true)
        for second in 29..<31 {
            try mixer.append(input,source:"microphone",presentationSeconds:host+Double(second))
            try mixer.flush(throughHostSeconds:host+Double(second+1))
        }
        try mixer.applyDecision(RecordingDecision(choice:"record",confidence:0.9),quietSeconds:0,inputsReady:true,soundConfirmed:true)
        try mixer.finish()
        let rows=try db.rows("SELECT * FROM segments ORDER BY started_ms")
        #expect(rows.count==2)
        let resumed=try #require(rows.last)
        let file=try AVAudioFile(forReading:db.verifiedAudioURL(try #require(resumed["id"])))
        #expect(abs(Double(file.length)/file.fileFormat.sampleRate-10)<0.06)
        #expect(try db.rows("SELECT * FROM jobs WHERE stage='transcribe'").count==2)
        let gap=try #require(db.rows("SELECT * FROM coverage WHERE reason='automatic_wait'").first)
        let duration=(Double(gap["ended_ms"]!)!-Double(gap["started_ms"]!)!)/1000
        #expect(abs(duration-5)<0.01)
    }
    @Test func delayedFlushCatchesUpWithoutAcceptingFutureClock() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let db=try MemoryDatabase(root:root),host=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))-10
        let mixer=MixedAudioWriter(database:db,sessionID:"delayed-timer",wallAnchor:Date().addingTimeInterval(-10),hostAnchor:host)
        let pcm=try tone(rate:48000,channels:1,seconds:0.1,frequency:880)
        try mixer.append(pcm,source:"microphone",presentationSeconds:host)
        // Simulate 10 s before the timer is allowed to run. Input remains on the host clock.
        try mixer.append(pcm,source:"microphone",presentationSeconds:host+10)
        try mixer.finish()
        let row=try #require(db.rows("SELECT * FROM segments").first)
        let file=try AVAudioFile(forReading:db.verifiedAudioURL(try #require(row["id"])))
        #expect(abs(Double(file.length)/file.fileFormat.sampleRate-10.1)<0.06)
        let invalid=MixedAudioWriter(database:db,sessionID:"future-clock",wallAnchor:Date(),hostAnchor:host+10)
        try invalid.append(pcm,source:"microphone",presentationSeconds:host+10)
        #expect(throws:CaptureFailure.self) {try invalid.append(pcm,source:"microphone",presentationSeconds:host+100)}
        try invalid.finish()
    }
    @Test func v1MigrationPreservesOriginalSourcesAndRelationships() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var schema=try String(contentsOf:repo.appendingPathComponent("plugins/agentone-memory/schema.sql"),encoding:.utf8)
        schema=schema.replacingOccurrences(of:"('schema_version', '2')",with:"('schema_version', '1')").replacingOccurrences(of:"'mixed','system_audio'",with:"'system_audio'")
        var raw:OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&raw)==SQLITE_OK)
        let old=try #require(raw)
        #expect(sqlite3_exec(old,schema,nil,nil,nil)==SQLITE_OK)
        #expect(sqlite3_exec(old,"INSERT INTO segments VALUES ('old','session','microphone',1,2,'UTC',1,1,'host_clock',48000,1,'Audio/old.m4a','hash','sealed',NULL,'{}',1); INSERT INTO transcripts VALUES ('old',1,'原话','[]','succeeded','fixture',1); INSERT INTO jobs (id,segment_id,stage,source_hash,state,created_ms,updated_ms) VALUES ('job','old','analyze','hash','pending',1,1);",nil,nil,nil)==SQLITE_OK)
        sqlite3_close(old)
        let db=try MemoryDatabase(root:root)
        #expect(try db.rows("SELECT value FROM meta WHERE key='schema_version'").first?["value"]=="2")
        #expect(try db.rows("SELECT source FROM segments WHERE id='old'").first?["source"]=="microphone")
        #expect(try db.rows("SELECT text FROM transcripts WHERE segment_id='old'").first?["text"]=="原话")
        #expect(try db.rows("SELECT * FROM jobs").count==1)
        #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
        #expect(try db.rows("PRAGMA foreign_keys").first?["foreign_keys"]=="1")
        try db.execute("INSERT INTO segments VALUES ('new','session','mixed',2,3,'UTC',2,1,'host_clock',48000,1,'Audio/new.m4a',NULL,'recording',NULL,'{}',2)")
    }
}
