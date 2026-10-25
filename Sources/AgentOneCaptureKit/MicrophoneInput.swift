@preconcurrency import AVFoundation
import CoreMedia
import Foundation

private struct MicrophonePacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let presentationSeconds: Double
}

/// Keep microphone input independent of ScreenCaptureKit's system-audio stream.
/// Both inputs use the CoreAudio host clock before a single mixed stream is saved.
@MainActor final class MicrophoneInput {
    private let engine = AVAudioEngine()
    private var installed = false
    private let deliver: @Sendable (AVAudioPCMBuffer,Double) -> Void
    private let fail: @Sendable (String) -> Void
    init(deliver: @escaping @Sendable (AVAudioPCMBuffer,Double) -> Void,fail: @escaping @Sendable (String) -> Void) {
        self.deliver = deliver; self.fail = fail
    }
    func start() throws {
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
