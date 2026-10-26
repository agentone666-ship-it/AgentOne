@preconcurrency import AVFoundation
import Foundation

public struct RecordingDecision: Codable, Sendable {
    public let choice: String
    public let confidence: Double
    public init(choice: String, confidence: Double) { self.choice=choice;self.confidence=confidence }
}

/// Shared UI snapshot; the audio queue alone mutates the gate and its pre-roll.
public final class RecordingDecisionStatus: @unchecked Sendable {
    private let lock=NSLock()
    private var saving=false
    private var detail="自动听候 · 等待持续声音"
    public let manual:Bool
    public let preserveAllAudio:Bool
    public init(manual:Bool=false,preserveAllAudio:Bool=false) {
        self.manual=manual;self.preserveAllAudio=preserveAllAudio;saving=manual || preserveAllAudio
        if preserveAllAudio {detail="持续保全中 · 模型只做标记"} else if manual {detail="手动持续录音"}
    }
    public var snapshot: (saving:Bool,detail:String) {lock.lock();defer{lock.unlock()};return(saving,detail)}
    func update(saving:Bool,detail:String) {lock.lock();defer{lock.unlock()};self.saving=saving;self.detail=detail}
}

/// Starting requires sustained measured activity and stable positive model decisions.
/// Unknown/error never starts recording; an existing recording keeps a bounded quiet tail.
/// Never closes devices: judging new sound requires listening. Only a bounded RAM pre-roll is kept while waiting.
final class RecordingGate {
    private struct Packet {let buffer:AVAudioPCMBuffer;let pts:Double;var end:Double {pts+Double(buffer.frameLength)/buffer.format.sampleRate}}
    private var preRoll:[Packet]=[]
    private var saving=false
    private var waitVotes=0
    private var recordVotes=0
    private var lastRecordVote:Double?
    private var inputsLostSince:Double?
    private var savingSince:Double?
    private var waitingSince:Double?
    private let status:RecordingDecisionStatus
    private let write:(AVAudioPCMBuffer,Double) throws -> Void
    private let seal:() throws -> Void
    private let gap:(Double,Double) throws -> Void
    init(status:RecordingDecisionStatus,write:@escaping(AVAudioPCMBuffer,Double)throws->Void,seal:@escaping()throws->Void,gap:@escaping(Double,Double)throws->Void) {
        self.status=status;self.saving=status.snapshot.saving;self.write=write;self.seal=seal;self.gap=gap
    }
    func consume(_ buffer:AVAudioPCMBuffer,pts:Double) throws {
        if saving {if savingSince==nil {savingSince=pts};try write(buffer,pts)}
        else {
            if waitingSince==nil {waitingSince=pts}
            preRoll.append(Packet(buffer:buffer,pts:pts))
            let oldest=pts+Double(buffer.frameLength)/buffer.format.sampleRate-10
            preRoll.removeAll {$0.end<=oldest}
        }
    }
    func apply(_ decision:RecordingDecision?,quietSeconds:Double,inputsReady:Bool,soundConfirmed:Bool,now:Double) throws {
        if status.preserveAllAudio {status.update(saving:true,detail:status.snapshot.detail);return}
        let probability=decision?.confidence ?? .nan
        let valid=probability.isFinite && (0...1).contains(probability)
        let positive=valid && decision?.choice=="record" && probability>=0.75
        if !saving {
            waitVotes=0;inputsLostSince=nil
            guard positive,inputsReady,soundConfirmed,quietSeconds<1 else {
                recordVotes=0;lastRecordVote=nil
                let detail = !inputsReady ? "输入未就绪，继续听候" : !soundConfirmed ? "未检测到持续声音，继续听候" : decision==nil ? "模型暂不可用，继续听候" : "等待模型稳定确认，继续听候"
                status.update(saving:false,detail:detail);return
            }
            if let last=lastRecordVote {
                guard now>last else {return}
                if now-last<1.5 {return} // Polling faster must not count duplicate decisions.
                recordVotes=now-last<=4.5 ? recordVotes+1:1
            } else {recordVotes=1}
            lastRecordVote=now
            guard recordVotes>=2 else {status.update(saving:false,detail:"检测到持续声音，等待再次确认");return}
            let resumed=preRoll.first?.pts ?? now
            if let start=waitingSince,resumed>start {try gap(start,resumed)}
            for packet in preRoll {try write(packet.buffer,packet.pts)}
            preRoll.removeAll();saving=true;savingSince=now;waitingSince=nil;recordVotes=0;lastRecordVote=nil
            status.update(saving:true,detail:"持续声音与模型已确认，开始录音 · 已补回预录")
            return
        }
        if inputsReady {inputsLostSince=nil} else if inputsLostSince==nil {inputsLostSince=now}
        let waiting=valid && decision?.choice=="wait" && probability>=0.75 && !soundConfirmed
        waitVotes=waiting ? waitVotes+1:0
        let minimumTail=now-(savingSince ?? now)>=10
        let quietTail=minimumTail && (quietSeconds>=15 || (waitVotes>=2 && quietSeconds>=3))
        let lost=inputsLostSince.map {now-$0>=5} ?? false
        if quietTail || lost {
            try seal();saving=false;waitingSince=now;preRoll.removeAll();savingSince=nil;waitVotes=0
            status.update(saving:false,detail:lost ? "音频输入中断，回到听候":"静音尾段已保留，回到听候")
        } else {
            status.update(saving:true,detail:soundConfirmed ? "已确认持续声音，正在录音":"录音中 · 等待静音尾段")
        }
    }
    func finish(now:Double) throws {
        try seal()
        if let start=waitingSince,now>start {try gap(start,now)}
        preRoll.removeAll();waitingSince=nil
    }
}
