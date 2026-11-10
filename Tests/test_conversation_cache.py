"""Switching bots repaints from memory, not from the wire.

Reported: "when I'm changing between bot chats, for a second the chat shows empty then it loads —
even going cody → atlas → back to cody". Nothing was cached: every switch cleared the pane and then
waited for `resumeSession`. The rules that must hold:
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")


class TheSnapshotExistsAndIsBounded(unittest.TestCase):
    def test_a_snapshot_holds_what_the_pane_shows(self) -> None:
        self.assertIn("public struct ConversationSnapshot", MODEL)
        block = MODEL.split("public struct ConversationSnapshot", 1)[1].split("\n    }", 1)[0]
        for field in ("sessionID", "entries", "earlierCursor", "historyTotal", "openRequests",
                      "contextUsed", "contextMax"):
            self.assertIn(f"var {field}", block, f"a restored pane needs {field}")

    def test_the_cache_is_bounded(self) -> None:
        self.assertIn("conversationCacheLimit", MODEL)
        self.assertIn("while conversationCacheOrder.count > Self.conversationCacheLimit", MODEL,
                      "an unbounded map of transcripts is a leak with extra steps")

    def test_switching_captures_before_it_clears(self) -> None:
        switch = MODEL.split("public func endlessSession(for botID: String)", 1)[1]
        body = switch.split("await loadModelLabel()", 1)[0]
        self.assertIn("captureConversation(for: selectedBotID)", body,
                      "the bot being left must be kept before resetForBotSwitch wipes it")
        self.assertLess(body.index("captureConversation"), body.index("resetForBotSwitch"),
                        "capturing after the reset would keep an empty transcript")
        self.assertIn("restoreConversation(for: botID)", body,
                      "the return visit paints from the cache instead of waiting for the host")

    def test_the_restore_happens_before_any_await(self) -> None:
        switch = MODEL.split("public func endlessSession(for botID: String)", 1)[1]
        first_await = switch.index("await ")
        self.assertLess(switch.index("restoreConversation(for: botID)"), first_await,
                        "after the first await the pane has already flashed empty")


class ThePaneDoesNotLie(unittest.TestCase):
    def test_an_opening_conversation_says_so(self) -> None:
        self.assertIn("isOpeningConversation", MODEL)
        pane = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationPane.swift").read_text(encoding="utf-8")
        self.assertIn('if model.isOpeningConversation { return "Opening \\(store.botTitle)…" }', pane)
        self.assertIn("Resuming the conversation you already have", pane)

    def test_the_flag_clears_when_the_call_returns(self) -> None:
        switch = MODEL.split("public func endlessSession(for botID: String)", 1)[1]
        self.assertIn("defer { isOpeningConversation = false }", switch,
                      "a flag left true would hide the conversation behind 'Opening…' forever")

    def test_the_open_button_is_hidden_while_opening(self) -> None:
        pane = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationPane.swift").read_text(encoding="utf-8")
        self.assertIn("model.selectedBotID != nil && !model.isOpeningConversation", pane)


class ResetMeansReset(unittest.TestCase):
    def test_a_reset_conversation_is_evicted(self) -> None:
        reset = MODEL.split("public func resetEndlessSession(for botID: String)", 1)[1]
        head = reset.split("/// A menu's", 1)[0]
        self.assertIn("conversationCache.removeValue(forKey: botID)", head,
                      "otherwise 'reset conversation' reopens the history it was meant to drop")


class TheSwiftTestExists(unittest.TestCase):
    def test_the_promise_is_held_by_a_real_test(self) -> None:
        path = ROOT / "Tests" / "HermesAppKitTests" / "ConversationCacheTests.swift"
        text = path.read_text(encoding="utf-8")
        for name in ("testLeavingABotKeepsWhatWasOnScreen", "testReturningPaintsBeforeTheHostAnswers",
                     "testAResetConversationDoesNotComeBackFromTheCache", "testOnlyTheMostRecentBotsAreKept"):
            self.assertIn(name, text)
        self.assertIn("resumeDelay", text,
                      "without a slow host the test cannot look at the pane mid-resume")


if __name__ == "__main__":
    unittest.main()
