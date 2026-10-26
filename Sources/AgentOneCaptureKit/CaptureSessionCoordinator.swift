import Foundation

/// Serializes device transitions across MainActor suspension points. A mode change
/// must seal and release the old session before constructing a new writer/gate.
@MainActor final class CaptureSessionCoordinator {
    enum Mode: Equatable { case manual, intelligent, preserve }
    private(set) var mode: Mode?
    private var tail: Task<Void, Error>?
    private var revision = 0

    func start(mode requested: Mode,
               start: @escaping @MainActor () async throws -> Void,
               stop: @escaping @MainActor (String) async throws -> Void) async throws {
        try await enqueue {
            guard self.mode != requested else { return }
            if self.mode != nil {
                self.mode = nil
                try await stop("capture_mode_changed")
            }
            try await start()
            self.mode = requested
        }
    }

    func stop(reason: String, operation: @escaping @MainActor (String) async throws -> Void) async throws {
        try await enqueue {
            self.mode = nil
            try await operation(reason)
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        revision += 1
        let ownRevision = revision
        let task = Task { @MainActor in
            // A failed transition must not prevent a later pause or retry.
            _ = try? await previous?.value
            try await operation()
        }
        tail = task
        defer { if revision == ownRevision { tail = nil } }
        try await task.value
    }
}
