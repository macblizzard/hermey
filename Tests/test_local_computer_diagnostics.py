"""A dropped computer-use socket must say why it dropped.

A run of drops in the Mac's log read `code=0 … The operation couldn't be completed. (… error 1.)`
and nothing else — the error type had no `LocalizedError`, so it printed its own type name instead
of the underlying failure, and `code=0` is what a *local* cancel looks like as much as a transport
fault (URLSession only reports a code the peer sent).

Two facts separate the cases, so both are recorded now: how long the socket lived, and how long it
had been since the newest frame. A self-drop after the heartbeat's three unanswered beats has a large
silence and no peer code; a transport failure has an underlying `URLError`; a host that stands down
sends 4400/4401/4403.
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SERVICE = (ROOT / "Apps" / "HermesMac" / "LocalComputer" / "LocalComputerService.swift").read_text()


class TheErrorNamesTheFailure(unittest.TestCase):
    def test_it_can_describe_itself(self) -> None:
        self.assertIn("private struct LocalComputerCloseError: Error, LocalizedError", SERVICE)

    def test_it_carries_the_underlying_error_into_the_message(self) -> None:
        self.assertIn("underlying.localizedDescription", SERVICE)

    def test_it_says_when_there_was_no_close_code(self) -> None:
        """"no close code" is the difference between a local cancel and a peer's decision."""
        self.assertIn("no close code (closed locally or transport ended)", SERVICE)

    def test_it_reports_how_long_the_socket_lived_and_how_silent_it_was(self) -> None:
        self.assertIn("let lived: TimeInterval", SERVICE)
        self.assertIn("let silent: TimeInterval", SERVICE)
        self.assertIn("socket failed after \\(Int(lived))s", SERVICE)


class TheHeartbeatDropSaysSo(unittest.TestCase):
    def test_the_silence_path_is_logged_before_dropping(self) -> None:
        self.assertIn('"local computer socket dropped: no frame from the host for "', SERVICE)
        self.assertIn("three heartbeats unanswered", SERVICE)

    def test_the_deadline_is_still_three_beats(self) -> None:
        """15 s beat, 45 s deadline: the numbers in the message must stay true to the code."""
        self.assertIn("Task.sleep(nanoseconds: 15_000_000_000)", SERVICE)
        self.assertIn("Date().timeIntervalSince(sent) > 45", SERVICE)

    def test_the_silence_clock_is_what_it_says(self) -> None:
        self.assertIn("private var lastInboundAt: Date?", SERVICE)
        self.assertIn("let message = try await task.receive()\n            lastInboundAt = Date()", SERVICE)

    def test_a_new_socket_restarts_the_clock(self) -> None:
        self.assertIn("connectedAt = Date()", SERVICE)
        self.assertIn("lastInboundAt = Date()", SERVICE)


if __name__ == "__main__":
    unittest.main()
