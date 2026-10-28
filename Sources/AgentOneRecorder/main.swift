import Foundation
import AppKit
import AgentOneCaptureKit
import Darwin

@main struct RecorderMain {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--inspect-microphone") {
            print(String(decoding:try JSONSerialization.data(withJSONObject:NativeAudioCaptureService.microphoneSelection()),as:UTF8.self));return
        }
        if CommandLine.arguments.contains("--self-check") {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("agentone-recorder-self-check-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            do {_=try MemoryDatabase(root:root)}
            catch {FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));Darwin.exit(78)}
            print("{\"agent_runtime\":false,\"role\":\"native_audio_recorder\",\"recording_started\":false}");return
        }
        guard let index=CommandLine.arguments.firstIndex(of:"--root"),index+1<CommandLine.arguments.count else {return}
        let root=URL(fileURLWithPath:CommandLine.arguments[index+1])
        if CommandLine.arguments.contains("--prune-silence") {
            let database=try MemoryDatabase(root:root)
            let report=try await Task.detached(priority:.utility) {try SilencePruner.scan(database:database,apply:CommandLine.arguments.contains("--apply"))}.value
            print(String(decoding:try JSONEncoder().encode(report),as:UTF8.self));return
        }
        if CommandLine.arguments.contains("--request-system-reconnect") {
            try RecorderSupervisor.requestSystemReconnect(root:root);return
        }
        if CommandLine.arguments.contains("--supervisor-self-check") || CommandLine.arguments.contains("--supervisor-pause-self-check") {
            try await RecorderSupervisor.run(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[0]),fixture:true,fixturePause:CommandLine.arguments.contains("--supervisor-pause-self-check"));return
        }
        if CommandLine.arguments.contains("--worker") {
            _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
            let host=try RecorderHost(root:root);try await host.run();return
        }
        // An ordinary UI Process object is not a supervisor after its UI has died.
        // This small native parent survives independently and restarts only its recorder.
        let executable=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        try await RecorderSupervisor.run(root:root,executable:executable)
    }
}
