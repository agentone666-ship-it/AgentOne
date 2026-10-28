@testable import AgentOneCaptureKit
import AVFoundation
import Foundation
import Testing
import Darwin
import SQLite3

@MainActor struct RecorderIsolationTests {
    @Test func persistedSystemStopWinsEvenWhenTheWorkerSnapshotWasRecreated() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let defaults=UserDefaults.standard,previous=UserDefaults.standard.object(forKey:"vNext.captureDesired")
        defer {if let previous {defaults.set(previous,forKey:"vNext.captureDesired")} else {defaults.removeObject(forKey:"vNext.captureDesired")}}
        let db=try MemoryDatabase(root:root)
        var control=RecorderControl();control.desired=true
        try RecorderFiles.write(control,to:RecorderFiles.control(root))
        var snapshot=RecorderSnapshot();snapshot.recording=true;snapshot.saving=true
        try RecorderFiles.write(snapshot,to:RecorderFiles.status(root))
        let client=AudioCaptureService(database:db,recorderExecutable:URL(fileURLWithPath:"/usr/bin/false"))
        control.desired=false;control.systemUserStopNonce="system-stop";control.pauseNonce="system-stop"
        try RecorderFiles.write(control,to:RecorderFiles.control(root))
        snapshot.recording=false;snapshot.userStopNonce=nil // New worker has not echoed the stop yet.
        try RecorderFiles.write(snapshot,to:RecorderFiles.status(root))
        try client.heartbeat()
        #expect(try !RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(root)).desired)
        #expect(client.externalPauseRequested)
    }
    @Test func newUIAdoptsExistingRecorderWithoutRestartOrChangingUserPause() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let database=try MemoryDatabase(root:root)
        var config=RecorderControl();config.desired=true
        try RecorderFiles.write(config,to:RecorderFiles.control(root))
        var snapshot=RecorderSnapshot();snapshot.recording=true;snapshot.saving=true;snapshot.mode="preserve";snapshot.detail="fixture recorder"
        let token=snapshot.session
        try RecorderFiles.write(snapshot,to:RecorderFiles.status(root))
        let starting=root.appendingPathComponent("fixture-starting")
        // A real recorder's heartbeat is independent of the UI actor. Keep the
        // fixture alive even while parallel Vision/AppKit tests occupy MainActor.
        let recorder=Task.detached(priority:.userInitiated) { [root,token,starting] in
            var pauseAt:Double?
            while !Task.isCancelled {
                do {
                    let control=try RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(root))
                    var value=RecorderSnapshot();value.session=token;value.mode="preserve"
                    value.recording=control.desired && !FileManager.default.fileExists(atPath:starting.path)
                    value.saving=value.recording
                    if !control.desired {
                        if pauseAt==nil {pauseAt=ProcessInfo.processInfo.systemUptime}
                        if ProcessInfo.processInfo.systemUptime-(pauseAt ?? 0)>0.1 {value.pauseNonce=control.pauseNonce}
                    } else {pauseAt=nil}
                    try RecorderFiles.write(value,to:RecorderFiles.status(root))
                } catch {}
                try? await Task.sleep(for:.milliseconds(30))
            }
        }
        defer{recorder.cancel()}
        // An executable that would fail if spawned: a fresh recorder must be adopted.
        let client=AudioCaptureService(database:database,recorderExecutable:URL(fileURLWithPath:"/usr/bin/false"))
        try await client.start(allowPermissionPrompts:false,preserveAllAudio:true)
        #expect(client.isIndependentRecorder)
        #expect(client.sessionToken==token)
        #expect(client.isRecording)
        try client.heartbeat()
        #expect(try RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(root)).desired)
        try Data().write(to:starting)
        for _ in 0..<100 {
            if try !RecorderFiles.read(RecorderSnapshot.self,from:RecorderFiles.status(root)).recording {break}
            try await Task.sleep(for:.milliseconds(30))
        }
        try #require(!RecorderFiles.read(RecorderSnapshot.self,from:RecorderFiles.status(root)).recording)
        let stoppingClient=AudioCaptureService(database:database,recorderExecutable:URL(fileURLWithPath:"/usr/bin/false"))
        try await stoppingClient.stop(reason:"user_paused")
        let acknowledgement=try RecorderFiles.read(RecorderSnapshot.self,from:RecorderFiles.status(root)).pauseNonce
        #expect(acknowledgement != nil)
        #expect(acknowledgement == (try RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(root)).pauseNonce))
        #expect(try !RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(root)).desired)
        // Reopening/polling a paused UI must not silently resume recording.
        let reopened=AudioCaptureService(database:database,recorderExecutable:URL(fileURLWithPath:"/usr/bin/false"))
        try reopened.heartbeat()
        #expect(try !RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(root)).desired)
        recorder.cancel();await recorder.value
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
    @Test func lockedOptionalModelAuditCannotStopAlreadyOpenPCM() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let db=try MemoryDatabase(root:root),host=ProcessInfo.processInfo.systemUptime
        let writer=AudioTrackWriter(database:db,source:"mixed",sessionID:"audit-lock",wallAnchor:Date(),hostAnchor:host)
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        let block=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!;block.frameLength=48000
        for channel in 0..<2 {block.floatChannelData![channel].update(repeating:0.2,count:48000)}
        try writer.append(block,presentationSeconds:host)
        var blocker:OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&blocker)==SQLITE_OK)
        defer{sqlite3_close(blocker)}
        #expect(sqlite3_exec(blocker,"BEGIN IMMEDIATE",nil,nil,nil)==SQLITE_OK)
        #expect(!db.tryRecordDecisionAudit("{\"observed_ms\":1}"))
        try writer.append(block,presentationSeconds:host+1)
        #expect(sqlite3_exec(blocker,"ROLLBACK",nil,nil,nil)==SQLITE_OK)
        try writer.finish()
        let row=try #require(db.rows("SELECT * FROM segments WHERE state='sealed'").first)
        #expect(abs(Double(row["ended_ms"]!)!-Double(row["started_ms"]!)!-2000)<2)
        _=try db.verifiedAudioURL(row["id"]!)
        #expect(db.tryRecordDecisionAudit("{\"observed_ms\":20}"))
        #expect(!db.tryRecordDecisionAudit("{\"observed_ms\":1}"))
        #expect(try db.rows("SELECT value FROM meta WHERE key='capture_decision'").first?["value"]=="{\"observed_ms\":20}")
    }
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
    @Test func systemStopPolicyDistinguishesUserIntentFromDeviceRecovery() {
        #expect(SystemStreamStopPolicy.isUserStop(domain:"com.apple.ScreenCaptureKit.SCStreamErrorDomain",code:-3817))
        #expect(!SystemStreamStopPolicy.isUserStop(domain:"com.apple.ScreenCaptureKit.SCStreamErrorDomain",code:-3821))
        #expect(!SystemStreamStopPolicy.isUserStop(domain:"com.apple.ScreenCaptureKit.SCStreamErrorDomain",code:-3808))
        #expect(!SystemStreamStopPolicy.isUserStop(domain:"unrelated",code:-3817))
    }
    @Test func missingFrameworkCompletionCannotHoldTheCallerForever() async throws {
        var parked:CheckedContinuation<Void,Never>?
        var underlyingCompleted=false
        do {
            try await CaptureDeadline.perform(seconds:0.05,message:"fixture timeout") {
                await withCheckedContinuation {parked=$0}
                underlyingCompleted=true
            }
            Issue.record("A missing framework completion must time out")
        } catch {#expect(error is CaptureOperationTimeout);#expect(error.localizedDescription=="fixture timeout")}
        #expect(!underlyingCompleted)
        #expect(parked != nil)
        parked?.resume()
        try await Task.sleep(for:.milliseconds(30)) // Late completion cannot resume twice.
        #expect(underlyingCompleted)
    }
    @Test func watchdogNeedsRealDiskProgressAndHonorsManualPause() {
        let policy=RecorderWatchdog(),pid:Int32=42
        var status=RecorderSnapshot();status.pid=pid;status.recording=true;status.saving=true;status.recordingStartedMS=0;status.heartbeatMS=100_000
        var pulse=RecorderAudioPulse(segmentID:"fixture",frames:48000);pulse.pid=pid;pulse.heartbeatMS=100_000
        #expect(!policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:true))
        status.heartbeatMS=70_000
        #expect(!policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:true)) // Audio still progresses.
        #expect(policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:false)) // Pause must be actionable.
        pulse.heartbeatMS=70_000;status.heartbeatMS=100_000
        #expect(policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:true)) // Fresh UI status cannot hide a dead writer.
        status.saving=false
        #expect(!policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:true)) // Intelligent listening intentionally has no file.
        status.recording=false
        #expect(!policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:false))
        status.waitingForUserPermission=true;status.heartbeatMS=0
        #expect(!policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:true))
        #expect(policy.shouldRestart(now:101_000,launched:0,pid:pid,status:status,pulse:pulse,desired:false))
    }
}
