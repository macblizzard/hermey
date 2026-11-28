"""An idle socket is asked something every four minutes, and a replay survives one abort.

The owner's 0.1.698 log: `socket reconnecting (attempt 1)` about every fifteen minutes, and one
`event replay failed: transportClosed("Software caused connection abort")`.

What the host's own relay log says (hermeyd, 27–28 Nov, two devices, thirty hours): sockets that
nobody typed into died at 14 m 32 s, 14 m 42 s and 15 m 15 s, and every close arrived as
`client read error: WebSocket protocol error: Connection reset without closing handshake` — an
abnormal termination, not a close either endpoint asked for. `hermeyd` has no idle timer on the
app-facing socket and no ping on it (unlike `local_computers.rs`, which pings); this client had no
keepalive either — `ping` was only ever sent once, for the latency chip at connect. So a socket
that carried `client.capabilities` and then nothing sat inside a ~15-minute idle window that
belongs to the hop in front of `hermeyd` (`tailscale serve`), which is not ours to configure. The
answer is to keep the socket warm from this side; the replay failure is the consequence, and it
gets one retry because the replay is the first call on the freshly dialled socket.

Swift does not build on this host, so these checks read the source: they fail if the keepalive, its
cancellation, or the retry is removed or weakened.
"""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ACTOR = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text(encoding="utf-8")


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


CONNECT = block(ACTOR, "private func performConnect(retrying: Bool = false) async throws {",
                "/// Wait for a socket that is **already dialed**")
BEGIN = block(ACTOR, "private func beginConnection() -> Int {",
              "/// Retire the current socket")
LOST = block(ACTOR, "private func connectionLost(reason: String) -> Bool {",
             "private func scheduleReconnect(")
DISCONNECT = block(ACTOR, "public func disconnect() async {",
                   "/// Dial now instead of on the ladder's clock.")
KEEPALIVE = block(ACTOR, "// MARK: - Idle keepalive", "private func performResume(")
REPLAY = block(ACTOR, "private func replaySurvivingOneAbort(", "// MARK: - Idle keepalive")
RESTORE = block(ACTOR, "private func restoreAfterReconnect() async throws {",
                "private func eventReplay(")
FRAME = block(ACTOR, "private func handle(_ frame: IncomingFrame) async {",
              "/// The key the replay bookkeeping uses")
SEND = block(ACTOR, "private func send(id: RPCID, method: String, params: JSONValue?) async throws {",
             "private func sendResponse(")


class AnIdleSocketIsKeptWarm(unittest.TestCase):
    def test_the_interval_is_well_inside_the_measured_close(self):
        self.assertIn("public static let keepaliveInterval: TimeInterval = 240", ACTOR)
        interval = int(ACTOR.split("keepaliveInterval: TimeInterval = ", 1)[1].split("\n", 1)[0])
        self.assertGreater(interval, 60, "a minute is a poll, not a keepalive")
        self.assertLess(interval, 900, "the measured closes were at ~15 minutes of silence")

    def test_the_tick_asks_the_cheapest_question(self):
        self.assertIn('perform("ping"', KEEPALIVE,
                      "`ping` is the gateway's no-database method")
        self.assertIn("guard case .open = stateBox.current, sawReady else { return }", KEEPALIVE)
        self.assertIn("Date().timeIntervalSince(lastTrafficAt) >= Self.keepaliveInterval",
                      KEEPALIVE,
                      "a socket carrying a streaming turn is not idle and must not be pinged")

    def test_a_socket_waiting_on_a_slow_answer_is_not_pinged(self):
        # A resume holds the engine's projection for seconds; a ping queued behind one would time
        # out into a drop of a socket that is working.
        self.assertIn("guard pending.isEmpty, resumeFlights.isEmpty else { return }", KEEPALIVE)

    def test_a_failed_ping_is_a_dead_socket(self):
        self.assertIn('_ = connectionLost(reason: "keepalive failed:', KEEPALIVE,
                      "swallowing it would leave the chip on `direct` with nothing behind it")

    def test_both_directions_refresh_the_idle_clock(self):
        self.assertIn("lastTrafficAt = Date()", FRAME)
        self.assertIn("lastTrafficAt = Date()", SEND)

    def test_the_task_starts_when_the_socket_opens(self):
        self.assertIn("setState(.open)\n        startKeepalive()", CONNECT)

    def test_every_way_a_socket_ends_stops_the_task(self):
        self.assertIn("stopKeepalive()", BEGIN, "a new dial owns the keepalive")
        self.assertIn("stopKeepalive()", LOST)
        self.assertIn("stopKeepalive()", DISCONNECT)

    def test_the_task_cannot_outlive_the_client(self):
        self.assertIn("keepaliveTask = Task { [weak self] in", KEEPALIVE)
        self.assertIn("guard let self else { return }", KEEPALIVE)
        self.assertIn("if Task.isCancelled { return }", KEEPALIVE)


class AReplaySurvivesOneAbortedSend(unittest.TestCase):
    def test_the_replay_is_the_retrying_one(self):
        self.assertIn("replaySurvivingOneAbort(session: resumed.runtimeID", RESTORE)

    def test_it_retries_once_after_a_pause(self):
        self.assertEqual(2, REPLAY.count("eventReplay(session: session, lastSeen: lastSeen)"),
                         "one try, one retry — no loop")
        self.assertIn("try? await Task.sleep(nanoseconds: 250_000_000)", REPLAY)

    def test_only_an_aborted_send_is_retried(self):
        guard = block(REPLAY, "guard Self.isAbortedSend(error) else { throw error }",
                      "try? await Task.sleep")
        self.assertTrue(guard)
        aborted = block(ACTOR, "static func isAbortedSend(_ error: GatewayError) -> Bool {",
                        "// MARK: - Idle keepalive")
        self.assertIn("case .notConnected, .transportClosed: return true", aborted)
        self.assertIn("default: return false", aborted,
                      "a refusal or a timeout is an answer, not an aborted write")


if __name__ == "__main__":
    unittest.main()
