"""A runtime session id is not news.

After the backend move the host service hands out a fresh *runtime* id every time a session is attached,
and the launch prefetch attaches many. The transcript treated each announced id as "a session moved",
so returning to a bot resumed and re-painted it — reported as content shifting/jumping while scrolling
his own messages, with the log repeating `resuming: … the socket named a newer session for this bot`.

`sessionAliases` already maps runtime id → stored id. These assertions pin that both the recording path
and the decision path use it, so the noise cannot creep back.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
APPMODEL = REPO_ROOT / "Sources" / "HermesAppKit" / "AppModel.swift"


class ARuntimeAliasIsNotASecondConversation(unittest.TestCase):
    def setUp(self) -> None:
        self.text = APPMODEL.read_text()

    def test_an_aliased_id_is_not_recorded_as_unseen(self) -> None:
        body = re.search(r"private func noteUnseen\(_\s*session: SessionID\)\s*\{(.*?)\n    \}", self.text, re.S)
        self.assertIsNotNone(body, "noteUnseen should still exist")
        self.assertIn(
            "sessionAliases[session] == nil",
            body.group(1),
            "an announced runtime id aliases a stored session we already know; recording it as unseen "
            "makes every return look like a moved conversation",
        )

    def test_the_decision_translates_announced_ids_before_comparing(self) -> None:
        # The comparison must canonicalise: `known == cachedSession`, never the raw announced id.
        self.assertIn("let known = sessionAliases[announced] ?? announced", self.text)
        self.assertIn("return known == cachedSession || sessionBots[known] == botID", self.text)
        self.assertNotIn(
            "unseenSessions.contains { $0 == cachedSession || sessionBots[$0] == botID }",
            self.text,
            "comparing the raw announced id is what caused the spurious resume",
        )

    def test_the_reason_is_still_logged(self) -> None:
        # The fix removes a false positive; it must not silence the true one.
        self.assertIn("the socket named a newer session for this bot", self.text)


if __name__ == "__main__":
    unittest.main()
