"""Getting the log out of the app: selectable rows, two copy actions, and a share sheet.

Reported twice by the owner: "in View log I cannot select multiple lines", and then — with a
screenshot of build 0.1.611 on macOS — a sheet whose only buttons were *Close* and *Refresh*, while
the Copy, Share and Clear `ToolbarItem`s sat in the source. A test that only reads the file cannot
tell the difference between a control that exists and a control the sheet draws, so these pin
*where* each control lives, not merely that its name appears somewhere in `ClientLogView.swift`.

The shapes, then: the row's own `Text` is selectable; the two copy actions take different lists and
serialise through one formatter; the share affordance hands that same text to the system; the
confirmation carries a count; and every one of them sits inside `controls` — the block that also
holds the entry count, which the Mac sheet has always drawn.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOG = (ROOT / "Sources" / "HermeyUI" / "ClientLogView.swift").read_text(encoding="utf-8")
# The model the sheet draws from: the four copy scopes and the words they are offered in.
MODEL = (ROOT / "Sources" / "HermesKit" / "ClientLog.swift").read_text(encoding="utf-8")

# The sheet's body: everything above the toolbar declaration. A control that appears down here is
# rendered by the content; one that appears below it is at the mercy of the sheet's toolbar.
BODY = LOG.split("// MARK: Toolbar", 1)[0]
# Just the toolbar block itself, so "not in the toolbar" means exactly that.
TOOLBAR = LOG.split("private var toolbar", 1)[1].split("// MARK: Behaviour", 1)[0]


def block(source: str, start: str, end: str) -> str:
    """The text between two markers, with a failure that names the missing marker."""
    if start not in source:
        raise AssertionError(f"expected to find {start!r}")
    return source.split(start, 1)[1].split(end, 1)[0]


class TheRowsCanBeSelected(unittest.TestCase):
    def setUp(self) -> None:
        self.row = block(LOG, "private func row(_ entry: ClientLogEntry) -> some View {",
                         "private var emptyState")

    def test_the_row_text_is_selectable(self) -> None:
        # SwiftUI's only selection story for a `Text` run. Per row, because a `LazyVStack` of `Text`
        # cannot be dragged across — which is what "Copy shown" is for.
        self.assertIn("Text(entry.line)", self.row)
        self.assertIn(".textSelection(.enabled)", self.row)

    def test_selecting_a_row_does_not_fight_the_row(self) -> None:
        # Nothing the reader drags over should also be a button: no row-level tap to swallow the
        # long-press, and no gesture that would end the selection on lift.
        self.assertNotIn(".onTapGesture", self.row)
        self.assertNotIn("TapGesture(", self.row)

    def test_the_list_inherits_selection_too(self) -> None:
        # A future row built from more than one view should inherit the ability to be read rather
        # than silently lose it.
        self.assertIn(".textSelection(.enabled)", block(BODY, "LazyVStack(alignment: .leading",
                                                        ".scrollDismissesKeyboard"))


class CopyIsAMenuOfFour(unittest.TestCase):
    """Two copies became four (build 0.1.663): a portion of the log, as well as all of it.

    The menu itself is pinned in `test_log_tail_and_upload.py`; what this file has always guarded is
    the *where* — a control in the sheet's body rather than in a toolbar the Mac sheet may not draw —
    and that the four still hand over different lists through one formatter.
    """

    def setUp(self) -> None:
        self.menu = block(LOG, "private var copyMenu: some View", "/// The sentence under each menu item")

    def test_the_copy_control_is_a_menu_in_the_body(self) -> None:
        self.assertIn("Menu {", self.menu)
        self.assertIn("ForEach(ClientLogCopyScope.allCases)", self.menu)
        self.assertIn("Button(scope.title(available: availableCount(scope)))", self.menu)
        self.assertIn('handoffLabel("Copy…"', self.menu)

    def test_copy_shown_takes_the_filtered_feed_and_the_others_the_log(self) -> None:
        # `feed.entries` holds back what a paused tail has not taken up, so the tails and "all" read
        # the log itself — one query, so the filter narrows every one of the four.
        copy = block(LOG, "private func copy(_ scope: ClientLogCopyScope)", "private func copy(_ entries:")
        self.assertIn("copy(shown, scope: .shown)", copy)
        self.assertIn("copy(logEntries(limit: scope.lineLimit), scope: scope)", copy)
        entries = block(LOG, "private func logEntries(limit: Int?)", "/// How many lines the log would hand")
        self.assertIn("ClientLog.shared.snapshot()", entries)
        self.assertIn("query.apply(to: buffer, limit: limit)", entries)

    def test_the_four_actions_hand_over_different_lists(self) -> None:
        # Not four labels on one behaviour: the scope is passed to the same entry point and the
        # receipt says which one was kept.
        self.assertIn('handoffLabel("Copy…"', LOG)
        self.assertIn("scope: .all", LOG)
        self.assertIn("scope: .shown", LOG)
        self.assertIn("case .all, .last100, .last500:", LOG)

    def test_there_is_still_one_formatter(self) -> None:
        self.assertEqual(LOG.count("ClientLog.text(of:"), 1)
        self.assertIn("private func exportText(_ entries: [ClientLogEntry]) -> String", LOG)
        # Every way out goes through it — the list on screen, the scopes read from the log, and the
        # upload — and none of them builds its own string on the way. Two `exportText(entries)` call
        # sites is the point: the copy and the file the host receives are the same bytes.
        self.assertEqual(LOG.count("exportText(shown)"), 1)
        self.assertEqual(LOG.count("exportText(entries)"), 2)
        self.assertNotIn("map(\\.line)", LOG)

    def test_a_copy_of_nothing_is_not_announced(self) -> None:
        body = block(LOG, "private func copy(_ entries: [ClientLogEntry]", "private func write(")
        self.assertIn("guard !entries.isEmpty else { return }", body)
        self.assertIn("write(exportText(entries))", body)


class TheReceiptSaysHowMuchWasCopied(unittest.TestCase):
    def test_the_confirmation_carries_a_count(self) -> None:
        # The sentences live with the scopes now, so the menu, the copy and the receipt cannot
        # describe three different lists. All three still count.
        self.assertIn("return copied.scope.receipt(count: copied.count)", LOG)
        self.assertIn(r'"Copied \(count) \(noun) shown"', MODEL)
        self.assertIn(r'"Copied all \(count) \(noun)"', MODEL)
        self.assertIn(r'"Copied last \(count) \(noun)"', MODEL)
        self.assertIn('let noun = count == 1 ? "line" : "lines"', MODEL)

    def test_no_bare_copied_label_survives(self) -> None:
        # "Copied" alone was both uninformative and able to stand for a write that never happened.
        self.assertNotIn('Label("Copied"', LOG)
        self.assertNotIn('Text("Copied")', LOG)
        self.assertNotIn('copied ? "Copied"', LOG)

    def test_the_count_line_carries_the_receipt(self) -> None:
        # The same spot the entry count lives in, so the sheet does not grow a row for a message
        # that lasts 1.6 seconds.
        self.assertIn("Text(copiedNotice ?? countLine)", LOG)

    def test_the_receipt_expires_without_clearing_a_newer_one(self) -> None:
        announce = block(LOG, "private func announce(", "private func tint(")
        self.assertIn("copySequence += 1", announce)
        self.assertIn("guard sequence == copySequence else { return }", announce)
        self.assertIn("copied = nil", announce)


class TheControlsAreInTheSheetsBody(unittest.TestCase):
    """Build 0.1.611: the Mac sheet drew Close and Refresh, and nothing else.

    A `ToolbarItemGroup` is not a promise. These assert the copy, share and clear controls are in
    `controls` — the same block as the entry count, which the photographed sheet did draw — and
    that the toolbar no longer carries a second, invisible copy of them.
    """

    def setUp(self) -> None:
        self.controls = block(LOG, "private var controls: some View {", "private var searchField")

    def test_the_handoff_row_is_part_of_the_controls(self) -> None:
        self.assertIn("handoffControls", self.controls)

    def test_every_action_is_a_word_in_the_body(self) -> None:
        for label in ('handoffLabel("Copy…"', 'handoffLabel("Share log"',
                      'handoffLabel("Send log to host"', 'handoffLabel("Clear"'):
            self.assertIn(label, BODY)
            # A title and a glyph: an icon alone is what the owner could not find.
            self.assertIn("Label(title, systemImage: symbol)", LOG)

    def test_the_toolbar_does_not_hide_a_copy_again(self) -> None:
        self.assertNotIn("Copy shown", TOOLBAR)
        self.assertNotIn("Share log", TOOLBAR)
        self.assertNotIn("ShareLink", TOOLBAR)
        # Refresh is the one action the photographed Mac sheet did draw, so it stays.
        self.assertIn('Label("Refresh", systemImage: "arrow.clockwise")', TOOLBAR)

    def test_the_row_is_not_platform_specific(self) -> None:
        # One row for both apps: a `#if os(` inside it is how the two presentations drift.
        handoff = block(BODY, "private var handoffControls", "private var copyShownButton")
        self.assertNotIn("#if os(", handoff)

    def test_each_action_explains_itself(self) -> None:
        # The copy menu's four sentences come from `copyHelp`, one per scope, so an item cannot be
        # offered without saying which list it takes.
        for help_text in ("Copy the newest 100 lines the filter admits",
                          "Copy the newest 500 lines the filter admits",
                          "Copy every line the filter admits, including lines a paused tail is holding back"):
            self.assertIn(f'return "{help_text}"', LOG)
        for help_text in ("Send the lines on screen to another app",
                          "Save this log as a file on the host, where it can be read without pasting it",
                          "Delete the entries on this device"):
            self.assertIn(help_text, LOG)


class TheLogCanBeSentToAnotherApp(unittest.TestCase):
    def test_share_hands_over_the_same_text(self) -> None:
        # One formatter, so what Share sends is exactly what Copy shown writes.
        self.assertIn("ShareLink(item: exportText(shown))", LOG)

    def test_share_has_a_visible_label_and_an_empty_state(self) -> None:
        share = block(LOG, "private var shareButton", "private var clearButton")
        self.assertIn('handoffLabel("Share log", "square.and.arrow.up")', share)
        self.assertIn(".disabled(shown.isEmpty)", share)
        self.assertNotIn("#if os(", share)


if __name__ == "__main__":
    unittest.main()
