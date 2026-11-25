import Foundation

/// The long messages the reader has opened out, remembered across rows.
///
/// A row in a lazy stack is destroyed when it leaves the viewport and rebuilt when it comes back, so
/// `@State` alone forgets an expansion two screens later — the reader taps "Show full message",
/// scrolls on, scrolls back, and finds the message collapsed again. The set is keyed by the
/// message's own id, which is also the identity the transcript rows are drawn by, so the answer is
/// the same before and after a rebuild.
///
/// Bounded: a person opens a handful of long rows, and the oldest is forgotten past `limit`.
/// Forgetting is safe — it only means a row draws its preview again.
public final class ExpandedLongRows {
    public static let shared = ExpandedLongRows()

    /// How many open rows are remembered. Enough for a reading session; small enough to be nothing.
    public static let limit = 64

    private let lock = NSLock()
    private var ids: [String] = []

    public init() {}

    public func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }

    public func insert(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
    }

    /// For a test, and for a row whose message was replaced by an edited one.
    public func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        ids.removeAll { $0 == id }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        ids.removeAll()
    }
}
