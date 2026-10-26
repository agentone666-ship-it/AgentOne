import Foundation
import AppKit
import Darwin

/// Native device lifecycle only. No ASR, model, window sampling or Agent execution.
@MainActor public final class RecorderHost {
    private let database:MemoryDatabase
    private let service:NativeAudioCaptureService
    private var locked=false,sleeping=false
    private var observers:[NSObjectProtocol]=[]
    private var failure:String?
    private var error=""
    private var retryAfter=Date.distantPast
    private var attempts=0
    private var lastHeartbeat=Date.distantPast
    private var healthySince:Date?
    private var decisionNonce:String?,sealNonce:String?
    public init(root:URL) throws {database=try MemoryDatabase(root:root);service=NativeAudioCaptureService(database:database)}
    public func run() async throws {
        let fd=Darwin.open(database.root.appendingPathComponent("recorder-worker.lock").path,O_CREAT|O_RDWR,0o600)
        guard fd>=0 else {throw CaptureFailure.message("无法锁定采集进程")}
        guard Darwin.lockf(fd,F_TLOCK,0)==0 else {Darwin.close(fd);return}
        defer {Darwin.close(fd)}
        service.onFailure={ [weak self] message in self?.failure=message;self?.log("capture_failure",detail:message) }
        let center=NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in Task {@MainActor in self?.sleeping=true}})
        observers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in Task {@MainActor in self?.sleeping=false}})
        observers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("com.apple.screenIsLocked"),object:nil,queue:.main) { [weak self] _ in Task {@MainActor in self?.locked=true}})
        observers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("com.apple.screenIsUnlocked"),object:nil,queue:.main) { [weak self] _ in Task {@MainActor in self?.locked=false}})
        try publish(mode:"preserve")
        while !Task.isCancelled {
            do {
                if let control=try? RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(database.root)),["preserve","intelligent","manual"].contains(control.mode) {
                    let suspended=sleeping || (locked && control.pauseOnLock)
                    if let failure {
                        self.failure=nil;error=failure;healthySince=nil;try await service.stop(reason:"stream_error")
                        attempts+=1;retryAfter=Date().addingTimeInterval(min(30,pow(2,Double(min(attempts-1,5)))))
                        log("stream_error",detail:failure)
                    }
                    if !control.desired || suspended {
                        if service.isRecording {try await service.stop(reason:!control.desired ? "user_paused":sleeping ? "sleep":"screen_locked");log("paused",detail:!control.desired ? "user_paused":"device_suspended")}
                        error="";attempts=0
                    } else if Date()>=retryAfter {
                        if Date().timeIntervalSince1970*1000-control.updatedMS<600000 {service.metadata.restore(place:control.place,context:control.context)}
                        else {service.metadata.update(place:nil,application:nil,bundleID:nil)}
                        let wasRecording=service.isRecording
                        do {
                            try await service.start(allowPermissionPrompts:control.allowPermissionPrompts,automaticDecisions:control.mode=="intelligent",preserveAllAudio:control.mode=="preserve")
                            if !wasRecording {log("started",detail:control.mode)}
                            error=""
                        } catch {
                            self.error="后台采集中断，正在重试："+error.localizedDescription;attempts+=1
                            retryAfter=Date().addingTimeInterval(min(30,pow(2,Double(min(attempts-1,5)))));log("start_failed",detail:self.error)
                        }
                    }
                    if control.decisionNonce != decisionNonce,let session=control.decisionSession {decisionNonce=control.decisionNonce;service.applyDecision(control.decision,session:session)}
                    if let nonce=control.sealNonce,nonce != sealNonce,service.isRecording {try await service.checkpoint();sealNonce=nonce}
                    if service.isRecording,service.activity.hasSamples(source:"system_audio",maxAge:3),service.activity.hasSamples(source:"microphone",maxAge:3) {
                        if healthySince==nil {healthySince=Date()}
                        if Date().timeIntervalSince(healthySince!)>10 {attempts=0}
                    } else {healthySince=nil}
                    if Date().timeIntervalSince(lastHeartbeat)>=1 {try service.heartbeat();lastHeartbeat=Date()}
                    try publish(mode:control.mode)
                }
            } catch {self.error="采集存储状态异常："+error.localizedDescription;log("operation_failed",detail:self.error);try? publish(mode:"preserve")}
            try await Task.sleep(for:.milliseconds(200))
        }
        try await service.stop(reason:"recorder_exit")
    }
    private func publish(mode:String) throws {
        var value=RecorderSnapshot();value.recording=service.isRecording;value.saving=service.isRecording && service.decisionStatus.snapshot.saving
        value.mode=mode;value.session=service.sessionToken;value.inputs=service.activity.telemetry();value.sealNonce=sealNonce
        value.detail=service.isRecording ? service.decisionStatus.snapshot.detail:error.isEmpty ? "后台采集已暂停":error
        value.warning=error.isEmpty ? service.microphoneWarning:error
        if service.isRecording,value.warning.isEmpty {
            let missing=["system_audio","microphone"].filter {!service.activity.hasSamples(source:$0,maxAge:3)}
            if !missing.isEmpty {value.warning="等待真实采样："+missing.map{$0=="system_audio" ? "系统音":"麦克风"}.joined(separator:"、")}
        }
        try RecorderFiles.write(value,to:RecorderFiles.status(database.root))
    }
    private func log(_ event:String,detail:String) {
        let url=database.root.appendingPathComponent("recorder-events.jsonl")
        let row:[String:Any]=["at":Date().timeIntervalSince1970*1000,"pid":getpid(),"event":event,"detail":detail]
        guard var data=try? JSONSerialization.data(withJSONObject:row) else {return};data.append(10)
        if !FileManager.default.fileExists(atPath:url.path) {FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])}
        if let file=try? FileHandle(forWritingTo:url) {defer{try? file.close()};try? file.seekToEnd();try? file.write(contentsOf:data);try? file.synchronize()}
    }
}
