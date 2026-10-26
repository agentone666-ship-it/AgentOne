@testable import AgentOneCaptureKit
import AVFoundation
import Foundation
import Testing

struct RecordingDecisionTests {
    private func buffer(amplitude:Float=0.2) throws -> AVAudioPCMBuffer {
        let format=try #require(AVAudioFormat(standardFormatWithSampleRate:48000,channels:2))
        let pcm=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800));pcm.frameLength=4800
        for channel in 0..<2 {pcm.floatChannelData![channel].update(repeating:amplitude,count:4800)}
        return pcm
    }
    @Test func quietNeedsStableModelVotesAndResumesWithBoundedPreRoll() throws {
        let status=RecordingDecisionStatus()
        var timestamps:[Double]=[],seals=0,gaps:[(Double,Double)]=[]
        let gate=RecordingGate(status:status,write:{_,pts in timestamps.append(pts)},seal:{seals+=1},gap:{gaps.append(($0,$1))})
        let pcm=try buffer(),wait=RecordingDecision(choice:"wait",confidence:0.95)
        try gate.consume(pcm,pts:0)
        try gate.apply(wait,quietSeconds:20,inputsReady:true,now:16)
        #expect(status.snapshot.saving)
        try gate.apply(wait,quietSeconds:20,inputsReady:true,now:18)
        #expect(!status.snapshot.saving);#expect(seals==1)
        for i in 180..<330 {try gate.consume(pcm,pts:Double(i)/10)}
        #expect(timestamps==[0])
        try gate.apply(RecordingDecision(choice:"record",confidence:0.6),quietSeconds:0,inputsReady:true,now:33)
        #expect(status.snapshot.saving)
        #expect(timestamps.count==101)
        #expect(abs(timestamps[1]-23)<0.001)
        #expect(abs(timestamps.last!-32.9)<0.001)
        #expect(gaps.count==1);#expect(gaps[0].0==18);#expect(abs(gaps[0].1-23)<0.001)
    }
    @Test func uncertaintyFailureAndMissingInputsKeepAudioInsteadOfDroppingIt() throws {
        for decision in [nil,RecordingDecision(choice:"wait",confidence:0.74),RecordingDecision(choice:"wait",confidence:.nan),RecordingDecision(choice:"invalid",confidence:1)] {
            let status=RecordingDecisionStatus();var saved=0
            let gate=RecordingGate(status:status,write:{_,_ in saved+=1},seal:{},gap:{_,_ in})
            let pcm=try buffer()
            try gate.consume(pcm,pts:0)
            for _ in 0..<3 {try gate.apply(decision,quietSeconds:60,inputsReady:true,now:60)}
            try gate.consume(pcm,pts:61)
            #expect(status.snapshot.saving);#expect(saved==2)
        }
        for (quiet,ready) in [(0.0,true),(60.0,false)] {
            let status=RecordingDecisionStatus()
            let gate=RecordingGate(status:status,write:{_,_ in},seal:{},gap:{_,_ in})
            try gate.consume(buffer(),pts:0)
            for _ in 0..<3 {try gate.apply(RecordingDecision(choice:"wait",confidence:1),quietSeconds:quiet,inputsReady:ready,now:60)}
            #expect(status.snapshot.saving)
        }
    }
    @Test func modelFailureRestoresWaitingAudioAndFinishDoesNotLeakPreRoll() throws {
        let status=RecordingDecisionStatus();var saved:[Double]=[],gaps=0
        let gate=RecordingGate(status:status,write:{_,pts in saved.append(pts)},seal:{},gap:{_,_ in gaps+=1})
        let pcm=try buffer(),wait=RecordingDecision(choice:"wait",confidence:1)
        try gate.consume(pcm,pts:0)
        for _ in 0..<2 {try gate.apply(wait,quietSeconds:20,inputsReady:true,now:20)}
        try gate.consume(pcm,pts:21)
        try gate.apply(nil,quietSeconds:20,inputsReady:true,now:22)
        #expect(saved==[0,21]);#expect(status.snapshot.saving)
        for _ in 0..<2 {try gate.apply(wait,quietSeconds:60,inputsReady:true,now:60)}
        try gate.consume(pcm,pts:61);try gate.finish(now:62)
        #expect(saved==[0,21]);#expect(gaps==2)
    }
    @Test func meterUsesPCMLevelAndExpiresWithoutFakeOscillation() throws {
        let meter=CaptureActivityMeter()
        meter.observe(AudioActivityReading.measure(try buffer(amplitude:0)),source:"mixed",now:0)
        #expect(meter.level(source:"mixed",now:0)==0)
        meter.observe(AudioActivityReading.measure(try buffer(amplitude:0.1)),source:"mixed",now:1)
        #expect(meter.level(source:"mixed",now:1)>0.7)
        #expect(meter.level(source:"mixed",now:1.4)<0.3)
        #expect(meter.level(source:"mixed",now:1.6)==0)
        #expect(meter.level(source:"mixed",now:0)==0)
        #expect(meter.quietSeconds(now:16)==15)
        meter.reset();#expect(meter.level(source:"mixed",now:20)==0)
    }
}
