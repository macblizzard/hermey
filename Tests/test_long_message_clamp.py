"""Every message that draws a body is clamped, and the collapsed one costs no markdown work.

The owner's report on 0.1.670, twice, with screenshots: scrolling still locked up for about thirty
seconds while a very long message was on screen. Both screenshots were the same shape — a huge
bubble whose every identifier was inline code, one an assistant reply and one an
`[ASYNC DELEGATION BATCH COMPLETE …]` system row.

The clamp that shipped in 0.1.670 did not save them for two reasons, and these tests are about both:

* it exempted anything whose text carried a `::` marker, so cards, boards and the delegation rows
  never reached it;
* it counted characters and lines, but each inline-code span is its own styled run inside one
  `Text`, so a body of ordinary length and 300 spans froze exactly where a 20,000-character log did.

So the guards read the Swift sources as text and hold the new shape: one decision
(`TranscriptClamp.plan`), every row kind through the shared view (`ClampedBody`), a collapsed path
that cannot reach a parser, a count taken from the body, and expansion remembered per message and
parsed off the main actor. There is no Swift toolchain on this box; the code itself compiles in CI
and on the Mac (`swift test`), where `TranscriptClampTests` proves the two reported bodies collapse.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

CLAMP = (ROOT / "Sources/HermesKit/TranscriptClamp.swift").read_text(encoding="utf-8")
LONG_BODY = (ROOT / "Sources/HermeyUI/LongMessageBody.swift").read_text(encoding="utf-8")
STORE = (ROOT / "Sources/HermesKit/ExpandedLongRows.swift").read_text(encoding="utf-8")
TOOL_CARD = (ROOT / "Sources/HermeyUI/ToolCard.swift").read_text(encoding="utf-8")
MOBILE = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text(encoding="utf-8")
MAC = (ROOT / "Apps/HermesMac/Conversation/TranscriptRowView.swift").read_text(encoding="utf-8")
PACKAGE = (ROOT / "Package.swift").read_text(encoding="utf-8")


def body(source: str, name: str) -> str:
    """One Swift function or property's text, from its signature to the closing brace at its indent."""
    start = source.index(name)
    indent = source.rindex("\n", 0, start) + 1
    pad = len(source[indent:start]) - len(source[indent:start].lstrip())
    lines = source[start:].split("\n")
    out = [lines[0]]
    for line in lines[1:]:
        out.append(line)
        if line.strip() == "}" and len(line) - len(line.lstrip()) == pad:
            break
    return "\n".join(out)


class EveryBodyTakesTheClamp(unittest.TestCase):
    """No row kind draws a body of its own: the decision and the view are shared."""

    def test_both_shells_route_every_body_through_the_shared_view(self) -> None:
        # Eight doors each, and the count is the assertion: the reply's prose (plain, A2UI, board
        # and card variants), the owner's bubble, a bot-to-bot message, reasoning, a system row —
        # and the tool body, which both shells draw through their own card.
        for name, source in (("iOS", MOBILE), ("macOS", MAC)):
            self.assertEqual(source.count("ClampedBody("), 8, name)
            self.assertNotIn("TranscriptClamp.plan(", source,
                             f"{name}: the decision belongs to the shared view, not to a row")
            self.assertNotIn("TranscriptClamp.Preview", source,
                             f"{name}: a shell does not take the preview apart itself")

    def test_the_system_and_delegation_rows_clamp(self) -> None:
        # The second screenshot: `[ASYNC DELEGATION BATCH COMPLETE — deleg_…]` is a system row, and
        # a system row may be a wall of identifiers like any reply.
        for name, source, prop in (("iOS", MOBILE, "private var systemNote: some View {"),
                                   ("macOS", MAC, "private var systemRow: some View {")):
            row = body(source, prop)
            self.assertIn("ClampedBody(TranscriptClamp.Body(text: entry.text)", row, name)

    def test_reasoning_and_bot_to_bot_bodies_clamp(self) -> None:
        self.assertIn("ClampedBody(TranscriptClamp.Body(text: text)",
                      body(MOBILE, "struct MobileReasoningBlock: View {"))
        self.assertIn("ClampedBody(TranscriptClamp.Body(text: label.body)",
                      body(MAC, "private func botMessageRow("))

    def test_the_tool_bodies_clamp(self) -> None:
        # A tool result is where this started: `ToolBodyView` draws up to 400 numbered rows, each its
        # own `HStack`, so the card is bounded before it is laid out.
        self.assertIn("ClampedBody(TranscriptClamp.Body(text: shownOutput)",
                      body(MOBILE, "struct MobileToolRow: View {"))
        self.assertIn("ClampedBody(TranscriptClamp.Body(text: outputText)",
                      body(TOOL_CARD, "private var outputBody: some View {"))

    def test_the_card_prose_clamps_with_its_kinds(self) -> None:
        # A card is drawn *beside* the prose, so the prose still clamps and only a message that is
        # nothing but one of the small cards is exempt.
        for name, source, prop, text in (
            ("iOS", MOBILE, "private func cardBubble(", "scan.prose"),
            ("macOS", MAC, "private func cardBubble(", "scan.prose"),
        ):
            row = body(source, prop)
            self.assertIn(f"TranscriptClamp.Body(text: {text}, cardKinds: scan.refs.map(\\.kind))",
                          row, name)

    def test_the_old_exemption_is_gone(self) -> None:
        # `entry.text.contains("::")` was the hole: every card, board and marker-carrying row
        # skipped the clamp. Kinds decide now, and only the enumerated small ones.
        self.assertNotIn('contains("::")', MOBILE)
        self.assertNotIn('contains("::")', MAC)


class TheNumbersLiveInOnePlace(unittest.TestCase):
    """Fifty lines, and two guards for what a line cannot express."""

    def test_the_owners_line_count_and_both_guards_exist(self) -> None:
        self.assertIn("public static let maxBodyLines = 50", CLAMP)
        self.assertIn("public static let maxBodyCharacters = 4_000", CLAMP)
        self.assertIn("public static let maxBodyInlineSpans = 40", CLAMP)

    def test_all_three_numbers_are_used(self) -> None:
        measure = body(CLAMP, "static func measure(")
        self.assertIn("measured.lines > maxBodyLines", measure)
        self.assertIn("measured.characters > maxBodyCharacters", measure)
        self.assertIn("measured.spans > maxBodyInlineSpans", measure)
        # ...and the preview is bounded by the same two budgets, so the collapsed row cannot be the
        # whole message it just collapsed.
        preview = body(CLAMP, "public static func preview(")
        self.assertIn("drawn.count < previewLines", preview)
        self.assertIn("used + cost <= previewCharacters", preview)
        self.assertIn("public static var previewLines: Int { maxBodyLines }", CLAMP)
        self.assertIn("public static var previewCharacters: Int { maxBodyCharacters }", CLAMP)

    def test_no_shell_keeps_its_own_copy(self) -> None:
        for name, source in (("iOS", MOBILE), ("macOS", MAC), ("shared view", LONG_BODY),
                             ("tool card", TOOL_CARD)):
            for number in ("4_000", "1_500", "maxBodyLines", "maxBodyCharacters"):
                self.assertNotIn(number, source, f"{name} spells the threshold itself: {number}")

    def test_the_line_rule_is_the_bodys_own_lines(self) -> None:
        # Counting *rendered* (wrapped) lines would mean measuring the text in the reader's font on
        # the main thread — the expense the clamp exists to remove. The source says so, in the one
        # place someone would otherwise "fix" it.
        self.assertIn("not the\n    /// lines it happens to wrap to", CLAMP)


class TheCollapsedPathDoesNoMarkdownWork(unittest.TestCase):
    """The preview is plain text, and the module boundary is the proof."""

    def test_the_clamp_module_cannot_reach_a_parser(self) -> None:
        # `HermesKit` has no dependency on `HermesRender`: the collapsed path is not *asked* not to
        # parse, it has nothing to parse with.
        self.assertIn('.target(name: "HermesKit", path: "Sources/HermesKit")', PACKAGE)
        for name, source in (("clamp", CLAMP), ("shared view", LONG_BODY)):
            for symbol in ("IncrementalMarkdown", "MarkdownTextView", "MarkdownParseStore",
                           "BlockText"):
                self.assertNotIn(symbol, source, f"{name} reaches the renderer: {symbol}")
        self.assertNotIn("AttributedString", LONG_BODY)

    def test_the_collapsed_branch_is_one_text(self) -> None:
        view = body(LONG_BODY, "public var body: some View {")
        collapsed = view[view.index("} else {"):view.index("button\n")]
        self.assertIn("Text(preview.text)", collapsed)
        self.assertNotIn("expanded()", collapsed,
                         "the shell's renderer is built only in the opened branch")
        self.assertNotIn("fixedSize", collapsed.replace(".fixedSize(horizontal: false, vertical: true)", ""))

    def test_the_whole_branch_is_deferred_not_built_eagerly(self) -> None:
        # `ClampedBody` takes the whole and expanded views as closures: passing a built view value
        # would run the shell's markdown parse (an argument of that view) on the collapsed path.
        container = body(LONG_BODY, "public struct ClampedBody")
        self.assertIn("private let whole: () -> Whole", container)
        self.assertIn("private let expanded: () -> Expanded", container)
        self.assertIn("case .whole:\n            whole()", container)


class TheCountIsReal(unittest.TestCase):
    """At most fifty lines, and the number beside the button is the body's own."""

    def test_the_hidden_count_is_computed_from_the_body(self) -> None:
        preview = body(CLAMP, "public static func preview(")
        self.assertIn("let lines = text.components(separatedBy:", preview)
        self.assertIn("hiddenLines: max(0, lines.count - whole)", preview)
        self.assertIn("totalLines: lines.count", preview)

    def test_the_button_names_the_message_and_the_count(self) -> None:
        self.assertIn('"Show full message · \\(hiddenLines) more line', CLAMP)
        self.assertIn('public static let showLessTitle = "Show less"', CLAMP)
        self.assertIn("TranscriptClamp.showFullTitle(hiddenLines: preview.hiddenLines)", LONG_BODY)
        self.assertIn("TranscriptClamp.showLessTitle", LONG_BODY)


class TheExpansionIsRememberedAndOffMain(unittest.TestCase):
    """Per message id, parsed away from the main actor, and local to the row."""

    def test_both_shells_parse_off_the_main_actor(self) -> None:
        for name, source, prop, guard in (
            ("iOS", MOBILE, "private func parseLongBody(", "guard entry.role == .assistant, fullBlocks == nil else { return }"),
            ("macOS", MAC, "private func parseLongBody(", "guard fullBody == nil else { return }"),
        ):
            parse = body(source, prop)
            self.assertIn("await Task.detached(priority: .userInitiated)", parse, name)
            self.assertIn("IncrementalMarkdown.parse(text)", parse, name)
            self.assertIn(guard, parse, name)

    def test_the_open_state_is_keyed_by_message_id(self) -> None:
        self.assertIn("public static let shared = ExpandedLongRows()", STORE)
        self.assertIn("ExpandedLongRows.shared.insert(messageID)", LONG_BODY)
        self.assertIn("ExpandedLongRows.shared.contains(messageID)", LONG_BODY)
        self.assertIn("ExpandedLongRows.shared.remove(messageID)", LONG_BODY)
        self.assertIn(".task(id: messageID)", LONG_BODY)
        # A row is handed the message it draws, not a constant.
        for name, source in (("iOS", MOBILE), ("macOS", MAC)):
            self.assertIn("messageID: entry.id", source, name)

    def test_the_parse_result_is_the_rows_own_state(self) -> None:
        # Neighbouring rows must not re-render when one message is opened: the answer is local.
        self.assertIn("@State private var fullBody:", MAC)
        self.assertIn("@State private var fullBlocks: [Block]?", MOBILE)
        self.assertNotIn("@Published", body(MAC, "private func parseLongBody("))


class OnlyTheEnumeratedSmallCardsAreExempt(unittest.TestCase):
    def test_the_exemption_list_is_exactly_the_four_structured_cards(self) -> None:
        listing = re.search(r"smallStructuredCards: Set<String> = \[(.*?)\]", CLAMP, re.S)
        self.assertIsNotNone(listing)
        assert listing is not None
        self.assertEqual(re.findall(r'"([a-z-]+)"', listing.group(1)),
                         ["approval", "draft-email", "infographic", "secure-entry"])

    def test_the_exemption_needs_an_empty_prose(self) -> None:
        rule = body(CLAMP, "public static func isOnlySmallStructuredCards(")
        self.assertIn("body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty", rule)
        self.assertIn("public static func plan(_ body: Body) -> Plan", CLAMP)
        self.assertIn("if isOnlySmallStructuredCards(body) { return .whole }",
                      body(CLAMP, "public static func plan("))


class TheTextIsNeverDropped(unittest.TestCase):
    def test_the_preview_is_built_from_the_text_and_the_text_is_kept(self) -> None:
        # A drawing decision: no row writes back a shortened copy, and the message's own actions
        # still copy `entry.text`.
        for name, source in (("iOS", MOBILE), ("macOS", MAC)):
            self.assertNotIn("entry.text =", source, name)
            self.assertIn("entry.text", source, name)
        self.assertIn("The stored text is untouched", CLAMP)
        self.assertIn("never a truncation", LONG_BODY)


if __name__ == "__main__":
    unittest.main()
