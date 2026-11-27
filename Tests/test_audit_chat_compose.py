"""The chat/compose audit's five fixes, each as the wiring it stands on.

The two high findings are also covered behaviourally in Swift
(`TranscriptDecorationTests`, `TranscriptDecorationAdoptTests`, `SendDoubleFireTests`); these
shape tests hold the exact wiring so a later refactor cannot quietly unwire it.
"""
from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPLICE = (ROOT / "Sources/HermesKit/TranscriptSplice.swift").read_text()
ROWS = (ROOT / "Sources/HermesKit/IncrementalTranscriptRows.swift").read_text()
APP = (ROOT / "Sources/HermesAppKit/AppModel.swift").read_text()
COMPOSER = (ROOT / "Sources/HermeyUI/Composer.swift").read_text()
MAC_BAR = (ROOT / "Apps/HermesMac/Conversation/MacComposerBar.swift").read_text()
MAC_SCROLL = (ROOT / "Apps/HermesMac/Conversation/TranscriptScroll.swift").read_text()
PHONE = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text()


def body(source: str, start: str, end: str) -> str:
    """The source between two markers, first occurrence of each."""
    lo = source.index(start)
    hi = source.index(end, lo)
    return source[lo:hi]


class TranscriptGenerationTests(unittest.TestCase):
    """A rewrite that keeps the ids must not read as `.unchanged`."""

    def test_the_splice_guard_is_wired_to_a_generation(self) -> None:
        # The parameter exists and answers for it.
        self.assertIn("sameGeneration: Bool = true", SPLICE)
        self.assertIn("guard sameGeneration else { return .replaced }", SPLICE)

    def test_the_model_keeps_and_passes_a_generation(self) -> None:
        self.assertIn("public private(set) var transcriptGeneration: UInt64 = 0", APP)
        did_change = body(APP, "private func transcriptDidChange(from old:",
                          "transcriptSplice = splice")
        self.assertIn("sameGeneration: sameGeneration", did_change)
        # The bump and the assignment cannot drift apart: one helper owns both.
        self.assertIn("transcriptGeneration &+= 1", APP)
        self.assertLess(APP.index("transcriptGeneration &+= 1"),
                        APP.index("transcript = entries"))

    def test_every_rewrite_adopts_through_the_bumping_helper(self) -> None:
        # A plain `transcript = ...` of a *replacement* would skip the bump and land back in the
        # dead-guard world. Adopt and decorate go through `replaceTranscript`.
        self.assertIn("replaceTranscript(merged.entries)", APP)          # adoptResume
        self.assertIn("self.replaceTranscript(decorated)", APP)          # decoration pass
        self.assertIn("replaceTranscript(snapshot.entries)", APP)        # restored cache paint
        self.assertIn("replaceTranscript(decorated)", APP)               # disk cache paint
        self.assertIn("replaceTranscript(index.attachMissing(to: transcript))", APP)
        self.assertIn("replaceTranscript(SentAttachmentVault.decorate(", APP)

    def test_both_caches_ask_the_generation_and_store_it(self) -> None:
        # The row cache: the shell-facing fold.
        self.assertIn("sameGeneration: generation == self.generation", ROWS)
        # The visibility cache builds its `sameGeneration` on its own line; both must be told.
        self.assertIn("let sameGeneration = generation == self.generation", ROWS)
        self.assertIn("sameGeneration: sameGeneration", ROWS)
        # Row cache stores it once, the visibility cache on both of its paths.
        self.assertEqual(ROWS.count("self.generation = generation"), 3,
                         "both caches must remember the generation they built from")
        self.assertIn("generation: UInt64,", ROWS)
        self.assertIn("generation: UInt64,", ROWS[ROWS.index("TranscriptVisibilityCache"):])

    def test_every_cache_caller_passes_the_model_generation(self) -> None:
        self.assertIn("generation: transcriptGeneration", APP)
        self.assertIn("generation: model.transcriptGeneration", PHONE)
        self.assertIn("generation: model.transcriptGeneration", MAC_SCROLL)


class SendDoubleFireTests(unittest.TestCase):
    """`send()` claims the turn synchronously and releases it on every exit."""

    def test_the_claim_precedes_the_first_await(self) -> None:
        send_body = body(APP, "public func send() async {", "let attachedNames =")
        claim = send_body.index("sending = true")
        truncate = send_body.index("await client.truncateMessages")
        self.assertLess(claim, truncate,
                        "a second Send during the truncate round-trip re-enters while "
                        "`sending` is still false")
        self.assertIn("defer { sending = false }", send_body)

    def test_every_exit_path_is_covered_by_the_defer(self) -> None:
        # The explicit releases are gone: only the entry claim and its defer remain.
        send_body = body(APP, "public func send() async {", "private func announce(")
        self.assertEqual(send_body.count("sending = true"), 1)
        self.assertEqual(send_body.count("sending = false"), 1)


class MacAttachmentOnlySendTests(unittest.TestCase):
    """The Mac passes the phone's own rule: an attachment with no words is sendable."""

    def test_the_mac_composer_carries_the_pending_attachments(self) -> None:
        self.assertIn("hasAttachments: !model.pendingAttachments.isEmpty", MAC_BAR)


class BareSlashCommandTests(unittest.TestCase):
    """A bare command the shell cannot run natively is sent, never intercepted into a loop."""

    def test_the_interception_only_fires_for_handled_actions(self) -> None:
        send_body = body(COMPOSER, "private func send() {", "Haptics.impact()")
        self.assertIn("nativeActions?.contains(exact.action) ?? true", send_body)

    def test_both_shells_declare_exactly_what_runCommand_answers(self) -> None:
        self.assertIn("nativeActions: [.help, .newSession, .resetConversation, .compact,\n"
                      "                                     .model, .reasoning]", MAC_BAR)
        self.assertIn("nativeActions: [.help, .newSession, .resetConversation, .compact]", PHONE)


class PagedHalfDeleteTests(unittest.TestCase):
    """A retired row leaves both halves of the screen, not only the resumed page."""

    def test_a_delete_drops_the_row_before_the_resume_merges(self) -> None:
        delete_body = body(APP, "public func deleteMessage(rowID: Int64) async {",
                           "public func reloadAfterRetire()")
        self.assertIn("transcript.removeAll { $0.rowID == rowID }", delete_body)
        self.assertLess(delete_body.index("transcript.removeAll { $0.rowID == rowID }"),
                        delete_body.index("await reloadAfterRetire()"),
                        "the merge joins at the incoming page's first row and keeps everything "
                        "above it — the row must be gone from the kept half first")

    def test_an_edit_truncate_drops_everything_from_the_row_on(self) -> None:
        send_body = body(APP, "public func send() async {", "let attachedNames =")
        self.assertIn("transcript.removeSubrange(start...)", send_body)
        self.assertLess(send_body.index("transcript.removeSubrange(start...)"),
                        send_body.index("await reloadAfterRetire()"))


if __name__ == "__main__":
    unittest.main()
