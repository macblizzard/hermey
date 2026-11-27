import Foundation

/// The loop's own account of what it did, for the log the user already knows how to send.
///
/// A hands-free conversation that never begins is invisible from the outside: the phone is in
/// someone's hand, the report is "nothing happens", and a screenshot cannot show whether the
/// microphone was ever opened, whether permission was answered, or whether the tap fired at all.
/// Every step from "the control was tapped" to "the first buffer arrived" writes one line here.
///
/// Two rules, because a log nobody can read is another silence:
///
/// * **A named step, not a paragraph.** `start: entered`, `permission: granted`,
///   `first buffer: 1440 frames`. The reader is comparing this against the moment it stopped
///   working, and the step that is missing is the answer.
/// * **A sink, not an import.** This module has no dependencies on purpose (the same loop runs in
///   both shells), so the shells install `ClientLog.note(_, level:, category: "voice")` and an
///   unwired sink is silent rather than fatal.
public final class VoiceLog: @unchecked Sendable {
    public static let shared = VoiceLog()

    private let lock = NSLock()
    private var sink: ((String) -> Void)?

    /// Install (or clear) the destination. Called once per shell, before the first tap.
    public func setSink(_ sink: ((String) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
    }

    /// Record one step. Safe from the audio thread, the main actor, or a background task — the
    /// sink is copied out under the lock and called outside it, so a sink that hops elsewhere
    /// cannot deadlock a caller mid-block.
    public func write(_ message: String) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(message)
    }

    public static func note(_ message: String) {
        shared.write(message)
    }
}
