import Foundation

/// A single local classifier process. It has no Agent runtime or access to recordings.
@MainActor public final class LayaDecisionClient {
    public private(set) var status="Laya 尚未启动"
    private var process:Process?
    private var input:FileHandle?
    private var buffer=Data()
    private var ready=false
    private var pending:(id:String,continuation:CheckedContinuation<RecordingDecision?,Never>)?
    private var deadline:Task<Void,Never>?
    public init() {}
    public func start(workerURL:URL) {
        guard process==nil else {return}
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentOne/Laya")
        let python=root.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath:python.path) else {status="Laya 未安装，继续保留声音";return}
        let process=Process(),stdin=Pipe(),stdout=Pipe()
        process.executableURL=python;process.arguments=["-u",workerURL.path]
        var env=ProcessInfo.processInfo.environment;env["HF_HOME"]=root.appendingPathComponent("cache").path;env["USE_TF"]="0";env["TOKENIZERS_PARALLELISM"]="false"
        // Setup downloads explicitly; app launches never download model weights.
        env["HF_HUB_OFFLINE"]="1";env["TRANSFORMERS_OFFLINE"]="1"
        process.environment=env;process.standardInput=stdin;process.standardOutput=stdout;process.standardError=FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler={ [weak self] handle in
            let data=handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler={ [weak self] _ in Task { @MainActor in self?.failed() } }
        do {try process.run();self.process=process;input=stdin.fileHandleForWriting;status="Laya 加载中，先保留声音"
            deadline=Task { [weak self] in
                do {try await Task.sleep(for:.seconds(30))} catch {return}
                self?.stop();self?.status="Laya 加载超时，继续保留声音"
            }}
        catch {stdout.fileHandleForReading.readabilityHandler=nil;status="Laya 启动失败，继续保留声音"}
    }
    private func receive(_ data:Data) {
        guard !data.isEmpty else {failed();return}
        buffer.append(data)
        guard buffer.count<=16384 else {failed();return}
        while let newline=buffer.firstIndex(of:10) {
            let line=buffer.prefix(upTo:newline);buffer.removeSubrange(...newline)
            guard let value=try? JSONSerialization.jsonObject(with:line) as? [String:Any] else {continue}
            if value["ready"] as? Bool == true {deadline?.cancel();deadline=nil;ready=true;status="Laya 本机决策已就绪";continue}
            guard let pending,value["id"] as? String==pending.id else {continue}
            var decision:RecordingDecision?
            if let choice=value["choice"] as? String,["record","wait"].contains(choice),let confidence=value["confidence"] as? Double,confidence.isFinite,(0...1).contains(confidence) {decision=RecordingDecision(choice:choice,confidence:confidence)}
            complete(decision)
        }
    }
    public func decide(state:[String:String]) async -> RecordingDecision? {
        guard ready,pending==nil,let input else {return nil}
        let id=UUID().uuidString
        guard var data=try? JSONSerialization.data(withJSONObject:["id":id,"state":state]) else {return nil}
        data.append(10)
        return await withCheckedContinuation { continuation in
            pending=(id,continuation)
            deadline=Task { [weak self] in
                do {try await Task.sleep(for:.seconds(5))} catch {return}
                // Stop our stalled classifier instead of accumulating requests behind it.
                self?.stop();self?.status="Laya 判断超时，继续保留声音"
            }
            do {try input.write(contentsOf:data)} catch {complete(nil)}
        }
    }
    private func complete(_ result:RecordingDecision?) {
        deadline?.cancel();deadline=nil
        let continuation=pending?.continuation;pending=nil;continuation?.resume(returning:result)
    }
    private func failed() {ready=false;status="Laya 暂不可用，继续保留声音";complete(nil)}
    public func stop() {failed();input?.closeFile();input=nil;if process?.isRunning==true {process?.terminate()};process=nil}
}
