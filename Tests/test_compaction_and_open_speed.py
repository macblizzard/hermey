"""Two complaints, two source-level guarantees.

1. The Compact button did nothing on both platforms. It sent a **stored** session id; the host
   addresses a session by the **runtime** id and only hands that out on a resume. A session restored
   from the last launch had no mapping, so the host answered `4001 session not found` — and that error
   went to `lastSendError`, which no view renders. Dead button, no explanation.
2. Opening a long chat showed an empty pane for seconds, because the host takes seconds to resume it.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
SELECT_AT = APP.index("public func select(_ id: SessionID) async")


def between(start: str, end: str) -> str:
    head = APP.index(start)
    return APP[head:APP.index(end, head)]


class CompactionIsTheHostsJob(unittest.TestCase):
    """There is no client-side auto-compact: the host already does it, at its own threshold.

    A threshold here was a second opinion — it could compact a thread the host was about to, and it
    shipped a setting nobody asked for. "Compact now" is the only path the app owns.
    """

    def test_the_threshold_and_its_trigger_are_gone(self) -> None:
        for gone in ("autoCompactTokens", "defaultAutoCompactTokens", "autoCompactIfNeeded",
                     "hermes.autoCompactTokens", "reactToContextUsage"):
            self.assertNotIn(gone, APP, gone)
        self.assertNotIn("autoCompact", CLIENT)

    def test_manual_compaction_is_still_here(self) -> None:
        # The verb, the retry on an unknown session, and the notice are untouched.
        self.assertIn("public func compressNow() async", APP)
        self.assertIn("client.compress(session: sid)", APP)
        self.assertIn('compactionNotice = "conversation compacted"', APP)
        self.assertIn("private func finishCompaction()", APP)

    def test_neither_settings_screen_offers_a_threshold(self) -> None:
        phone = (ROOT / "Apps" / "HermesMobile" / "Views" / "SettingsScreen.swift").read_text(encoding="utf-8")
        mac = (ROOT / "Apps" / "HermesMac" / "Views" / "MacSettingsView.swift").read_text(encoding="utf-8")
        for source, name in ((phone, "phone"), (mac, "mac")):
            self.assertNotIn("autoCompact", source, name)
            self.assertNotIn("Auto-compact", source, name)
            self.assertNotIn("syncThreshold", source, name)
        # And the rest of both screens is still there.
        self.assertIn("Devices", phone)
        self.assertIn("Show reasoning", phone)
        self.assertIn("BotsSettingsTab", mac)
        self.assertIn("Show reasoning", mac)

    def test_the_doc_describes_the_host_as_the_compactor(self) -> None:
        doc = (ROOT / "docs" / "ENDLESS-CHAT.md").read_text(encoding="utf-8")
        # The doc may name the key it says goodbye to; it may not present it as a setting.
        self.assertNotIn("default 200_000", doc)
        self.assertIn("compression.threshold", doc)
        self.assertIn("no client-side threshold", doc)
        self.assertIn("Compact now", doc)


class CompactionOpensTheSessionFirst(unittest.TestCase):
    def test_an_unknown_session_is_opened_and_the_call_retried(self) -> None:
        body = between("public func compressNow()", "private func finishCompaction()")
        self.assertIn("isUnknownSession", body)
        # It resumes — but through `refreshTranscript`, because a compaction is not a re-open: `select`
        # empties the transcript first, which would blank the chat while the host is rewriting it.
        self.assertIn("await refreshTranscript(sid)", body, "the mapping comes from a resume, so resume")
        self.assertEqual(body.count("client.compress(session: sid)"), 2,
                         "one call, one retry — not a loop")

    def test_both_unknown_session_codes_are_recognised(self) -> None:
        body = between("private static func isUnknownSession", "\n    }")
        self.assertIn("4001", body)
        self.assertIn("4007", body)

    def test_a_failure_is_visible_in_the_header(self) -> None:
        body = between("public func compressNow()", "private func finishCompaction()")
        self.assertIn('compactionNotice = "could not compact', body,
                      "`lastSendError` is rendered nowhere; the notice is")

    def test_the_host_sentence_is_preferred_over_a_generic_error(self) -> None:
        body = between("private static func compactionReason", "\n    }")
        self.assertIn("rpc.message", body)


class AChatPaintsBeforeTheHostAnswers(unittest.TestCase):
    def test_the_cache_is_read_before_the_resume(self) -> None:
        body = APP[SELECT_AT:APP.index("private func adopt(", SELECT_AT)]
        self.assertLess(body.index("recentTranscripts[id]"), body.index("resumeSession"),
                        "the cached rows must be on screen before the 4-second resume starts")

    def test_the_host_still_wins(self) -> None:
        body = APP[SELECT_AT:APP.index("private func adopt(", SELECT_AT)]
        # The resume is adopted through the one helper that also keeps the pages already loaded —
        # the host's copy replaces the cached paint from the join onwards, it is not skipped.
        self.assertIn("adoptResume(resumed.entries", body)

    def test_a_finished_turn_updates_the_cache(self) -> None:
        body = between("case .messageComplete", "case .contextUsage")
        self.assertIn("remember(session, entries: transcript", body)

    def test_the_cache_is_memory_only(self) -> None:
        body = between("private var recentTranscripts", "/// Rows kept per session")
        for forbidden in ("UserDefaults", "FileManager", "defaults.set"):
            self.assertNotIn(forbidden, body,
                             "a stale transcript must not outlive the process — the host is the authority")

    def test_an_empty_transcript_is_not_cached_over_a_real_one(self) -> None:
        body = between("private func remember(", "\n    }")
        self.assertIn("guard !entries.isEmpty", body)


MAC_PANEL = (ROOT / "Apps" / "HermesMac" / "Workspace" / "MacBotPanel.swift").read_text(encoding="utf-8")
MAC_HEADER = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")
IOS_SCREEN = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
# The chat's verbs are a page swiped in from the trailing edge now, not a bar menu.
IOS_VERBS = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationDrawer.swift").read_text(encoding="utf-8")
CLIENT = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text(encoding="utf-8")


class ACompactionSaysItIsRunning(unittest.TestCase):
    """The verb works — it is the *silence* that made it a dead button.

    Measured on the live bridge: `session.compress` answered `ok` after **74 s** and **163 s** on two
    real runs, and for every one of those seconds neither app drew anything at all. The button was
    reported broken twice; the requests had reached the host and succeeded both times.
    """

    def test_the_mac_says_it_on_the_bots_face_at_every_width(self) -> None:
        # The face is inside the pill and the pill is never dropped, so a compaction shows at any
        # width — as `working`, which is what a compaction is: a turn the host is running.
        self.assertIn("store.activity(for: bot.id)", MAC_HEADER)
        self.assertNotIn('StatusChip("compacting', MAC_HEADER)
        # The one place that turns `isCompressing` into a face: the model's own resync, so both
        # shells get it and neither re-derives it.
        sync = APP.split("private func syncActivityWithRunState", 1)[1].split("\n    }", 1)[0]
        self.assertIn("isCompressing", sync)
        self.assertIn("setStreaming(", sync)

    def test_the_outcome_is_not_hidden_behind_a_breakpoint(self) -> None:
        self.assertNotIn("width >= ChipBreakpoint.notice", MAC_HEADER,
                         "the compaction note is evidence the verb ran; it must not be width-gated")

    def test_the_phone_says_so_in_the_strip_that_stays_on_screen(self) -> None:
        self.assertIn('StatusChip("compacting…"', IOS_SCREEN)
        self.assertIn("compactingChip", IOS_SCREEN)

    def test_both_surfaces_keep_the_verb_and_disable_it_while_it_runs(self) -> None:
        self.assertIn('model.isCompressing ? "Compacting…"', MAC_PANEL,
                      "mac: the row must not vanish mid-compaction")
        self.assertIn("model.isCompressing)", MAC_PANEL, "mac: it must not be tappable twice")
        # The phone's page no longer carries the verb at all: compaction is automatic there, and a
        # row for it on a page of things you do to a chat read as one more thing to press.
        self.assertNotIn('"Compact"', IOS_VERBS)
        self.assertIn("isCompressing: model.isCompressing", IOS_SCREEN,
                      "the page still receives the running state, for its own quiet reporting")

    def test_the_phone_verb_is_not_gated_on_a_session_id_it_learns_late(self) -> None:
        # Nothing on the page is gated on the session id the chat learns late.
        self.assertNotIn("sessionID", IOS_VERBS,
                         "the drawer must not be gated on an id the chat learns late")


class IdenticalReadsShareOneFlight(unittest.TestCase):
    """One launch asked the host for the same things repeatedly.

    Measured on the live bridge: `profiles.list` ×2, `session.list` ×5, `model.options` ×3 within
    three seconds (the last answering after 3.7 s), repeated on every reconnect — and the host
    answers them one at a time, so the transcript queues behind them.
    """

    def test_the_client_has_a_coalescer(self) -> None:
        for symbol in ("performRead(", "struct ReadKey", "struct ReadFlight", "func forgetReads"):
            self.assertIn(symbol, CLIENT)
        self.assertIn("if let inFlight = entry.task { return try await inFlight.value }", CLIENT)

    def test_the_catalogue_is_the_one_that_ages(self) -> None:
        self.assertIn('performRead("model.options"', CLIENT)
        self.assertIn("freshFor: 120", CLIENT,
                      "1-4 s of host work, unchanged until the model changes")

    def test_a_write_drops_what_it_invalidates(self) -> None:
        body = CLIENT.split("private static func readsExpire", 1)[1].split("\n    }", 1)[0]
        for method in ('"profiles.configure"', '"model.save_key"', '"session.compress"'):
            self.assertIn(method, body,
                          "a remembered catalogue must not outlive the change that invalidated it")

    def test_a_refusal_is_never_remembered(self) -> None:
        body = CLIENT.split("private func performRead", 1)[1].split("\n    }", 1)[0]
        self.assertIn("reads.removeValue(forKey: key)", body)


if __name__ == "__main__":
    unittest.main()
