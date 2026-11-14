"""The shell's small shapes: a floating pill, an icon row, a faded list, a quiet composer.

Each guard here is one decision that a later edit could quietly undo — a reserved strip creeping
back above the transcript, a search box growing back into the row, a hint line returning under the
field — so each is pinned by its shape rather than by a pixel count.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"

PANE = (MAC / "Conversation" / "ConversationPane.swift").read_text(encoding="utf-8")
HEADER = (MAC / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")
TRANSCRIPT = (MAC / "Conversation" / "TranscriptScroll.swift").read_text(encoding="utf-8")
SIDEBAR = (MAC / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
COMPOSER_BAR = (MAC / "Conversation" / "MacComposerBar.swift").read_text(encoding="utf-8")
COMPOSER = (ROOT / "Sources" / "OpenBotUI" / "Composer.swift").read_text(encoding="utf-8")


class ThePillFloats(unittest.TestCase):
    def test_the_transcript_reserves_nothing_above_it(self) -> None:
        # A reserved strip outside the scroll view means content can never pass behind the pill,
        # which is the whole point of the shape.
        self.assertNotIn(".padding(.top, Geometry.chatHeader)", PANE)
        self.assertIn("ConversationHeader(model: model, store: store)", PANE)

    def test_the_rows_carry_the_inset_instead(self) -> None:
        # Inside the scroll view, so the inset scrolls away and later rows pass underneath.
        self.assertIn(".padding(.top, Geometry.chatHeaderPill + 20)", TRANSCRIPT)
        self.assertIn(".padding(.top, Geometry.chatHeaderPill + 10)", TRANSCRIPT)

    def test_the_pill_sits_against_the_window_edge(self) -> None:
        # Six of air and the capsule; no extra top padding, so the pill's centre is 26 pt down and
        # level with the sidebar's first row.
        # On the traffic lights' line: the capsule plus two points, top-aligned in the pane.
        self.assertIn(".frame(width: width, height: Geometry.chatHeaderPill + 2)", HEADER)
        self.assertIn("alignment: .top", HEADER)
        self.assertNotIn(".padding(.top, 2)", HEADER)


class TheSidebarRowIsIcons(unittest.TestCase):
    def test_search_is_a_button_not_a_box(self) -> None:
        self.assertIn("private var isSearching", SIDEBAR)
        # The field only exists inside the searching branch.
        searching = SIDEBAR.split("if isSearching {", 1)[1].split("} else {", 1)[0]
        self.assertIn("MacSidebarSearchField", searching)
        outside = SIDEBAR.split("if isSearching {", 1)[0]
        self.assertNotIn("MacSidebarSearchField", outside)
        self.assertIn('OpenBotIconButton("magnifyingglass"', SIDEBAR)

    def test_the_panels_toggle_lives_in_the_panel(self) -> None:
        self.assertIn('OpenBotIconButton("sidebar.left"', SIDEBAR)
        self.assertIn("store.toggleSidebar()", SIDEBAR)
        # The chat header keeps one only while the panel is hidden, so the door is never gone.
        self.assertIn("if store.isSidebarHidden {", HEADER)

    def test_the_plus_replaces_the_three_dots(self) -> None:
        self.assertIn("private var addMenu", SIDEBAR)
        self.assertIn('Image(systemName: "plus")', SIDEBAR)
        # Our verbs, unchanged: add, group chat, manage, hidden, read.
        for verb in ("Add bot…", "Start group chat…", "Manage bots…",
                     "Show hidden bots", "Mark all as read"):
            self.assertIn(verb, SIDEBAR)
        # The ⋯ menu it replaced is gone from the panel's row.
        self.assertNotIn('Image(systemName: "ellipsis")', SIDEBAR)


class TheListFadesAtBothEnds(unittest.TestCase):
    def test_the_mask_is_fixed_height_and_two_sided(self) -> None:
        self.assertIn(".mask(listFade)", SIDEBAR)
        fade = SIDEBAR.split("private var listFade", 1)[1].split("\n    }", 1)[0]
        self.assertIn("LinearGradient(colors: [.clear, .black]", fade)
        self.assertIn("LinearGradient(colors: [.black, .clear]", fade)
        # Fixed, not a fraction: a fraction eats a short list and hides a row of a long one.
        self.assertEqual(fade.count("frame(height: 26)"), 2)


class TheComposerIsQuiet(unittest.TestCase):
    def test_no_placeholder(self) -> None:
        self.assertIn('placeholder: ""', COMPOSER_BAR)

    def test_the_hint_is_state_only(self) -> None:
        self.assertIn("private var hint: String?", COMPOSER_BAR)
        hint = COMPOSER_BAR.split("private var hint: String?", 1)[1].split("\n    }", 1)[0]
        self.assertIn("return nil", hint)
        # The keyboard reference is what went; the recording states are what stayed.
        self.assertNotIn("newline", hint)
        self.assertIn("voice.isRecording", hint)

    def test_attach_is_a_ring_not_a_bare_glyph(self) -> None:
        # Rakazo's plus is a circle with a border and a fill that brightens on hover; an unstroked
        # glyph in a floating capsule read as punctuation rather than a button.
        self.assertIn("ComposerRingButton(glyph: \"plus\"", COMPOSER)
        self.assertIn("Circle().strokeBorder(isHovering ? Tokens.borderFocus : Tokens.borderStrong",
                      COMPOSER)
        self.assertIn(".onHover { isHovering = $0 }", COMPOSER)

    def test_the_controls_ride_the_last_line(self) -> None:
        # Controls sit at the foot of the card, on the line the caret is on, so a long message grows
        # above them instead of leaving them behind on line one.
        self.assertIn("private func rowCentred<V: View>(_ view: V) -> some View", COMPOSER)
        self.assertIn(".frame(maxHeight: .infinity, alignment: .bottom)", COMPOSER)
        self.assertIn("HStack(alignment: .bottom, spacing: 8)", COMPOSER)
        self.assertNotIn("alignment: .top)", COMPOSER)

    def test_attach_is_a_plus(self) -> None:
        self.assertIn('glyph: "plus"', COMPOSER)
        self.assertNotIn('"paperclip"', COMPOSER)

    def test_no_hint_line_by_default(self) -> None:
        self.assertIn("public static let defaultHint: String? = nil", COMPOSER)


if __name__ == "__main__":
    unittest.main()
