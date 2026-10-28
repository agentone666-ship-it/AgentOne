import AppKit
import AgentOneCaptureKit
import Darwin
import Foundation

/// On-demand, on-device transcription of a verified local source. This does not
/// start capture, change permissions or replace the persisted transcript.
@MainActor enum HeadlessSpeechCheck {
    static func runIfRequested() {
        let args=CommandLine.arguments
        guard let flag=args.firstIndex(of:"--transcribe-segment"),flag+1<args.count else {return}
        let id=args[flag+1]
        Task { @MainActor in
            do {
                let database=try MemoryDatabase()
                let row=try database.rows("SELECT sha256 FROM segments WHERE id=? AND state='sealed'",[id]).first
                let worker=LocalTranscriptionWorker(database:database)
                let (text,utterances)=try await worker.recognizeAuthorizedAudio(database.verifiedAudioURL(id))
                let data=try JSONEncoder().encode(utterances)
                let result:[String:Any]=["segment_id":id,"source_sha256":row?["sha256"] ?? "","engine":"apple-on-device-windowed-v2","text":text,"utterances":try JSONSerialization.jsonObject(with:data)]
                print(String(decoding:try JSONSerialization.data(withJSONObject:result),as:UTF8.self))
                Darwin.exit(0)
            } catch {fputs("On-device transcription check failed: \(error.localizedDescription)\n",stderr);Darwin.exit(1)}
        }
        RunLoop.main.run()
        Darwin.exit(1)
    }
}
