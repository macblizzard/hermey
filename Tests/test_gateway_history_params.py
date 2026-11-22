"""`session.history` must send only what the gateway's contract allows.

The gateway declares `session.history` with `SessionHistoryParams`, which is `SessionParams` —
`session_id` and `profile`, nothing else — and its pydantic model refuses extra inputs. Asking for a
`limit` therefore failed every call with "limit: Extra inputs are not permitted".

Trimming belongs on this side, and already happens: `GatewayPayloadDecoder.history` returns
`entries.suffix(limit)`.

The launch sweep no longer uses this call at all: `session.history` resolves in-memory live sessions
only, so a *stored* id is refused whatever the profile (see `test_prefetch_and_return_are_current`).
What remains here is the contract for the call a live pane makes with the runtime id a resume
returned.
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLIENT = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text()
DECODER = (ROOT / "Sources" / "HermesKit" / "GatewayEventDecoder.swift").read_text()


class TheHistoryCallMatchesTheContract(unittest.TestCase):
    def test_no_limit_is_sent_to_the_gateway(self) -> None:
        call = CLIENT.split("public func history(_ id: SessionID, limit: Int, profile: String?)", 1)[1]
        call = call.split("return try", 1)[0]
        self.assertIn('"session_id": .string(id)', call)
        self.assertNotIn('"limit"', call,
                         "the gateway's SessionParams has no limit field; sending one fails the call")

    def test_the_read_names_the_bot_it_is_for(self) -> None:
        # Same contract, the other half: `SessionParams` is `session_id` **and** `profile`. Left
        # out, a multiplexed gateway resolves the id against its default profile only and answers
        # `4007 session not found` for every other bot — the launch prefetch's eighteen failures.
        call = CLIENT.split("public func history(_ id: SessionID, limit: Int, profile: String?)", 1)[1]
        call = call.split("return try", 1)[0]
        self.assertIn('params["profile"] = .string(profile)', call,
                      "session.history must carry the bot's profile")

    def test_paging_still_sends_a_limit(self) -> None:
        # `historyPage` is answered by the bridge, not the gateway, and the bridge's paging route
        # reads `limit` — so the two calls deliberately differ.
        page = CLIENT.split("public func historyPage(", 1)[1].split("return try", 1)[0]
        self.assertIn('"cursor"', page)
        self.assertIn('"limit"', page)

    def test_the_trim_happens_on_this_side(self) -> None:
        decoder = DECODER.split("static func history(", 1)[1].split("static func", 1)[0]
        self.assertIn("entries.suffix(limit)", decoder)


if __name__ == "__main__":
    unittest.main()
