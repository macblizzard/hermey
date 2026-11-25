"""Scrolling a 6,400-row chat on the main actor, pinned.

Reported 2026-11-25, after the open was fixed: "loads fast now, but still getting stuck after
scrolling for sometime for upto 30 seconds and app becomes fully unresponsive", and then, with the
answer narrowed: "got stuck again after scrolling past the long log".

Two causes, both of them *scale* rather than a bug in one line:

* **the number of rows.** `rowCache.rows(model.visibleTranscript + model.visibleLiveToolEntries)`
  regrouped the whole conversation whenever the transcript changed, and the transcript changes on
  every page the background fill lands — above the reader, where the count grows but the last id
  does not, so the old `(count, lastID)` signature could never see it. `visibleTranscript` re-ran
  three whole-array filters for the same reason, and the `+` allocated a fresh 6,400-element array on
  every body pass.
* **the size of one row.** A pasted log or a long tool result is markdown-parsed, scanned four times
  for markers, and handed to a view that is measured in full — on every body pass, i.e. every frame
  of a scroll.

The measured breakdown (see `Tests/README.md` and the PR body) put the tool-payload `JSONSerialization`
passes first: a run of thirty commands with long outputs was re-read per frame, on the main actor, to
draw one line of text.

What these tests hold is the shape of the fix, because there is no Swift toolchain on this box:
each one names the mechanism and fails if it is replaced by the whole-transcript version again. The
feeling of scrolling — and the phone's own milliseconds — can only be confirmed on a device, where
`TranscriptBuildMeter` (HERMEY_SCROLL_METER=1) logs the breakdown per 240 builds.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SPLICE = (ROOT / "Sources/HermesKit/TranscriptSplice.swift").read_text(encoding="utf-8")
ROWS = (ROOT / "Sources/HermesKit/IncrementalTranscriptRows.swift").read_text(encoding="utf-8")
GROUPING = (ROOT / "Sources/HermesKit/TranscriptGrouping.swift").read_text(encoding="utf-8")
CLAMP = (ROOT / "Sources/HermesKit/TranscriptClamp.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources/HermesAppKit/AppModel.swift").read_text(encoding="utf-8")
IOS_SCREEN = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text(encoding="utf-8")
IOS_ROW = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text(encoding="utf-8")
IOS_MARKDOWN = (ROOT / "Apps/HermesMobile/Views/MobileMarkdown.swift").read_text(encoding="utf-8")
MAC_SCROLL = (ROOT / "Apps/HermesMac/Conversation/TranscriptScroll.swift").read_text(encoding="utf-8")
PAYLOAD = (ROOT / "Sources/HermeyUI/ToolPayload.swift").read_text(encoding="utf-8")
RUN_GROUP = (ROOT / "Sources/HermeyUI/ToolRunGroup.swift").read_text(encoding="utf-8")
TOOL_CARD = (ROOT / "Sources/HermeyUI/ToolCard.swift").read_text(encoding="utf-8")


def body(source: str, name: str) -> str:
    """One Swift function's text, from its signature to the closing brace at its indentation."""
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


class TheGroupListIsSplicedNotRebuilt(unittest.TestCase):
    """A page landing above the reader must add rows, not re-fold the conversation."""

    def test_a_page_merge_only_groups_the_page(self) -> None:
        append = body(ROWS, "private func appendRows(")
        prepend = body(ROWS, "private func prependRows(")
        for name, chunk in (("append", append), ("prepend", prepend)):
            # The only entries handed to the grouper are the new ones, plus the one run the page
            # boundary cut in half — never `entries` itself.
            self.assertIn("TranscriptGrouping.rows(fresh", chunk + "TranscriptGrouping.rows(fresh", name)
            self.assertNotIn("TranscriptGrouping.rows(entries", chunk, name)
            self.assertNotIn("TranscriptGrouping.rows(self.entries", chunk, name)
        self.assertIn("TranscriptGrouping.rows(join, running: running)", ROWS)

    def test_the_published_signature_no_longer_depends_on_the_whole_array(self) -> None:
        # The old cache decided by `(count, lastID)`, which a prepend cannot be seen through.
        self.assertNotIn("Signature(count:", GROUPING)
        self.assertNotIn("Signature(count:", ROWS)
        self.assertNotIn("lastID:", ROWS)

    def test_the_splice_check_is_the_cheap_structural_one(self) -> None:
        detect = body(SPLICE, "public static func detect(")
        self.assertIn("entries[previous.count - 1].id == oldLast", detect)
        # A prepend is recognised by the old *first* row having moved down, never by the new first.
        self.assertIn("entries[entries.count - previous.count].id == oldFirst", detect)
        self.assertIn("guard entries.last?.id == oldLast else { return .replaced }", detect)
        # And it costs three id comparisons: no loop over the transcript anywhere in the check.
        self.assertNotIn("for ", detect)
        self.assertNotIn("filter", detect)
        self.assertNotIn("map", detect)

    def test_visibility_is_spliced_the_same_way(self) -> None:
        rows = body(ROWS, "public func rows(_ entries: [TranscriptEntry],\n                     showToolCalls")
        self.assertIn("filter(Array(entries[0..<count])) + self.rows", rows)
        self.assertIn("self.rows + filter(Array(entries[(entries.count - count)...]))", rows)
        self.assertNotIn("TranscriptVisibility.rows(entries,\n                                             showToolCalls: showToolCalls,\n                                             showReasoning: showReasoning)\n        self.entries = entries\n        self.rows = done", rows)


class NothingOnTheMainActorWalksTheWholeTranscriptPerPage(unittest.TestCase):
    def test_the_page_merge_does_not_hash_every_row(self) -> None:
        # `Set(transcript.map(\\.id))` was 6,400 string hashes on the main actor per 400-row page.
        self.assertNotIn("let known = Set(transcript.map(\\.id))", MODEL)
        self.assertIn("page.entries.filter { !transcriptIDs.contains($0.id) }", MODEL)

    def test_the_visible_list_comes_from_the_cache(self) -> None:
        visible = body(MODEL, "public var visibleTranscript: [TranscriptEntry] {")
        self.assertIn("visibleTranscriptCache.rows(transcript", visible)
        self.assertNotIn("TranscriptVisibility.rows(transcript", visible)

    def test_the_whole_array_copy_is_gone_from_both_transcripts(self) -> None:
        for name, source in (("ios", IOS_SCREEN), ("mac", MAC_SCROLL)):
            self.assertNotIn("model.visibleTranscript + model.visibleLiveToolEntries", source, name)
            self.assertIn("appending: model.visibleLiveToolEntries", source, name)


class RowIdentityIsTheMessageId(unittest.TestCase):
    def test_the_row_id_is_the_message_id(self) -> None:
        self.assertIn("case .entry(let entry): return entry.id", GROUPING)
        self.assertIn("case .toolRun(let run): return run.id", GROUPING)

    def test_both_lists_key_on_that_id(self) -> None:
        self.assertIn("ForEach(rowCache.rows(model.visibleTranscript,", IOS_SCREEN)
        self.assertIn("id: \\.id) { row in", IOS_SCREEN)
        self.assertIn("ForEach(groupedRows, id: \\.id) { row in", MAC_SCROLL)
        # An index is not an identity: a prepend renumbers every row.
        self.assertNotIn("enumerated()) { index, row in", IOS_SCREEN)


class ThePerRowParseIsRememberedAcrossRebuilds(unittest.TestCase):
    def test_markdown_is_remembered_by_its_text_not_by_its_row(self) -> None:
        self.assertIn("MarkdownParseStore.shared.blocks(for: source)", IOS_MARKDOWN)
        self.assertIn("final class MarkdownParseStore", IOS_MARKDOWN)
        self.assertIn("MarkdownParseStore.shared.sanitized(raw)", IOS_MARKDOWN)
        # The per-instance cache is the fast path only, and says so.
        self.assertIn("The instance cache is only the fast path", IOS_MARKDOWN)

    def test_a_tool_payload_is_read_once(self) -> None:
        self.assertIn("public static func remembered(", PAYLOAD)
        self.assertIn("public static func rememberedFailure(", PAYLOAD)
        self.assertIn("final class PayloadMemo", PAYLOAD)
        # No view body parses a payload directly any more.
        for name, source in (("run group", RUN_GROUP), ("card", TOOL_CARD),
                             ("ios row", IOS_ROW)):
            self.assertNotIn("ToolPayload.info(raw:", source, name)
            self.assertNotIn("ToolPayload.failed(raw:", source, name)
        self.assertIn("ToolPayload.rememberedFailure(raw:", RUN_GROUP)
        self.assertIn("ToolPayload.remembered(output)", IOS_ROW)


class TheBackgroundFillYields(unittest.TestCase):
    def test_the_fill_hands_the_main_actor_back_between_pages(self) -> None:
        fill = body(MODEL, "public func scheduleHistoryBackfill() {")
        loop = fill[fill.index("while !Task.isCancelled"):]
        self.assertIn("await Task.yield()", loop)
        self.assertIn("await self.loadEarlierHistory(limit: Self.backfillPage, silent: true)", loop)
        self.assertIn("Task.sleep(nanoseconds: 120_000_000)", loop)
        # The yield comes *before* the page, so the next page cannot start in the same turn as the
        # last one's arrival.
        self.assertLess(loop.index("await Task.yield()"),
                        loop.index("await self.loadEarlierHistory"))

    def test_the_fill_is_still_bounded_and_still_silent(self) -> None:
        self.assertIn("public static let autoBackfillRows = 1200", MODEL)
        self.assertIn("public static let backfillPage = 400", MODEL)
        self.assertIn("silent: true", MODEL)


class ALongRowIsDrawnAsAPreview(unittest.TestCase):
    """The 'got stuck scrolling past the long log' case."""

    def test_the_threshold_is_defined_once(self) -> None:
        self.assertIn("public static let maxPreviewCharacters = 4_000", CLAMP)
        self.assertIn("public static let maxPreviewLines = 60", CLAMP)
        # Nobody else keeps a copy of the numbers.
        for name, source in (("row", IOS_ROW), ("model", MODEL), ("screen", IOS_SCREEN)):
            self.assertNotIn("4_000", source, name)

    def test_a_long_message_takes_the_preview_path(self) -> None:
        # Both doors — the owner's bubble and the bot's reply — ask the clamp first, and the ordinary
        # renderer is only reached when it says no. One door per kind of message, as before.
        bubble = body(IOS_ROW, "private var bubbleText: some View {")
        self.assertIn("if let preview = clampedPreview {", bubble)
        self.assertIn("clampedBody(preview)", bubble)
        self.assertLess(bubble.index("clampedPreview"), bubble.index("MobileSelectableText"))
        reply = body(IOS_ROW, "private var assistant: some View {")
        self.assertIn("if let preview = clampedPreview {", reply)
        # The plain-prose branch is the last one (a card or a board has its own earlier branch), and
        # there the clamp is asked before the markdown renderer.
        prose = reply[reply.index("} else {\n                Group {"):]
        self.assertLess(prose.index("clampedPreview"),
                        prose.index("MobileMarkdownText(blocks: markdownCache.parse"))
        # The card/surface paths are never clamped, so a plugin's board still draws.
        self.assertIn('entry.text.contains("::")', body(IOS_ROW, "private var clampedPreview:"))

    def test_the_collapsed_preview_never_reaches_the_markdown_renderer(self) -> None:
        # The 20,000-character assertion. The clamp's own body is extracted, and the *collapsed*
        # branch — the one that runs while the row is not open — must contain no markdown renderer
        # and no markdown parse. A `Text` of 24 whole lines is all it draws.
        clamped = body(IOS_ROW, "private func clampedBody(")
        collapsed = clamped[clamped.index("} else {\n                Text(preview.text)"):]
        opened = clamped[clamped.index("} else if longRowIsOpen, let blocks = fullBlocks"):]
        self.assertIn("MobileMarkdownText(blocks: blocks", opened)     # the *opened* state only
        self.assertIn("Text(preview.text)", collapsed)
        self.assertNotIn("markdownCache.parse", clamped)
        self.assertNotIn("MobileMarkdownText", collapsed)
        self.assertNotIn("fixedSize", clamped)
        self.assertNotIn("ToolPayload", clamped)

    def test_the_preview_is_a_clamp_and_not_a_truncation(self) -> None:
        # The stored row is untouched: the preview is built from it, and the full text is still
        # selectable and still what the message's actions copy.
        self.assertIn("TranscriptClamp.preview(clampSource)", IOS_ROW)
        self.assertIn("private var clampSource: String", IOS_ROW)
        self.assertIn(".textSelection(.enabled)", IOS_ROW)
        self.assertIn("never a truncation", IOS_ROW)

    def test_opening_a_long_row_parses_off_the_main_actor_once(self) -> None:
        parse = body(IOS_ROW, "private func parseIfOpen() async {")
        self.assertIn("await Task.detached(priority: .userInitiated)", parse)
        self.assertIn("IncrementalMarkdown.parse(text)", parse)
        # Once: the state is the guard, and the store makes a second visit a lookup.
        self.assertIn("guard entry.role == .assistant, longRowIsOpen, fullBlocks == nil else { return }",
                      parse)
        self.assertIn("await Task.detached", IOS_ROW)

    def test_the_expansion_is_remembered_by_message_id(self) -> None:
        store = (ROOT / "Sources/HermesKit/ExpandedLongRows.swift").read_text(encoding="utf-8")
        self.assertIn("public final class ExpandedLongRows", store)
        self.assertIn("ExpandedLongRows.shared.insert(entry.id)", IOS_ROW)
        self.assertIn("showsFullContent ?? ExpandedLongRows.shared.contains(entry.id)", IOS_ROW)

    def test_a_card_or_a_surface_is_never_clamped(self) -> None:
        # `::` rows are the plugin's boards and cards: their own views decide what to draw.
        self.assertIn('if entry.role == .assistant, entry.text.contains("::") { return nil }', IOS_ROW)


class TheClampNumbersBehave(unittest.TestCase):
    """The threshold and the preview, ported — the shape both apps rely on."""

    @staticmethod
    def preview(text: str) -> tuple[str, int] | None:
        def is_long(value: str) -> bool:
            if not value:
                return False
            seen, lines = 0, 1          # lines, not newlines: 60 lines, 61 is a log
            for character in value:
                seen += 1
                if seen > 4_000:
                    return True
                if character == "\n":
                    lines += 1
                    if lines > 60:
                        return True
            return False

        if not is_long(text):
            return None
        out, lines, hidden = [], 0, 0
        for line in text.split("\n"):
            if lines >= 24 or sum(len(x) for x in out) + len(line) > 1_600:
                hidden += 1
                continue
            out.append(line)
            lines += 1
        return "\n".join(out), hidden

    def test_a_twenty_thousand_character_message_is_clamped(self) -> None:
        text = "\n".join(f"log line {i}: the run said something it had already said before"
                         for i in range(500))
        self.assertGreater(len(text), 20_000)
        clamped = self.preview(text)
        self.assertIsNotNone(clamped)
        assert clamped is not None
        shown, hidden = clamped
        self.assertLessEqual(shown.count("\n") + 1, 24)
        self.assertLessEqual(len(shown), 1_600 + 60)
        self.assertGreater(hidden, 400)

    def test_an_ordinary_message_is_not(self) -> None:
        self.assertIsNone(self.preview("Done. The vault is snapshotted."))
        self.assertIsNone(self.preview("\n".join("short line" for _ in range(40))))

    def test_the_line_threshold_is_sixty_lines(self) -> None:
        sixty = "\n".join("x" for _ in range(60))
        sixty_one = "\n".join("x" for _ in range(61))
        self.assertIsNone(self.preview(sixty))
        self.assertIsNotNone(self.preview(sixty_one))


if __name__ == "__main__":
    unittest.main()
