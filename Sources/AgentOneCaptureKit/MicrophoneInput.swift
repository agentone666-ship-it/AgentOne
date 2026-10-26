@preconcurrency import AVFoundation
import CoreMedia
import Foundation

private struct MicrophonePacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let presentationSeconds: Double
}

/// Missing callbacks, not low amplitude, cause recovery. Retry budgets reset only on real input.
struct MicrophoneRecoveryPolicy {
    private(set) var attempts=0
    private var nextRetry:Double
    init(now:Double) {nextRetry=now+6}
    mutating func observe(hasSamples:Bool,now:Double) -> Bool {
        if hasSamples {attempts=0;nextRetry=now+6;return false}
        guard now>=nextRetry,attempts<3 else {return false}
        attempts+=1;nextRetry=now+6;return true
    }
}

/// Keep microphone input independent of ScreenCaptureKit's system-audio stream.
/// Both inputs use the CoreAudio host clock before a single mixed stream is saved.
@MainActor final class MicrophoneInput {
    private var engine = AVAudioEngine()
    private var installed = false
    private var recovery:Task<Void,Never>?
    private var fallback:CaptureSessionMicrophone?
    private var fallbackAttempted=false
    private let hasSamples:@Sendable () -> Bool
    private let warning:@Sendable (String) -> Void
    private let deliver: @Sendable (AVAudioPCMBuffer,Double) -> Void
    private let fail: @Sendable (String) -> Void
    init(deliver: @escaping @Sendable (AVAudioPCMBuffer,Double) -> Void,fail: @escaping @Sendable (String) -> Void,hasSamples:@escaping @Sendable () -> Bool,warning:@escaping @Sendable (String) -> Void) {
        self.deliver = deliver; self.fail = fail;self.hasSamples=hasSamples;self.warning=warning
    }
    func start() throws {
        try startEngine()
        recovery=Task { [weak self] in
            var policy=MicrophoneRecoveryPolicy(now:ProcessInfo.processInfo.systemUptime)
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(3))} catch {return}
                guard let self,!Task.isCancelled else {return}
                let receiving=self.hasSamples()
                if receiving {self.warning("")}
                if self.fallbackAttempted {
                    if !receiving {self.warning("麦克风仍未收到采样，请检查输入设备；电脑声音继续保存")}
                    continue
                }
                if policy.observe(hasSamples:receiving,now:ProcessInfo.processInfo.systemUptime) {
                    self.warning("麦克风未收到采样，正在自动恢复；电脑声音继续保存")
                    self.stopEngine();self.engine=AVAudioEngine()
                    do {try self.startEngine()} catch {self.warning("麦克风恢复失败；电脑声音继续保存，请检查输入设备")}
                } else if !receiving,policy.attempts>=3 {
                    if !self.fallbackAttempted {
                        self.fallbackAttempted=true
                        self.stopEngine()
                        do {
                            let capture=try CaptureSessionMicrophone(deliver:self.deliver,fail:self.fail)
                            self.fallback=capture;capture.start()
                            self.warning("正在切换麦克风采集通道；电脑声音继续保存")
                        } catch {self.warning("麦克风采样中断，请检查输入设备；电脑声音继续保存")}
                    }
                }
            }
        }
    }
    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0,format.sampleRate > 0 else { throw CaptureFailure.message("麦克风没有可用输入，请检查输入设备") }
        let deliver = self.deliver, fail = self.fail
        input.installTap(onBus: 0,bufferSize: 4096,format: format,block: makeMicrophoneTap(deliver: deliver,fail: fail))
        installed = true
        engine.prepare()
        try engine.start()
    }
    func stop() {
        recovery?.cancel();recovery=nil
        fallback?.stop();fallback=nil
        stopEngine()
    }
    private func stopEngine() {
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        engine.stop()
    }
}

/// Independent audio-only fallback when the engine's tap never resumes after a route change.
/// Capture-session timestamps are explicitly converted to the mixer's host clock.
private final class CaptureSessionMicrophone:NSObject,AVCaptureAudioDataOutputSampleBufferDelegate,@unchecked Sendable {
    private let session=AVCaptureSession()
    private let queue=DispatchQueue(label:"life.agentone.microphone-fallback")
    private let deliver:@Sendable (AVAudioPCMBuffer,Double) -> Void
    private let fail:@Sendable (String) -> Void
    init(deliver:@escaping @Sendable (AVAudioPCMBuffer,Double) -> Void,fail:@escaping @Sendable (String) -> Void) throws {
        self.deliver=deliver;self.fail=fail;super.init()
        guard let device=AVCaptureDevice.default(for:.audio) else {throw CaptureFailure.message("没有可用麦克风")}
        let input=try AVCaptureDeviceInput(device:device),output=AVCaptureAudioDataOutput()
        guard session.canAddInput(input),session.canAddOutput(output) else {throw CaptureFailure.message("麦克风采集通道不可用")}
        session.beginConfiguration();session.addInput(input);session.addOutput(output);session.commitConfiguration()
        output.setSampleBufferDelegate(self,queue:queue)
    }
    func start() {queue.async {self.session.startRunning()}}
    func stop() {queue.async {self.session.stopRunning()}}
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        do {
            guard let packet=try AudioTrackWriter.decodePCM(sampleBuffer),let clock=session.synchronizationClock else {return}
            let pts=CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),from:clock,to:CMClockGetHostTimeClock())
            deliver(packet.buffer,CMTimeGetSeconds(pts))
        } catch {fail("麦克风备用通道采样失败："+error.localizedDescription)}
    }
}

// This closure is intentionally constructed outside MainActor. CoreAudio invokes
// AVAudioNodeTapBlock on its realtime messenger queue, never on the UI executor.
func makeMicrophoneTap(deliver: @escaping @Sendable (AVAudioPCMBuffer,Double) -> Void,
                               fail: @escaping @Sendable (String) -> Void) -> AVAudioNodeTapBlock {
    { buffer,when in

            guard when.isHostTimeValid,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,frameCapacity: buffer.frameLength) else {
                fail("麦克风采样或主机时间不可用，已停止记录"); return
            }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            guard source.count == target.count else { fail("麦克风格式发生变化，请恢复记录"); return }
            for index in source.indices {
                guard let from = source[index].mData, let to = target[index].mData,
                      target[index].mDataByteSize >= source[index].mDataByteSize else { fail("麦克风缓冲格式不可用"); return }
                memcpy(to,from,Int(source[index].mDataByteSize))
            }
            // The tap's buffer is reused by CoreAudio; deliver only our owned copy.
            let packet = MicrophonePacket(buffer: copy,presentationSeconds: AVAudioTime.seconds(forHostTime: when.hostTime))
            deliver(packet.buffer,packet.presentationSeconds)
    }
}
