"""One dead socket says so once — and a sweep never wakes a refresh that cannot be sent.

The owner's 0.1.698 log carried `transcript refresh failed: not connected` five times in an hour,
every one of them directly under `sweep saw a newer host message`. Two faults compounding:

* the 25-second cache sweep woke `reconcileOpenChatWithHost` while the socket was down, and the
  refresh it started could only fail — the sweep was the reason there was something to report;
* the refresh logged every failure, so one dead wire read as five.

The fixes are the two the codebase already uses elsewhere: a one-shot note per disconnect
(`silenceReported` next door), cleared when the wire comes back, and a sweep that asks the
transport itself rather than this window's copy of its state — the copy is a frame behind, which
is exactly the window the paired lines fell into.

Swift does not build on this host, so these checks read the source: they fail if the guard, the
one-shot flag or the transport gate is removed or weakened.
"""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")


def block(source: str, start: str, end: str) -> str:
    """The text between two anchors, or "" when one is gone.

    Empty rather than raising: a removed guard has to fail the test that names it (with the
    assertion's own message), not the import of the whole file — six other checks in here are
    about code that is still there.
    """
    if start not in source:
        return ""
    tail = source.split(start, 1)[1]
    return tail.split(end, 1)[0] if end in tail else tail


REFRESH = block(MODEL, "private func refreshTranscript(_ sid: SessionID) async -> Bool {",
                "/// Finish a turn the host says is over")
SWEEP = block(MODEL, "public func startUnreadSweep() {", "/// Whether the socket itself is up")
GATE = block(MODEL, "private func transportIsUp() async -> Bool {", "public func stopUnreadSweep()")
RECONCILE = block(MODEL, "private func reconcileOpenChatWithHost() async {",
                  "/// Retry a dropped connection")
OPEN_REFRESH = block(MODEL, "private func scheduleOpenRefresh() {", "/// Re-read the open conversation")
READY = block(MODEL, "        case .ready:", "            // A session that could not be opened")


class AFailedRefreshIsSaidOncePerConnection(unittest.TestCase):
    def test_the_warning_is_behind_a_one_shot_flag(self):
        self.assertIn("private var refreshFailureNoted = false", MODEL)
        self.assertIn("if !refreshFailureNoted {", REFRESH,
                      "an unguarded note is the five lines the owner read")
        self.assertIn("refreshFailureNoted = true", REFRESH)

    def test_the_flag_is_set_before_the_line_is_written(self):
        # Otherwise a failure during the write could print twice, which is the bug with extra steps.
        if ("refreshFailureNoted = true" not in REFRESH
                or 'ClientLog.note("transcript refresh failed:' not in REFRESH):
            self.fail("the one-shot flag, or the line it guards, is gone")
        self.assertLess(REFRESH.index("refreshFailureNoted = true"),
                        REFRESH.index("ClientLog.note(\"transcript refresh failed:"))

    def test_the_sentence_is_written_in_exactly_one_place(self):
        self.assertEqual(1, MODEL.count('ClientLog.note("transcript refresh failed:'))

    def test_the_next_message_from_the_host_clears_it(self):
        self.assertIn("refreshFailureNoted = false", READY,
                      "a failure after the wire returns is news again")

    def test_an_unknown_session_is_still_reported_every_time(self):
        # That branch names a conversation that moved, and is a different fault: it keeps its line.
        unknown = block(REFRESH, "if let gateway = error as? GatewayError, Self.isUnknownSession(gateway) {",
                        "} else {")
        self.assertIn("no longer resolves", unknown)
        self.assertNotIn("refreshFailureNoted", unknown)


class TheSweepAsksTheTransportNotTheCopy(unittest.TestCase):
    def test_the_sweep_skips_a_disconnected_transport(self):
        self.assertIn("if await self.transportIsUp() { await self.loadBotPreviews() }", SWEEP,
                      "a sweep that runs while the socket is down is what woke the failing refresh")
        self.assertNotIn("if self.connection.isLive { await self.loadBotPreviews() }", SWEEP)

    def test_the_gate_reads_the_actors_own_state(self):
        self.assertIn("switch await client.state {", GATE)
        self.assertIn("case .open: return true", GATE)
        self.assertIn("guard connection.isLive else { return false }", GATE)

    def test_the_open_chat_reconcile_is_behind_the_same_gate(self):
        self.assertIn("guard await transportIsUp(),", RECONCILE,
                      "this is the function that pairs the sweep line with the failure line")

    def test_the_deferred_open_refresh_rechecks_after_its_delay(self):
        self.assertIn("guard await self.transportIsUp() else {", OPEN_REFRESH,
                      "400 ms is long enough for the socket to die between scheduling and reading")


if __name__ == "__main__":
    unittest.main()
