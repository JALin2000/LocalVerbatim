import Foundation

private final class ContinuationRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func resolve(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: result)
    }
}

/// Unlike a task group, this returns when an OS callback ignores cancellation.
/// Callers that start a resource must explicitly clean up a late success.
@MainActor
func boundedOperation<T>(seconds: Double, message: String, operation: @escaping @MainActor () async throws -> T) async throws -> T {
    let race = ContinuationRace<T>()
    let worker = Task { @MainActor in
        do { race.resolve(.success(try await operation())) }
        catch { race.resolve(.failure(error)) }
    }
    let timeout = Task { @MainActor in
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        catch { return }
        race.resolve(.failure(NSError(domain: "LocalVerbatim.Timeout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
        worker.cancel()
    }
    defer { timeout.cancel() }
    return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { race.install($0) }
    }, onCancel: { worker.cancel(); race.resolve(.failure(CancellationError())) })
}
