"""A reply the socket names with an id this app cannot place must still reach the screen.

Reported twice: the reply does not appear in the open conversation until you switch to another bot and
come back, while the bot list already shows its preview. The list is fed by the sweep, the transcript by
the socket — so the event was arriving and being *dropped*: `apply` calls `adoptMovedConversation`, and
when that fails it returns without applying.

Dropping is right — applying another conversation's session to the open transcript would put one bot's
words in another's chat. Being silent is not: the fix re-reads the conversation on screen, debounced so a
turn's delta storm collapses into one read.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
APPMODEL = REPO_ROOT / "Sources" / "HermesAppKit" / "AppModel.swift"


class ADroppedEventBecomesARead(unittest.TestCase):
    def setUp(self) -> None:
        self.text = APPMODEL.read_text()

    def test_the_unplaceable_branch_re_reads_instead_of_only_returning(self) -> None:
        # The branch still records the session as unseen and still returns — it must also schedule a read.
        branch = re.search(
            r"else if known != open \{(.*?)\n            \}", self.text, re.S
        )
        self.assertIsNotNone(branch, "the adopt-failure branch should still exist")
        body = branch.group(1)
        self.assertIn("noteUnseen(named)", body)
        self.assertIn("scheduleOpenRefresh()", body)
        self.assertIn("return", body)

    def test_the_refresh_is_debounced(self) -> None:
        helper = re.search(r"private func scheduleOpenRefresh\(\) \{(.*?)\n    \}", self.text, re.S)
        self.assertIsNotNone(helper, "scheduleOpenRefresh should exist")
        body = helper.group(1)
        self.assertIn("pendingOpenRefresh == nil", body, "one read per burst, not one per delta")
        self.assertIn("refreshTranscript(sid)", body)
        self.assertIn("pendingOpenRefresh = nil", body, "the guard must be released or no later read runs")

    def test_it_does_not_apply_a_foreign_session(self) -> None:
        # The safety property: the read replaces nothing by injecting another session's content.
        branch = re.search(r"else if known != open \{(.*?)\n            \}", self.text, re.S)
        body = branch.group(1)
        self.assertNotIn("selectedSessionID = named", body)


if __name__ == "__main__":
    unittest.main()
