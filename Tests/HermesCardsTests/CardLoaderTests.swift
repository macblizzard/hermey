import XCTest
@testable import HermesCards
import HermesKit

/// The loader is the transcript's whole fetch policy, so these pin the four promises it makes:
/// one read per `(session, card)`, a failure remembered rather than retried, a tap that ticks the
/// chosen button and locks the rest, and prose that does not depend on any of it.
@MainActor
final class CardLoaderTests: XCTestCase {

    private func cardJSON(title: String = "Book the cabin") -> Data {
        Data("""
        {
          "schema": "card.v1",
          "kind": "approval",
          "title": "\(title)",
          "status": {"state": "awaiting-approval"},
          "body": [{"type": "text", "text": "Book the cabin?"}],
          "actions": [
            {"label": "Approve", "send": "APPROVE c-9b", "style": "primary"},
            {"label": "No", "send": "NO c-9b", "style": "danger"}
          ],
          "resolved": null
        }
        """.utf8)
    }

    private func ref(_ id: String = "c-9b") -> CardRef {
        CardRef(id: id, kind: "approval", file: "cards/\(id).json")
    }

    func testACardIsFetchedOnceAndRemembered() async {
        let loader = CardLoader()
        var calls = 0
        let fetch: CardLoader.Fetch = { _, _ in
            calls += 1
            return CardFetch(card: self.cardJSON(), mtime: "2026-11-22T21:04:06.120Z", final: false)
        }

        let first = await loader.load(ref(), session: "20261122_120000_abcdef", using: fetch)
        guard case .loaded(.available(let card)) = first else {
            return XCTFail("a valid document is a card, got \(first)")
        }
        XCTAssertEqual(card.title, "Book the cabin")
        XCTAssertEqual(card.actions.count, 2)

        // The same read twice is still one request: a body pass per frame must not be a round trip.
        let second = await loader.load(ref(), session: "20261122_120000_abcdef", using: fetch)
        XCTAssertEqual(second, first)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(loader.state(cardID: "c-9b", session: "20261122_120000_abcdef"), first)
    }

    func testASecondSessionIsItsOwnRead() async {
        let loader = CardLoader()
        var calls = 0
        let fetch: CardLoader.Fetch = { _, _ in
            calls += 1
            return CardFetch(card: self.cardJSON(), mtime: "", final: false)
        }

        _ = await loader.load(ref(), session: "20261122_120000_abcdef", using: fetch)
        _ = await loader.load(ref(), session: "20261123_090000_123456", using: fetch)
        XCTAssertEqual(calls, 2, "two sessions may hold two different files with one id")
    }

    func testAFailureIsRememberedAndIsNotRetried() async {
        let loader = CardLoader()
        var calls = 0
        let fetch: CardLoader.Fetch = { _, _ in
            calls += 1
            throw CardFetchError.noSuchCard
        }

        let first = await loader.load(ref(), session: "s1", using: fetch)
        XCTAssertEqual(first, .unavailable(.noSuchCard))
        XCTAssertNil(first.card)

        let second = await loader.load(ref(), session: "s1", using: fetch)
        XCTAssertEqual(second, .unavailable(.noSuchCard))
        XCTAssertEqual(calls, 1, "a refusal is an answer, not a reason to ask again on every frame")
    }

    func testANonRouteErrorStillDegradesInsteadOfThrowing() async {
        let loader = CardLoader()
        struct Whoops: Error {}
        let state = await loader.load(ref(), session: "s1") { _, _ in throw Whoops() }
        guard case .unavailable(.unreachable(let why)) = state else {
            return XCTFail("expected an unreachable answer, got \(state)")
        }
        XCTAssertFalse(why.isEmpty)
        // A transport failure is a finished read like any other: the row says so, and stops asking.
        XCTAssertTrue(state.isSettled)
    }

    func testABrokenDocumentIsUnavailableNotACrash() async {
        let loader = CardLoader()
        let state = await loader.load(ref(), session: "s1") { _, _ in
            CardFetch(card: Data("{not a card".utf8), mtime: "", final: false)
        }
        XCTAssertEqual(state, .loaded(.unavailable(CardModel.unavailableMessage)))
        // A document this client cannot draw is still a *finished* read: the row shows the apology
        // rather than waiting for a better answer that is never coming.
        XCTAssertTrue(state.isSettled)
        XCTAssertNil(state.card)
    }

    func testChoosingAnActionTicksItAndLocksTheRest() async throws {
        let loader = CardLoader()
        _ = await loader.load(ref(), session: "s1") { _, _ in
            CardFetch(card: cardJSON(), mtime: "", final: false)
        }
        let card = loader.state(cardID: "c-9b", session: "s1").card
        let approve = try XCTUnwrap(card?.actions.first)

        let ticked = loader.choose(approve, cardID: "c-9b", session: "s1")
        guard case .loaded(.available(let answered)) = ticked else {
            return XCTFail("a tap keeps the card, got \(ticked)")
        }
        XCTAssertTrue(answered.isResolved)
        XCTAssertEqual(answered.state(of: approve), .chosen)
        for other in answered.actions.dropFirst() {
            XCTAssertEqual(answered.state(of: other), .locked, other.label)
        }
        // The cache holds the tick too, so scrolling the row away does not undo the answer.
        XCTAssertEqual(loader.state(cardID: "c-9b", session: "s1"), ticked)
    }

    func testASecondTapCannotAnswerTwice() async throws {
        let loader = CardLoader()
        _ = await loader.load(ref(), session: "s1") { _, _ in
            CardFetch(card: cardJSON(), mtime: "", final: false)
        }
        let actions = try XCTUnwrap(loader.state(cardID: "c-9b", session: "s1").card?.actions)
        _ = loader.choose(actions[0], cardID: "c-9b", session: "s1")
        let again = loader.choose(actions[1], cardID: "c-9b", session: "s1")
        guard case .loaded(.available(let answered)) = again else {
            return XCTFail("still the card, got \(again)")
        }
        XCTAssertEqual(answered.resolved?.action, actions[0].send,
                       "the first answer is the answer")
    }

    func testAChoiceOnACardThatNeverLoadedChangesNothing() {
        let loader = CardLoader()
        let action = Card.Action(label: "Approve", send: "APPROVE c-9b")
        XCTAssertEqual(loader.choose(action, cardID: "c-9b", session: "s1"), .idle)
        XCTAssertEqual(loader.state(cardID: "c-9b", session: "s1"), .idle)
    }

    /// The prose is the message; a card is an extra. Stripping happens in the parser, and nothing a
    /// failed read does can put the marker back into the text the row shows.
    func testAFailedLoadLeavesTheProseExactlyAsWritten() {
        let text = """
        I wrote the card for you.

        ::card{id="c-9b" kind="approval" file="cards/c-9b.json"}

        Say yes and I will book it.
        """
        let scan = CardMarker.scan(text)
        XCTAssertEqual(scan.refs.count, 1)
        XCTAssertFalse(scan.prose.contains("::card"))
        XCTAssertTrue(scan.prose.contains("I wrote the card for you."))
        XCTAssertTrue(scan.prose.contains("Say yes and I will book it."))
    }

    func testResetForgetsEveryRead() async {
        let loader = CardLoader()
        _ = await loader.load(ref(), session: "s1") { _, _ in
            CardFetch(card: cardJSON(), mtime: "", final: false)
        }
        loader.reset()
        XCTAssertEqual(loader.state(cardID: "c-9b", session: "s1"), .idle)
    }
}

/// `CardFetch` and its error are the client's contract, not the renderer's: the route's codes must
/// survive the trip as themselves.
final class CardFetchErrorTests: XCTestCase {
    private func body(_ code: String) -> Data {
        Data("{\"error\":\"\(code)\",\"detail\":\"…\"}".utf8)
    }

    func testTheRoutesCodesMapToOneCaseEach() {
        XCTAssertEqual(CardFetchError(status: 404, body: body("no_such_card")), .noSuchCard)
        XCTAssertEqual(CardFetchError(status: 400, body: body("bad_id")), .badId)
        XCTAssertEqual(CardFetchError(status: 413, body: body("too_large")), .tooLarge)
        XCTAssertEqual(CardFetchError(status: 403, body: body("outside_base")), .outsideBase)
        XCTAssertEqual(CardFetchError(status: 422, body: body("bad_card")), .badCard)
    }

    func testTheStatusIsTheFallbackWhenTheBodyIsNotJSON() {
        XCTAssertEqual(CardFetchError(status: 404, body: Data("<html>".utf8)), .noSuchCard)
        XCTAssertEqual(CardFetchError(status: 401, body: Data()), .refused(status: 401, code: nil))
    }

    func testAnIDWithAPathInItIsRefusedBeforeARequestIsBuilt() {
        XCTAssertTrue(CardFetchError.isValidID("c-9b"))
        XCTAssertTrue(CardFetchError.isValidID("c_9-b"))
        XCTAssertFalse(CardFetchError.isValidID("../c-9b"))
        XCTAssertFalse(CardFetchError.isValidID("c-9b.json"))
        XCTAssertFalse(CardFetchError.isValidID(String(repeating: "a", count: 41)))
        XCTAssertFalse(CardFetchError.isValidID(""))
    }
}
