"""`session.history` must send only what the gateway's contract allows.

The gateway declares `session.history` with `SessionHistoryParams`, which is `SessionParams` —
`session_id` and `profile`, nothing else — and its pydantic model refuses extra inputs. Asking for a
`limit` therefore failed every call with "limit: Extra inputs are not permitted", which is invisible
in the app except as a prefetch that never warms anything: the reported "I still have to open each
chat after a start".

Trimming belongs on this side, and already happens: `GatewayPayloadDecoder.history` returns
`entries.suffix(limit)`.
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLIENT = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text()
DECODER = (ROOT / "Sources" / "HermesKit" / "GatewayEventDecoder.swift").read_text()


class TheHistoryCallMatchesTheContract(unittest.TestCase):
    def test_no_limit_is_sent_to_the_gateway(self) -> None:
        call = CLIENT.split("public func history(", 1)[1].split("return try", 1)[0]
        self.assertIn('"session_id": .string(id)', call)
        self.assertNotIn('"limit"', call,
                         "the gateway's SessionParams has no limit field; sending one fails the call")

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
