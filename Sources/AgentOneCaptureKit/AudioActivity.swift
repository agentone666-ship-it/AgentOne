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

/// A volume observation, not a speech/person detector; never gates original audio.
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

public final class CaptureActivityMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSound: [String: TimeInterval] = [:]
    private var lastSample: [String: TimeInterval] = [:]
    private var readings: [String: (Double,TimeInterval)] = [:]
    private var firstSample: TimeInterval?
    public init() {}
    public func observe(_ reading: AudioActivityReading?, source: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let reading,reading.rmsDBFS.isFinite else {return}
        lock.lock(); defer { lock.unlock() }
        lastSample[source] = now
        if firstSample == nil { firstSample = now }
        readings[source] = (reading.rmsDBFS,now)
        if reading.hasSound { lastSound[source] = now }
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
    public func reset() { lock.lock(); defer { lock.unlock() }; lastSound.removeAll(); lastSample.removeAll(); readings.removeAll(); firstSample = nil }
}
