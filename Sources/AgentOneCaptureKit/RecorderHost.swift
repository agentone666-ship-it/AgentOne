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
    private var lastSilenceCleanup=Date()
    private var healthySince:Date?
    private var decisionNonce:String?,sealNonce:String?
    private var pauseNonce:String?
    private var reconnectRequested:String?,reconnectNonce:String?,userStopNonce:String?
    private var userStopRequested=false
    private let diagnosticQueue=DispatchQueue(label:"life.agentone.recorder-diagnostics",qos:.utility)
    public init(root:URL) throws {database=try MemoryDatabase(root:root);service=NativeAudioCaptureService(database:database)}
    public func run() async throws {
        let fd=Darwin.open(database.root.appendingPathComponent("recorder-worker.lock").path,O_CREAT|O_RDWR,0o600)
        guard fd>=0 else {throw CaptureFailure.message("无法锁定采集进程")}
        guard Darwin.lockf(fd,F_TLOCK,0)==0 else {Darwin.close(fd);return}
        defer {Darwin.close(fd)}
        SilencePruner.enqueueExisting(root: database.root)
        service.onFailure={ [weak self] message in self?.failure=message;self?.log("capture_failure",detail:message) }
        service.onUserStopped={ [weak self] in self?.userStopRequested=true }
        service.onDiagnostic={ [weak self] message in self?.log("system_stream_status",detail:message) }
        let center=NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in Task {@MainActor in self?.sleeping=true}})
        observers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in Task {@MainActor in self?.sleeping=false}})
        observers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("com.apple.screenIsLocked"),object:nil,queue:.main) { [weak self] _ in Task {@MainActor in self?.locked=true}})
        observers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("com.apple.screenIsUnlocked"),object:nil,queue:.main) { [weak self] _ in Task {@MainActor in self?.locked=false}})
        try publish(mode:"preserve")
        while !Task.isCancelled {
            do {
                if Date().timeIntervalSince(lastSilenceCleanup)>300 {lastSilenceCleanup=Date();SilencePruner.enqueueExisting(root:database.root)}
                if var control=try? RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(database.root)),["preserve","intelligent","manual"].contains(control.mode) {
                    if userStopRequested {
                        userStopRequested=false;let nonce=UUID().uuidString;userStopNonce=nonce
                        control.desired=false;control.pauseNonce=nonce;control.systemUserStopNonce=nonce
                        try RecorderFiles.write(control,to:RecorderFiles.control(database.root))
                        UserDefaults(suiteName:"life.agentone.desktop")?.set(false,forKey:"vNext.captureDesired")
                        log("system_user_stopped",detail:"explicit_user_stop")
                    }
                    if let nonce=control.systemUserStopNonce {
                        userStopNonce=nonce
                        if control.desired {control.desired=false;try RecorderFiles.write(control,to:RecorderFiles.control(database.root))}
                    }
                    let suspended=sleeping || (locked && control.pauseOnLock)
                    if let failure {
                        self.failure=nil;error=failure;healthySince=nil;try await service.stop(reason:"stream_error")
                        attempts+=1;retryAfter=Date().addingTimeInterval(min(30,pow(2,Double(min(attempts-1,5)))))
                        log("stream_error",detail:failure)
                    }
                    if !control.desired || suspended {
                        if service.isRecording {try await service.stop(reason:!control.desired ? "user_paused":sleeping ? "sleep":"screen_locked");log("paused",detail:!control.desired ? "user_paused":"device_suspended")}
                        if !control.desired {pauseNonce=control.pauseNonce}
                        error="";attempts=0
                    } else if Date()>=retryAfter {
                        userStopNonce=nil
                        if Date().timeIntervalSince1970*1000-control.updatedMS<600000 {service.metadata.restore(place:control.place,context:control.context)}
                        else {service.metadata.update(place:nil,application:nil,bundleID:nil)}
                        let wasRecording=service.isRecording
                        do {
                            if !wasRecording,control.allowPermissionPrompts,NativeAudioCaptureService.needsUserConsent {try publish(mode:control.mode,waitingForPermission:true)}
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
                    if let nonce=control.reconnectNonce,nonce != reconnectRequested,service.isRecording {reconnectRequested=nonce;service.requestSystemReconnect();log("system_reconnect_requested",detail:nonce)}
                    if reconnectRequested != reconnectNonce,service.systemHealthy {reconnectNonce=reconnectRequested;log("system_reconnected",detail:"microphone_and_mix_session_preserved")}
                    if service.isRecording,service.activity.hasSamples(source:"system_audio",maxAge:3),service.activity.hasSamples(source:"microphone",maxAge:3) {
                        if healthySince==nil {healthySince=Date()}
                        if Date().timeIntervalSince(healthySince!)>10 {attempts=0}
                    } else {healthySince=nil}
                    if Date().timeIntervalSince(lastHeartbeat)>=1 {try service.heartbeat();lastHeartbeat=Date()}
                    try publish(mode:control.mode)
                }
            } catch {self.error="采集存储状态异常："+error.localizedDescription;log("operation_failed",detail:self.error);try? publish(mode:"preserve")}
            if service.needsProcessRestart {log("restart_required",detail:"native_operation_timeout");Darwin._exit(75)}
            try await Task.sleep(for:.milliseconds(200))
        }
        try await service.stop(reason:"recorder_exit")
    }
    private func publish(mode:String,waitingForPermission:Bool=false) throws {
        var value=RecorderSnapshot();value.recording=service.isRecording;value.saving=service.isRecording && service.decisionStatus.snapshot.saving
        value.mode=mode;value.session=service.sessionToken;value.inputs=service.activity.telemetry();value.sealNonce=sealNonce
        value.recordingStartedMS=service.recordingStartedMS
        value.waitingForUserPermission=waitingForPermission
        value.pauseNonce=pauseNonce
        value.reconnectNonce=reconnectNonce;value.userStopNonce=userStopNonce
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
        let payload=data
        diagnosticQueue.async {
            let fd=Darwin.open(url.path,O_CREAT|O_APPEND|O_WRONLY|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard fd>=0 else{return};defer{Darwin.close(fd)}
            payload.withUnsafeBytes {if let base=$0.baseAddress {_=Darwin.write(fd,base,$0.count)}}
        }
    }
}
