@preconcurrency import AVFoundation
import Foundation

public struct AudioActivityReading: Sendable {
    public let rmsDBFS: Double
    public var hasSound: Bool { rmsDBFS >= -50 }
    public static func measure(_ buffer: AVAudioPCMBuffer) -> AudioActivityReading? {
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        var sum = 0.0
        for channel in 0..<channels {
            for frame in 0..<frames {
                let lane = buffer.format.isInterleaved ? 0 : channel
                let index = buffer.format.isInterleaved ? frame * channels + channel : frame
                let value: Double
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32:
                    guard let data = buffer.floatChannelData else { return nil }; value = Double(data[lane][index])
                case .pcmFormatFloat64:
                    guard let data = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)[lane].mData else { return nil }; value = data.assumingMemoryBound(to: Double.self)[index]
                case .pcmFormatInt16:
                    guard let data = buffer.int16ChannelData else { return nil }; value = Double(data[lane][index]) / 32768
                case .pcmFormatInt32:
                    guard let data = buffer.int32ChannelData else { return nil }; value = Double(data[lane][index]) / 2147483648
                default: return nil
                }
                guard value.isFinite else { return nil }
                sum += value * value
            }
        }
        return AudioActivityReading(rmsDBFS: max(-160,10 * log10(max(sum / Double(frames * channels),1e-16))))
    }
}

/// Volume summary for saved audio, not a speech/person detector. Listening gaps are tracked separately.
public struct AudioActivitySummary: Sendable {
    private(set) var windows = 0
    private(set) var activeWindows = 0
    private(set) var peakRMS = -160.0
    public init() {}
    public mutating func observe(_ reading: AudioActivityReading?) {
        guard let reading else { return }
        windows += 1
        if reading.hasSound { activeWindows += 1 }
        peakRMS = max(peakRMS,reading.rmsDBFS)
    }
    public var json: [String: Any] {
        ["detector":"rms_dbfs","threshold_dbfs": -50,"windows":windows,"active_windows":activeWindows,
         "peak_rms_dbfs":peakRMS,"classification":windows == 0 ? "unknown" : activeWindows > 0 ? "sound" : "quiet",
         "semantic_classification":false,"silence_discarded":false]
    }
}

public struct CaptureStartEvidence:Sendable {
    public let inputsReady:Bool
    public let sustainedSound:Bool
    public let quietSeconds:Double
    public let activeFraction:Double
    public let readySources:[String]
}

public final class CaptureActivityMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSound: [String: TimeInterval] = [:]
    private var lastSample: [String: TimeInterval] = [:]
    private var readings: [String: (Double,TimeInterval)] = [:]
    private var firstSample: TimeInterval?
    private var firstNativeSample:TimeInterval?
    private var lastClearSound:[String:TimeInterval]=[:]
    private struct Bucket {let slot:Int64;var power:Double;var count:Int}
    private var buckets:[String:[Bucket]]=[:]
    private static let startThreshold = -42.0
    public init() {}
    public func observe(_ reading: AudioActivityReading?, source: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let reading,reading.rmsDBFS.isFinite,now.isFinite,now>=0,now<Double(Int64.max)/5 else {return}
        lock.lock(); defer { lock.unlock() }
        if let last=lastSample[source],now<last {return}
        lastSample[source] = now
        if firstSample == nil { firstSample = now }
        readings[source] = (reading.rmsDBFS,now)
        if reading.hasSound { lastSound[source] = now }
        if source=="system_audio" || source=="microphone" {
            if firstNativeSample==nil {firstNativeSample=now}
            if reading.rmsDBFS>=Self.startThreshold {lastClearSound[source]=now}
            let slot=Int64(floor(now*5)),power=pow(10,min(0,reading.rmsDBFS)/10)
            var history=(buckets[source] ?? []).filter {$0.slot>=slot-20}
            if let last=history.last,last.slot==slot {history[history.count-1].power+=power;history[history.count-1].count+=1}
            else {history.append(Bucket(slot:slot,power:power,count:1))}
            buckets[source]=history
        }
    }
    public func hasSound(source: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let observed = lastSound[source] else { return false }
        return now >= observed && now - observed < 3.5
    }
    public func hasSamples(source: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime, maxAge:Double = 10) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let observed = lastSample[source] else { return false }
        return now >= observed && now - observed < maxAge
    }
    /// Actual PCM amplitude with a short release envelope. No periodic or random animation.
    public func level(source: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let (db,time) = readings[source],now >= time else { return 0 }
        return min(1,max(0,(db+60)/54)) * max(0,1-max(0,now-time-0.12)/0.4)
    }
    public func quietSeconds(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        lock.lock(); defer { lock.unlock() }
        let last = lastSound.values.max() ?? firstSample ?? now
        return max(0,now-last)
    }
    /// A 3-second native-input window, not a speech classifier. A single loud click is insufficient.
    public func startEvidence(now:TimeInterval=ProcessInfo.processInfo.systemUptime) -> CaptureStartEvidence {
        lock.lock();defer {lock.unlock()}
        guard now.isFinite,now>=0,now<Double(Int64.max)/5 else {return CaptureStartEvidence(inputsReady:false,sustainedSound:false,quietSeconds:0,activeFraction:0,readySources:[])}
        let slot=Int64(floor(now*5))
        let ready=["system_audio","microphone"].filter {source in
            guard let sample=lastSample[source] else {return false};return now>=sample && now-sample<1
        }
        var sustained=false,fraction=0.0
        for source in ready {
            let window=(buckets[source] ?? []).filter {$0.slot>=slot-14 && $0.slot<=slot}
            let active=window.filter {10*log10(max($0.power/Double($0.count),1e-16))>=Self.startThreshold}.count
            let ratio=Double(active)/15
            fraction=max(fraction,ratio)
            let span=window.first.map {Double(slot-$0.slot)/5} ?? 0
            let recent=lastClearSound[source].map {now >= $0 && now-$0<0.8} ?? false
            if window.count>=13,span>=2.4,ratio>=0.6,recent {sustained=true}
        }
        let last=lastClearSound.values.max() ?? firstNativeSample ?? now
        return CaptureStartEvidence(inputsReady:!ready.isEmpty,sustainedSound:sustained,quietSeconds:max(0,now-last),activeFraction:fraction,readySources:ready)
    }
    public func reset() {lock.lock();defer{lock.unlock()};lastSound.removeAll();lastSample.removeAll();readings.removeAll();firstSample=nil;firstNativeSample=nil;lastClearSound.removeAll();buckets.removeAll()}
}
