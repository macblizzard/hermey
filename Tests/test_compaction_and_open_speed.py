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


class CompactionOpensTheSessionFirst(unittest.TestCase):
    def test_an_unknown_session_is_opened_and_the_call_retried(self) -> None:
        body = between("public func compressNow()", "private func autoCompactIfNeeded()")
        self.assertIn("isUnknownSession", body)
        self.assertIn("await select(sid)", body, "the mapping comes from a resume, so resume")
        self.assertEqual(body.count("client.compress(session: sid)"), 2,
                         "one call, one retry — not a loop")

    def test_both_unknown_session_codes_are_recognised(self) -> None:
        body = between("private static func isUnknownSession", "\n    }")
        self.assertIn("4001", body)
        self.assertIn("4007", body)

    def test_a_failure_is_visible_in_the_header(self) -> None:
        body = between("public func compressNow()", "private func autoCompactIfNeeded()")
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
        self.assertIn("transcript = SentAttachmentVault.decorate(resumed.entries", body)

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


if __name__ == "__main__":
    unittest.main()
