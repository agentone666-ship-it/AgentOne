@preconcurrency import AVFoundation
import Foundation
import CryptoKit

/// A bounded write-ahead copy of the current mixed segment. AAC's container index
/// is written at close; these plain float frames remain readable after _exit/SIGKILL.
final class PCMRecoveryJournal {
    struct Info:Codable {
        let id:String
        let startedMS:Double
        let sampleRate:Double
        let channels:Int
        var frames:Int64=0
        var context:String
    }
    private let raw:URL,sidecar:URL
    private let file:FileHandle
    private let pulseURL:URL?
    private var info:Info
    private var synced:Int64=0
    var frames:Int64 {info.frames}
    init(id:String,directory:URL,startedMS:Double,sampleRate:Double,channels:Int,context:String,pulseURL:URL? = nil) throws {
        self.pulseURL=pulseURL
        raw=directory.appendingPathComponent(id+".pcm");sidecar=directory.appendingPathComponent(id+".pcm.json")
        info=Info(id:id,startedMS:startedMS,sampleRate:sampleRate,channels:channels,context:context)
        guard FileManager.default.createFile(atPath:raw.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw CaptureFailure.message("无法创建录音恢复日志")}
        file=try FileHandle(forWritingTo:raw)
        try RecorderFiles.write(info,to:sidecar)
    }
    func append(_ buffer:AVAudioPCMBuffer,context:String) throws {
        guard buffer.format.commonFormat == .pcmFormatFloat32,let input=buffer.floatChannelData,Int(buffer.format.channelCount)==info.channels else {throw CaptureFailure.message("恢复日志 PCM 格式无效")}
        let count=Int(buffer.frameLength),channels=info.channels
        var data=Data(count:count*channels*4)
        data.withUnsafeMutableBytes { raw in
            let output=raw.bindMemory(to:Float.self)
            for frame in 0..<count {for channel in 0..<channels {output[frame*channels+channel]=buffer.format.isInterleaved ? input[0][frame*channels+channel]:input[channel][frame]}}
        }
        try file.write(contentsOf:data);info.frames+=Int64(count);info.context=context
        if info.frames-synced>=Int64(info.sampleRate) {
            try file.synchronize();try RecorderFiles.write(info,to:sidecar)
            if let pulseURL {try RecorderFiles.write(RecorderAudioPulse(segmentID:info.id,frames:info.frames),to:pulseURL)}
            synced=info.frames
        }
    }
    func removeAfterSeal() throws {
        try file.synchronize();try file.close()
        try FileManager.default.removeItem(at:raw);try FileManager.default.removeItem(at:sidecar)
    }
    static func recover(database:MemoryDatabase) throws {
        for row in try database.rows("SELECT * FROM segments WHERE state IN ('recording','incomplete') AND source='mixed' AND sha256 IS NULL") {
            guard let id=row["id"],UUID(uuidString:id) != nil,let relative=row["relative_path"],let started=Double(row["started_ms"] ?? "") else {continue}
            let directory=database.root.appendingPathComponent(relative).deletingLastPathComponent().resolvingSymlinksInPath()
            guard directory.path.hasPrefix(database.root.resolvingSymlinksInPath().appendingPathComponent("Audio").path+"/") else {continue}
            let raw=directory.appendingPathComponent(id+".pcm"),sidecar=directory.appendingPathComponent(id+".pcm.json")
            guard FileManager.default.fileExists(atPath:raw.path),FileManager.default.fileExists(atPath:sidecar.path) else {continue}
            guard (try raw.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else {throw CaptureFailure.message("录音恢复日志不能是符号链接")}
            let info=try RecorderFiles.read(Info.self,from:sidecar)
            guard info.id==id,abs(info.startedMS-started)<2,info.sampleRate==48000,info.channels==2 else {throw CaptureFailure.message("录音恢复日志与来源不一致")}
            let size=(try raw.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            guard size>0,size<=256*1024*1024 else {throw CaptureFailure.message("录音恢复日志大小无效")}
            let data=try Data(contentsOf:raw),frames=data.count/(info.channels*4)
            guard frames>0,let format=AVAudioFormat(standardFormatWithSampleRate:info.sampleRate,channels:AVAudioChannelCount(info.channels)) else {continue}
            let output=directory.appendingPathComponent(id+".recovered.m4a")
            var encoder:AVAudioFile?=try AVAudioFile(forWriting:output,settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:info.sampleRate,AVNumberOfChannelsKey:info.channels,AVEncoderBitRateKey:96000],commonFormat:.pcmFormatFloat32,interleaved:false)
            for first in stride(from:0,to:frames,by:4800) {
                let count=min(4800,frames-first)
                guard let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count)) else {throw CaptureFailure.message("恢复 PCM 内存不足")}
                pcm.frameLength=AVAudioFrameCount(count)
                data.withUnsafeBytes { bytes in
                    let input=bytes.bindMemory(to:Float.self)
                    for frame in 0..<count {for channel in 0..<info.channels {pcm.floatChannelData![channel][frame]=input[(first+frame)*info.channels+channel]}}
                }
                try encoder?.write(from:pcm)
            }
            encoder=nil
            let check=try AVAudioFile(forReading:output)
            guard abs(Int64(check.length)-Int64(frames))<4096 else {throw CaptureFailure.message("恢复音频长度校验失败")}
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
            let hash=SHA256.hash(data:try Data(contentsOf:output)).map{String(format:"%02x",$0)}.joined()
            var context=(info.context.data(using:.utf8).flatMap{try? JSONSerialization.jsonObject(with:$0)} as? [String:Any]) ?? [:]
            context["crash_recovery"]=["method":"mixed_pcm_write_ahead_journal","frames":frames,"sample_rate":info.sampleRate,"source_raw_sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),"reencoded":true]
            let encoded=String(decoding:try JSONSerialization.data(withJSONObject:context),as:UTF8.self)
            let end=started+Double(frames)/info.sampleRate*1000
            let accepted=try database.transaction {
                guard try !database.rows("SELECT id FROM segments WHERE id=? AND state IN ('recording','incomplete') AND sha256 IS NULL",[id]).isEmpty else {return false}
                try database.execute("UPDATE segments SET state='sealed',ended_ms=?,relative_path=?,sha256=?,context_json=? WHERE id=?",[String(Int64(end)),String(output.path.dropFirst(database.root.path.count+1)),hash,encoded,id])
                try database.execute("INSERT OR IGNORE INTO jobs(id,segment_id,stage,source_hash,state,created_ms,updated_ms) VALUES (?,?,'transcribe',?,'pending',?,?)",[UUID().uuidString,id,hash,MemoryDatabase.now,MemoryDatabase.now])
                try database.addGap(started:Date(timeIntervalSince1970:end/1000),ended:Date(),source:"mixed",reason:"recorder_restart_after_recovered_tail")
                return true
            }
            if accepted {try FileManager.default.removeItem(at:raw);try FileManager.default.removeItem(at:sidecar)}
            else {try? FileManager.default.removeItem(at:output)}
        }
    }
}
