@testable import AgentOneCaptureKit
import AVFoundation
import Foundation
import Testing
import Darwin

@MainActor struct RecorderIsolationTests {
    @Test func newUIAdoptsExistingRecorderWithoutRestartOrChangingUserPause() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let database=try MemoryDatabase(root:root)
        var config=RecorderControl();config.desired=true
        try RecorderFiles.write(config,to:RecorderFiles.control(root))
        var snapshot=RecorderSnapshot();snapshot.recording=true;snapshot.saving=true;snapshot.mode="preserve";snapshot.detail="fixture recorder"
        let token=snapshot.session
        try RecorderFiles.write(snapshot,to:RecorderFiles.status(root))
        // An executable that would fail if spawned: a fresh recorder must be adopted.
        let client=AudioCaptureService(database:database,recorderExecutable:URL(fileURLWithPath:"/usr/bin/false"))
        try await client.start(allowPermissionPrompts:false,preserveAllAudio:true)
        #expect(client.isIndependentRecorder)
        #expect(client.sessionToken==token)
        #expect(client.isRecording)
        try client.heartbeat()
        #expect(try RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(root)).desired)
        snapshot.recording=false;snapshot.saving=false
        try RecorderFiles.write(snapshot,to:RecorderFiles.status(root))
        try await client.stop(reason:"user_paused")
        #expect(try !RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(root)).desired)
        // Reopening/polling a paused UI must not silently resume recording.
        let reopened=AudioCaptureService(database:database,recorderExecutable:URL(fileURLWithPath:"/usr/bin/false"))
        try reopened.heartbeat()
        #expect(try !RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(root)).desired)
    }
    @Test func controlFilesRejectSymlinksAndUsePrivatePermissions() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file=root.appendingPathComponent("control.json")
        try RecorderFiles.write(RecorderControl(),to:file)
        #expect((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue==0o600)
        let link=root.appendingPathComponent("link.json");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        #expect(throws:(any Error).self){try RecorderFiles.write(RecorderControl(),to:link)}
        #expect(throws:(any Error).self){try RecorderFiles.read(RecorderControl.self,from:link)}
    }
}

struct RecorderWatermarkTests {
    @Test func delayedDeviceShutdownSealsOnlyReceivedPCMAndRecordsTheMissingTail() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let db=try MemoryDatabase(root:root),host=ProcessInfo.processInfo.systemUptime
        let mixer=MixedAudioWriter(database:db,sessionID:"slow-shutdown",wallAnchor:Date(),hostAnchor:host)
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let block=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!;block.frameLength=48000
        block.floatChannelData![0].update(repeating:0.2,count:48000)
        try mixer.append(block,source:"microphone",presentationSeconds:host)
        try mixer.finish(throughHostSeconds:host+61)
        let row=try #require(db.rows("SELECT * FROM segments WHERE state='sealed'").first)
        #expect(abs(Double(row["ended_ms"]!)!-Double(row["started_ms"]!)!-1000)<2)
        let gap=try #require(db.rows("SELECT * FROM coverage WHERE reason='inputs_stopped_before_close'").first)
        #expect(abs(Double(gap["ended_ms"]!)!-Double(gap["started_ms"]!)!-60000)<2)
    }
    @Test func fasterSystemInputCannotSealOverQueuedMicrophone() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let db=try MemoryDatabase(root:root),host=ProcessInfo.processInfo.systemUptime
        let mixer=MixedAudioWriter(database:db,sessionID:"dual-watermark",wallAnchor:Date(),hostAnchor:host)
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let block=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!;block.frameLength=48000
        block.floatChannelData![0].update(repeating:0.2,count:48000)
        for second in 0..<4 {try mixer.append(block,source:"system_audio",presentationSeconds:host+Double(second))}
        for second in 0..<2 {try mixer.append(block,source:"microphone",presentationSeconds:host+Double(second))}
        try mixer.flushAvailable(throughHostSeconds:host+10)
        for second in 2..<4 {try mixer.append(block,source:"microphone",presentationSeconds:host+Double(second))}
        try mixer.finish()
        let row=try #require(db.rows("SELECT * FROM segments WHERE state='sealed'").first)
        let context=try #require(JSONSerialization.jsonObject(with:Data(row["context_json"]!.utf8)) as? [String:Any])
        let mixing=try #require(context["mixing"] as? [String:Any]);let late=try #require(mixing["late_frames"] as? [String:NSNumber])
        #expect(late["microphone"]?.intValue==0)
        #expect(try db.rows("SELECT * FROM coverage").isEmpty)
    }
    @Test func delayedTimerCannotFillOverQueuedNativeAudio() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let db=try MemoryDatabase(root:root),host=ProcessInfo.processInfo.systemUptime
        let mixer=MixedAudioWriter(database:db,sessionID:"watermark",wallAnchor:Date(),hostAnchor:host)
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let block=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!;block.frameLength=48000
        block.floatChannelData![0].update(repeating:0.2,count:48000)
        try mixer.append(block,source:"system_audio",presentationSeconds:host)
        // Simulate a delayed writer timer firing before callbacks queued behind it.
        try mixer.flushAvailable(throughHostSeconds:host+10)
        for second in 1..<4 {try mixer.append(block,source:"system_audio",presentationSeconds:host+Double(second))}
        try mixer.finish()
        let row=try #require(db.rows("SELECT * FROM segments WHERE state='sealed'").first)
        let audio=try AVAudioFile(forReading:db.verifiedAudioURL(row["id"]!))
        #expect(abs(Double(audio.length)/48000-4)<0.02)
        let context=try #require(JSONSerialization.jsonObject(with:Data(row["context_json"]!.utf8)) as? [String:Any])
        let mixing=try #require(context["mixing"] as? [String:Any]);let late=try #require(mixing["late_frames"] as? [String:NSNumber])
        #expect(late["system_audio"]?.intValue==0)
        #expect(try db.rows("SELECT * FROM coverage WHERE source='system_audio'").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("Audio").path).count==1)
    }
}

@MainActor struct RecorderDeadlineTests {
    @Test func missingFrameworkCompletionCannotHoldTheCallerForever() async throws {
        var parked:CheckedContinuation<Void,Never>?
        let start=Date()
        do {
            try await CaptureDeadline.perform(seconds:0.05,message:"fixture timeout") {
                await withCheckedContinuation {parked=$0}
            }
            Issue.record("A missing framework completion must time out")
        } catch {#expect(error.localizedDescription=="fixture timeout")}
        #expect(Date().timeIntervalSince(start)<2)
        parked?.resume()
        try await Task.sleep(for:.milliseconds(30)) // Late completion cannot resume twice.
    }
    @Test func watchdogNeedsRealDiskProgressAndHonorsManualPause() {
        let policy=RecorderWatchdog(),pid:Int32=42
        var status=RecorderSnapshot();status.pid=pid;status.recording=true;status.recordingStartedMS=0;status.heartbeatMS=100_000
        var pulse=RecorderAudioPulse(segmentID:"fixture",frames:48000);pulse.pid=pid;pulse.heartbeatMS=100_000
        #expect(!policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:true))
        status.heartbeatMS=70_000
        #expect(!policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:true)) // Audio still progresses.
        #expect(policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:false)) // Pause must be actionable.
        pulse.heartbeatMS=70_000;status.heartbeatMS=100_000
        #expect(policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:true)) // Fresh UI status cannot hide a dead writer.
        status.recording=false
        #expect(!policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:false))
        status.waitingForUserPermission=true;status.heartbeatMS=0
        #expect(!policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:true))
        #expect(policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:false))
    }
}
