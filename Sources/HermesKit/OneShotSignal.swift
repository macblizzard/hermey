import Foundation

/// A one-shot hand-off of exactly one value to exactly one waiter.
///
/// The client parks a call on this and later resumes it from whichever side wins — the matching
/// response frame, the per-call timeout, a connection drop, or task cancellation. "Exactly once" is
/// the whole point: `CheckedContinuation` traps if it is resumed twice, and a timeout racing a
/// response is the normal case, not the exception.
final class OneShotSignal<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var settled: Result<Value, Error>?

    func wait() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                lock.lock()
                if let existing = self.settled {
                    lock.unlock()
                    continuation.resume(with: existing)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            self.settle(.failure(CancellationError()))
        }
    }

    func settle(_ result: Result<Value, Error>) {
        lock.lock()
        guard settled == nil else {
            lock.unlock()
            return
        }
        settled = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

/// `TransportState` behind a lock so it can be read without `await` (the connection chip polls it
/// from the main actor) while the actor mutates it.
final class TransportStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TransportState = .idle

    var current: TransportState {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ new: TransportState) {
        lock.lock()
        value = new
        lock.unlock()
    }
}
