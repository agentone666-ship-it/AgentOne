@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Darwin
@preconcurrency import ScreenCaptureKit

public final class CaptureMetadata: @unchecked Sendable {
    private let lock = NSLock()
    private var place: String?
    private var context = "{}"
    private var microphoneDevice:[String:String]?
    public init() {}
    public func update(place: String?, application: String?, bundleID: String?, location:LocationObservation? = nil) {
        lock.lock(); defer { lock.unlock() }
        let fresh=location.flatMap {$0.isFresh() ? $0:nil}
        self.place = location != nil ? fresh?.displayName:place?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var value: [String: Any] = ["application": application ?? NSNull(), "bundle_identifier": bundleID ?? NSNull(),
            "observed_at": ISO8601DateFormatter().string(from: Date()), "place_source": fresh != nil ? "core_location" : self.place == nil ? "unknown" : "user_annotation"]
        if let fresh {value["location"]=fresh.json}
        context = (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    func snapshot() -> (String?, String) {
        lock.lock();defer{lock.unlock()}
        guard let microphoneDevice else {return(place,context)}
        var value=(context.data(using:.utf8).flatMap{try? JSONSerialization.jsonObject(with:$0)} as? [String:Any]) ?? [:]
        value["microphone_device"]=microphoneDevice
        return(place,(try? JSONSerialization.data(withJSONObject:value)).map{String(decoding:$0,as:UTF8.self)} ?? context)
    }
    func setMicrophoneDevice(_ device:AVCaptureDevice) {
        lock.lock();defer{lock.unlock()};microphoneDevice=["name":device.localizedName,"uid":device.uniqueID,"selection":"mac_builtin_only"]
    }
    func restore(place:String?,context:String) {lock.lock();defer{lock.unlock()};self.place=place;self.context=context}
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

private struct OwnedAudioPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let presentationSeconds: Double
}

private final class AudioStreamSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "life.agentone.audio-writer", qos: .userInitiated)
    let inputQueue = DispatchQueue(label: "life.agentone.audio-input", qos: .userInitiated)
    let mixed: MixedAudioWriter
    let activity: CaptureActivityMeter
    let decisionStatus: RecordingDecisionStatus
    let database: MemoryDatabase
    let onFailure: @Sendable (String) -> Void
    let onSystemFailure:@Sendable (ObjectIdentifier,String,Int)->Void
    private var timer: DispatchSourceTimer?
    fileprivate var failed = false
    init(database: MemoryDatabase, metadata: CaptureMetadata, activity: CaptureActivityMeter, decisionStatus: RecordingDecisionStatus,onSystemFailure:@escaping @Sendable (ObjectIdentifier,String,Int)->Void,onFailure: @escaping @Sendable (String) -> Void) {
        let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        mixed = MixedAudioWriter(database:database,sessionID:UUID().uuidString,wallAnchor:Date(),hostAnchor:host,decisionStatus:decisionStatus,onActivity:{activity.observe($0,source:"mixed")},metadata:{metadata.snapshot()})
        self.database=database;self.decisionStatus=decisionStatus;self.activity=activity;self.onFailure=onFailure;self.onSystemFailure=onSystemFailure
    }
    func beginMixing() {
        queue.async {
            guard !self.failed else {return}
            let timer=DispatchSource.makeTimerSource(queue:self.queue)
            timer.schedule(deadline:.now(),repeating:.milliseconds(100),leeway:.milliseconds(15))
            timer.setEventHandler { [weak self] in
                guard let self,!self.failed else {return}
                do {try self.mixed.flushAvailable(throughHostSeconds:CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))-MixedAudioWriter.latency)}
                catch {self.failed=true;self.onFailure("混合录音已停止："+error.localizedDescription)}
            }
            self.timer=timer;timer.resume()
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else {return}
        do {
            if let packet=try AudioTrackWriter.decodePCM(sampleBuffer) {
                enqueue(packet.buffer,source:"system_audio",presentationSeconds:packet.presentationSeconds)
            }
        } catch {onFailure("系统声音采样读取失败："+error.localizedDescription)}
    }
    func enqueueMicrophone(_ buffer: AVAudioPCMBuffer, presentationSeconds: Double) {
        enqueue(buffer,source:"microphone",presentationSeconds:presentationSeconds)
    }
    private func enqueue(_ buffer:AVAudioPCMBuffer,source:String,presentationSeconds:Double) {
        let packet=OwnedAudioPacket(buffer:buffer,presentationSeconds:presentationSeconds)
        queue.async {
            guard !self.failed else {return}
            do {
                self.activity.observe(AudioActivityReading.measure(packet.buffer),source:source)
                try self.mixed.append(packet.buffer,source:source,presentationSeconds:packet.presentationSeconds)
            } catch {self.failed=true;self.onFailure("麦克风混音失败："+error.localizedDescription)}
        }
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) {
        let value=error as NSError
        onSystemFailure(ObjectIdentifier(stream),value.domain,value.code)
    }
    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.failed = true
                self.timer?.cancel();self.timer=nil
                do { try self.mixed.finish(throughHostSeconds:CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Native capture lifecycle only. It has no model credentials, chat or Agent tools.
@MainActor public final class NativeAudioCaptureService {
    public static var needsUserConsent:Bool {AVCaptureDevice.authorizationStatus(for:.audio) != .authorized || !CGPreflightScreenCaptureAccess()}
    public static func microphoneSelection() throws -> [String:String] {
        let device=try BuiltInMicrophone.device()
        return ["name":device.localizedName,"uid":device.uniqueID,"selection":"mac_builtin_only"]
    }
    public private(set) var isRecording = false
    public private(set) var needsProcessRestart=false
    public private(set) var recordingStartedMS:Double=0
    public private(set) var automaticDecisions = true
    public private(set) var preserveAllAudio = false
    private var micWarning="",systemWarning=""
    public var microphoneWarning:String {[systemWarning,micWarning].filter{!$0.isEmpty}.joined(separator:" · ")}
    public var systemHealthy:Bool {isRecording && systemRecovery==nil && systemWarning.isEmpty && activity.hasSamples(source:"system_audio",maxAge:3)}
    public let metadata = CaptureMetadata()
    public let activity = CaptureActivityMeter()
    public private(set) var decisionStatus = RecordingDecisionStatus()
    public private(set) var sessionToken = UUID()
    private let database: MemoryDatabase
    private var stream: SCStream?
    private var sink: AudioStreamSink?
    private var microphoneInput: MicrophoneInput?
    private var lockFD: Int32 = -1
    private var recordingActivity:NSObjectProtocol?
    private var systemRecovery:Task<Void,Never>?
    private let sessions = CaptureSessionCoordinator()
    public var onFailure: (@MainActor @Sendable (String) -> Void)?
    public var onUserStopped:(@MainActor @Sendable ()->Void)?
    public var onDiagnostic:(@MainActor @Sendable (String)->Void)?

    public init(database: MemoryDatabase) { self.database = database }

    public func start(allowPermissionPrompts: Bool,automaticDecisions:Bool=true,preserveAllAudio:Bool=false) async throws {
        let mode: CaptureSessionCoordinator.Mode = preserveAllAudio ? .preserve : automaticDecisions ? .intelligent : .manual
        try await sessions.start(mode: mode, start: {
            try await self.startSession(allowPermissionPrompts: allowPermissionPrompts, automaticDecisions: automaticDecisions, preserveAllAudio: preserveAllAudio)
        }, stop: { try await self.performStop(reason: $0) })
    }

    private func startSession(allowPermissionPrompts: Bool,automaticDecisions:Bool,preserveAllAudio:Bool) async throws {
        guard !needsProcessRestart else {throw CaptureFailure.message("采集组件需要重建")}
        guard !isRecording, stream == nil else { return }
        guard #available(macOS 15, *) else { throw CaptureFailure.message("双路原生录音需要 macOS 15 或更新版本") }
        lockFD = Darwin.open(database.root.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, Darwin.lockf(lockFD, F_TLOCK, 0) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
            throw CaptureFailure.message("另一采集进程正在使用这个 Memory 目录")
        }
        do {
            recordingActivity=ProcessInfo.processInfo.beginActivity(options:[.userInitiatedAllowingIdleSystemSleep,.latencyCritical],reason:"Preserve authorized continuous audio without App Nap")
            let microphoneAllowed: Bool
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { microphoneAllowed = true }
            else if allowPermissionPrompts { microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio) }
            else { microphoneAllowed = false }
            guard microphoneAllowed else { throw CaptureFailure.message("请在系统设置中允许 AgentOne 使用麦克风") }
            metadata.setMicrophoneDevice(try BuiltInMicrophone.device())
            if !allowPermissionPrompts, !CGPreflightScreenCaptureAccess() {
                throw CaptureFailure.message("系统音权限不可用；请手动继续录音以检查授权")
            }
            var discovered:SCShareableContent?
            if allowPermissionPrompts,!CGPreflightScreenCaptureAccess() {
                discovered=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
            } else {
                do {try await CaptureDeadline.perform(seconds:15,message:"系统音设备查询未响应，需要重新创建采集器") {discovered=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)}}
                catch {if error is CaptureOperationTimeout {needsProcessRestart=true};throw error}
            }
            guard let content=discovered else {throw CaptureFailure.message("未取得系统音设备")}
            guard let display = content.displays.first else { throw CaptureFailure.message("没有可用显示器，无法启动系统音采集") }
            try database.recoverInterruptedSegments()
            self.automaticDecisions=automaticDecisions && !preserveAllAudio;self.preserveAllAudio=preserveAllAudio
            activity.reset();decisionStatus=RecordingDecisionStatus(manual:!automaticDecisions && !preserveAllAudio,preserveAllAudio:preserveAllAudio);sessionToken=UUID()
            let activeSession=sessionToken
            let output = AudioStreamSink(database: database, metadata: metadata, activity: activity, decisionStatus:decisionStatus,onSystemFailure:{ [weak self] id,domain,code in
                Task { @MainActor in
                    guard let self,self.sessionToken==activeSession,self.stream.map(ObjectIdentifier.init)==id else{return}
                    self.systemWarning="系统音中断（\(domain.prefix(80)) \(code)）；Mac 麦克风继续保存"
                    self.onDiagnostic?(self.systemWarning)
                    if SystemStreamStopPolicy.isUserStop(domain:domain,code:code) {self.onUserStopped?();return}
                    guard self.isRecording else{return}
                    if self.systemRecovery != nil {self.stream=nil} else {self.requestSystemReconnect()}
                }
            }) { [weak self] message in
                Task { @MainActor in guard let self,self.isRecording,self.sessionToken==activeSession else {return};self.onFailure?(message) }
            }
            let configuration = SCStreamConfiguration()
            configuration.width = 2; configuration.height = 2
            configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
            configuration.showsCursor = false
            configuration.capturesAudio = true; configuration.captureMicrophone = false
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000; configuration.channelCount = 2
            let capture = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), configuration: configuration, delegate: output)
            try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.inputQueue)
            // Consume/discard tiny screen frames to avoid SCStream output errors; never save them.
            try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.inputQueue)
            sink = output; stream = capture
            output.beginMixing()
            do {try await CaptureDeadline.perform(seconds:15,message:"系统音启动未响应，需要重新创建采集器") {try await capture.startCapture()}}
            catch {
                let value=error as NSError
                if SystemStreamStopPolicy.isUserStop(domain:value.domain,code:value.code) {onUserStopped?()}
                if error is CaptureOperationTimeout {needsProcessRestart=true};throw error
            }
            micWarning="";systemWarning=""
            let microphoneSession=sessionToken
            let microphone = MicrophoneInput(deliver: { buffer,pts in output.enqueueMicrophone(buffer,presentationSeconds: pts) },fail: { [weak self] message in
                Task { @MainActor in guard let self,self.isRecording,self.sessionToken==activeSession else {return};self.onFailure?(message) }
            },hasSamples:{output.activity.hasSamples(source:"microphone",maxAge:3)},warning:{ [weak self] message in
                Task { @MainActor in
                    guard let self,self.isRecording,self.sessionToken==microphoneSession else {return}
                    self.micWarning=message
                }
            })
            microphoneInput = microphone
            try microphone.start()
            let failed=output.queue.sync {output.failed}
            guard !failed,sink === output else {throw CaptureFailure.message("音频在启动期间中断，请重试")}
            try database.execute("UPDATE coverage SET ended_ms=? WHERE ended_ms IS NULL", [MemoryDatabase.now])
            isRecording = true
            recordingStartedMS=Date().timeIntervalSince1970*1000
            try database.setCaptureState(self.automaticDecisions ? "listening":"recording", detail:decisionStatus.snapshot.detail)
        } catch {
            isRecording = false
            microphoneInput?.stop(); microphoneInput = nil
            if let stream { await stopStream(stream) }
            if let sink { try? await sink.finish() }
            stream = nil; sink = nil; releaseLock()
            try? database.setCaptureState("error", detail: "capture_start_failed")
            throw error
        }
    }

    public func stop(reason: String = "user_paused") async throws {
        try await sessions.stop(reason: reason) { try await self.performStop(reason: $0) }
    }

    private func performStop(reason: String) async throws {
        let wasRecording = isRecording
        if systemRecovery != nil {systemRecovery?.cancel();systemRecovery=nil;needsProcessRestart=true}
        activity.reset()
        microphoneInput?.stop(); microphoneInput = nil
        isRecording = false
        if let stream { await stopStream(stream) }
        let output = sink
        stream = nil; sink = nil
        defer { releaseLock() }
        do { try await output?.finish() }
        catch { try? database.setCaptureState("error", detail: "finalization_failed"); throw error }
        if wasRecording {
            try database.setCaptureState("paused", detail: reason)
            try database.addGap(started: Date(), ended: nil, reason: reason)
        }
    }

    public func applyDecision(_ decision:RecordingDecision?,session:UUID) {
        guard isRecording,(automaticDecisions || preserveAllAudio),session==sessionToken,let sink else {return}
        let evidence=activity.startEvidence(),preserve=preserveAllAudio
        sink.queue.async {
            guard !sink.failed else {return}
            do {
                if preserve {try sink.mixed.annotateActivity(decision,evidence:evidence)}
                else {try sink.mixed.applyDecision(decision,quietSeconds:evidence.quietSeconds,inputsReady:evidence.inputsReady,soundConfirmed:evidence.sustainedSound)}
            }
            catch {sink.onFailure("录音分段失败："+error.localizedDescription);return}
            let state=sink.decisionStatus.snapshot,confidence=decision.map {$0.confidence.isFinite ? max(0,min(1,$0.confidence)):0} ?? 0
            let value:[String:Any]=["effect":preserve ? "annotate_only":"capture_gate","model":"convaiinnovations/laya/multilingual","choice":decision?.choice ?? "unavailable","answer_probability":confidence,"saving":state.saving,"quiet_seconds":evidence.quietSeconds,"inputs_ready":evidence.inputsReady,"sound_confirmed":evidence.sustainedSound,"active_fraction":evidence.activeFraction,"ready_sources":evidence.readySources,"observed_ms":MemoryDatabase.now]
            if let data=try? JSONSerialization.data(withJSONObject:value) {
                let json=String(decoding:data,as:UTF8.self),database=sink.database
                DispatchQueue.global(qos:.utility).async {_=database.tryRecordDecisionAudit(json)}
            }
        }
    }

    public func heartbeat() throws {
        guard isRecording else { return }
        if systemRecovery==nil,Date().timeIntervalSince1970*1000-recordingStartedMS>10_000,!activity.hasSamples(source:"system_audio",maxAge:6) {requestSystemReconnect()}
        let state=decisionStatus.snapshot
        try database.setCaptureState(state.saving ? "recording" : "listening", detail: state.detail+(microphoneWarning.isEmpty ? "":" · "+microphoneWarning))
    }

    public func checkpoint() async throws {
        guard let sink,isRecording else {return}
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            sink.queue.async {do {try sink.mixed.checkpoint();continuation.resume()} catch {continuation.resume(throwing:error)}}
        }
    }

    private func releaseLock() {
        if let recordingActivity {ProcessInfo.processInfo.endActivity(recordingActivity);self.recordingActivity=nil}
        if lockFD >= 0 { Darwin.lockf(lockFD, F_ULOCK, 0); Darwin.close(lockFD); lockFD = -1 }
    }
    private func stopStream(_ stream:SCStream) async {
        do {try await CaptureDeadline.perform(seconds:3,message:"系统音停止未响应，需要重新创建采集器") {try await stream.stopCapture()}}
        catch {if error is CaptureOperationTimeout {needsProcessRestart=true}}
    }
    /// A failed system stream must not close the healthy microphone or reset
    /// the mixed writer's clock/journal while it reconnects.
    public func requestSystemReconnect() {
        guard #available(macOS 15,*) else{return}
        guard isRecording,systemRecovery==nil,let output=sink else{return}
        let token=sessionToken,old=stream
        stream=nil;systemWarning="正在恢复系统声音；Mac 麦克风继续保存"
        systemRecovery=Task { @MainActor [weak self] in
            guard let self else{return}
            defer {if self.sessionToken==token {self.systemRecovery=nil}}
            if let old {try? await CaptureDeadline.perform(seconds:3,message:"旧系统音未响应") {try await old.stopCapture()}}
            var attempts=0
            while self.isRecording,self.sessionToken==token,!Task.isCancelled {
                var candidate:SCStream?
                do {
                    guard CGPreflightScreenCaptureAccess() else {throw CaptureFailure.message("系统音权限不可用，请在系统设置中恢复；Mac 麦克风继续保存")}
                    var content:SCShareableContent?
                    try await CaptureDeadline.perform(seconds:15,message:"系统音设备查询未响应") {content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)}
                    guard self.isRecording,self.sessionToken==token,!Task.isCancelled else{return}
                    guard let display=content?.displays.first else {throw CaptureFailure.message("系统音显示源暂不可用；Mac 麦克风继续保存")}
                    let config=SCStreamConfiguration();config.width=2;config.height=2;config.minimumFrameInterval=CMTime(seconds:1,preferredTimescale:1);config.showsCursor=false;config.capturesAudio=true;config.captureMicrophone=false;config.excludesCurrentProcessAudio=true;config.sampleRate=48_000;config.channelCount=2
                    let capture=SCStream(filter:SCContentFilter(display:display,excludingApplications:[],exceptingWindows:[]),configuration:config,delegate:output)
                    candidate=capture
                    self.stream=capture
                    try capture.addStreamOutput(output,type:.audio,sampleHandlerQueue:output.inputQueue)
                    try capture.addStreamOutput(output,type:.screen,sampleHandlerQueue:output.inputQueue)
                    let started=ProcessInfo.processInfo.systemUptime
                    try await CaptureDeadline.perform(seconds:15,message:"系统音重连未响应") {try await capture.startCapture()}
                    guard self.isRecording,self.sessionToken==token,!Task.isCancelled else {try? await CaptureDeadline.perform(seconds:3,message:"取消系统音重连") {try await capture.stopCapture()};return}
                    self.stream=capture
                    for _ in 0..<30 {
                        if self.stream !== capture || (self.activity.telemetry()["system_audio"]?.observedUptime ?? 0)>started {break}
                        try await Task.sleep(for:.milliseconds(100))
                    }
                    guard self.stream === capture,(self.activity.telemetry()["system_audio"]?.observedUptime ?? 0)>started else {throw CaptureFailure.message("系统音重连后未收到真实采样")}
                    self.systemWarning="";self.onDiagnostic?("系统音已恢复；Mac 麦克风和混音会话保持连续");return
                } catch {
                    let value=error as NSError
                    if SystemStreamStopPolicy.isUserStop(domain:value.domain,code:value.code) {self.onUserStopped?();return}
                    if self.sessionToken==token {self.stream=nil;self.systemWarning="系统音恢复中："+error.localizedDescription}
                    if let candidate {try? await CaptureDeadline.perform(seconds:3,message:"清理失败系统音") {try await candidate.stopCapture()}}
                    attempts+=1
                    do {try await Task.sleep(for:.seconds(min(30,pow(2,Double(min(attempts-1,5))))))} catch{return}
                }
            }
        }
    }

}


enum SystemStreamStopPolicy {
    // SCError.h: -3817 is explicit user stop; -3821 is a system interruption.
    static func isUserStop(domain:String,code:Int)->Bool {domain=="com.apple.ScreenCaptureKit.SCStreamErrorDomain" && code == -3817}
}
