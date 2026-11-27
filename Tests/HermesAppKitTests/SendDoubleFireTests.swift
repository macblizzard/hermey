#if canImport(Combine)
import XCTest
@testable import HermesAppKit
import HermesKit

/// Send must claim the turn before its first await.
///
/// An edit in flight truncates the old message on the host, and the round trip takes a round of the
/// wire. A second tap of Send — or ⌘↩ — that arrives inside that window used to pass the
/// `!sending` guard and truncate and submit the same message a second time. The claim is now
/// synchronous, before anything awaits, and these tests hold both halves: one truncate, one prompt.
@MainActor
final class SendDoubleFireTests: XCTestCase {

    /// Two Sends fired while the edit's truncate is still on the wire: the second must be refused.
    ///
    /// The scripted truncate is deliberately slow, so the window the bug lived in is wide: the
    /// second call lands *inside* the first's pending-edit round trip, where `sending` used to
    /// still be false.
    func test_a_second_send_inside_the_edit_round_trip_is_refused() async {
        let host = ScriptedHost(session: "s1", entries: [
            TranscriptEntry(id: "u1", rowID: 11, role: .user, text: "old ask"),
        ])
        host.bridge = true
        host.truncateDelay = .milliseconds(150)
        let model = AppModel(client: host)
        await model.start()
        await model.select("s1")
        XCTAssertEqual(model.transcript.map(\.rowID), [11])

        model.requestEditAndResend(TranscriptEntry(id: "u1", rowID: 11, role: .user,
                                                   text: "old ask"))
        XCTAssertEqual(model.pendingEdit?.rowID, 11)
        model.draft = "new ask"

        let first = Task { await model.send() }
        let second = Task { await model.send() }
        await first.value
        await second.value

        // One truncate, one prompt: the second Send never reached the host. The turn is still
        // streaming (nothing ended it), and that is not the bug under test.
        XCTAssertEqual(host.truncateCalls, [11],
                       "the same truncate was attempted twice — the second Send was not refused")
        XCTAssertEqual(host.submitted, ["new ask"])
        XCTAssertEqual(model.draft, "")
        XCTAssertNil(model.lastSendError)
        XCTAssertFalse(model.sending, "the claim must be released when the send returns")
    }

    /// Two Sends on an ordinary message: the claim also holds when there is no edit to wait for.
    func test_a_second_send_on_an_ordinary_message_is_refused() async {
        let host = ScriptedHost(session: "s1", entries: [
            TranscriptEntry(id: "u1", rowID: 11, role: .user, text: "earlier"),
        ])
        let model = AppModel(client: host)
        await model.start()
        await model.select("s1")
        model.draft = "hello"
        let first = Task { await model.send() }
        let second = Task { await model.send() }
        await first.value
        await second.value
        XCTAssertEqual(host.submitted, ["hello"])
        XCTAssertEqual(model.draft, "")
    }
}
#endif
