"""The card wiring, pinned at the source.

`Sources/HermesCards` and its Swift tests are covered by `test_cards_client.py`; this file is the
*join* between them and the rest of the app, which no compiler on this box can check:

* the gateway read call exists, with the route the engine actually serves — including the message
  id the host keys its snapshot on;
* the route's refusals arrive as distinct errors, so the view degrades instead of spinning;
* the loader is a fetch-once cache keyed by `(session, message, card id)` that never polls;
* both transcripts parse `::card{…}` **after** the A2UI check and **before** the genui `::blocks`
  check, honour `cards.enabled`, and pass the row's own message id;
* a failed read leaves the prose alone, and an action goes out through the ordinary send path.
"""
from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

CLIENT = (ROOT / "Sources/HermesKit/GatewayClient.swift").read_text()
ACTOR = (ROOT / "Sources/HermesKit/GatewayClientActor.swift").read_text()
BRIDGE = (ROOT / "Sources/HermesKit/EndlessSessionPointer.swift").read_text()
FETCH = (ROOT / "Sources/HermesKit/CardFetch.swift").read_text()
APP_MODEL = (ROOT / "Sources/HermesAppKit/AppModel.swift").read_text()
LOADER = (ROOT / "Sources/HermesCards/CardLoader.swift").read_text()
LOADER_TESTS = (ROOT / "Tests/HermesCardsTests/CardLoaderTests.swift").read_text()
ROUTE_TESTS = (ROOT / "Tests/HermesKitTests/CardRouteTests.swift").read_text()

MAC = (ROOT / "Apps/HermesMac/Conversation/TranscriptRowView.swift").read_text()
MAC_SCROLL = (ROOT / "Apps/HermesMac/Conversation/TranscriptScroll.swift").read_text()
IOS = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text()

SIGNATURE = "func card(id: String, session: SessionID, message: String) async throws -> CardFetch"


def body(source: str, start: str, end: str) -> str:
    """The slice of a Swift file between two markers, so an ordering claim cannot pass by accident."""
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


class GatewayReadTests(unittest.TestCase):
    def test_the_client_method_is_the_route_the_engine_serves(self) -> None:
        # Protocol requirement and the actor's implementation, both named the same, both carrying
        # the message id the host snapshots on.
        self.assertIn(SIGNATURE, CLIENT)
        self.assertIn(SIGNATURE, ACTOR)
        # …and the implementation is on the bridge store, like every other `/v1` read.
        self.assertIn("sessionPointer.card(id: id, session: session, message: message)", ACTOR)

    def test_the_bridge_builds_the_cards_route_with_both_parameters(self) -> None:
        route = body(BRIDGE, "public func card(id: String, session sessionID", "public func approvalSettings")
        self.assertIn('.appendingPathComponent("cards")', route)
        self.assertIn('.appendingPathComponent(id)', route)
        # `sessionID`, not `session`: a parameter called `session` shadows the URLSession in scope and
        # `session.data(for:)` then resolves against a String (that is exactly how it broke once).
        self.assertIn('URLQueryItem(name: "session", value: sessionID)', route)
        # The message id is the snapshot's second key. Omitting it is the collision this closes.
        self.assertIn('URLQueryItem(name: "message", value: message)', route)
        self.assertLess(route.index('name: "session"'), route.index('name: "message"'),
                        "the documented order is session, then message")
        # Same credential shape as its neighbours: one ticket per request, on the Authorization header.
        self.assertIn('request.setValue("Bearer \\(endpoint.ticket)"', route)
        # The id is checked before a path is built, so a caller that skipped the parser cannot
        # reshape the URL into another route.
        self.assertIn("CardFetchError.isValidID(id)", route)
        self.assertIn("throw CardFetchError.badId", route)

    def test_the_route_codes_are_kept_apart(self) -> None:
        for code in ("no_such_card", "bad_id", "too_large", "outside_base", "bad_card"):
            self.assertIn(f'case "{code}"', FETCH, code)
        # Each wire code is its own case, so the view can tell "gone" from "never fetchable".
        for case in ("case noSuchCard", "case badId", "case tooLarge", "case outsideBase", "case badCard"):
            self.assertIn(case, FETCH, case)
        # The status is only the fallback for a body that was not the route's JSON.
        self.assertIn("public init(status: Int, body: Data)", FETCH)

    def test_a_client_with_no_bridge_degrades_instead_of_hanging(self) -> None:
        self.assertIn('throw CardFetchError.unreachable("this connection has no bridge to read cards from")',
                      CLIENT)
        self.assertIn("guard let sessionPointer else {", ACTOR)

    def test_the_app_sends_the_transcript_to_the_client(self) -> None:
        # A Mac row holds no model; the pane hands it one closure to the model's own read.
        self.assertIn("public func fetchCard(id: String, session: SessionID, message: String) async throws -> CardFetch",
                      APP_MODEL)
        self.assertIn("try await client.card(id: id, session: session, message: message)", APP_MODEL)
        self.assertIn("fetchCard: { id, session, message in", MAC_SCROLL)
        self.assertIn("try await model.fetchCard(id: id, session: session, message: message)", MAC_SCROLL)

    def test_the_message_id_is_the_rows_own(self) -> None:
        # A host row is `row:<id>`; a message still streaming is `live:<id>`. Both are stable
        # per message, which is what the snapshot key needs.
        self.assertIn("public var messageID: String", CLIENT)
        self.assertIn('rowID.map { "row:\\($0)" } ?? "live:\\(id)"', CLIENT)

    def test_the_request_itself_is_pinned_in_swift(self) -> None:
        # The Python assertions above can see the parameter in the source; only a request can see
        # it in the URL, so `CardRouteTests` records one through a URLProtocol stub.
        for name in (
            "testTheCardRequestCarriesTheSessionAndTheMessage",
            "testTwoMessagesAskForTheirOwnSnapshots",
            "testTheAnswerKeepsItsMtimeAndItsFinalFlag",
            "testARefusalKeepsItsOwnCode",
            "testAnIDThatCouldBeAPathIsRefusedBeforeARequestExists",
            "testAnEmptyMessageStillAsksForTheEmptyKey",
        ):
            self.assertIn(name, ROUTE_TESTS, name)
        self.assertIn('XCTAssertEqual(request.path, "/v1/cards/c-9b")', ROUTE_TESTS)
        self.assertIn('XCTAssertEqual(request.query["message"], "row:42"', ROUTE_TESTS)


class LoaderTests(unittest.TestCase):
    def test_the_cache_is_keyed_by_session_message_and_card(self) -> None:
        self.assertIn("private struct Key: Hashable", LOADER)
        self.assertIn("let session: String", LOADER)
        self.assertIn("let message: String", LOADER)
        self.assertIn("let cardID: String", LOADER)
        self.assertIn("Key(session: session, message: message, cardID: ref.id)", LOADER)
        # The key is read back the same way it is written.
        self.assertIn("states[Key(session: session, message: message, cardID: cardID)]", LOADER)

    def test_one_fetch_per_card_and_a_shared_flight(self) -> None:
        self.assertIn("public enum State: Equatable, Sendable", LOADER)
        self.assertIn("case idle", LOADER)
        self.assertIn("case loading", LOADER)
        self.assertIn("case loaded(CardModel)", LOADER)
        self.assertIn("case unavailable(CardFetchError)", LOADER)
        # A settled read — success *or* failure — is returned without a second request.
        self.assertIn("if let known = states[key], known.isSettled { return known }", LOADER)
        self.assertIn("private var inFlight: [Key: Task<State, Never>] = [:]", LOADER)
        self.assertIn("if let running = inFlight[key] { return await running.value }", LOADER)

    def test_the_fetch_carries_the_message_too(self) -> None:
        # The transport signature and the call: a loader that keyed by message but asked without it
        # would still fetch the wrong snapshot.
        self.assertIn("public typealias Fetch = (_ id: String, _ session: String, _ message: String) async throws -> CardFetch",
                      LOADER)
        self.assertIn("try await fetch(ref.id, session, message)", LOADER)

    def test_cards_never_poll(self) -> None:
        for clock in ("Timer", "Task.sleep", "while true", "DispatchQueue.main.asyncAfter"):
            self.assertNotIn(clock, LOADER, clock)
        # The only thing that reads again is the cache being empty (or reset by hand).
        self.assertIn("public func reset()", LOADER)

    def test_a_tap_ticks_the_chosen_action_and_locks_the_rest(self) -> None:
        self.assertIn("resolved: Card.Resolved(action: action.send)", LOADER)
        self.assertIn("!card.isResolved", LOADER)
        # The card itself is never mutated: the tick is a copy of the host's document, and an
        # optimistic tick must not lose the draft email it was drawn from.
        self.assertIn("public func choose(_ action: Card.Action,", LOADER)
        self.assertIn("message: String) -> State", LOADER)
        self.assertIn("email: card.email)", LOADER)

    def test_the_loader_cases_are_pinned_in_swift(self) -> None:
        for name in (
            "testACardIsFetchedOnceAndRemembered",
            "testASecondSessionIsItsOwnRead",
            "testTwoMessagesNamingOneCardAreTwoReads",
            "testTheFetchCarriesTheMessagesID",
            "testAFailureIsRememberedAndIsNotRetried",
            "testABrokenDocumentIsUnavailableNotACrash",
            "testChoosingAnActionTicksItAndLocksTheRest",
            "testASecondTapCannotAnswerTwice",
            "testAFailedLoadLeavesTheProseExactlyAsWritten",
        ):
            self.assertIn(name, LOADER_TESTS, name)


class HookTests(unittest.TestCase):
    def assert_hooked(self, source: str, start: str, end: str, name: str, prose_render: str) -> None:
        row = body(source, start, end)

        # The order is the contract: A2UI, then cards, then the genui board.
        a2ui = row.index("A2UISurfaceSettings.isEnabled")
        cards = row.index("cardScan.refs.isEmpty")
        genui = row.index("GenUITag.boardID(in:")
        self.assertLess(a2ui, cards, name)
        self.assertLess(cards, genui, name)

        # The marker parser is what decides there is a card at all. It reads the reply with any
        # bot-made workspace link already taken out: that link is a file row, not prose.
        self.assertRegex(source,
                         r"CardMarker\.scan\((?:entry\.text|WorkspaceLinkScan\.scan\(entry\.text\)\.prose)\)",
                         name)

        # `cards.enabled` is honoured: off means today's plain text, nothing stripped, nothing read.
        self.assertIn("CardsSettings.isEnabled", source, name)
        self.assertIn("private var cardsActive", source, name)

        # The app's own palette is mapped in, because HermesCards may not import HermeyUI.
        self.assertIn("CardTheme(canvas: Tokens.canvas", source, name)
        self.assertIn("accent: Tokens.accent", source, name)
        self.assertIn("surface: Tokens.surface", source, name)
        self.assertIn("ink: Tokens.textPrimary", source, name)

        # The card is drawn for every ref, and the prose is the prose the parser left behind —
        # rendered as text, ahead of the cards, never merely referenced.
        self.assertIn("CardView(model: model, theme: cardTheme)", source, name)
        bubble = body(source, "private func cardBubble", "private func loadCards")
        self.assertIn(prose_render, bubble, name)
        self.assertLess(bubble.index(prose_render), bubble.index("ForEach(Array(scan.refs"), name)

        # A failed read is one line under the prose, never a spinner.
        self.assertIn(".unavailable(CardModel.unavailableMessage)", source, name)
        self.assertIn("case .idle, .loading:", source, name)

        # A tap is the ordinary send path: the same notification a genui button posts.
        self.assertIn("NotificationCenter.default.post(name: .genUICardSend", source, name)
        self.assertIn('"text": action.send', source, name)
        self.assertNotIn("URLSession", source, name)

    def test_the_mac_transcript_hooks_cards_between_a2ui_and_genui(self) -> None:
        self.assert_hooked(MAC, "private var assistantRow", "// MARK: Native cards", "macOS",
                           "MarkdownTextView(text: scan.prose)")

    def test_the_phone_transcript_hooks_cards_between_a2ui_and_genui(self) -> None:
        self.assert_hooked(IOS, "private var assistant:", "// MARK: Native cards", "iOS",
                           "rawText: scan.prose")

    def test_the_phone_reads_through_the_model_in_its_environment(self) -> None:
        self.assertIn("try await app.model.fetchCard(id: id, session: cardSession, message: message)", IOS)

    def test_both_transcripts_send_the_rows_message_id(self) -> None:
        # The row knows its own message; the read and the tick both carry it, so two replies naming
        # one card file never share a snapshot.
        for source, name in ((MAC, "macOS"), (IOS, "iOS")):
            self.assertIn("message: entry.messageID", source, name)
            self.assertIn("CardLoader.shared.load(ref,", source, name)
            self.assertIn("CardLoader.shared.choose(action,", source, name)
            # Nothing reads a card without one: the old two-argument call is gone.
            self.assertNotIn("CardLoader.shared.load(ref, session: session) {", source, name)
            self.assertNotIn("choose(action, cardID: ref.id, session: session)", source, name)

    def test_the_mac_row_hands_the_closure_three_arguments(self) -> None:
        self.assertIn("var fetchCard: ((String, SessionID, String) async throws -> CardFetch)? = nil", MAC)
        self.assertIn("try await fetchCard(id, cardSession, message)", MAC)

    def test_the_marker_line_survives_when_the_flag_is_off(self) -> None:
        # With `cards.enabled` off the card branch is skipped entirely, so the genui check and then
        # the plain markdown fallback see `entry.text` untouched — `::card{…}` renders as text.
        for source in (MAC, IOS):
            row = body(source, "private var assistant", "// MARK: Native cards")
            self.assertIn("entry.text", row)
            self.assertNotIn("CardMarker.textWithoutMarkers(entry.text)", row)


class DraftEditPathTests(unittest.TestCase):
    """A typed draft leaves through the door every card's button already used.

    The card view composes the turn and hands it over as an ordinary `Card.Action`, so neither
    shell knows what an editable draft is: the hook still posts `action.send` and still ticks the
    action through the loader. Discard never reaches the host at all.
    """

    VIEW = (ROOT / "Sources/HermesCards/CardView.swift").read_text()

    def test_the_composed_turn_is_a_card_action_like_any_other(self) -> None:
        self.assertIn('onAction?(Card.Action(label: "Send",', self.VIEW)
        self.assertIn("send: typed.composedSend(lead: action?.send)", self.VIEW)
        # One callback, unchanged in shape: whoever wired the card up needs to learn nothing.
        self.assertIn("onAction: ((Card.Action) -> Void)? = nil", self.VIEW)

    def test_no_hook_needs_to_know_about_editing(self) -> None:
        for source, name in ((MAC, "macOS"), (IOS, "iOS")):
            self.assertIn('"text": action.send', source, name)
            self.assertIn("CardLoader.shared.choose(action,", source, name)
            for word in ("DraftEditor", "composedSend", "discarded"):
                self.assertNotIn(word, source, f"{name}: {word}")

    def test_discard_never_reaches_the_host(self) -> None:
        controls = self.VIEW[self.VIEW.index("private func draftControls"):
                              self.VIEW.index("private func draftButton")]
        self.assertIn("self.discarded = true", controls)
        self.assertNotIn("onAction?", controls, "discard is local: it posts no turn")

    def test_the_cards_stay_dumb_about_the_transport(self) -> None:
        # The composed turn is text in an action, never a second way to reach the engine.
        self.assertNotIn("NotificationCenter", self.VIEW)
        self.assertNotIn("URLSession", self.VIEW)


if __name__ == "__main__":
    unittest.main()
