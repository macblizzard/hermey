"""Returning to a chat inside the freshness window must not reload it."""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text()


class TheCacheIsTrusted(unittest.TestCase):
    def test_a_fresh_snapshot_answers_without_a_resume(self) -> None:
        self.assertIn("public static let defaultCacheFreshness: TimeInterval = 120", MODEL)
        self.assertIn("Date().timeIntervalSince(stamp) < conversationCacheFreshness", MODEL)
        self.assertIn("return selectedSessionID", MODEL.split("from cache")[1][:400])

    def test_the_skip_never_hides_a_deliberate_session_pick(self) -> None:
        # Choosing a session in All Sessions outranks the canonical chat exactly once; a cache hit
        # must not swallow that pick.
        self.assertIn("pinnedSessionPicks[botID] == nil", MODEL)
        self.assertIn("connection.isLive", MODEL)

    def test_every_decision_is_logged_for_the_next_report(self) -> None:
        # The cache could not be diagnosed from a build that stayed silent: capture, miss, restore
        # and the cache-hit short circuit each say what happened under category "cache".
        for line in ('"cached \\(transcript.count) rows for',
                     '"no cached conversation for',
                     '"restored \\(snapshot.entries.count) cached rows for',
                     '"returned to \\(botID) from cache "'):
            self.assertIn(line, MODEL, line)
        self.assertGreaterEqual(MODEL.count('category: "cache"'), 4)
