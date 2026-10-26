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
    private let record=RecordingDecision(choice:"record",confidence:0.9)
    @Test func startupUnknownErrorsAndQuietNeverCreateFilesEvenIfModelSaysRecord() throws {
        for decision in [nil,RecordingDecision(choice:"record",confidence:0.8257),RecordingDecision(choice:"record",confidence:0.74),RecordingDecision(choice:"record",confidence:.nan),RecordingDecision(choice:"wait",confidence:0.9)] {
            for (ready,confirmed,quiet) in [(false,false,712.0),(true,false,30.0),(false,true,0.0)] {
                let status=RecordingDecisionStatus();var saved=0
                let gate=RecordingGate(status:status,write:{_,_ in saved+=1},seal:{},gap:{_,_ in})
                for t in 0..<20 {
                    try gate.consume(buffer(amplitude:0),pts:Double(t))
                    try gate.apply(decision,quietSeconds:quiet,inputsReady:ready,soundConfirmed:confirmed,now:Double(t))
                }
                #expect(!status.snapshot.saving);#expect(saved==0)
            }
        }
    }
    @Test func startRequiresTwoSpacedVotesAndResumesWithTenSecondPreRoll() throws {
        let status=RecordingDecisionStatus();var saved:[Double]=[],gaps:[(Double,Double)]=[]
        let gate=RecordingGate(status:status,write:{_,pts in saved.append(pts)},seal:{},gap:{gaps.append(($0,$1))})
        let pcm=try buffer()
        for i in 0..<150 {try gate.consume(pcm,pts:Double(i)/10)}
        #expect(saved.isEmpty)
        try gate.apply(record,quietSeconds:0,inputsReady:true,soundConfirmed:true,now:15)
        try gate.apply(record,quietSeconds:0,inputsReady:true,soundConfirmed:true,now:15)
        try gate.apply(record,quietSeconds:0,inputsReady:true,soundConfirmed:true,now:15.5)
        #expect(!status.snapshot.saving)
        for i in 150..<170 {try gate.consume(pcm,pts:Double(i)/10)}
        try gate.apply(record,quietSeconds:0,inputsReady:true,soundConfirmed:true,now:17)
        #expect(status.snapshot.saving);#expect(saved.count==100)
        #expect(abs(saved.first!-7)<0.001);#expect(abs(saved.last!-16.9)<0.001)
        #expect(gaps.count==1);#expect(gaps[0].0==0);#expect(abs(gaps[0].1-7)<0.001)
    }
    @Test func noiseOrErrorBetweenVotesCancelsPendingStart() throws {
        for middle in [nil,RecordingDecision(choice:"wait",confidence:0.9)] {
            let status=RecordingDecisionStatus();var saved=0
            let gate=RecordingGate(status:status,write:{_,_ in saved+=1},seal:{},gap:{_,_ in})
            try gate.consume(buffer(),pts:0)
            try gate.apply(record,quietSeconds:0,inputsReady:true,soundConfirmed:true,now:3)
            try gate.apply(middle,quietSeconds:0,inputsReady:true,soundConfirmed:false,now:5)
            try gate.apply(record,quietSeconds:0,inputsReady:true,soundConfirmed:true,now:7)
            #expect(!status.snapshot.saving);#expect(saved==0)
        }
    }
    @Test func quietStopsExistingRecordingDespiteWrongModelAndErrorNeverRestartsIt() throws {
        let status=RecordingDecisionStatus();var saved=0,seals=0
        let gate=RecordingGate(status:status,write:{_,_ in saved+=1},seal:{seals+=1},gap:{_,_ in})
        try gate.consume(buffer(),pts:0)
        try gate.apply(record,quietSeconds:0,inputsReady:true,soundConfirmed:true,now:3)
        try gate.apply(record,quietSeconds:0,inputsReady:true,soundConfirmed:true,now:5)
        #expect(status.snapshot.saving)
        try gate.apply(nil,quietSeconds:2,inputsReady:true,soundConfirmed:false,now:7)
        #expect(status.snapshot.saving)
        try gate.apply(record,quietSeconds:20,inputsReady:true,soundConfirmed:false,now:25)
        #expect(!status.snapshot.saving);#expect(seals==1)
        let before=saved
        try gate.consume(buffer(),pts:26)
        try gate.apply(nil,quietSeconds:21,inputsReady:false,soundConfirmed:false,now:27)
        #expect(!status.snapshot.saving);#expect(saved==before)
    }
    @Test func manualRecordingStillStartsImmediately() throws {
        let status=RecordingDecisionStatus(manual:true);var saved=0
        let gate=RecordingGate(status:status,write:{_,_ in saved+=1},seal:{},gap:{_,_ in})
        try gate.consume(buffer(),pts:0)
        #expect(status.snapshot.saving);#expect(saved==1)
    }
    @Test func nativePCMWindowRejectsQuietImpulsesAndStaleSoundButAcceptsSustainedSound() {
        let meter=CaptureActivityMeter()
        for i in 0..<35 {meter.observe(AudioActivityReading(rmsDBFS:-65),source:"microphone",now:Double(i)/10)}
        #expect(!meter.startEvidence(now:3.4).sustainedSound)
        meter.observe(AudioActivityReading(rmsDBFS:-15),source:"microphone",now:3.5)
        #expect(!meter.startEvidence(now:3.5).sustainedSound)
        for i in 36..<70 {meter.observe(AudioActivityReading(rmsDBFS:-65),source:"microphone",now:Double(i)/10)}
        #expect(!meter.startEvidence(now:6.9).sustainedSound)
        for i in 70..<100 {meter.observe(AudioActivityReading(rmsDBFS:-25),source:"microphone",now:Double(i)/10)}
        let evidence=meter.startEvidence(now:9.9)
        #expect(evidence.inputsReady);#expect(evidence.sustainedSound);#expect(evidence.activeFraction>=0.6)
        #expect(evidence.readySources==["microphone"])
        #expect(!meter.startEvidence(now:12).sustainedSound)
        #expect(!meter.startEvidence(now:12).inputsReady)
        meter.reset();#expect(!meter.startEvidence(now:13).sustainedSound)
    }
    @Test func mixedOutputAndRepeatedShortBurstsCannotSupplySustainedNativeEvidence() {
        let meter=CaptureActivityMeter()
        for i in 0..<40 {
            meter.observe(AudioActivityReading(rmsDBFS:-10),source:"mixed",now:Double(i)/10)
            meter.observe(AudioActivityReading(rmsDBFS:i%10==0 ? -20:-65),source:"microphone",now:Double(i)/10)
        }
        #expect(!meter.startEvidence(now:3.9).sustainedSound)
        #expect(meter.startEvidence(now:3.9).activeFraction<0.6)
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
