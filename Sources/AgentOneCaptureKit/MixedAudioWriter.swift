@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// A bounded, host-clock mixer. Input buffers never become separate files.
/// All methods run on the capture sink's serial writer queue.
public final class MixedAudioWriter: @unchecked Sendable {
    public static let sampleRate = 48_000.0
    public static let latency = 1.5
    private static let blockFrames = 960
    private struct Block {
        var system = [Float](repeating: 0,count: blockFrames*2)
        var microphone = [Float](repeating: 0,count: blockFrames)
        var presence = [UInt8](repeating: 0,count: blockFrames)
    }
    private let database: MemoryDatabase
    private let wall: Date
    private let host: Double
    private let sessionID: String
    private let segmentSeconds: Double
    private let discardSilence: Bool
    private let metadata: @Sendable () -> (String?,String)
    private let onActivity: @Sendable (AudioActivityReading?) -> Void
    private let decisionStatus: RecordingDecisionStatus?
    private var blocks: [Int64:Block] = [:]
    private var cursor: Int64?
    private var latest: Int64 = 0
    private var inputEnds:[String:Int64]=[:]
    private var written = false
    private var closed = false
    private var activityLabel="unknown"
    private var activityCandidate="unknown"
    private var activityVotes=0
    private var lastModelBoundary:Double?
    private var modelActivity:[String:Any]=[:]
    /// A cut only seals a file; the next PCM buffer is always written with its original timestamp.
    public func annotateActivity(_ decision:RecordingDecision?,evidence:CaptureStartEvidence) throws {
        guard !closed,decisionStatus?.preserveAllAudio==true else {return}
        let valid=decision.map {$0.confidence.isFinite && $0.confidence>=0.75 && $0.confidence<=1} ?? false
        let label = !evidence.inputsReady || !valid ? "unknown" : evidence.sustainedSound && decision?.choice=="record" ? "sound" : !evidence.sustainedSound && decision?.choice=="wait" ? "quiet":"uncertain"
        let position=host+Double(cursor ?? 0)/Self.sampleRate
        modelActivity=["label":label,"model":"laya-multilingual","confidence":valid ? decision!.confidence:0,"observed_at":ISO8601DateFormatter().string(from:wall.addingTimeInterval(position-host)),"scope":"last_activity_observation_not_segment_summary"]
        if label==activityCandidate {activityVotes+=1} else {activityCandidate=label;activityVotes=1}
        if valid,label != "unknown",activityVotes>=2,label != activityLabel {
            if activityLabel != "unknown",position-(lastModelBoundary ?? host)>=15 {try writer.finish();lastModelBoundary=position}
            activityLabel=label
        }
        decisionStatus?.update(saving:true,detail:label=="sound" ? "持续保全中 · Laya 标记有声活动":label=="quiet" ? "持续保全中 · Laya 标记安静片段":"持续保全中 · 模型标记待确认")
    }
    private var lateFrames: [String:Int64] = [:]
    private var missingStarts: [String:Int64] = [:]
    private var sourceFrames: [String:Int64] = [:]
    private var unavailableFrames: [String:Int64] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate:sampleRate,channels:2)!
    private lazy var writer = AudioTrackWriter(database:database,source:"mixed",sessionID:sessionID,wallAnchor:wall,hostAnchor:host,segmentSeconds:segmentSeconds,discardSilence:discardSilence,
        finishingContext: { [weak self] in self?.mixingContext() ?? "{}" },metadata:metadata)
    private lazy var gate = decisionStatus.map { status in RecordingGate(status:status,
        write:{[unowned self] buffer,pts in try self.writer.append(buffer,presentationSeconds:pts)},
        seal:{[unowned self] in try self.writer.finish()},
        gap:{[unowned self] start,end in try self.database.addGap(started:self.wall.addingTimeInterval(start-self.host),ended:self.wall.addingTimeInterval(end-self.host),source:"mixed",reason:"automatic_wait")}) }
    public func applyDecision(_ decision:RecordingDecision?,quietSeconds:Double,inputsReady:Bool,soundConfirmed:Bool) throws {
        guard !closed,decisionStatus?.preserveAllAudio != true else {return}
        // The last emitted output is behind the device clock by the jitter buffer.
        try gate?.apply(decision,quietSeconds:quietSeconds,inputsReady:inputsReady,soundConfirmed:soundConfirmed,now:host+Double(cursor ?? 0)/Self.sampleRate)
    }
    public var sealedCount: Int { writer.sealedCount }

    public init(database:MemoryDatabase,sessionID:String,wallAnchor:Date,hostAnchor:Double,segmentSeconds:Double = 60,discardSilence:Bool = false,decisionStatus:RecordingDecisionStatus? = nil,onActivity:@escaping @Sendable (AudioActivityReading?) -> Void = {_ in},metadata:@escaping @Sendable () -> (String?,String) = {(nil,"{}")}) {
        self.onActivity=onActivity;self.decisionStatus=decisionStatus;self.database=database;self.sessionID=sessionID;wall=wallAnchor;host=hostAnchor;self.segmentSeconds=segmentSeconds;self.metadata=metadata
        self.discardSilence=discardSilence
    }
    public func consume(_ sample:CMSampleBuffer,source:String) throws {
        if let packet=try AudioTrackWriter.decodePCM(sample) {try append(packet.buffer,source:source,presentationSeconds:packet.presentationSeconds)}
    }
    public func append(_ buffer:AVAudioPCMBuffer,source:String,presentationSeconds pts:Double) throws {
        guard !closed else {return}
        guard source=="system_audio" || source=="microphone",pts.isFinite,
              buffer.format.sampleRate>0,buffer.frameLength>0 else {throw CaptureFailure.message("混音输入或时间戳无效")}
        let rate=buffer.format.sampleRate,frames=Int(buffer.frameLength),channels=Int(buffer.format.channelCount)
        guard channels>0,channels<=32,Double(frames)/rate<=4,abs(pts-host)<1e9 else {throw CaptureFailure.message("混音输入格式或时间跨度无效")}
        let start=Int64(ceil((pts-host)*Self.sampleRate-0.001))
        let end=Int64(ceil((pts-host+Double(frames)/rate)*Self.sampleRate-0.001))
        guard end>0 else {return} // Samples from before this recording session.
        if cursor==nil {cursor=max(0,start)}
        if !written {cursor=min(cursor!,max(0,start))}
        if end-(cursor ?? 0)>Int64(Self.sampleRate*8) {
            let arrival=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            // A delayed timer/slow device start is not a clock jump. Catch up on the
            // timestamp of this packet, leaving the same jitter window for the other input.
            if pts<=arrival+1,pts>=arrival-30 {try flush(throughHostSeconds:pts-Self.latency)}
        }
        guard end-(cursor ?? 0)<=Int64(Self.sampleRate*8) else {
            let lag=Double(end-(cursor ?? 0))/Self.sampleRate
            let clock=pts-CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            throw CaptureFailure.message(String(format:"音频时钟异常（缓冲 %.1f 秒，时差 %.1f 秒），已停止以免混错时间",lag,clock))
        }
        let first=max(max(0,start),cursor ?? 0)
        lateFrames[source,default:0] += max(0,min(end,cursor ?? 0)-max(0,start))
        guard first<end else {return}
        let bit:UInt8=source=="system_audio" ? 1:2
        let list=UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        func value(_ frame:Int,_ channel:Int) throws -> Double {
            let lane=buffer.format.isInterleaved ? 0:channel
            let index=buffer.format.isInterleaved ? frame*channels+channel:frame
            guard lane<list.count,let data=list[lane].mData else {throw CaptureFailure.message("混音输入数据缺失")}
            let sample:Double
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:sample=Double(data.assumingMemoryBound(to:Float.self)[index])
            case .pcmFormatFloat64:sample=data.assumingMemoryBound(to:Double.self)[index]
            case .pcmFormatInt16:sample=Double(data.assumingMemoryBound(to:Int16.self)[index])/32768
            case .pcmFormatInt32:sample=Double(data.assumingMemoryBound(to:Int32.self)[index])/2147483648
            default:throw CaptureFailure.message("混音暂不支持此 PCM 格式")
            }
            return sample.isFinite ? min(1,max(-1,sample)):0
        }
        var index=first
        while index<end {
            let key=index/Int64(Self.blockFrames),offset=Int(index%Int64(Self.blockFrames))
            let count=min(Int(end-index),Self.blockFrames-offset)
            var block=blocks[key] ?? Block()
            for n in 0..<count {
                let position=max(0,(Double(index+Int64(n))/Self.sampleRate-(pts-host))*rate)
                let left=min(frames-1,Int(position)),right=min(frames-1,left+1),fraction=min(1,position-Double(left))
                func resampled(_ channel:Int) throws -> Float {
                    let a=try value(left,channel),b=try value(right,channel)
                    return Float(a+(b-a)*fraction)
                }
                if bit==1 {
                    // Keep system left/right spatial content; both final channels also receive microphone.
                    block.system[(offset+n)*2]=try resampled(0)
                    block.system[(offset+n)*2+1]=try resampled(channels>1 ? 1:0)
                } else {
                    var mono:Float=0
                    for channel in 0..<channels {mono += try resampled(channel)}
                    block.microphone[offset+n]=mono/Float(channels)
                }
                block.presence[offset+n] |= bit
            }
            blocks[key]=block;index += Int64(count)
        }
        sourceFrames[source,default:0] += end-first
        inputEnds[source]=max(inputEnds[source] ?? 0,end)
        latest=max(latest,end)
    }

    /// Release frames only after the jitter window; absent inputs are zero, never time-compressed.
    public func flushAvailable(throughHostSeconds cutoff:Double) throws {
        // A busy writer queue must not advance its cursor past PCM callbacks still queued
        // behind the timer. The packet watermark advances only after append has consumed data.
        guard latest>0 else {return}
        // Let both input queues reach a frame before sealing it. When an input
        // actually stalls for >3 seconds, continue the other stream with an
        // explicit missing-input interval rather than stop preserving audio.
        let active=inputEnds.values.filter {latest-$0<Int64(Self.sampleRate*3)}
        let watermark=active.min() ?? latest
        try flush(throughHostSeconds:min(cutoff,host+Double(watermark)/Self.sampleRate-Self.latency))
    }
    public func checkpoint() throws {try writer.finish()}
    public func flush(throughHostSeconds cutoff:Double) throws {
        guard !closed,let start=cursor,cutoff.isFinite else {return}
        let end=Int64(floor((cutoff-host)*Self.sampleRate+0.001))
        guard end>start else {return}
        guard end-start<=Int64(Self.sampleRate*30) else {throw CaptureFailure.message("混音写入延迟过大，已停止以保留缺口信息")}
        var position=start
        while position<end {
            let count=min(4800,Int(end-position))
            guard let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count)) else {throw CaptureFailure.message("无法分配混音缓冲")}
            buffer.frameLength=AVAudioFrameCount(count)
            for n in 0..<count {
                let frame=position+Int64(n),key=frame/Int64(Self.blockFrames),offset=Int(frame%Int64(Self.blockFrames))
                let block=blocks[key]
                buffer.floatChannelData![0][n]=0.5*(block?.system[offset*2] ?? 0)+0.5*(block?.microphone[offset] ?? 0)
                buffer.floatChannelData![1][n]=0.5*(block?.system[offset*2+1] ?? 0)+0.5*(block?.microphone[offset] ?? 0)
                let mask=block?.presence[offset] ?? 0
                for (source,bit) in [("system_audio",UInt8(1)),("microphone",UInt8(2))] {
                    if mask&bit==0 {unavailableFrames[source,default:0] += 1;if missingStarts[source]==nil {missingStarts[source]=frame}}
                    else if let missing=missingStarts.removeValue(forKey:source) {try gap(source:source,start:missing,end:frame)}
                }
                if offset==Self.blockFrames-1 {blocks.removeValue(forKey:key)}
            }
            onActivity(AudioActivityReading.measure(buffer))
            let pts=host+Double(position)/Self.sampleRate
            if let gate {try gate.consume(buffer,pts:pts)} else {try writer.append(buffer,presentationSeconds:pts)}
            written=true;position += Int64(count);cursor=position
        }
    }
    public func finish(throughHostSeconds cutoff:Double? = nil) throws {
        guard !closed else {return}
        if cursor != nil {
            let end=max(latest,cursor ?? 0)
            try flush(throughHostSeconds:host+Double(end)/Self.sampleRate)
            for (source,start) in missingStarts {try gap(source:source,start:start,end:end)}
            if let cutoff,cutoff>host+Double(end)/Self.sampleRate+0.01 {
                try database.addGap(started:wall.addingTimeInterval(Double(end)/Self.sampleRate),ended:wall.addingTimeInterval(cutoff-host),source:"all",reason:"inputs_stopped_before_close")
            }
        }
        if let gate {try gate.finish(now:host+Double(cursor ?? 0)/Self.sampleRate)} else {try writer.finish()};closed=true;blocks.removeAll();missingStarts.removeAll()
        try database.execute("INSERT INTO meta VALUES ('mixed_input_stats',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[mixingContext()])
    }
    private func gap(source:String,start:Int64,end:Int64) throws {
        guard end-start>=480 else {return} // Persist gaps >=10 ms; every absent frame remains in cumulative statistics.
        try database.addGap(started:wall.addingTimeInterval(Double(start)/Self.sampleRate),ended:wall.addingTimeInterval(Double(end)/Self.sampleRate),source:source,reason:"mixed_input_no_samples")
    }
    private func mixingContext() -> String {
        let value:[String:Any] = ["laya_activity":modelActivity,"decision_policy":decisionStatus == nil ? "continuous" : decisionStatus!.preserveAllAudio ? "continuous_preservation":decisionStatus!.manual ? "manual_continuous":"laya_with_confirmed_activity","recording_mode":"mixed","inputs":["system_audio","microphone"],"mixing":["sample_rate":Self.sampleRate,"channels":2,"system_gain":0.5,"microphone_gain":0.5,"jitter_buffer_seconds":Self.latency,"late_frames":lateFrames,"input_frames":sourceFrames,"unavailable_input_frames":unavailableFrames,"statistics_scope":"session_cumulative","resampling":"host_timestamp_linear","echo_cancellation":false]]
        return (try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])).map {String(decoding:$0,as:UTF8.self)} ?? "{}"
    }
}
