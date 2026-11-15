"""Search inside conversations, and a bot's message drawn as a person.

Asked for 2026-11-15: "search in bot list should search for all the items on all bot conversations
and list the findings rather than just bot names", and a bot-to-bot exchange should read
`Messaged <face> Aria` / `Message from <face> Cody` rather than a bare text prefix.

These are source-shape tests: the bridge behaviour itself is covered by
`Bridge/tests/test_bot_search.py` and `Bridge/tests/test_bot_transfers.py`.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "Bridge" / "hermes_bridge"
SEARCH = (BRIDGE / "bot_search.py").read_text(encoding="utf-8")
TRANSFERS = (BRIDGE / "bot_transfers.py").read_text(encoding="utf-8")
MESSAGE = (BRIDGE / "bot_message.py").read_text(encoding="utf-8")
APP_PY = (BRIDGE / "app.py").read_text(encoding="utf-8")

KIT_SEARCH = (ROOT / "Sources" / "HermesKit" / "BotSearch.swift").read_text(encoding="utf-8")
POINTER = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
IOS_LIST = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
IOS_ROW = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text(encoding="utf-8")
MAC_LIST = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift").read_text(encoding="utf-8")
MAC_VIEW = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
MAC_ROW = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift").read_text(encoding="utf-8")


class TheHostSearchesTranscripts(unittest.TestCase):
    def test_the_route_exists_and_is_mounted(self) -> None:
        self.assertIn('@router.get("/search")', SEARCH)
        self.assertIn("create_bot_search_router(runtime)", APP_PY)

    def test_it_reads_each_profile_read_only(self) -> None:
        # A search must never block a bot's own writes, and must not need write access at all.
        self.assertIn("mode=ro", SEARCH)
        self.assertIn('directory / "state.db"', SEARCH)

    def test_one_character_is_not_a_search(self) -> None:
        self.assertIn("MIN_QUERY = 2", SEARCH)
        self.assertIn('if len(needle) < MIN_QUERY:', SEARCH)

    def test_a_bot_cannot_fill_the_page_by_itself(self) -> None:
        self.assertIn("PER_BOT = 20", SEARCH)
        self.assertIn("LIMIT ?", SEARCH)

    def test_the_answer_is_a_snippet_not_a_transcript(self) -> None:
        self.assertIn("SNIPPET_PAD = 80", SEARCH)
        self.assertIn('"snippet": snippet', SEARCH)


class TheAppsAskForFindings(unittest.TestCase):
    def test_the_client_has_the_two_verbs(self) -> None:
        for token in ("func searchTranscripts", "func botTransfers"):
            self.assertIn(token, POINTER)
            self.assertIn(token, (ROOT / "Sources" / "HermesKit" / "GatewayClient.swift").read_text(encoding="utf-8"))
            self.assertIn(token, (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text(encoding="utf-8"))

    def test_a_typed_query_is_percent_encoded(self) -> None:
        self.assertIn("addingPercentEncoding(withAllowedCharacters: .alphanumerics)", POINTER)

    def test_the_last_answer_wins(self) -> None:
        # A slower answer to an older query must not replace the newer one.
        self.assertIn("searchToken += 1", MODEL)
        self.assertIn("guard token == searchToken else { return }", MODEL)

    def test_both_lists_draw_findings_above_the_bot_rows(self) -> None:
        self.assertIn("findingsSection", IOS_LIST)
        self.assertIn("model.searchPage.hits", IOS_LIST)
        self.assertIn("model.searchPage.hits", MAC_LIST)

    def test_typing_is_debounced_rather_than_asked_per_keystroke(self) -> None:
        self.assertIn("250_000_000", IOS_LIST)
        self.assertIn("searchTranscripts(for: typed)", MAC_VIEW)


class ABotMessageReadsAsAPerson(unittest.TestCase):
    def test_the_label_names_the_sender_when_the_caller_knows_it(self) -> None:
        self.assertIn("sender_profile", MESSAGE)
        self.assertIn('f"{sender.title()} ({sender_profile})"', MESSAGE)

    def test_every_exchange_is_recorded(self) -> None:
        self.assertIn("record_transfer(runtime", MESSAGE)
        self.assertIn('"bot-transfers.jsonl"', TRANSFERS)
        # Append-only, and rotated so a long-lived host does not fill its disk.
        self.assertIn('path.open("a"', TRANSFERS)
        self.assertIn("MAX_BYTES = 4 * 1024 * 1024", TRANSFERS)

    def test_the_pair_can_be_read_back(self) -> None:
        self.assertIn('@router.get("/bot-transfers")', TRANSFERS)
        self.assertIn("{first, second} <= pair", TRANSFERS)
        self.assertIn("create_bot_transfers_router(runtime)", APP_PY)

    def test_the_parser_understands_both_labels(self) -> None:
        # "Assistant (cody) → Ops: …" and the legacy "Assistant → Ops: …" — old rows keep their
        # attribution; only the sender's profile is unknown.
        self.assertIn('text.range(of: " → ")', KIT_SEARCH)
        self.assertIn("senderProfile = inside", KIT_SEARCH)
        self.assertIn("incomingTitle", KIT_SEARCH)
        self.assertIn("outgoingTitle", KIT_SEARCH)

    def test_both_apps_draw_the_attribution(self) -> None:
        self.assertIn("BotMessageLabel.parse(entry.text)", IOS_ROW)
        self.assertIn("BotMessageLabel.parse(entry.text)", MAC_ROW)
        self.assertIn('Text(label.incomingTitle)', IOS_ROW)
        self.assertIn('Text(label.incomingTitle)', MAC_ROW)


if __name__ == "__main__":
    unittest.main()
