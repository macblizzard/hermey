"""Search inside conversations, and a bot's message drawn as a person.

Asked for 2026-11-15: "search in bot list should search for all the items on all bot conversations
and list the findings rather than just bot names", and a bot-to-bot exchange should read
`Messaged <face> Aria` / `Message from <face> Cody` rather than a bare text prefix.

These are source-shape tests. The host behaviour itself is covered by the Rust tests beside it in
`hermeyd/src/search.rs` and `hermeyd/src/transfers.rs` (`cargo test` in `hermeyd/`).
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAIR = (ROOT / "Sources" / "HermeyUI" / "BotPairSheet.swift").read_text(encoding="utf-8")
IOS_SCREEN = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
MAC_SCROLL = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptScroll.swift").read_text(encoding="utf-8")
# The host service is the Rust crate in `hermeyd/` now.
BRIDGE = ROOT / "hermeyd" / "src"
SEARCH = (BRIDGE / "search.rs").read_text(encoding="utf-8")
TRANSFERS = (BRIDGE / "transfers.rs").read_text(encoding="utf-8")
MESSAGE = (BRIDGE / "bot_message.rs").read_text(encoding="utf-8")
APP_PY = (BRIDGE / "main.rs").read_text(encoding="utf-8")

KIT_SEARCH = (ROOT / "Sources" / "HermesKit" / "BotSearch.swift").read_text(encoding="utf-8")
POINTER = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
IOS_LIST = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
IOS_ROW = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text(encoding="utf-8")
MAC_LIST = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift").read_text(encoding="utf-8")
MAC_VIEW = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
MAC_ROW = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift").read_text(encoding="utf-8")


class TheRelayStampIsAHeader(unittest.TestCase):
    def test_the_hosts_stamp_is_parsed(self) -> None:
        self.assertIn('text.hasPrefix("Message from 🤖 ")', KIT_SEARCH)
        self.assertIn('text.hasPrefix("Message to 🤖 ")', KIT_SEARCH)
        self.assertIn("parseRelayStamp(text)", KIT_SEARCH)
        self.assertIn("public let isOutgoing: Bool", KIT_SEARCH)
        self.assertIn("public var headerTitle: String", KIT_SEARCH)

    def test_both_apps_draw_the_header_above_the_body(self) -> None:
        for name, row in (("iOS", IOS_ROW), ("macOS", MAC_ROW)):
            with self.subTest(platform=name):
                self.assertIn("Text(label.headerTitle)", row)
                self.assertLess(row.index("Text(label.headerTitle)"), row.index("MarkdownTextView(text: label.body") if "MarkdownTextView" in row else row.index("IncrementalMarkdown.parse(markdownCache.sanitized(label.body))"))


class TheHostSearchesTranscripts(unittest.TestCase):
    def test_the_route_exists_and_is_mounted(self) -> None:
        # Retargeted from `hermes_bridge/bot_search.py` (deleted with the Python bridge).
        self.assertIn('"/v1/search"', APP_PY)
        self.assertIn("search::search", APP_PY)
        self.assertIn("pub async fn search(", SEARCH)

    def test_it_reads_each_profile_read_only(self) -> None:
        # A search must never block a bot's own writes, and must not need write access at all.
        self.assertIn("OpenFlags::SQLITE_OPEN_READ_ONLY", SEARCH)
        self.assertIn('"state.db"', SEARCH)

    def test_one_character_is_not_a_search(self) -> None:
        self.assertIn("const MIN_QUERY: usize = 2", SEARCH)
        self.assertIn("if needle.chars().count() < MIN_QUERY", SEARCH)

    def test_a_bot_cannot_fill_the_page_by_itself(self) -> None:
        self.assertIn("const PER_BOT: usize = 20", SEARCH)
        self.assertIn("LIMIT ?2", SEARCH)

    def test_the_answer_is_a_snippet_not_a_transcript(self) -> None:
        self.assertIn("const SNIPPET_PAD: usize = 80", SEARCH)
        self.assertIn('"snippet": snip', SEARCH)


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
        # The Mac's field: 200 ms of quiet, the previous wait cancelled, and the model's own token
        # behind it — so a fast typist asks the host once and a slow answer to an older phrase can
        # never land on top of a newer one.
        self.assertIn("searchTask?.cancel()", MAC_VIEW)
        self.assertIn("200_000_000", MAC_VIEW)
        self.assertIn("SidebarSearch.minimumQuery", MAC_VIEW)


class TheMacPanelSearchesEveryConversation(unittest.TestCase):
    """The desktop's one field: findings above the bots, one keyboard walking both.

    The rules themselves are held by `Tests/HermesAppKitTests/SidebarSearchTests` — ordering,
    the cursor, and the state machine. These contracts are about the wiring: that the view uses
    that type rather than a second copy of the rules, and that the states the user reads exist.
    """

    def test_the_rules_live_in_one_tested_type(self) -> None:
        source = (ROOT / "Sources" / "HermesAppKit" / "SidebarSearch.swift").read_text(encoding="utf-8")
        self.assertIn("public enum SidebarSearchPhase", source)
        self.assertIn("public struct SidebarSearchSelection", source)
        self.assertIn("public static func rows(hits: [BotSearchHit], botIDs: [String])", source)
        # One floor, the host's own: two characters.
        self.assertIn("public static let minimumQuery = 2", source)
        # The view asks it rather than re-deriving the rules with its own `if`s.
        self.assertIn("SidebarSearch.phase(query:", MAC_LIST)
        self.assertIn("SidebarSearch.rows(hits:", MAC_VIEW)
        self.assertIn("SidebarSearch.matches(", MAC_LIST)

    def test_the_messages_section_is_headed_with_a_total(self) -> None:
        self.assertIn('SectionCaption("MESSAGES · \\(model.searchPage.total)")', MAC_LIST)
        # ...and counts zero when the transcripts had nothing but a bot name matched, so the panel
        # never looks like it only filtered the roster.
        self.assertIn('SectionCaption("MESSAGES · 0")', MAC_LIST)

    def test_a_request_in_flight_says_so(self) -> None:
        self.assertIn('Text("Searching…")', MAC_LIST)
        self.assertIn("case .searching:", MAC_LIST)

    def test_one_character_asks_for_a_second_rather_than_reporting_nothing(self) -> None:
        self.assertIn('"Type at least 2 characters to search messages."', MAC_LIST)
        # The bridge will not answer below two (`MIN_QUERY`), so this is the host's floor stated.
        self.assertIn("case .tooShort:", MAC_LIST)

    def test_nothing_at_all_names_the_phrase_once(self) -> None:
        self.assertIn("case .noMatches:", MAC_LIST)
        self.assertIn("No matches for “\\(trimmedQuery)”", MAC_LIST)

    def test_the_snippet_is_emphasised_by_range_not_markup(self) -> None:
        self.assertIn("private func emphasising(_ hit: BotSearchHit) -> AttributedString", MAC_LIST)
        self.assertIn("AttributedString(hit.snippet)", MAC_LIST)
        self.assertIn("text[found].font", MAC_LIST)
        # A snippet is a conversation, not a document: nothing parses markup into the row.
        self.assertNotIn("NSAttributedString(data:", MAC_LIST)
        self.assertNotIn("<b>", MAC_LIST)

    def test_the_keyboard_walks_the_combined_list(self) -> None:
        self.assertIn("onMoveUp: { moveHighlight(-1) }", MAC_VIEW)
        self.assertIn("onMoveDown: { moveHighlight(1) }", MAC_VIEW)
        self.assertIn("onSubmit: { openHighlighted() }", MAC_VIEW)
        self.assertIn("onEscape: { closeSearch() }", MAC_VIEW)
        self.assertIn("searchSelection.opening", MAC_VIEW)
        self.assertIn("highlighted: searchSelection.highlighted", MAC_VIEW)
        # The field really delivers those keys; a closure nobody calls is not a shortcut.
        field = (ROOT / "Apps" / "HermesMac" / "Views" / "MacSidebarSearchField.swift").read_text(encoding="utf-8")
        for key in (".onKeyPress(.upArrow)", ".onKeyPress(.downArrow)", ".onKeyPress(.escape)", ".onSubmit"):
            self.assertIn(key, field)

    def test_a_finding_opens_the_bot_then_the_phrase(self) -> None:
        store = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
        self.assertIn("func openSearchHit(_ hit: BotSearchHit, query: String)", store)
        self.assertIn("selectBot(hit.profile)", store)
        # The wait is for the conversation, not for a guess at how long a resume takes.
        self.assertIn("while model.selectedSessionID == nil", store)
        # The bar is opened *with* the phrase, tied to the request it belongs to.
        self.assertIn("findSeedRequest = findRequest + 1", store)
        scroll = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptScroll.swift").read_text(encoding="utf-8")
        # The phrase is applied once, by `pendingSeed`, and retired so a later ⌘F does not replay it.
        self.assertIn("guard findSeedRequest == findRequest, findSeedRequest != appliedSeedRequest", scroll)
        self.assertIn("search.query = seed", scroll)


class ABotMessageReadsAsAPerson(unittest.TestCase):
    def test_the_label_names_the_sender_when_the_caller_knows_it(self) -> None:
        self.assertIn("sender_profile", MESSAGE)
        # The name is title-cased, except for the pet: its wire id is `desktop-pet` and the sentence
        # must read `Desktop Pet`, so the branch names that title instead of slug-casing the id.
        self.assertIn("fn label(", MESSAGE)
        self.assertIn('format!("{} ({profile})", sender_title)', MESSAGE)
        self.assertIn('if sender == PET_SENDER { PET_TITLE.to_string() }', MESSAGE)

    def test_every_exchange_is_recorded(self) -> None:
        self.assertIn("fn record_transfer(", MESSAGE)
        self.assertIn('"bot-transfers.jsonl"', TRANSFERS)
        # Append-only, and rotated so a long-lived host does not fill its disk.
        self.assertIn("OpenOptions::new()", TRANSFERS)
        self.assertIn("const MAX_BYTES: u64 = 4 * 1024 * 1024", TRANSFERS)

    def test_the_pair_can_be_read_back(self) -> None:
        self.assertIn('"/v1/bot-transfers"', APP_PY)
        self.assertIn("transfers::list_transfers", APP_PY)
        self.assertIn("pub between: String", TRANSFERS)
        self.assertIn('json!({ "between": [first, second], "entries": entries })', TRANSFERS)

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
        self.assertIn('Text(label.headerTitle)', IOS_ROW)
        self.assertIn('Text(label.headerTitle)', MAC_ROW)


class TheAttributionOpensTheExchange(unittest.TestCase):
    def test_the_sheet_draws_both_directions_with_faces(self) -> None:
        self.assertIn("public struct BotPairSheet", PAIR)
        self.assertIn("entry.fromProfile", PAIR)
        self.assertIn("BotAvatarView(identity: sender", PAIR)
        self.assertIn("color: faces[sender]?.raw", PAIR)
        # An empty record says so rather than showing a blank page.
        self.assertIn("Nothing between these two yet", PAIR)

    def test_the_phone_opens_it_from_the_attribution(self) -> None:
        self.assertIn("pairPeer = label.senderProfile", IOS_ROW)
        self.assertIn("BotPairSheet(current: botID, peer: peer.id", IOS_ROW)
        # The row has to know which conversation it is in: the near side of the pair.
        self.assertIn("botID: bot.id", IOS_SCREEN)

    def test_the_mac_opens_it_from_the_attribution(self) -> None:
        self.assertIn("onOpenPair?(profile)", MAC_ROW)
        self.assertIn("onOpenPair: { peer in pairPeer = peer }", MAC_SCROLL)
        # The sheet lives in the transcript, not the row: a row is torn down as it scrolls.
        self.assertIn("BotPairSheet(current: model.selectedBotID", MAC_SCROLL)


if __name__ == "__main__":
    unittest.main()
