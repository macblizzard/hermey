"""A host error belongs to the conversation its frame named — not to whatever pane is open.

The owner's screenshot: the `cody` pane carried "Hermes could not start the assistant for this
session … No LLM provider configured" while cody's own conversation was fine. The app opens sessions
for other bots in the background (the preview sweep), one socket serves all of them, and `.error`
carried no session at all: `AppModel` assigned the text straight to `lastSendError`, which both apps
draw as the red banner over the open transcript. So a failure that had nothing to do with the open
conversation was painted in it.

The fix has two halves that must agree, and neither suite can see the other:

* `HermesKit` puts the frame's session on the event (it was decoded and then thrown away);
* `HermesAppKit` shows the text only when that session is the one on screen, and logs the rest under
  `session`. The conversation on screen is not silenced, and a failed send is still reported to the
  person who pressed send — that path is a `catch`, not this event.

The Swift sources are read as text; the behaviour itself is pinned by
`Tests/HermesAppKitTests/HostErrorScopeTests.swift`.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

KIT = (ROOT / "Sources" / "HermesKit" / "GatewayClient.swift").read_text(encoding="utf-8")
DECODER = (ROOT / "Sources" / "HermesKit" / "GatewayEventDecoder.swift").read_text(encoding="utf-8")
ACTOR = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
BEHAVIOUR = ROOT / "Tests" / "HermesAppKitTests" / "HostErrorScopeTests.swift"


def block(source: str, opening: str, closing: str) -> str:
    """The text between one marker and the next, both exclusive."""
    assert opening in source, f"{opening!r} is gone"
    tail = source.split(opening, 1)[1]
    assert closing in tail, f"{closing!r} did not follow {opening!r}"
    return tail.split(closing, 1)[0]


BRANCH = block(MODEL, "        case .error(let session, _, let message):",
               "        case .unknown:")
DECODE = block(DECODER, '        case "error":', "        default:")


class TheEventCarriesItsSession(unittest.TestCase):
    """It was on the wire and normalised for every other event type — except this one."""

    def test_the_event_has_a_session(self) -> None:
        self.assertIn("case error(session: SessionID, code: Int?, message: String)", KIT)

    def test_the_decoder_puts_the_frames_session_on_it(self) -> None:
        self.assertIn(".error(session: session,", DECODE)
        self.assertIn('payload["code"]?.intValue.map { Int($0) }', DECODE)
        self.assertIn('message: payload["message"]?.stringValue', DECODE)

    def test_the_socket_is_what_tells_the_decoder_which_session(self) -> None:
        # The envelope's own `session_id`, normalised to the stored id by `attributedSession`.
        self.assertIn("let session = attributedSession(params[\"session_id\"]?.stringValue)", ACTOR)
        self.assertIn("GatewayEventDecoder.events(type: type, session: session, payload: payload)", ACTOR)

    def test_the_two_errors_the_client_makes_itself_have_a_session_too(self) -> None:
        # A torn frame names no conversation: it carries the attached one, or "" for none.
        self.assertIn('yield(.error(session: attachedStoredID ?? "", code: -32700,', ACTOR)
        # A failed replay belongs to the session it was replaying.
        self.assertIn("yield(.error(session: attributedSession(resumed.runtimeID),", ACTOR)


class TheModelScopesItToTheOpenConversation(unittest.TestCase):

    def test_the_session_is_resolved_through_the_runtime_aliases(self) -> None:
        # A frame may name the runtime id the host minted; the pane knows the stored one.
        self.assertIn("let named = sessionAliases[session] ?? session", BRANCH)

    def test_an_error_for_another_session_is_logged_and_never_shown(self) -> None:
        self.assertIn("guard !named.isEmpty, named == selectedSessionID else {", BRANCH)
        dropped = BRANCH.split("guard !named.isEmpty, named == selectedSessionID else {", 1)[1]
        dropped = dropped.split("return", 1)[0]
        self.assertIn("ClientLog.note(", dropped, "a dropped error still leaves a trace")
        self.assertIn('category: "session"', dropped)
        self.assertIn("is open:", dropped, "the log says which conversation was on screen")

    def test_the_open_conversation_keeps_its_banner(self) -> None:
        self.assertIn("lastSendError = message", BRANCH)
        self.assertLess(BRANCH.index("guard !named.isEmpty, named == selectedSessionID else {"),
                        BRANCH.index("lastSendError = message"),
                        "the text is painted after the scope check, never before it")
        self.assertIn('level: .error, category: "gateway"', BRANCH,
                      "the on-screen case is still an error in the log")

    def test_this_is_the_only_place_a_host_error_becomes_the_banner(self) -> None:
        self.assertEqual(MODEL.count("lastSendError = message"), 1)
        self.assertIn("case .error(let session, _, let message):", MODEL)
        # And no other branch reads a host error without asking which session it was about.
        self.assertNotIn("case .error(_, let message)", MODEL)

    def test_a_failed_send_is_still_reported_to_whoever_pressed_send(self) -> None:
        # The send path reports from its own `catch`; this change never touches it.
        self.assertIn("lastSendError = error.localizedDescription", MODEL)
        self.assertIn('lastSendError = "could not start a session: \\(error.localizedDescription)"', MODEL)

    def test_both_apps_read_that_one_drawing(self) -> None:
        for view in ("Apps/HermesMac/Conversation/MacComposerBar.swift",
                     "Apps/HermesMobile/Views/ConversationScreen.swift"):
            source = (ROOT / view).read_text(encoding="utf-8")
            self.assertIn("model.lastSendError", source,
                          f"{view} draws the banner from the model, so the scoping covers it")


class TheBehaviourIsPinnedInSwift(unittest.TestCase):
    """The two cases that matter, asserted where the model actually runs."""

    def test_the_two_cases_have_a_test(self) -> None:
        self.assertTrue(BEHAVIOUR.is_file(), "the behaviour test for this scoping is gone")
        source = BEHAVIOUR.read_text(encoding="utf-8")
        self.assertIn("func testAnErrorForAnotherSessionIsNotPaintedHere()", source)
        self.assertIn("func testAnErrorForTheOpenSessionStillShows()", source)
        other = block(source, "func testAnErrorForAnotherSessionIsNotPaintedHere() async {",
                      "func testAnErrorForTheOpenSessionStillShows()")
        self.assertIn('host.emit(.error(session: "another-bots-session"', other)
        self.assertIn("XCTAssertNil(model.lastSendError", other)


if __name__ == "__main__":
    unittest.main()
