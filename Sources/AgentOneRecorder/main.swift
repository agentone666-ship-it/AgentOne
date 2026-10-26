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
            _=try MemoryDatabase(root:root);try FileManager.default.removeItem(at:root)
            print("{\"agent_runtime\":false,\"role\":\"native_audio_recorder\",\"recording_started\":false}");return
        }
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        guard let index=CommandLine.arguments.firstIndex(of:"--root"),index+1<CommandLine.arguments.count else {return}
        let root=URL(fileURLWithPath:CommandLine.arguments[index+1])
        if CommandLine.arguments.contains("--worker") {
            let host=try RecorderHost(root:root);try await host.run();return
        }
        // An ordinary UI Process object is not a supervisor after its UI has died.
        // This small native parent survives independently and restarts only its recorder.
        let fd=Darwin.open(root.appendingPathComponent("recorder-supervisor.lock").path,O_CREAT|O_RDWR,0o600)
        guard fd>=0 else {return};defer{Darwin.close(fd)}
        guard Darwin.lockf(fd,F_TLOCK,0)==0 else {return}
        let executable=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        var failures=0
        while !Task.isCancelled {
            let child=Process();child.executableURL=executable;child.arguments=["--worker","--root",root.path]
            child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice
            let start=Date()
            do {try child.run();while child.isRunning {try await Task.sleep(for:.milliseconds(200))}} catch {}
            if Date().timeIntervalSince(start)>30 {failures=0}
            failures+=1;try await Task.sleep(for:.seconds(min(10,pow(2,Double(min(failures-1,4))))))
        }
    }
}
