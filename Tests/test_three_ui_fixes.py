"""Three screenshots from Mohammad, 2026-11-24, and the one design behind each fix.

* **The ring.** A group chat's avatar is a stack of three faces, each with a plate behind it — a
  1.5 pt stroke in the page colour that separates one face from the one it overlaps. It was drawn
  as a `Circle` behind *every* face, so a bot with a drawn avatar (a cat's ears, a square) wore a
  second, circular outline with gaps between it and its own silhouette. The plate now follows the
  face that is actually drawn: a shape face keeps today's ring, a drawn avatar gets none and is
  separated by its own outline. Overlap, spacing and crop are untouched.
* **The menu.** One row of five had an icon (`Share`), the rest were bare titles. Every row of a
  message menu is now built by `MessageMenuRow`, whose constructors *require* a symbol — so the next
  row cannot ship without one — and a row whose title is conditional carries the glyph from the same
  condition.
* **The line.** `provider/model · 540k/1M Tokens` over the compose box, on both apps, in muted
  chrome outside the field: one formatter (`SessionLine` over `TokenCount`), one view
  (`ComposerSessionLine`), no wrapping, truncated before the composer can grow, model-only on a
  narrow window, and `Equatable` so typing cannot re-lay it out per character. *(Moved again on
  2026-11-24: Mohammad's sample put it **inside** the composer, as a pill in the control row, so the
  same formatter now feeds `ComposerModelPill`. Its own guards are in
  `test_composer_pill_and_row_menu.py`; what stays here is the rule both apps share.)*
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"

STACK = UI / "StackedBotFaces.swift"
GROUP = UI / "GroupChatViews.swift"
MENU_ROW = UI / "MessageMenuRow.swift"
SESSION_LINE = UI / "ComposerModelPill.swift"
MAC_ROW = ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift"
MAC_BAR = ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerBar.swift"
PHONE = ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift"
MOBILE_TRANSCRIPT = ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift"
APP_MODEL = ROOT / "Sources" / "HermesAppKit" / "AppModel.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def between(text: str, start: str, end: str) -> str:
    """The source between two markers, exclusive of `end`."""
    assert start in text, f"missing start marker: {start!r}"
    body = text.split(start, 1)[1]
    assert end in body, f"missing end marker: {end!r}"
    return body.split(end, 1)[0]


def call_arguments(text: str, marker: str) -> list[str]:
    """The argument text of every `marker(...)` call, parentheses balanced.

    A line-wise grep would pass a row whose `symbol:` sits on the next line; this reads the whole
    call, which is the only way to assert that *this* row carries *its* glyph.
    """
    found: list[str] = []
    for match in re.finditer(re.escape(marker) + r"\(", text):
        depth = 0
        start = match.end()
        for index in range(match.end() - 1, len(text)):
            char = text[index]
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    found.append(text[start:index])
                    break
    return found


class TheGroupStackPlatesOnlyTheShapeFace(unittest.TestCase):
    """The plate behind a face follows the face, not a circle drawn around its bounding box."""

    SOURCE = read(STACK)
    ROOMS = read(GROUP)

    def test_the_plate_is_conditional_on_what_is_actually_drawn(self) -> None:
        body = between(self.SOURCE,
                       "private func plate(for identity: String) -> some View {",
                       "\n    }\n}")
        # The condition asks the same library `BotAvatarView` resolves its face through, and it asks
        # *before* the circle is drawn: a plate behind a drawn avatar is the bug.
        self.assertIn("avatars[identity] == nil", body)
        self.assertLess(body.index("avatars[identity] == nil"), body.index("Circle()"))
        self.assertIn(".stroke(Tokens.canvas, lineWidth: 1.5)", body)

    def test_a_drawn_face_is_recognised_by_the_shared_library(self) -> None:
        # Not a second guess at "is this an image / a shape / a definition": the environment the
        # avatar itself reads, so the stack and the face cannot disagree.
        self.assertIn("@Environment(\\.botAvatars) private var avatars", self.SOURCE)
        self.assertIn("BotAvatarView(identity: face.id", self.SOURCE)
        self.assertIn(".overlay { plate(for: face.id) }", self.SOURCE)

    def test_no_call_site_draws_its_own_circle_behind_a_face(self) -> None:
        self.assertNotIn(".overlay(Circle().stroke(Tokens.canvas", self.ROOMS)
        self.assertNotIn("overlay(Circle()", self.ROOMS)
        # Both heads of a room — the row's portrait and the pane's — go through the one stack.
        self.assertEqual(self.ROOMS.count("StackedBotFaces(faces:"), 2)

    def test_the_stack_keeps_the_overlap_and_the_crop(self) -> None:
        # Today's look is the baseline: the faces still tuck under one another by the same amounts
        # and draw at the same sizes, so only the plate changed.
        self.assertIn("spacing: -7", self.ROOMS)   # the pane header, 24 pt faces
        self.assertIn("spacing: -8", self.ROOMS)   # the list row, 30 pt faces
        self.assertIn("size: 24", self.ROOMS)
        self.assertIn("size: 30", self.ROOMS)
        self.assertIn("room.members.prefix(3)", self.ROOMS)


class EveryMenuRowCarriesItsGlyph(unittest.TestCase):
    """One helper builds every row, and no constructor can be called without a symbol."""

    HELPER = read(MENU_ROW)
    MAC = read(MAC_ROW)
    MOBILE = read(MOBILE_TRANSCRIPT)
    ROOMS = read(GROUP)

    def message_menu(self) -> str:
        return between(self.MAC,
                       "@ViewBuilder private var messageMenu: some View {",
                       "@ViewBuilder private var content: some View {")

    def test_the_mac_menu_has_no_bare_buttons_left(self) -> None:
        menu = self.message_menu()
        self.assertNotIn("Button(", menu)
        self.assertNotIn("ShareLink(", menu)
        self.assertIn("MessageMenuRow.share(entry.text)", menu)
        # The five rows the owner photographed, in the order they were in.
        titles = re.findall(r"MessageMenuRow\.(?:action|share)\(\s*(?:\"[^\"]*\"|isSpeaking[^,]*)?", menu)
        self.assertGreaterEqual(len(titles), 5)

    def test_every_verb_row_passes_its_own_symbol(self) -> None:
        menu = self.message_menu()
        verbs = call_arguments(menu, "MessageMenuRow.action")
        self.assertGreaterEqual(len(verbs), 4)
        for arguments in verbs:
            self.assertIn("symbol:", arguments, f"a row without a glyph: {arguments!r}")
            symbol = arguments.split("symbol:", 1)[1]
            self.assertRegex(symbol, r'"[a-z0-9][a-z0-9.]*"|\?', "a glyph name, not an empty string")
            self.assertNotIn('symbol: ""', arguments)

    def test_a_conditional_row_carries_a_conditional_glyph(self) -> None:
        menu = self.message_menu()
        # The read-aloud verb swaps with the turn: "Stop Reading" must not keep the speaking mark.
        self.assertIn('isSpeaking ? "Stop Reading" : "Read Aloud"', menu)
        self.assertIn('symbol: isSpeaking ? "speaker.slash" : "speaker.wave.2"', menu)

    def test_the_helper_cannot_build_a_row_without_a_symbol(self) -> None:
        # `symbol:` is a required parameter of both constructors — there is no default to forget.
        self.assertIn("public static func action(_ title: String, symbol: String,", self.HELPER)
        self.assertNotIn("symbol: String =", self.HELPER)
        self.assertIn("Label(title, systemImage: symbol)", self.HELPER)
        # Share is a `ShareLink`, and it is built here too, with the same Label — one row style.
        self.assertIn("public static func share(_ text: String) -> MessageMenuRow", self.HELPER)
        self.assertIn('symbol: "square.and.arrow.up"', self.HELPER)

    def test_the_other_transcript_menus_build_rows_the_same_way(self) -> None:
        mobile = between(self.MOBILE, "private var menu: some View {", "// MARK: Action card")
        self.assertNotIn("Button {", mobile)
        self.assertNotIn("Button(", mobile)
        self.assertNotIn("ShareLink(", mobile)
        self.assertIn("MessageMenuRow.share(entry.text)", mobile)
        for arguments in call_arguments(mobile, "MessageMenuRow.action"):
            self.assertIn("symbol:", arguments)

        room = between(self.ROOMS, ".contextMenu {", "// Under every message")
        self.assertIn("MessageMenuRow.action(", room)
        self.assertIn("MessageMenuRow.share(message.text)", room)
        self.assertNotIn("Button {", room)


class TheComposerNamesTheModelAndItsContext(unittest.TestCase):
    """`provider/model · used/limit Tokens`, from one formatter, on one pill, on both apps."""

    LINE = read(SESSION_LINE)
    MAC = read(MAC_BAR)
    PHONE = read(PHONE)
    MODEL = read(APP_MODEL)

    def test_both_apps_draw_the_same_view_from_the_same_values(self) -> None:
        for name, source in (("the Mac's composer bar", self.MAC),
                             ("the phone's conversation", self.PHONE)):
            self.assertIn("ComposerModelPill(provider: model.modelProvider", source, name)
            self.assertIn("model: model.modelLabel", source, name)
            self.assertIn("used: model.contextUsed", source, name)
            self.assertIn("limit: model.contextMax", source, name)

    def test_the_numbers_come_from_the_host_and_the_shared_token_rule(self) -> None:
        # `TokenCount`, the rule the phone's header already prints, not a second rounding.
        self.assertEqual(self.LINE.count("TokenCount.short("), 3)
        self.assertIn('"\\(TokenCount.short(used))/\\(TokenCount.short(limit)) Tokens"', self.LINE)
        self.assertIn('"\\(TokenCount.short(used)) Tokens"', self.LINE)
        # A provider and a model, in the host's own words; a name that already carries a slash is
        # not prefixed twice.
        self.assertIn('guard !name.contains("/") else { return name }', self.LINE)
        self.assertIn('return "\\(slug)/\\(name)"', self.LINE)
        # Nothing is invented: no used, no count; no limit, no denominator.
        self.assertIn("guard let used, used >= 0 else { return nil }", self.LINE)
        self.assertIn("guard let limit, limit > 0 else", self.LINE)

    def test_the_provider_travels_with_the_model(self) -> None:
        self.assertIn("public private(set) var modelProvider: String?", self.MODEL)
        self.assertIn("modelProvider = current?.provider", self.MODEL)
        self.assertIn("modelProvider = nil", self.MODEL)

    def test_the_phone_keeps_no_second_formatter(self) -> None:
        self.assertNotIn("MobileTokens.short(used)", self.PHONE)
        self.assertNotIn("private var contextUsage: String?", self.PHONE)
        self.assertNotIn("private var modelChipLabel: String?", self.PHONE)

    def test_the_pill_is_a_row_of_the_composer_not_a_line_above_it(self) -> None:
        for field in ("TextField(", "TextEditor(", "ComposerTextView(", "Composer(text:"):
            self.assertNotIn(field, self.LINE)
        # Drawn *by* the composer, in the control row: the design system takes the pill as a row
        # sibling, and neither app draws it outside the `Composer(` call any more.
        composer = read(UI / "Composer.swift")
        self.assertIn("private let sessionPill: ComposerModelPill?", composer)
        self.assertIn("if let sessionPill {", composer)
        for name, source in (("the Mac's composer bar", self.MAC),
                             ("the phone's conversation", self.PHONE)):
            self.assertLess(source.index("Composer(text: $model.draft"),
                            source.index("ComposerModelPill("), name)
            self.assertNotIn("ComposerSessionLine", source, name)

    def test_it_cannot_wrap_grow_or_truncate_the_message(self) -> None:
        # One line, truncated at the tail, and the full line gives way to the model alone rather
        # than to a squeezed one.
        self.assertIn(".lineLimit(1)", self.LINE)
        self.assertIn(".truncationMode(.tail)", self.LINE)
        # The count keeps its room; the model name is the half that gives way.
        self.assertIn("context(tokens)", self.LINE)
        self.assertNotIn("ViewThatFits(in: .horizontal)", self.LINE)
        self.assertIn(".fixedSize(horizontal: true, vertical: false)", self.LINE)
        # No geometry, no draft: it cannot read the width or the text, so it cannot reflow either.
        self.assertNotIn("GeometryReader", self.LINE)
        self.assertNotIn("model.draft", self.LINE)

    def test_a_keystroke_cannot_re_lay_it_out(self) -> None:
        # The pill is `Equatable` and the composer applies `.equatable()` once, for both apps:
        # typing changes the draft binding, not these four values, so SwiftUI skips its body (and
        # its ViewThatFits pass).
        self.assertIn("public struct ComposerModelPill: View, Equatable", self.LINE)
        self.assertIn("public static func == (lhs: ComposerModelPill", self.LINE)
        composer = read(UI / "Composer.swift")
        block = composer.split("private var sessionPillBand", 1)[1]
        self.assertIn(".equatable()", block)


if __name__ == "__main__":
    unittest.main()
