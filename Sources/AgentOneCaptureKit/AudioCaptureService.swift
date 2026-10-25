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
    public func update(place: String?, application: String?, bundleID: String?) {
        lock.lock(); defer { lock.unlock() }
        self.place = place?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let value: [String: Any] = ["application": application ?? NSNull(), "bundle_identifier": bundleID ?? NSNull(),
            "observed_at": ISO8601DateFormatter().string(from: Date()), "place_source": self.place == nil ? "unknown" : "user_annotation"]
        context = (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    func snapshot() -> (String?, String) { lock.lock(); defer { lock.unlock() }; return (place,context) }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

private final class AudioStreamSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "life.agentone.audio-writer", qos: .utility)
    let system: AudioTrackWriter
    let microphone: AudioTrackWriter
    let onFailure: @Sendable (String) -> Void
    private var failed = false
    init(database: MemoryDatabase, metadata: CaptureMetadata, onFailure: @escaping @Sendable (String) -> Void) {
        let sessionID = UUID().uuidString
        let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let wall = Date()
        system = AudioTrackWriter(database: database, source: "system_audio", sessionID: sessionID, wallAnchor: wall, hostAnchor: host, metadata: { metadata.snapshot() })
        microphone = AudioTrackWriter(database: database, source: "microphone", sessionID: sessionID, wallAnchor: wall, hostAnchor: host, metadata: { metadata.snapshot() })
        self.onFailure = onFailure
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !failed else { return }
        do {
            if type == .audio { try system.consume(sampleBuffer) }
            else if #available(macOS 15, *), type == .microphone { try microphone.consume(sampleBuffer) }
        } catch { failed = true; onFailure("音频保存失败，录音已停止。请检查磁盘空间和 Memory 路径。") }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure("系统音频流已中断，请检查设备或系统授权后继续。") }
    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.failed = true // Late callbacks cannot reopen a sealed track.
                do { try self.system.finish(); try self.microphone.finish(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Native capture lifecycle only. It has no model credentials, chat or Agent tools.
@MainActor public final class AudioCaptureService {
    public private(set) var isRecording = false
    public let metadata = CaptureMetadata()
    private let database: MemoryDatabase
    private var stream: SCStream?
    private var sink: AudioStreamSink?
    private var lockFD: Int32 = -1
    private var stoppingTask: Task<Void, Error>?
    public var onFailure: (@MainActor @Sendable (String) -> Void)?

    public init(database: MemoryDatabase) { self.database = database }

    public func start(allowPermissionPrompts: Bool) async throws {
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
            let output = AudioStreamSink(database: database, metadata: metadata) { [weak self] message in
                Task { @MainActor in self?.onFailure?(message) }
            }
            let configuration = SCStreamConfiguration()
            configuration.width = 2; configuration.height = 2
            configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
            configuration.showsCursor = false
            configuration.capturesAudio = true; configuration.captureMicrophone = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000; configuration.channelCount = 2
            let capture = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), configuration: configuration, delegate: output)
            try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try capture.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
            sink = output; stream = capture
            try await capture.startCapture()
            try database.execute("UPDATE coverage SET ended_ms=? WHERE ended_ms IS NULL", [MemoryDatabase.now])
            isRecording = true
            try database.setCaptureState("recording", detail: "system_audio+microphone")
        } catch {
            isRecording = false
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

    public func heartbeat() throws {
        guard isRecording else { return }
        try database.setCaptureState("recording", detail: "system_audio+microphone")
    }

    private func releaseLock() {
        if lockFD >= 0 { Darwin.lockf(lockFD, F_ULOCK, 0); Darwin.close(lockFD); lockFD = -1 }
    }
}
