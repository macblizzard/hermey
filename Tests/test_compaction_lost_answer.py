"""A compaction is host work; losing the socket must not be reported as a refusal.

Reported from a phone, 2026-11-12 16:20: Compact was tapped and the app said

    could not compact — The operation couldn't be completed. Software caused connection abort

What the bridge actually logged (`hermes_bridge.audit`):

    16:19:51.491  client_request   session.compress   (device o4pPfKTB7WHRI17S)
    16:19:51.677  ws_close         reason client_closed, code 1001
    16:03:23.569  client_request   session.compress
    16:05:26.854  client_response  session.compress   duration_ms 123285.7  outcome ok

So the host accepted the work, the phone left the foreground 186 ms later and iOS took the socket
down with it (1001 = going away), and an earlier compaction on the same profile was answered `ok`
after **123 s**. The compaction was running; the answer had nowhere to land. The app called that a
refusal and printed an errno at the user.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")


def _function(name: str, source: str = MODEL) -> str:
    """The body of one function, from its signature to the next blank line at method indentation."""
    start = source.index(name)
    rest = source[start:]
    end = rest.find("\n    }\n")
    return rest[: end + 7] if end != -1 else rest


class ALostAnswerIsNotARefusal(unittest.TestCase):
    def setUp(self) -> None:
        self.compress = _function("public func compressNow()")

    def test_the_spinner_is_not_dropped_by_a_defer(self) -> None:
        self.assertNotIn("defer { isCompressing = false }", self.compress)
        self.assertIn("isCompressing = true", self.compress)
        self.assertIn("finishCompaction()", self.compress)

    def test_the_wait_is_recorded_before_the_host_is_asked(self) -> None:
        wait = self.compress.index("compactionWait = CompactionWait(")
        request = self.compress.index("try await client.compress(")
        self.assertLess(wait, request, "the 'before' photograph must be taken before the rewrite")

    def test_a_lost_answer_keeps_the_compaction_alive(self) -> None:
        branch = self.compress.split("if Self.isLostAnswer(error) {", 1)[1].split("\n            }", 1)[0]
        self.assertIn("compactionAnswerLost = true", branch)
        self.assertIn("compacting… the host keeps working while the app is away", branch)
        self.assertNotIn("lastSendError", branch, "the host did not refuse anything")
        self.assertIn("return", branch, "it must not fall through to the failure path")

    def test_the_failure_path_is_still_there_for_a_real_refusal(self) -> None:
        failure = self.compress.split("// Say it in the place the header already draws.", 1)[1]
        self.assertIn('lastSendError = "could not compact: \\(reason)"', failure)
        self.assertIn('compactionNotice = "could not compact — \\(reason)"', failure)
        self.assertIn("finishCompaction()", failure)

    def test_what_counts_as_a_lost_answer(self) -> None:
        lost = _function("private static func isLostAnswer")
        for case in ("case .notConnected, .transportClosed:", "[-1001, -1003, -1004, -1005, -1009]",
                     "[53, 54, 57, 60]", 'method == "session.compress"'):
            self.assertIn(case, lost, f"{case} is a lost answer")
        self.assertIn("NSPOSIXErrorDomain", lost)
        self.assertIn("NSURLErrorDomain", lost)

    def test_the_retry_does_not_blank_the_conversation_being_compacted(self) -> None:
        retry = self.compress.split("isUnknownSession(error)", 1)[1]
        self.assertIn("await refreshTranscript(sid)", retry,
                      "select() empties the transcript; a compaction is not a re-open")
        self.assertNotIn("await select(sid)", self.compress)


class TheNextTranscriptSettlesIt(unittest.TestCase):
    def test_the_refresh_settles_a_lost_answer(self) -> None:
        refresh = _function("private func refreshTranscript")
        self.assertIn("settleCompactionWait()", refresh)

    def test_settling_needs_a_lost_answer_not_just_a_pending_one(self) -> None:
        settle = _function("private func settleCompactionWait")
        self.assertIn("guard compactionAnswerLost,", settle,
                      "a refresh during a live request must not claim an outcome")

    def test_a_changed_conversation_is_the_outcome(self) -> None:
        settle = _function("private func settleCompactionWait")
        self.assertIn("transcript.count != wait.entriesBefore || historyTotal != wait.totalBefore", settle)
        self.assertIn('compactionNotice = "conversation compacted"', settle)

    def test_patience_is_bounded_and_honest(self) -> None:
        settle = _function("private func settleCompactionWait")
        self.assertIn("Self.compactionPatience", settle)
        self.assertIn("compacting did not report back", settle)
        watchdog = MODEL.split("compactionWatchdog = Task", 1)[1].split("\n                }", 1)[0]
        self.assertIn("Self.compactionPatience", watchdog,
                      "without a reconnect the app must still stop pretending it knows")
        self.assertIn("finishCompaction()", watchdog)

    def test_patience_is_longer_than_the_slowest_measured_compaction(self) -> None:
        value = re.search(r"compactionPatience: TimeInterval = (\d+)", MODEL)
        assert value is not None, "the patience bound must be declared"
        self.assertGreater(int(value.group(1)), 163, "measured: 74 s, 123 s, 163 s")

    def test_a_posix_errno_is_never_shown_to_the_user(self) -> None:
        reason = _function("private static func compactionReason")
        self.assertIn("NSURLErrorDomain", reason)
        self.assertIn("NSPOSIXErrorDomain", reason)
        self.assertIn("the connection dropped before the host answered", reason)


if __name__ == "__main__":
    unittest.main()
