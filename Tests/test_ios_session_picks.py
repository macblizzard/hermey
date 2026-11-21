"""A session picked by hand in All Sessions must survive the endless-chat opener.

`ConversationScreen.openConversation` asks `endlessSession(for:)`, which resolves the host's
canonical `Bot Chat` on every appear. Before `openSession` existed, a conversation picked in the
sessions sheet was resumed and then replaced a moment later — the pick visibly did not stick. These
contract tests pin the two halves of the fix so neither can be removed silently.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
MODEL = (ROOT / "Sources/HermesAppKit/AppModel.swift").read_text()
LIST = (ROOT / "Apps/HermesMobile/Views/BotListScreen.swift").read_text()


class TheModelRecordsAPickAndHonoursItOnce(unittest.TestCase):
    def test_the_model_exposes_open_session_with_a_bot_id(self):
        self.assertRegex(MODEL, r"public func openSession\(_ id: SessionID, for botID: String\) async")

    def test_the_pick_is_stored_before_the_resume(self):
        body = MODEL[MODEL.index("public func openSession(_ id: SessionID"):]
        body = body[: body.index("\n    }\n")]
        self.assertLess(body.index("pinnedSessionPicks[botID] = id"),
                        body.index("await select(id)"),
                        "a pick recorded after the resume can be overruled by an appear in between")

    def test_the_endless_opener_consumes_the_pick(self):
        opener = MODEL[MODEL.index("public func endlessSession(for botID: String, select: Bool = true) async"):]
        opener = opener[: opener.index("\n    }\n")]
        self.assertIn("pinnedSessionPicks.removeValue(forKey: botID)", opener,
                      "the pick must be taken, not merely read, or the canonical chat never returns")
        self.assertLess(opener.index("pinnedSessionPicks.removeValue"),
                        opener.index("CanonicalBotChat.plan"),
                        "a pick consumed after the plan is computed still loses to the canonical chat")


class TheSessionsSheetUsesIt(unittest.TestCase):
    def test_the_row_opens_through_the_model_not_a_bare_select(self):
        self.assertIn("await model.openSession(session.id, for: bot.id)", LIST)

    def test_the_old_known_gap_note_is_gone(self):
        self.assertNotIn("Known gap: `ConversationScreen.openConversation`", LIST)


if __name__ == "__main__":
    unittest.main()
