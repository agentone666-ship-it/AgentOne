import Foundation

struct CaptureOperationTimeout:LocalizedError {
    let message:String
    var errorDescription:String? {message}
}

/// Framework continuations can fail to complete. A task-group timeout would
/// still wait for a noncooperative child; this race resumes the caller once.
@MainActor enum CaptureDeadline {
    private final class Reply {
        var continuation:CheckedContinuation<Void,Error>?
        init(_ continuation:CheckedContinuation<Void,Error>) {self.continuation=continuation}
        func finish(_ result:Result<Void,Error>) {guard let value=continuation else{return};continuation=nil;value.resume(with:result)}
    }
    static func perform(seconds:Double,message:String,operation:@escaping @MainActor () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let reply=Reply(continuation)
            let task=Task { @MainActor in
                do {try await operation();reply.finish(.success(()))} catch {reply.finish(.failure(error))}
            }
            Task { @MainActor in
                do {try await Task.sleep(for:.seconds(seconds))} catch {return}
                guard reply.continuation != nil else {return}
                reply.finish(.failure(CaptureOperationTimeout(message:message)));task.cancel()
            }
        }
    }
}
