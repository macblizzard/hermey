import Foundation

/// Broadcasts decoded events without tying the transport pump to any observer's lifetime.
/// Each subscription buffers at most 1,024 events, keeping the newest on overflow. This is a
/// live feed, not history/replay: events emitted with no subscribers are intentionally discarded.
/// A stalled observer cannot grow memory without bound or block another observer/the RPC pump.
final class ClientEventHub: @unchecked Sendable {
    // All mutable state is protected by lock. Never yield/finish while holding it: terminating a
    // continuation can synchronously call onTermination, which takes this same lock.
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<ClientEvent>.Continuation] = [:]
    private var finished = false
    private let bufferLimit: Int

    init(bufferLimit: Int = 1_024) {
        precondition(bufferLimit > 0)
        self.bufferLimit = bufferLimit
    }

    func subscribe() -> AsyncStream<ClientEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ClientEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(bufferLimit))
        // Weak capture is essential: the hub owns continuations, and a continuation owns this
        // callback. Neither a cancelled observer nor an abandoned stream may keep the hub alive.
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished { subscribers[id] = continuation }
        lock.unlock()
        if alreadyFinished { continuation.finish() }
        return stream
    }

    /// Called serially by GatewayClient's actor, preserving event order per subscriber.
    func yield(_ event: ClientEvent) {
        lock.lock()
        let current = Array(subscribers.values)
        lock.unlock()
        for continuation in current { continuation.yield(event) }
    }

    func finish() {
        lock.lock()
        finished = true
        let current = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        for continuation in current { continuation.finish() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }

    /// Internal visibility lets lifetime tests verify that cancellation actually releases entries.
    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribers.count
    }

    deinit { finish() }
}
