import Foundation
import Darwin

struct RecorderWatchdog {
    var startupGraceMS=30_000.0
    var statusTimeoutMS=10_000.0
    var pulseTimeoutMS=10_000.0
    func shouldRestart(now:Double,launched:Double,pid:Int32,status:RecorderSnapshot?,pulse:RecorderAudioPulse?,desired:Bool) -> Bool {
        guard now-launched>startupGraceMS else{return false}
        if desired,status?.pid==pid,status?.waitingForUserPermission==true,now-launched<300_000 {return false}
        let statusAge=status?.pid==pid ? now-(status?.heartbeatMS ?? 0):Double.infinity
        let pulseAge=pulse?.pid==pid ? now-(pulse?.heartbeatMS ?? 0):Double.infinity
        if desired,status?.pid==pid,status?.recording==true,status?.saving==true,now-(status?.recordingStartedMS ?? launched)>startupGraceMS,pulseAge>pulseTimeoutMS {return true}
        return statusAge>statusTimeoutMS && (!desired || pulseAge>pulseTimeoutMS)
    }
}

/// Separate process: a suspended framework continuation must not suspend its
/// own watchdog. Monitors both control-loop liveness and actual PCM disk progress.
public enum RecorderSupervisor {
    public static func run(root:URL,executable:URL,fixture:Bool=false,fixturePause:Bool=false) async throws {
        if fixture {
            guard (try FileManager.default.contentsOfDirectory(atPath:root.path)).isEmpty else {throw CaptureFailure.message("监督测试必须使用空目录")}
            var control=RecorderControl();control.desired = !fixturePause
            if fixturePause {control.pauseNonce=UUID().uuidString}
            try RecorderFiles.write(control,to:RecorderFiles.control(root))
        }
        let fd=Darwin.open(root.appendingPathComponent("recorder-supervisor.lock").path,O_CREAT|O_RDWR|O_CLOEXEC,0o600)
        guard fd>=0 else {throw CaptureFailure.message("无法锁定采集监督进程")};defer{Darwin.close(fd)}
        guard Darwin.lockf(fd,F_TLOCK,0)==0 else {return}
        var policy=RecorderWatchdog()
        if fixture {policy.startupGraceMS=250;policy.statusTimeoutMS=400;policy.pulseTimeoutMS=250}
        var failures=0,starts=0,watchdogRestarts=0
        var firstPID:Int32=0
        while !Task.isCancelled {
            let child=Process();child.executableURL=fixture ? URL(fileURLWithPath:"/bin/sleep"):executable
            child.arguments=fixture ? ["60"]:["--worker","--root",root.path]
            child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice
            let launched=Date().timeIntervalSince1970*1000
            var pauseRequestedAt:Double?
            do {
                try child.run();starts+=1
                if fixture {
                    if starts==1 {firstPID=child.processIdentifier}
                    else {
                        let restarted=watchdogRestarts==1 && child.processIdentifier != firstPID
                        Darwin.kill(child.processIdentifier,SIGKILL)
                        while child.isRunning {try await Task.sleep(for:.milliseconds(25))}
                        guard restarted else {throw CaptureFailure.message("监督重建测试失败")}
                        print("{\"fixture\":true,\"watchdog_restart\":true,\"starts\":2,\"pause_respected\":\(fixturePause),\"recording_started\":false}");return
                    }
                    var status=RecorderSnapshot();status.pid=child.processIdentifier;status.recording = !fixturePause;status.recordingStartedMS=launched-1000
                    try RecorderFiles.write(status,to:RecorderFiles.status(root))
                    var pulse=RecorderAudioPulse(segmentID:"fixture",frames:1);pulse.pid=child.processIdentifier;pulse.heartbeatMS=launched-1000
                    try RecorderFiles.write(pulse,to:RecorderFiles.audioPulse(root))
                }
                while child.isRunning {
                    if fixturePause {
                        var status=RecorderSnapshot();status.pid=child.processIdentifier;status.recording=false
                        try RecorderFiles.write(status,to:RecorderFiles.status(root))
                    }
                    let status=try? RecorderFiles.read(RecorderSnapshot.self,from:RecorderFiles.status(root))
                    let pulse=try? RecorderFiles.read(RecorderAudioPulse.self,from:RecorderFiles.audioPulse(root))
                    let control=try? RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(root))
                    let desired=control?.desired ?? true,now=Date().timeIntervalSince1970*1000
                    let pausePending = !desired && control?.pauseNonce != nil && (status?.pid != child.processIdentifier || status?.pauseNonce != control?.pauseNonce || status?.recording != false)
                    if pausePending {if pauseRequestedAt==nil {pauseRequestedAt=now}} else {pauseRequestedAt=nil}
                    let forcePause=pauseRequestedAt.map {now-$0>(fixture ? 250:5000)} ?? false
                    if forcePause || policy.shouldRestart(now:now,launched:launched,pid:child.processIdentifier,status:status,pulse:pulse,desired:desired) {
                        appendEvent(root:root,event:forcePause ? "watchdog_unacknowledged_pause":"watchdog_unresponsive_recorder",pid:child.processIdentifier)
                        Darwin.kill(child.processIdentifier,SIGKILL);watchdogRestarts+=1
                        while child.isRunning {try await Task.sleep(for:.milliseconds(50))}
                        break
                    }
                    try await Task.sleep(for:.milliseconds(200))
                }
                appendEvent(root:root,event:"worker_exit_\(child.terminationStatus)",pid:child.processIdentifier)
            } catch {appendEvent(root:root,event:"worker_launch_failed",pid:child.processIdentifier)}
            if Date().timeIntervalSince1970*1000-launched>30_000 {failures=0}
            failures+=1;try await Task.sleep(for:.seconds(min(10,pow(2,Double(min(failures-1,4))))))
        }
    }
    private static func appendEvent(root:URL,event:String,pid:Int32) {
        let url=root.appendingPathComponent("recorder-watchdog.jsonl")
        guard var data=try? JSONSerialization.data(withJSONObject:["at":Date().timeIntervalSince1970*1000,"event":event,"pid":pid]) else{return};data.append(10)
        let fd=Darwin.open(url.path,O_CREAT|O_APPEND|O_WRONLY|O_CLOEXEC,0o600);guard fd>=0 else{return};defer{Darwin.close(fd)}
        data.withUnsafeBytes {if let base=$0.baseAddress {_=Darwin.write(fd,base,$0.count)}}
    }
}
