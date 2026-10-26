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
    private var saving=true
    private var detail="Laya 正在加载，先保留声音"
    public init() {}
    public var snapshot: (saving:Bool,detail:String) {lock.lock();defer{lock.unlock()};return(saving,detail)}
    func update(saving:Bool,detail:String) {lock.lock();defer{lock.unlock()};self.saving=saving;self.detail=detail}
}

/// Laya chooses record/wait. Low confidence, unavailable inputs and inference failures retain audio.
/// Never closes devices: judging new sound requires listening. Only a bounded RAM pre-roll is kept while waiting.
final class RecordingGate {
    private struct Packet {let buffer:AVAudioPCMBuffer;let pts:Double;var end:Double {pts+Double(buffer.frameLength)/buffer.format.sampleRate}}
    private var preRoll:[Packet]=[]
    private var saving=true
    private var waitVotes=0
    private var savingSince:Double?
    private var waitingSince:Double?
    private let status:RecordingDecisionStatus
    private let write:(AVAudioPCMBuffer,Double) throws -> Void
    private let seal:() throws -> Void
    private let gap:(Double,Double) throws -> Void
    init(status:RecordingDecisionStatus,write:@escaping(AVAudioPCMBuffer,Double)throws->Void,seal:@escaping()throws->Void,gap:@escaping(Double,Double)throws->Void) {
        self.status=status;self.write=write;self.seal=seal;self.gap=gap
    }
    func consume(_ buffer:AVAudioPCMBuffer,pts:Double) throws {
        if saving {if savingSince==nil {savingSince=pts};try write(buffer,pts)}
        else {
            preRoll.append(Packet(buffer:buffer,pts:pts))
            let oldest=pts+Double(buffer.frameLength)/buffer.format.sampleRate-10
            preRoll.removeAll {$0.end<=oldest}
        }
    }
    func apply(_ decision:RecordingDecision?,quietSeconds:Double,inputsReady:Bool,now:Double) throws {
        let confidentWait=decision?.choice=="wait" && (decision?.confidence ?? 0)>=0.75 && (decision?.confidence ?? 2)<=1 && inputsReady && quietSeconds>=15
        waitVotes=confidentWait ? waitVotes+1:0
        if confidentWait && (!saving || (waitVotes>=2 && now-(savingSince ?? now)>=15)) {
            if saving {try seal();saving=false;waitingSince=now;preRoll.removeAll()}
            status.update(saving:false,detail:"Laya 判断暂时无声，听候中 · 保留 10 秒预录")
            return
        }
        if !confidentWait {
            if !saving {
                let resumed=preRoll.first?.pts ?? now
                if let start=waitingSince,resumed>start {try gap(start,resumed)}
                for packet in preRoll {try write(packet.buffer,packet.pts)}
                preRoll.removeAll();saving=true;savingSince=resumed;waitingSince=nil
            }
            let detail=decision == nil ? "Laya 尚无可用判断，先保留声音" : decision?.choice=="record" && (decision?.confidence ?? 0)>=0.75 ? "Laya 判断开始记录 · 已保留开头" : "判断不确定，继续保留声音"
            status.update(saving:true,detail:detail)
        }
    }
    func finish(now:Double) throws {
        try seal()
        if let start=waitingSince,now>start {try gap(start,now)}
        preRoll.removeAll();waitingSince=nil
    }
}
