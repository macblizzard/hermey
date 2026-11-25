import XCTest
@testable import HermesKit

/// The live half of reaction sync: the frame the host publishes, decoded.
///
/// The host broadcasts one envelope for every change — `{"jsonrpc":"2.0","method":"event",
/// "params":{"type":"reaction.updated","session_id":…,"payload":{bot,session,message,emoji,by}}}` —
/// and both apps decode it with `ClientEvent`. The frames below are the real ones, captured from a
/// scratch host: a set, a replacement, and a removal. If the decoder stops answering
/// `.reactionUpdated` for these, a reaction made on the other device never reaches a row, which is
/// exactly the report this file exists to keep fixed.
final class ReactionEventTests: XCTestCase {

    private func frame(session: String, emoji: JSONValue, message: String = "row:1") -> JSONValue {
        .object([
            "bot": .string("cody"),
            "session": .string(session),
            "message": .string(message),
            "emoji": emoji,
            "by": .string("Mo's Mac"),
        ])
    }

    func testASetDecodesAsAnEmojiForTheNamedSession() throws {
        let events = GatewayEventDecoder.events(type: "reaction.updated",
                                                session: "attached-runtime",
                                                payload: frame(session: "20261125_101500_ab12cd",
                                                               emoji: .string("👍")))
        let event = try XCTUnwrap(events?.first)
        guard case .reactionUpdated(let bot, let session, let message, let emoji, let by) = event else {
            return XCTFail("a reaction.updated frame must decode as .reactionUpdated, got \(event)")
        }
        XCTAssertEqual(bot, "cody")
        // The frame's own session wins over the socket's: one socket serves several conversations.
        XCTAssertEqual(session, "20261125_101500_ab12cd")
        XCTAssertEqual(message, "row:1")
        XCTAssertEqual(emoji, "👍")
        XCTAssertEqual(by, "Mo's Mac")
    }

    func testARemovalArrivesAsNilRatherThanAsAMissingEvent() throws {
        // `null` is how the host says "cleared". An omitted field would be indistinguishable from
        // "not about me", and the badge would stay on the other device.
        let events = GatewayEventDecoder.events(type: "reaction.updated",
                                                session: "s",
                                                payload: frame(session: "20261125_101500_ab12cd",
                                                               emoji: .null))
        let event = try XCTUnwrap(events?.first)
        guard case .reactionUpdated(_, _, _, let emoji, _) = event else {
            return XCTFail("a cleared reaction is still a reaction event, got \(event)")
        }
        XCTAssertNil(emoji)
    }

    func testAMessageKeyTheHostCouldNotPlaceIsDropped() {
        // `row:`/`live:` is the host's rule, checked here as well: a frame for a key the host would
        // refuse is not something either app could have written, so it is dropped rather than
        // applied to whatever is open.
        for bad in ["41", "row:", "msg:1", "row:with space"] {
            XCTAssertEqual(GatewayEventDecoder.events(type: "reaction.updated",
                                                      session: "s",
                                                      payload: frame(session: "s",
                                                                     emoji: .string("👍"),
                                                                     message: bad))?.count,
                           0, bad)
        }
    }

    func testALiveRowAndAHostRowAreDifferentKeysForTheSameEmoji() {
        // The two apps must agree on which half a row uses; the decoder passes it through untouched.
        XCTAssertEqual(ReactionKey.message(rowID: 1, entryID: "r1"), "row:1")
        XCTAssertEqual(ReactionKey.message(rowID: nil, entryID: "r1"), "live:r1")
    }
}
