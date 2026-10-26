@testable import AgentOneCaptureKit
import AVFoundation
import CoreMedia
import Foundation
import Testing

struct PreservationTests {
    @Test func modelWaitUnknownAndFailureCannotStopContinuousPCMOrCreateOmittedTime() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let db=try MemoryDatabase(root:root),status=RecordingDecisionStatus(preserveAllAudio:true),host=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let mixer=MixedAudioWriter(database:db,sessionID:"preserve-fixture",wallAnchor:Date(),hostAnchor:host,decisionStatus:status)
        let format=try #require(AVAudioFormat(standardFormatWithSampleRate:48000,channels:1))
        let pcm=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000));pcm.frameLength=48000
        pcm.floatChannelData![0].update(repeating:0,count:48000)
        for second in 0..<32 {
            try mixer.append(pcm,source:"microphone",presentationSeconds:host+Double(second))
            try mixer.flush(throughHostSeconds:host+Double(second+1))
            try mixer.applyDecision(nil,quietSeconds:100,inputsReady:false,soundConfirmed:false)
            let sound=second<16
            let evidence=CaptureStartEvidence(inputsReady:true,sustainedSound:sound,quietSeconds:sound ? 0:20,activeFraction:sound ? 1:0,readySources:["microphone"])
            let decision=RecordingDecision(choice:sound ? "record":"wait",confidence:0.9)
            if second%2==0 {try mixer.annotateActivity(decision,evidence:evidence)}
            #expect(status.snapshot.saving)
        }
        // Invalid model output is never allowed to corrupt JSON or stop the file writer.
        try mixer.annotateActivity(RecordingDecision(choice:"wait",confidence:.nan),evidence:CaptureStartEvidence(inputsReady:false,sustainedSound:false,quietSeconds:100,activeFraction:0,readySources:[]))
        try mixer.finish()
        let rows=try db.rows("SELECT * FROM segments ORDER BY started_ms")
        #expect(rows.count>=2)
        var total=0.0,previousEnd:Double?
        for row in rows {
            let start=Double(row["started_ms"]!)!,end=Double(row["ended_ms"]!)!
            if let previousEnd {#expect(abs(previousEnd-start)<2)}
            previousEnd=end;total+=end-start
            #expect(row["context_json"]?.contains("continuous_preservation")==true)
            _=try db.verifiedAudioURL(row["id"]!)
        }
        #expect(abs(total/1000-32)<0.01)
        #expect(try db.rows("SELECT * FROM coverage WHERE source='mixed' AND reason='automatic_wait'").isEmpty)
        #expect(try db.rows("SELECT * FROM jobs WHERE stage='transcribe'").count==rows.count)
    }
}

@MainActor struct LocalTopicLabelerTests {
    private func fixture() throws -> (MemoryDatabase,URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),db=try MemoryDatabase(root:root)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Audio"),withIntermediateDirectories:true)
        try Data("fixture audio".utf8).write(to:root.appendingPathComponent("Audio/test.m4a"))
        try db.execute("INSERT INTO segments VALUES ('sample','session','mixed',1,1000,'UTC',1,1,'host_clock',48000,1,'Audio/test.m4a','fixture-hash','sealed',NULL,'{}',1)")
        try db.execute("INSERT INTO transcripts VALUES ('sample',1,'讨论产品需求','[]','succeeded','fixture',1)")
        try db.execute("INSERT INTO jobs (id,segment_id,stage,source_hash,input_revision,state,created_ms,updated_ms) VALUES ('analysis','sample','analyze','fixture-hash',1,'pending',1,1)")
        return(db,root)
    }
    @Test func previewCategoryDoesNotCompleteHostAnalysisAndDeletionRemovesIt() async throws {
        let (db,root)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let labeler=LocalTopicLabeler(database:db)
        await labeler.runNext {_ in RecordingDecision(choice:"work",confidence:0.9)}
        let row=try #require(db.rows("SELECT value FROM meta WHERE key='local_label:sample:1'").first)
        let value=try #require(JSONSerialization.jsonObject(with:Data(row["value"]!.utf8)) as? [String:Any])
        #expect(value["label"] as? String=="工作讨论")
        #expect(value["status"] as? String=="model_inference")
        #expect(value["source_sha256"] as? String=="fixture-hash")
        #expect(try db.rows("SELECT state FROM jobs WHERE id='analysis'").first?["state"]=="pending")
        try db.deleteSegment("sample")
        #expect(try db.rows("SELECT * FROM meta WHERE key='local_label:sample:1'").isEmpty)
    }
    @Test func staleTranscriptAndFailedClassifierCannotWritePreview() async throws {
        let (db,root)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let labeler=LocalTopicLabeler(database:db)
        await labeler.runNext {_ in nil}
        #expect(try db.rows("SELECT * FROM meta WHERE key LIKE 'local_label:%'").isEmpty)
        await labeler.runNext {_ in
            try? db.execute("UPDATE transcripts SET text='已更正内容' WHERE segment_id='sample'")
            return RecordingDecision(choice:"work",confidence:0.9)
        }
        #expect(try db.rows("SELECT * FROM meta WHERE key LIKE 'local_label:%'").isEmpty)
    }
    @Test func lowConfidenceAndNoSpeechStayQualified() async throws {
        let (db,root)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let labeler=LocalTopicLabeler(database:db)
        await labeler.runNext {_ in RecordingDecision(choice:"tasks",confidence:0.55)}
        let row=try #require(db.rows("SELECT value FROM meta WHERE key='local_label:sample:1'").first)
        #expect(row["value"]!.contains("待确认"))
        try db.execute("DELETE FROM meta WHERE key='local_label:sample:1'")
        try db.execute("UPDATE transcripts SET text='',status='no_speech' WHERE segment_id='sample'")
        await labeler.runNext {_ in Issue.record("Empty transcript should not call the classifier");return nil}
        let value=try #require(db.rows("SELECT value FROM meta WHERE key='local_label:sample:1'").first?["value"])
        #expect(value.contains("未识别语音"));#expect(value.contains("not_proof_of_silence"))
    }
}
