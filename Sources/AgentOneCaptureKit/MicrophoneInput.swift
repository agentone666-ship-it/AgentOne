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
                if policy.observe(hasSamples:receiving,now:ProcessInfo.processInfo.systemUptime) {
                    self.warning("麦克风未收到采样，正在自动恢复；电脑声音继续保存")
                    self.stopEngine();self.engine=AVAudioEngine()
                    do {try self.startEngine()} catch {self.warning("麦克风恢复失败；电脑声音继续保存，请检查输入设备")}
                } else if !receiving,policy.attempts>=3 {
                    self.warning("麦克风采样中断，已尝试恢复；电脑声音继续保存，请检查输入设备")
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
        stopEngine()
    }
    private func stopEngine() {
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        engine.stop()
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
