@preconcurrency import AVFoundation
import CoreMedia
import CoreAudio
import Foundation

private struct MicrophonePacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let presentationSeconds: Double
}

/// Match AVFoundation's unique ID to a real built-in CoreAudio input. Names,
/// default routes and Bluetooth devices are never used to guess the microphone.
enum BuiltInMicrophone {
    static func device() throws -> AVCaptureDevice {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var bytes:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&bytes)==noErr else {throw CaptureFailure.message("无法读取 Mac 内置麦克风")}
        var devices=[AudioDeviceID](repeating:0,count:Int(bytes)/MemoryLayout<AudioDeviceID>.size)
        let status=devices.withUnsafeMutableBytes {AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&bytes,$0.baseAddress!)}
        guard status==noErr else {throw CaptureFailure.message("无法读取 Mac 音频设备")}
        var builtInUIDs=Set<String>()
        for id in devices {
            var transport:UInt32=0,size=UInt32(MemoryLayout<UInt32>.size)
            var key=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyTransportType,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id,&key,0,nil,&size,&transport)==noErr,transport==kAudioDeviceTransportTypeBuiltIn else {continue}
            key=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioDevicePropertyScopeInput,mElement:kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyDataSize(id,&key,0,nil,&size)==noErr,size>0 else {continue}
            key=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceUID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var uid:CFString?;size=UInt32(MemoryLayout<CFString?>.size)
            if AudioObjectGetPropertyData(id,&key,0,nil,&size,&uid)==noErr,let uid {builtInUIDs.insert(uid as String)}
        }
        let microphones=AVCaptureDevice.DiscoverySession(deviceTypes:[.microphone],mediaType:.audio,position:.unspecified).devices
        guard let microphone=microphones.first(where:{builtInUIDs.contains($0.uniqueID)}) else {throw CaptureFailure.message("Mac 内置麦克风不可用；不会使用耳机麦克风")}
        return microphone
    }
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
    private var capture:CaptureSessionMicrophone?
    private var recovery:Task<Void,Never>?
    private let hasSamples:@Sendable () -> Bool
    private let warning:@Sendable (String) -> Void
    private let deliver:@Sendable (AVAudioPCMBuffer,Double) -> Void
    private let fail:@Sendable (String) -> Void
    init(deliver:@escaping @Sendable (AVAudioPCMBuffer,Double) -> Void,fail:@escaping @Sendable (String) -> Void,hasSamples:@escaping @Sendable () -> Bool,warning:@escaping @Sendable (String) -> Void) {
        self.deliver=deliver;self.fail=fail;self.hasSamples=hasSamples;self.warning=warning
    }
    func start() throws {
        try startBuiltInCapture()
        recovery=Task { [weak self] in
            var policy=MicrophoneRecoveryPolicy(now:ProcessInfo.processInfo.systemUptime)
            var exhaustedAt:Double?
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(3))} catch {return}
                guard let self,!Task.isCancelled else {return}
                let receiving=self.hasSamples(),now=ProcessInfo.processInfo.systemUptime
                if receiving {self.warning("");exhaustedAt=nil}
                if policy.observe(hasSamples:receiving,now:now) {
                    self.warning("Mac 内置麦克风未收到采样，正在自动恢复；电脑声音继续保存")
                    self.capture?.stop();self.capture=nil
                    do {try self.startBuiltInCapture()} catch {self.warning("Mac 内置麦克风恢复失败；不会切换到耳机麦克风")}
                } else if !receiving,policy.attempts>=3 {
                    self.warning("Mac 内置麦克风未就绪；电脑声音继续保存，稍后重试")
                    if exhaustedAt==nil {exhaustedAt=now}
                    if now-(exhaustedAt ?? now)>=30 {policy=MicrophoneRecoveryPolicy(now:now);exhaustedAt=nil}
                }
            }
        }
    }
    private func startBuiltInCapture() throws {
        let microphone=try CaptureSessionMicrophone(deliver:deliver,fail:fail)
        capture=microphone;microphone.start()
    }
    func stop() {recovery?.cancel();recovery=nil;capture?.stop();capture=nil}

}

/// Explicit built-in audio input. Headphones never become a microphone fallback.
/// Capture-session timestamps are explicitly converted to the mixer's host clock.
private final class CaptureSessionMicrophone:NSObject,AVCaptureAudioDataOutputSampleBufferDelegate,@unchecked Sendable {
    private let session=AVCaptureSession()
    private let queue=DispatchQueue(label:"life.agentone.microphone-fallback")
    private let deliver:@Sendable (AVAudioPCMBuffer,Double) -> Void
    private let fail:@Sendable (String) -> Void
    init(deliver:@escaping @Sendable (AVAudioPCMBuffer,Double) -> Void,fail:@escaping @Sendable (String) -> Void) throws {
        self.deliver=deliver;self.fail=fail;super.init()
        let device=try BuiltInMicrophone.device()
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
