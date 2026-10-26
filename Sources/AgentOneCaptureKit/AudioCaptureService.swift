@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Darwin
@preconcurrency import ScreenCaptureKit

public final class CaptureMetadata: @unchecked Sendable {
    private let lock = NSLock()
    private var place: String?
    private var context = "{}"
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
    func snapshot() -> (String?, String) { lock.lock(); defer { lock.unlock() }; return (place,context) }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

private struct OwnedAudioPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let presentationSeconds: Double
}

private final class AudioStreamSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "life.agentone.audio-writer", qos: .utility)
    let mixed: MixedAudioWriter
    let activity: CaptureActivityMeter
    let decisionStatus: RecordingDecisionStatus
    let database: MemoryDatabase
    let onFailure: @Sendable (String) -> Void
    private var timer: DispatchSourceTimer?
    fileprivate var failed = false
    init(database: MemoryDatabase, metadata: CaptureMetadata, activity: CaptureActivityMeter, decisionStatus: RecordingDecisionStatus, onFailure: @escaping @Sendable (String) -> Void) {
        let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        mixed = MixedAudioWriter(database:database,sessionID:UUID().uuidString,wallAnchor:Date(),hostAnchor:host,decisionStatus:decisionStatus,onActivity:{activity.observe($0,source:"mixed")},metadata:{metadata.snapshot()})
        self.database=database;self.decisionStatus=decisionStatus;self.activity=activity;self.onFailure=onFailure
    }
    func beginMixing() {
        queue.async {
            guard !self.failed else {return}
            let timer=DispatchSource.makeTimerSource(queue:self.queue)
            timer.schedule(deadline:.now(),repeating:.milliseconds(100),leeway:.milliseconds(15))
            timer.setEventHandler { [weak self] in
                guard let self,!self.failed else {return}
                do {try self.mixed.flush(throughHostSeconds:CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))-MixedAudioWriter.latency)}
                catch {self.failed=true;self.onFailure("混合录音已停止："+error.localizedDescription)}
            }
            self.timer=timer;timer.resume()
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !failed,type == .audio else {return}
        do {
            if let packet=try AudioTrackWriter.decodePCM(sampleBuffer) {
                activity.observe(AudioActivityReading.measure(packet.buffer),source:"system_audio")
                try mixed.append(packet.buffer,source:"system_audio",presentationSeconds:packet.presentationSeconds)
            }
        } catch {failed=true;onFailure("系统声音混音失败："+error.localizedDescription)}
    }
    func enqueueMicrophone(_ buffer: AVAudioPCMBuffer, presentationSeconds: Double) {
        let packet=OwnedAudioPacket(buffer:buffer,presentationSeconds:presentationSeconds)
        queue.async {
            guard !self.failed else {return}
            do {
                self.activity.observe(AudioActivityReading.measure(packet.buffer),source:"microphone")
                try self.mixed.append(packet.buffer,source:"microphone",presentationSeconds:packet.presentationSeconds)
            } catch {self.failed=true;self.onFailure("麦克风混音失败："+error.localizedDescription)}
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure("系统音频流已中断，请检查设备或系统授权后继续。") }
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
@MainActor public final class AudioCaptureService {
    public private(set) var isRecording = false
    public private(set) var automaticDecisions = true
    public private(set) var preserveAllAudio = false
    public private(set) var microphoneWarning = ""
    public let metadata = CaptureMetadata()
    public let activity = CaptureActivityMeter()
    public private(set) var decisionStatus = RecordingDecisionStatus()
    public private(set) var sessionToken = UUID()
    private let database: MemoryDatabase
    private var stream: SCStream?
    private var sink: AudioStreamSink?
    private var microphoneInput: MicrophoneInput?
    private var lockFD: Int32 = -1
    private var stoppingTask: Task<Void, Error>?
    public var onFailure: (@MainActor @Sendable (String) -> Void)?

    public init(database: MemoryDatabase) { self.database = database }

    public func start(allowPermissionPrompts: Bool,automaticDecisions:Bool=true,preserveAllAudio:Bool=false) async throws {
        if let stoppingTask { try await stoppingTask.value }
        guard !isRecording, stream == nil else { return }
        guard #available(macOS 15, *) else { throw CaptureFailure.message("双路原生录音需要 macOS 15 或更新版本") }
        lockFD = Darwin.open(database.root.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, Darwin.lockf(lockFD, F_TLOCK, 0) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
            throw CaptureFailure.message("另一采集进程正在使用这个 Memory 目录")
        }
        do {
            let microphoneAllowed: Bool
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { microphoneAllowed = true }
            else if allowPermissionPrompts { microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio) }
            else { microphoneAllowed = false }
            guard microphoneAllowed else { throw CaptureFailure.message("请在系统设置中允许 AgentOne 使用麦克风") }
            if !allowPermissionPrompts, !CGPreflightScreenCaptureAccess() {
                throw CaptureFailure.message("系统音权限不可用；请手动继续录音以检查授权")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw CaptureFailure.message("没有可用显示器，无法启动系统音采集") }
            try database.recoverInterruptedSegments()
            self.automaticDecisions=automaticDecisions && !preserveAllAudio;self.preserveAllAudio=preserveAllAudio
            activity.reset();decisionStatus=RecordingDecisionStatus(manual:!automaticDecisions && !preserveAllAudio,preserveAllAudio:preserveAllAudio);sessionToken=UUID()
            let output = AudioStreamSink(database: database, metadata: metadata, activity: activity, decisionStatus:decisionStatus) { [weak self] message in
                Task { @MainActor in self?.onFailure?(message) }
            }
            let configuration = SCStreamConfiguration()
            configuration.width = 2; configuration.height = 2
            configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
            configuration.showsCursor = false
            configuration.capturesAudio = true; configuration.captureMicrophone = false
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000; configuration.channelCount = 2
            let capture = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), configuration: configuration, delegate: output)
            try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            // Consume/discard tiny screen frames to avoid SCStream output errors; never save them.
            try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            sink = output; stream = capture
            output.beginMixing()
            try await capture.startCapture()
            microphoneWarning=""
            let microphoneSession=sessionToken
            let microphone = MicrophoneInput(deliver: { buffer,pts in output.enqueueMicrophone(buffer,presentationSeconds: pts) },fail: { [weak self] message in
                Task { @MainActor in self?.onFailure?(message) }
            },hasSamples:{output.activity.hasSamples(source:"microphone",maxAge:3)},warning:{ [weak self] message in
                Task { @MainActor in
                    guard let self,self.isRecording,self.sessionToken==microphoneSession else {return}
                    self.microphoneWarning=message
                }
            })
            microphoneInput = microphone
            try microphone.start()
            let failed=output.queue.sync {output.failed}
            guard !failed,sink === output else {throw CaptureFailure.message("音频在启动期间中断，请重试")}
            try database.execute("UPDATE coverage SET ended_ms=? WHERE ended_ms IS NULL", [MemoryDatabase.now])
            isRecording = true
            try database.setCaptureState(self.automaticDecisions ? "listening":"recording", detail:decisionStatus.snapshot.detail)
        } catch {
            isRecording = false
            microphoneInput?.stop(); microphoneInput = nil
            if let stream { try? await stream.stopCapture() }
            if let sink { try? await sink.finish() }
            stream = nil; sink = nil; releaseLock()
            try? database.setCaptureState("error", detail: "capture_start_failed")
            throw error
        }
    }

    public func stop(reason: String = "user_paused") async throws {
        if let stoppingTask { try await stoppingTask.value; return }
        let task = Task { @MainActor in try await self.performStop(reason: reason) }
        stoppingTask = task
        defer { stoppingTask = nil }
        try await task.value
    }

    private func performStop(reason: String) async throws {
        let wasRecording = isRecording
        activity.reset()
        microphoneInput?.stop(); microphoneInput = nil
        isRecording = false
        if let stream { try? await stream.stopCapture() }
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
                let state=sink.decisionStatus.snapshot
                let value:[String:Any]=["effect":preserve ? "annotate_only":"capture_gate","model":"convaiinnovations/laya/multilingual","choice":decision?.choice ?? "unavailable","answer_probability":decision?.confidence ?? 0,"saving":state.saving,"quiet_seconds":evidence.quietSeconds,"inputs_ready":evidence.inputsReady,"sound_confirmed":evidence.sustainedSound,"active_fraction":evidence.activeFraction,"ready_sources":evidence.readySources,"observed_ms":MemoryDatabase.now]
                let json=String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
                try sink.database.execute("INSERT INTO meta VALUES ('capture_decision',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[json])
            }
            catch {sink.onFailure("录音决策切换失败："+error.localizedDescription)}
        }
    }

    public func heartbeat() throws {
        guard isRecording else { return }
        let state=decisionStatus.snapshot
        try database.setCaptureState(state.saving ? "recording" : "listening", detail: state.detail+(microphoneWarning.isEmpty ? "":" · "+microphoneWarning))
    }

    private func releaseLock() {
        if lockFD >= 0 { Darwin.lockf(lockFD, F_ULOCK, 0); Darwin.close(lockFD); lockFD = -1 }
    }
}
