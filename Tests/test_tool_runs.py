"""Folding tool calls into one row, pinned.

A turn can make thirty calls. Drawn as thirty cards they push the answer off the screen, and the
failure mode is invisible in a test that only renders a two-call turn — so the rule itself (only
consecutive tool rows, only two or more) and both transcripts' use of it are asserted here.
"""
from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GROUPING = (ROOT / "Sources/HermesKit/TranscriptGrouping.swift").read_text()
GROUP_VIEW = (ROOT / "Sources/OpenBotUI/ToolRunGroup.swift").read_text()
MAC_SCROLL = (ROOT / "Apps/HermesMac/Conversation/TranscriptScroll.swift").read_text()
IOS_CHAT = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text()
IOS_ROW = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text()


class GroupingTests(unittest.TestCase):
    def test_the_rule_is_consecutive_tool_rows_only(self) -> None:
        self.assertIn("if entry.role == .tool {", GROUPING)
        self.assertIn("pending.append(entry)", GROUPING)
        # A message flushes the run: a group must never swallow the answer between its calls.
        self.assertIn("flush()\n                rows.append(.entry(entry))", GROUPING)

    def test_one_call_is_not_a_group(self) -> None:
        self.assertIn("if pending.count == 1 {", GROUPING)
        self.assertIn("rows.append(.entry(pending[0]))", GROUPING)

    def test_the_run_is_named_after_its_first_call(self) -> None:
        # Otherwise every new call in the run would re-create the row and close the disclosure.
        self.assertIn('self.id = "run-" + (entries.first?.id ?? UUID().uuidString)', GROUPING)


class WordingTests(unittest.TestCase):
    def test_the_counts_and_the_plural_live_in_one_place(self) -> None:
        self.assertIn("Running a command…", GROUP_VIEW)
        self.assertIn('"Running \\(count) commands…"', GROUP_VIEW)
        self.assertIn("Ran 1 command", GROUP_VIEW)
        self.assertIn('"Ran \\(count) commands"', GROUP_VIEW)
        self.assertIn('" · \\(failures) failed"', GROUP_VIEW)

    def test_failures_are_read_from_the_result_not_the_arguments(self) -> None:
        self.assertIn("ToolPayload.failed(raw: $0.tool?.content)", GROUP_VIEW)


class AppTests(unittest.TestCase):
    def test_both_transcripts_group(self) -> None:
        for source, name in ((MAC_SCROLL, "mac"), (IOS_CHAT, "ios")):
            # Grouped through the memo: the rows themselves still come from `TranscriptGrouping`,
            # but whether to walk the transcript again is decided by a signature, because a body
            # pass happens on every published token (2026-11-14).
            self.assertIn("rowCache.rows(", source, name)
            self.assertIn("TranscriptRowCache", source, name)
            self.assertIn("case .toolRun(let run):", source, name)
            self.assertIn("ToolRunGroup(run: run)", source, name)

    def test_the_running_calls_are_folded_in_not_drawn_twice(self) -> None:
        # The phone used to draw its live tools in a section of their own; inside the grouped rows
        # they would appear twice.
        self.assertIn("model.visibleLiveToolEntries", IOS_CHAT)
        self.assertNotIn("liveToolsSection", IOS_CHAT)
        self.assertIn("running: runningToolIDs", IOS_CHAT)

    def test_a_card_in_a_run_still_knows_it_is_running(self) -> None:
        self.assertIn("var running: Set<String> = []", IOS_ROW)
        self.assertIn("isRunning: running.contains(entry.id)", IOS_ROW)

    def test_the_disclosure_starts_closed(self) -> None:
        self.assertIn("@State private var expanded = false", GROUP_VIEW)


if __name__ == "__main__":
    unittest.main()
