import Foundation

public struct AgentConnectionPackage:Sendable {
    public let resources:URL
    public let memoryRoot:URL
    public let node:URL
    public init(resources:URL,memoryRoot:URL,node:URL) {self.resources=resources;self.memoryRoot=memoryRoot;self.node=node}
    public static func findNode() -> URL? {
        let home=FileManager.default.homeDirectoryForCurrentUser
        let candidates=[home.appendingPathComponent(".local/bin/node").path,"/opt/homebrew/bin/node","/usr/local/bin/node","/usr/bin/node"]+(ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map {String($0)+"/node"}
        return candidates.first {FileManager.default.isExecutableFile(atPath:$0)}.map {URL(fileURLWithPath:$0)}
    }
    public func configuration(plugin:Bool=false) -> [String:Any] {
        ["mcpServers":["agentone-memory":["command":node.path,"args":[plugin ? "${PLUGIN_ROOT}/server.mjs":resources.appendingPathComponent("server.mjs").path],"env":["AGENTONE_MEMORY_HOME":memoryRoot.path]]]]
    }
    public func configurationText() throws -> String {String(decoding:try JSONSerialization.data(withJSONObject:configuration(),options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self)}
    /// Export only public program files; never copy Memory, recordings, credentials or user facts.
    public func export(to parent:URL) throws -> URL {
        let fm=FileManager.default
        try fm.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let root=parent.appendingPathComponent("agentone-"+UUID().uuidString.prefix(8)),plugin=root.appendingPathComponent("agentone-memory")
        try fm.createDirectory(at:plugin,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            for file in ["server.mjs","store.mjs","recall.mjs","conversations.mjs","schema.sql","migrate-v2.sql","README.md","plugin.json",".codex-plugin","skills"] {
                let source=resources.appendingPathComponent(file)
                guard (try source.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else {throw CaptureFailure.message("插件源路径不可信")}
                try fm.copyItem(at:source,to:plugin.appendingPathComponent(file))
            }
            try write(configuration(plugin:true),to:plugin.appendingPathComponent(".mcp.json"))
            var portable=configuration(plugin:true)
            var servers=portable["mcpServers"] as! [String:[String:Any]]
            servers["agentone-memory"]?["type"]="stdio";servers["agentone-memory"]?["cwd"]="${PLUGIN_ROOT}"
            portable["mcpServers"]=servers;portable["$schema"]="https://agent-plugins.org/schemas/1.0.0/mcp.schema.json"
            try write(portable,to:plugin.appendingPathComponent("mcp.json"))
            let catalog:[String:Any]=["name":"agentone-local","plugins":[["name":"agentone-memory","source":["source":"local","path":"./agentone-memory"],"policy":["installation":"AVAILABLE","authentication":"ON_INSTALL"],"category":"Productivity"]]]
            let catalogURL=root.appendingPathComponent(".agents/plugins/marketplace.json")
            try fm.createDirectory(at:catalogURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try write(catalog,to:catalogURL)
            let guide="AgentOne Memory 本机插件\n\n推荐：在支持本地插件的桌面 Agent 中导入 agentone-memory 文件夹。Codex 可先运行：\n\ncodex plugin marketplace add \(Self.shellQuote(root.path))\n\n再在插件目录的 agentone-local 来源安装 AgentOne Memory。导入后在 Agent 里调用 get_capture_status；App 只有收到宿主握手后才显示最近连接。宿主需支持本机 stdio MCP，云端沙箱不能直接访问这台 Mac。原音权限仍由灵动岛单独控制。\n"
            try Data(guide.utf8).write(to:root.appendingPathComponent("接入说明.txt"),options:.atomic)
            return root
        } catch {try? fm.removeItem(at:root);throw error}
    }
    public func connectionCheck() throws -> Int {
        let process=Process(),stdin=Pipe(),stdout=Pipe(),stderr=Pipe()
        process.executableURL=node;process.arguments=[resources.appendingPathComponent("server.mjs").path,"--home",memoryRoot.path]
        process.standardInput=stdin;process.standardOutput=stdout;process.standardError=stderr
        let timeout=DispatchWorkItem {if process.isRunning {process.terminate()}}
        try process.run();DispatchQueue.global().asyncAfter(deadline:.now()+8,execute:timeout)
        defer {timeout.cancel()}
        let messages:[[String:Any]]=[
            ["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":"2025-06-18","capabilities":[:],"clientInfo":["name":"agentone-connection-check","version":"1"]]],
            ["jsonrpc":"2.0","id":2,"method":"tools/list"]]
        for message in messages {var data=try JSONSerialization.data(withJSONObject:message);data.append(10);try stdin.fileHandleForWriting.write(contentsOf:data)}
        try stdin.fileHandleForWriting.close()
        let data=stdout.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        guard process.terminationStatus==0 else {throw CaptureFailure.message("连接检查失败；需要 Node.js 22.19 或更新版本")}
        let replies=data.split(separator:10).compactMap {try? JSONSerialization.jsonObject(with:Data($0)) as? [String:Any]}
        let tools=replies.first {$0["id"] as? Int==2}?["result"] as? [String:Any]
        guard let list=tools?["tools"] as? [[String:Any]],list.contains(where:{$0["name"] as? String=="recall_context"}) else {throw CaptureFailure.message("MCP 工具握手未通过")}
        return list.count
    }
    private func write(_ value:[String:Any],to url:URL) throws {
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private static func shellQuote(_ text:String) -> String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
}
