@preconcurrency import AVFoundation
import Foundation

@MainActor public final class VoiceprintService {
    private let database:MemoryDatabase
    private var recorder:AVAudioRecorder?
    private var busy=false
    private var expiry:Task<Void,Never>?
    public private(set) var status="未录入本人声纹"
    public private(set) var enrolling=false
    public let models=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentOne/Voiceprint")
    private var folder:URL {database.root.appendingPathComponent("Voiceprint")}
    private var profile:URL {folder.appendingPathComponent("owner.json")}
    public var installed:Bool {FileManager.default.isExecutableFile(atPath:models.appendingPathComponent("runtime/bin/python").path) && FileManager.default.fileExists(atPath:models.appendingPathComponent("models.json").path)}
    public var enrolled:Bool {VoiceprintStore(database:database).profileID != nil}
    public init(database:MemoryDatabase) {self.database=database;if enrolled {status="声纹已录入 · 逐段比对中"}}
    private func resource(_ name:String)->URL? {
        if let r=Bundle.main.url(forResource:name,withExtension:"py"){return r}
        return nil
    }
    public func install() async {
        guard !busy,!enrolling else {return}
        if installed {status="声纹组件已就绪，请录制本人声音";return}
        busy=true;defer{busy=false}
        guard let setup=resource("voiceprint-setup") else {status="声纹安装脚本缺失";return}
        status="正在下载本机声纹组件；不会上传声音"
        let home=FileManager.default.homeDirectoryForCurrentUser
        let options=[home.appendingPathComponent("Library/Application Support/AgentOne/Laya/.venv/bin/python").path,home.appendingPathComponent("miniconda3/bin/python3").path,"/opt/homebrew/bin/python3","/usr/local/bin/python3","/usr/bin/python3"]
        let python=options.first {FileManager.default.isExecutableFile(atPath:$0)} ?? "/usr/bin/python3"
        do {_ = try await Task.detached(priority:.utility) {try VoiceprintProcess.run(executable:URL(fileURLWithPath:python),arguments:[setup.path,self.models.path],timeout:600)}.value;status="声纹组件已就绪，请录制本人声音"}
        catch {status="声纹组件安装失败；请检查网络和 Python 3.10 或更新版本"}
    }
    public func startEnrollment() async {
        guard installed,!busy,!enrolling else {status="请先安装声纹组件，或等待当前操作完成";return}
        let granted=await AVCaptureDevice.requestAccess(for:.audio)
        guard granted else {status="未允许麦克风，无法录制声纹";return}
        do {
            try prepareFolder()
            let url=folder.appendingPathComponent("enrollment.wav")
            if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}
            recorder=try AVAudioRecorder(url:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false])
            guard recorder?.record(forDuration:30)==true else {throw CaptureFailure.message("无法启动麦克风")}
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            enrolling=true;status="正在录制，最多30秒；请独自朗读，至少12秒清晰人声"
            expiry=Task {[weak self] in do {try await Task.sleep(for:.seconds(30))}catch{return};await self?.finishEnrollment()}
        }catch{status=error.localizedDescription;recorder=nil;enrolling=false}
    }
    public func cancelEnrollment() {
        expiry?.cancel();expiry=nil;recorder?.stop();recorder=nil;enrolling=false
        try? FileManager.default.removeItem(at:folder.appendingPathComponent("enrollment.wav"));status=enrolled ? "保留原声纹":"已取消录入"
    }
    public func finishEnrollment() async {
        guard enrolling else {return};expiry?.cancel();expiry=nil;recorder?.stop();recorder=nil;enrolling=false;busy=true;defer{busy=false}
        let audio=folder.appendingPathComponent("enrollment.wav");defer{try? FileManager.default.removeItem(at:audio)}
        status="正在提取本机声纹"
        do {
            var result=try await compute(mode:"enroll",audio:audio)
            guard result["embedding"] is [Double],result["model_hash"] is String else {throw CaptureFailure.message("声纹结果无效")}
            let id=UUID().uuidString;result["profile_id"]=id
            let data=try JSONSerialization.data(withJSONObject:result);try data.write(to:profile,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:profile.path)
            try database.execute("INSERT INTO meta VALUES ('voiceprint_profile',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[id])
            try database.execute("DELETE FROM voice_matches");status="录入完成 · 正在从最近的录音开始比对"
        }catch {status=error.localizedDescription}
    }
    public func forget() throws {
        guard !busy else {throw CaptureFailure.message("请等待当前比对完成后移除")};cancelEnrollment()
        if FileManager.default.fileExists(atPath:profile.path){try FileManager.default.removeItem(at:profile)}
        try database.transaction {try database.execute("DELETE FROM meta WHERE key='voiceprint_profile'");try database.execute("DELETE FROM voice_matches")}
        status="已移除声纹及比对标签；原录音保留"
    }
    public func runNext() async {
        guard installed,enrolled,!busy,!enrolling,let id=VoiceprintStore(database:database).profileID else {return}
        busy=true;defer{busy=false}
        var candidate:[String:String]?
        do {
            guard let source=try database.rows("SELECT s.* FROM segments s WHERE s.state='sealed' AND NOT EXISTS(SELECT 1 FROM voice_matches v WHERE v.segment_id=s.id AND v.source_hash=s.sha256 AND v.profile_id=?) ORDER BY s.started_ms DESC LIMIT 1",[id]).first,let sid=source["id"] else {return}
            candidate=source
            let original=try database.verifiedAudioURL(sid)
            let wav=folder.appendingPathComponent("scan-"+UUID().uuidString+".wav")
            defer {try? FileManager.default.removeItem(at:wav)}
            try await Task.detached(priority:.utility){try VoiceprintAudio.convert(original,to:wav)}.value
            let result=try await compute(mode:"verify",audio:wav)
            guard result["profile_id"] as? String==id,["detected","not_detected","uncertain"].contains(result["status"] as? String ?? "") else {throw CaptureFailure.message("声纹比对结果无效")}
            _ = try database.verifiedAudioURL(sid)
            let intervals=String(decoding:try JSONSerialization.data(withJSONObject:result["intervals"] ?? []),as:UTF8.self)
            try database.transaction {
                guard VoiceprintStore(database:database).profileID==id,try !database.rows("SELECT id FROM segments WHERE id=? AND state='sealed' AND sha256=?",[sid,source["sha256"]]).isEmpty else {return}
                try database.execute("INSERT OR REPLACE INTO voice_matches VALUES (?,?,?,?,?,?,?)",[sid,id,source["sha256"],result["status"] as? String,(result["score"] as? Double).map{String($0)},intervals,MemoryDatabase.now])
            }
            status="声纹比对进行中 · 不会自动删除任何录音"
        }catch {
            if let source=candidate,let sid=source["id"],VoiceprintStore(database:database).profileID==id {
                _=try? database.execute("INSERT OR REPLACE INTO voice_matches SELECT id,?,sha256,'uncertain',NULL,'[]',? FROM segments WHERE id=? AND state='sealed' AND sha256=?",[id,MemoryDatabase.now,sid,source["sha256"]])
            }
            status="声纹比对失败，保留待确认："+error.localizedDescription
        }
    }
    private func prepareFolder() throws {
        guard (try? folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else {throw CaptureFailure.message("声纹目录不能是符号链接")}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
    }
    private func compute(mode:String,audio:URL) async throws -> [String:Any] {
        try prepareFolder()
        if mode=="verify",(try? profile.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink)==true {throw CaptureFailure.message("声纹文件不能是符号链接")}

        guard let worker=resource("voiceprint-worker") else {throw CaptureFailure.message("声纹脚本缺失")}
        let job=folder.appendingPathComponent("job-"+UUID().uuidString+".json")
        let data=try JSONSerialization.data(withJSONObject:["mode":mode,"audio":audio.path,"models":models.path,"profile":profile.path])
        try data.write(to:job,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:job.path)
        defer{try? FileManager.default.removeItem(at:job)}
        let python=models.appendingPathComponent("runtime/bin/python")
        let output=try await Task.detached(priority:.utility){try VoiceprintProcess.run(executable:python,arguments:[worker.path,job.path],timeout:180)}.value
        guard let value=try JSONSerialization.jsonObject(with:output) as? [String:Any] else {throw CaptureFailure.message("声纹模型返回无效")}
        if let error=value["error"] as? String {throw CaptureFailure.message(error)}
        return value
    }
}

enum VoiceprintProcess {
    static func run(executable:URL,arguments:[String],timeout:Double) throws -> Data {
        let log=FileManager.default.temporaryDirectory.appendingPathComponent("voiceprint-output-"+UUID().uuidString)
        FileManager.default.createFile(atPath:log.path,contents:Data(),attributes:[.posixPermissions:0o600])
        let handle=try FileHandle(forWritingTo:log);defer{try? handle.close();try? FileManager.default.removeItem(at:log)}
        let process=Process();process.executableURL=executable;process.arguments=arguments;process.standardOutput=handle;process.standardError=FileHandle.nullDevice
        try process.run()
        let until=Date().addingTimeInterval(timeout)
        while process.isRunning && Date()<until {Thread.sleep(forTimeInterval:0.1)}
        if process.isRunning {process.terminate();throw CaptureFailure.message("声纹处理超时")}
        guard (try log.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<3_000_000 else {throw CaptureFailure.message("声纹输出过长")}
        let data=try Data(contentsOf:log)
        if process.terminationStatus != 0 {
            if let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let error=value["error"] as? String {throw CaptureFailure.message(error)}
            throw CaptureFailure.message("本机声纹模型运行失败")
        }
        return data
    }
}

enum VoiceprintAudio {
    static func convert(_ url:URL,to output:URL) throws {
        let file=try AVAudioFile(forReading:url),input=file.processingFormat
        guard file.length>0,Double(file.length)/input.sampleRate<=125,
              let pcm=AVAudioPCMBuffer(pcmFormat:input,frameCapacity:AVAudioFrameCount(file.length)),
              let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1),
              let converter=AVAudioConverter(from:input,to:format),
              let converted=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(ceil(Double(file.length)/input.sampleRate*16000))+4096) else {throw CaptureFailure.message("声纹采样格式不支持")}
        // Sequential reads preserve compressed-file priming/tail frames.
        var count:AVAudioFrameCount=0
        while count<pcm.frameCapacity {
            let part=AVAudioPCMBuffer(pcmFormat:input,frameCapacity:min(65536,pcm.frameCapacity-count))!
            try file.read(into:part);if part.frameLength==0{break}
            let bytes=Int(input.streamDescription.pointee.mBytesPerFrame)
            let src=UnsafeMutableAudioBufferListPointer(part.mutableAudioBufferList),dst=UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            for i in src.indices {dst[i].mData!.advanced(by:Int(count)*bytes).copyMemory(from:src[i].mData!,byteCount:Int(part.frameLength)*bytes)}
            count+=part.frameLength
        }
        pcm.frameLength=count;var sent=false;var error:NSError?
        let result=converter.convert(to:converted,error:&error){_,status in if sent {status.pointee = .endOfStream;return nil};sent=true;status.pointee = .haveData;return pcm}
        guard result != .error,error==nil,converted.frameLength>0 else {throw CaptureFailure.message("声纹重采样失败")}
        let writer=try AVAudioFile(forWriting:output,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false],commonFormat:.pcmFormatFloat32,interleaved:false)
        try writer.write(from:converted);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
    }
}
