import Foundation
import Darwin

struct RecorderControl:Codable {
    var desired=false
    var mode="preserve"
    var pauseOnLock=true
    var allowPermissionPrompts=false
    var updatedMS=Date().timeIntervalSince1970*1000
    var place:String?
    var context="{}"
    var decision:RecordingDecision?
    var decisionNonce:String?
    var decisionSession:UUID?
    var sealNonce:String?
}
struct RecorderSnapshot:Codable {
    var pid=Int32(getpid())
    var heartbeatMS=Date().timeIntervalSince1970*1000
    var recording=false
    var saving=false
    var mode="preserve"
    var detail="后台采集正在启动"
    var warning=""
    var session=UUID()
    var inputs:[String:AudioInputTelemetry]=[:]
    var sealNonce:String?
}
enum RecorderFiles {
    static func control(_ root:URL)->URL {root.appendingPathComponent("recorder-control.json")}
    static func status(_ root:URL)->URL {root.appendingPathComponent("recorder-status.json")}
    static func read<T:Decodable>(_ type:T.Type,from url:URL) throws -> T {
        guard (try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else {throw CaptureFailure.message("采集状态文件不能是符号链接")}
        let data=try Data(contentsOf:url);guard data.count<131072 else {throw CaptureFailure.message("采集状态文件过大")}
        return try JSONDecoder().decode(type,from:data)
    }
    static func write<T:Encodable>(_ value:T,to url:URL) throws {
        guard (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else {throw CaptureFailure.message("采集控制文件不能是符号链接")}
        try JSONEncoder().encode(value).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}

/// UI facade: audio devices and file writers live in a separate, already-authorized
/// local process. Losing a window, ASR task or event observer cannot close them.
@MainActor public final class AudioCaptureService {
    private let database:MemoryDatabase
    private let native:NativeAudioCaptureService?
    private var current=RecorderSnapshot()
    private var control=RecorderControl()
    private var loadedAt=Date.distantPast
    private var spawnedAt=Date.distantPast
    private var child:Process?
    private let executable:URL?
    public let metadata=CaptureMetadata()
    private let remoteActivity=CaptureActivityMeter()
    public var activity:CaptureActivityMeter {native?.activity ?? remoteActivity}
    private var remoteDecision=RecordingDecisionStatus(preserveAllAudio:true)
    public var onFailure:(@MainActor @Sendable (String)->Void)?
    public var isIndependentRecorder:Bool {native==nil}
    public var isRecording:Bool {if let native {return native.isRecording};reload();return fresh && current.recording}
    public var automaticDecisions:Bool {if let native{return native.automaticDecisions};reload();return current.mode=="intelligent"}
    public var preserveAllAudio:Bool {if let native{return native.preserveAllAudio};reload();return current.mode=="preserve"}
    public var microphoneWarning:String {if let native{return native.microphoneWarning};reload();return fresh ? current.warning:"后台采集状态暂不可用，正在检查恢复"}
    public var decisionStatus:RecordingDecisionStatus {if let native{return native.decisionStatus};reload();return remoteDecision}
    public var sessionToken:UUID {if let native{return native.sessionToken};reload();return current.session}
    private var fresh:Bool {current.pid>1 && Darwin.kill(current.pid,0)==0 && Date().timeIntervalSince1970*1000-current.heartbeatMS<5000}
    public init(database:MemoryDatabase,recorderExecutable:URL? = nil) {
        self.database=database
        let candidate=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AgentOneRecorder.app/Contents/MacOS/AgentOneRecorder")
        executable=recorderExecutable ?? (FileManager.default.isExecutableFile(atPath:candidate.path) ? candidate:nil)
        native=executable==nil ? NativeAudioCaptureService(database:database):nil
        if let saved=try? RecorderFiles.read(RecorderControl.self,from:RecorderFiles.control(database.root)) {control=saved}
        native?.onFailure={ [weak self] in self?.onFailure?($0)}
        reload()
    }
    private func reload() {
        guard native==nil,Date().timeIntervalSince(loadedAt)>0.07 else {return};loadedAt=Date()
        guard let value=try? RecorderFiles.read(RecorderSnapshot.self,from:RecorderFiles.status(database.root)) else {current.heartbeatMS=0;return}
        if value.session != current.session {activity.reset()}
        current=value
        for (source,value) in value.inputs {activity.observe(AudioActivityReading(rmsDBFS:value.rmsDBFS),source:source,now:value.observedUptime)}
        remoteDecision=RecordingDecisionStatus(manual:value.mode=="manual",preserveAllAudio:value.mode=="preserve")
        remoteDecision.update(saving:value.saving,detail:value.detail)
    }
    private func publish() throws {
        let value=metadata.snapshot();control.place=value.0;control.context=value.1
        control.pauseOnLock=(UserDefaults.standard.object(forKey:"vNext.pauseOnLock") as? Bool) ?? true
        control.updatedMS=Date().timeIntervalSince1970*1000
        try RecorderFiles.write(control,to:RecorderFiles.control(database.root))
    }
    private func ensureWorker() throws {
        reload();guard !fresh,Date().timeIntervalSince(spawnedAt)>3,let executable else {return}
        let process=Process();process.executableURL=executable;process.arguments=["--root",database.root.path]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();child=process;spawnedAt=Date()
    }
    public func start(allowPermissionPrompts:Bool,automaticDecisions:Bool=true,preserveAllAudio:Bool=false) async throws {
        if let native {native.metadata.restore(place:metadata.snapshot().0,context:metadata.snapshot().1);try await native.start(allowPermissionPrompts:allowPermissionPrompts,automaticDecisions:automaticDecisions,preserveAllAudio:preserveAllAudio);return}
        control.desired=true;control.mode=preserveAllAudio ? "preserve":automaticDecisions ? "intelligent":"manual";control.allowPermissionPrompts=allowPermissionPrompts
        try publish();try ensureWorker()
        let until=Date().addingTimeInterval(40)
        while Date()<until {
            reload();if fresh,current.recording,current.mode==control.mode,current.warning.isEmpty {return}
            try await Task.sleep(for:.milliseconds(150));try ensureWorker()
        }
        throw CaptureFailure.message("后台采集启动尚未就绪；将继续恢复，请检查录音状态")
    }
    public func stop(reason:String="user_paused") async throws {
        if let native {try await native.stop(reason:reason);return}
        // The recorder owns sleep/lock notifications. These never cancel persisted intent.
        if ["sleep","screen_locked","application_exit"].contains(reason) {return}
        control.desired=false;try publish()
        for _ in 0..<80 {reload();if !current.recording {return};try await Task.sleep(for:.milliseconds(100))}
        throw CaptureFailure.message("后台采集暂停尚未确认")
    }
    public func applyDecision(_ decision:RecordingDecision?,session:UUID) {
        if let native {native.applyDecision(decision,session:session);return}
        control.decision=decision;control.decisionNonce=UUID().uuidString;control.decisionSession=session
        do {try publish()} catch {onFailure?("模型标记发送失败，原音继续由后台保存")}
    }
    public func heartbeat() throws {
        if let native {let value=metadata.snapshot();native.metadata.restore(place:value.0,context:value.1);try native.heartbeat();return}
        try publish();if control.desired {try ensureWorker()};reload()
    }
    public func checkpoint() async throws {
        if let native {try await native.checkpoint();return}
        let nonce=UUID().uuidString;control.sealNonce=nonce;try publish()
        for _ in 0..<80 {reload();if current.sealNonce==nonce{return};try await Task.sleep(for:.milliseconds(100))}
        throw CaptureFailure.message("片段封口尚未确认")
    }
}
