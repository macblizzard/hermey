"""The launch sweep **resumes** each bot's conversation, and only a complete transcript is kept.

Two failures from one real log (build 0.1.612):

  `cache prefetch of tinker failed: session not found` — once per bot, every launch. The sweep read
  through `session.history`, which resolves **in-memory live sessions only**
  (`session_registry.py::_sess_nowait` is `_sessions.get(sid)`, and its `4001` says "client should
  resume the stored session"). A `profile` did not help: measured on the host, a *stored* id is
  refused with and without one. `session.resume {profile, session_id}` answers in 0.03-0.7 s and
  carries the `messages` itself, so that — not a history read — is the warm.

  `session opened cody (was aria)` / `cache restored 500 cached rows for cody` / `cache returned to
  cody from cache (26s old), no resume` — and the reply that had arrived was not in the thread until
  a later sweep forced a re-read. Returning to a conversation inside the freshness window treated the
  cache as current because the host's newest stamp had not been reported yet, and "not reported" was
  read as "nothing new".

What must stay true:
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")


def block(start: str, end: str) -> str:
    """The slice of `AppModel.swift` between two markers, asserting both are there."""
    assert start in MODEL, f"missing marker: {start}"
    return MODEL.split(start, 1)[1].split(end, 1)[0]


PREFETCH_START = "public func prefetchConversations() async {"
PREFETCH_END = "    /// The conversation the host says this bot has right now"


class TheSweepResolvesThenResumes(unittest.TestCase):
    def setUp(self) -> None:
        self.prefetch = block(PREFETCH_START, PREFETCH_END)
        self.warm = block("private func warmConversation(", "    /// Remember what is on screen")

    def test_the_identity_is_resolved_before_anything_is_resumed(self) -> None:
        self.assertIn("resolvedConversationID(for: bot.id", self.prefetch)
        self.assertIn("client.warmResume(stored, profile: bot.id)", self.prefetch)
        self.assertLess(self.prefetch.index("resolvedConversationID(for: bot.id"),
                        self.prefetch.index("client.warmResume("),
                        "the id must come from the host before a transcript is asked for")

    def test_the_warm_is_a_resume_and_never_a_history_read(self) -> None:
        # The whole of bug A: `session.history` cannot resolve a stored id, profile or no profile.
        self.assertNotIn("client.history(", self.prefetch,
                         "session.history resolves live sessions only; a stored id is refused")
        self.assertNotIn("client.history(", self.warm)
        self.assertIn("client.warmResume(", self.prefetch)
        self.assertNotIn("client.resumeSession(", self.prefetch,
                         "the pane's resume would take the socket's bound profile and runtime id")

    def test_the_warm_names_the_bot_that_owns_the_conversation(self) -> None:
        self.assertIn("client.warmResume(stored, profile: bot.id)", self.prefetch,
                      "a stored id is only resolvable inside its bot")

    def test_it_walks_the_roster_one_bot_at_a_time(self) -> None:
        # Do not fire eighteen resumes at launch: each one touches the engine and schedules an agent
        # build, and a roster-wide burst is what makes a host feel slow.
        self.assertNotIn("withTaskGroup", self.prefetch,
                         "a roster-wide burst is what made the log unreadable")
        self.assertLess(self.prefetch.index("client.warmResume("),
                        self.prefetch.index("await Task.sleep"),
                        "the pause belongs after a bot, not before the first resume")


class TheRuntimeSessionIsReleased(unittest.TestCase):
    """A resume registers a live session on the host, and a live-transport session is never reaped or
    LRU-evicted (`session_reaper.py::_session_is_lru_evictable`). Eighteen warm resumes would pin
    eighteen idle records, each scheduling an agent build, for the life of the connection."""

    def setUp(self) -> None:
        self.prefetch = block(PREFETCH_START, PREFETCH_END)
        self.warm = block("private func warmConversation(", "    /// Remember what is on screen")

    def test_the_host_is_asked_what_it_already_holds_before_the_sweep(self) -> None:
        self.assertIn("let alreadyLive = (try? await client.liveSessionIDs()) ?? []", self.prefetch)
        self.assertLess(self.prefetch.index("client.liveSessionIDs()"),
                        self.prefetch.index("client.warmResume("),
                        "the live snapshot has to be taken before the first resume")

    def test_the_release_uses_the_runtime_id_the_resume_returned(self) -> None:
        # `session.close` pops `_sessions[session_id]`; the stored id is not a key there.
        self.assertIn("let resumed = try await client.warmResume(stored, profile: bot.id)",
                      self.prefetch)
        self.assertIn("if mayReleaseWarmSession(resumed, alreadyLive: alreadyLive, for: bot.id) {",
                      self.prefetch)
        self.assertIn("try await client.closeSession(resumed.id)", self.prefetch,
                      "the release must be addressed by the runtime id, not the stored one")
        self.assertNotIn("client.closeSession(stored)", self.prefetch)

    def test_a_session_that_was_already_live_is_never_closed(self) -> None:
        guard = block("private func mayReleaseWarmSession(", "\n    /// Up to four named failures")
        self.assertIn("!alreadyLive.contains(resumed.id)", guard,
                      "a session the host was already holding is somebody's open pane")
        self.assertIn("!resumed.isStreaming", guard,
                      "a turn in flight is not the sweep's to end")
        self.assertIn("selectedBotID != botID", guard,
                      "a bot the person switched to mid-sweep is their pane now")

    def test_the_stored_id_is_what_gets_cached(self) -> None:
        # The runtime id dies with the release; every later user of the snapshot addresses the
        # conversation by its durable id, which is the only one a resume accepts.
        self.assertIn("warmConversation(bot.id, session: stored, resumed: resumed)", self.prefetch)
        self.assertIn("sessionID: session,", self.warm)
        self.assertNotIn("sessionID: resumed.id", self.warm)

    def test_the_client_exposes_a_warm_that_does_not_take_the_socket(self) -> None:
        protocol = (ROOT / "Sources" / "HermesKit" / "GatewayClient.swift").read_text(encoding="utf-8")
        self.assertIn("func warmResume(_ id: SessionID, profile: String) async throws -> SessionResume",
                      protocol)
        self.assertIn("func liveSessionIDs() async throws -> Set<SessionID>", protocol)
        self.assertIn("func closeSession(_ id: SessionID) async throws", protocol)

    def test_the_real_client_warms_without_attaching(self) -> None:
        actor = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text(encoding="utf-8")
        warm = actor.split("public func warmResume(", 1)[1].split("public func liveSessionIDs(", 1)[0]
        # Through the shared resume flight (`resumeOnce`) since the open path learned to join it;
        # the invariant this test owns is the same: a warm does not adopt the pane's runtime id.
        self.assertIn("resumeOnce(id, profile: profile)", warm)
        self.assertNotIn("attach(", warm, "a warm must not adopt the runtime id the pane owns")
        self.assertNotIn("boundProfile = ", warm, "a warm must not rebind the socket's profile")


class AStaleIDIsASignalNotAReport(unittest.TestCase):
    def setUp(self) -> None:
        self.prefetch = block(PREFETCH_START, PREFETCH_END)
        self.resolve = block("private func resolvedConversationID(",
                             "    /// File a warm resume's rows")

    def test_a_stale_id_earns_exactly_one_second_resolve(self) -> None:
        self.assertIn("while attempt < 2", self.prefetch,
                      "a stale id is retried once, not forever and not never")
        self.assertIn("Self.isStaleSessionError(error)", self.prefetch,
                      "4001/4007 is the stale-id signal")
        self.assertIn("forgettingStale: attempt > 0", self.prefetch,
                      "the second resolve must start from nothing remembered")

    def test_forgetting_drops_the_cached_identity_and_the_remembered_id(self) -> None:
        self.assertIn("canonicalChatIDCache.removeValue(forKey: botID)", self.resolve)
        self.assertIn("canonicalChatIDStamp.removeValue(forKey: botID)", self.resolve)
        self.assertIn("Self.defaults.removeObject(forKey: Self.endlessKey(botID))", self.resolve,
                      "the id remembered across launches is the stale one")

    def test_one_bot_failing_does_not_abort_the_sweep(self) -> None:
        loop = self.prefetch.split("for bot in bots", 1)[1].split("// One line for the whole sweep", 1)[0]
        self.assertIn("} catch {", loop, "the per-bot resume is caught, not rethrown")
        self.assertIn("failures.append(", self.prefetch, "a failed bot is collected for the report")


class TheSweepReportsOnce(unittest.TestCase):
    def setUp(self) -> None:
        self.prefetch = block(PREFETCH_START, PREFETCH_END)

    def test_the_summary_line_counts_the_whole_sweep(self) -> None:
        self.assertIn(r'"cache prefetched \(warmed) of \(attempted) conversation(s) at launch"',
                      self.prefetch)
        self.assertIn(r'String(format: " (resume %.1fs avg)", $0)', self.prefetch,
                      "the line must say what a warm cost")

    def test_a_genuine_failure_is_one_named_line_with_its_count(self) -> None:
        self.assertIn(r'"cache prefetch could not warm \(failures.count) of \(attempted): "',
                      self.prefetch,
                      "a real failure must still be visible - one line, with how many bots it hit")
        self.assertIn("Self.summarise(failures)", self.prefetch)
        self.assertIn("level: .warning", self.prefetch.split("if !failures.isEmpty", 1)[1])
        self.assertIn(r'failures.append("\(bot.id): \(lastError.localizedDescription)")',
                      self.prefetch)

    def test_no_per_bot_error_line_survives(self) -> None:
        self.assertNotIn("prefetch of \\(bot.id) failed", MODEL,
                         "eighteen identical failures is not a report anybody can read")
        loop = self.prefetch.split("for bot in bots", 1)[1].split("// One line for the whole sweep", 1)[0]
        for line in loop.splitlines():
            if "ClientLog.note(" in line:
                self.assertIn("was stale", line,
                              "the only per-bot line allowed is the quiet stale-id note")

    def test_a_release_that_failed_is_its_own_line(self) -> None:
        self.assertIn(r'"cache prefetch left \(stranded.count) runtime session(s) on the host: "',
                      self.prefetch,
                      "the transcript is cached but the host still holds the session - say so")

    def test_the_summary_names_at_most_four_before_counting(self) -> None:
        self.assertIn("private static func summarise(_ entries: [String], limit: Int = 4) -> String",
                      MODEL)
        self.assertIn(r'"; and \(entries.count - limit) more"', MODEL)


class TheCacheIsOnlyKeptWhenTheHostIsProvenQuiet(unittest.TestCase):
    def setUp(self) -> None:
        self.branch = block("let cachedHost = conversationCacheHostStamp[botID]",
                            "// A pick made in All Sessions outranks")

    def test_an_unknown_host_stamp_forces_the_resume(self) -> None:
        # `botPreviewTimes[bot]` is nil until a sweep reports it, and nil used to compare as "older
        # than nothing new" — the stale pane the log shows.
        self.assertIn("let hostNewest = botPreviewTimes[botID]", self.branch)
        self.assertIn("hostNewest != nil || conversationCacheReadFromHost[botID] == true",
                      self.branch,
                      "an unreported stamp is not proof that the host is quiet")
        self.assertIn("hostKnownQuiet", self.branch)

    def test_unread_activity_forces_the_resume(self) -> None:
        self.assertIn("let unread = unreadBots.contains(botID) || (unreadCounts[botID] ?? 0) > 0",
                      self.branch,
                      "the badge knows something arrived; the thread must not refuse to")

    def test_the_socket_is_compared_with_the_snapshots_session(self) -> None:
        self.assertIn("let cachedSession = conversationCache[botID]?.sessionID ?? selectedSessionID",
                      self.branch,
                      "the old comparison read whichever id the previous bot left selected")
        # The announced id is translated through the runtime→stored alias first: after the host service
        # move every attach mints a new runtime id, and comparing those raw made every return look like
        # a moved conversation (content shifting while scrolling).
        self.assertIn("let known = sessionAliases[announced] ?? announced", self.branch)
        self.assertIn("return known == cachedSession || sessionBots[known] == botID", self.branch)

    def test_the_skip_needs_all_three_facts_to_be_quiet(self) -> None:
        skip = self.branch.split("if restored, pinnedSessionPicks[botID] == nil", 1)[1]
        skip = skip.split("return selectedSessionID", 1)[0]
        self.assertIn("hostKnownQuiet, !unread, !socketSaidSo", skip,
                      "any one of them is enough to make the cache a guess")

    def test_the_skip_line_says_why(self) -> None:
        self.assertIn('), no resume: the cache "', self.branch)
        self.assertIn("+ \"already holds the host's newest message\"", self.branch,
                      "a skipped resume must say what it was skipped on")

    def test_the_resume_says_which_fact_overruled_the_cache(self) -> None:
        self.assertIn('+ "(\\(Int(Date().timeIntervalSince(stamp)))s old), resuming: "',
                      self.branch)
        for reason in ("the bot has unread activity since the snapshot",
                       "the host's newest message is newer than the snapshot",
                       "the host's newest message is not known yet",
                       "the socket named a newer session for this bot"):
            self.assertIn(reason, self.branch, f"missing resume reason: {reason}")

    def test_the_cache_still_paints_before_the_resume(self) -> None:
        opening = block("let restored = restoreConversation(for: botID)", "let cachedHost")
        self.assertIn("isOpeningConversation = !restored", opening)
        self.assertIn("defer { isOpeningConversation = false }", opening,
                      "the pane must paint the snapshot and only then read the host")


class TheSnapshotRemembersHowItWasTaken(unittest.TestCase):
    def test_only_a_complete_transcript_may_stand_in_for_a_resume(self) -> None:
        # A resume that shipped the newest page of a long conversation leaves the older half on the
        # host, and the release took the paging copy with it — so that snapshot is paint-only.
        warm = block("private func warmConversation(", "    /// Remember what is on screen")
        self.assertIn("conversationCacheReadFromHost[botID] = resumed.earlierCursor == nil", warm)

    def test_a_captured_snapshot_is_not(self) -> None:
        capture = block("func captureConversation(for botID: String?)",
                        "    /// Adopt a resume's page")
        self.assertIn("conversationCacheReadFromHost[botID] = false", capture,
                      "what was on screen is not what the host holds now")

    def test_eviction_and_reset_forget_the_mark(self) -> None:
        self.assertIn("conversationCacheReadFromHost.removeValue(forKey: evicted)", MODEL)
        self.assertIn("conversationCacheReadFromHost.removeValue(forKey: botID)", MODEL)


class TheSwiftTestsExist(unittest.TestCase):
    def test_the_promises_are_held_by_real_tests(self) -> None:
        prefetch = (ROOT / "Tests" / "HermesAppKitTests" / "ConversationPrefetchTests.swift"
                    ).read_text(encoding="utf-8")
        for name in ("testThePrefetchResumesScopedToTheBotAndNeverReadsHistory",
                     "testAStalePrefetchIDIsResolvedAgainInsteadOfReported",
                     "testTheSweepReleasesEveryRuntimeSessionItMinted",
                     "testASessionThatWasAlreadyLiveIsNotClosed"):
            self.assertIn(name, prefetch)

        cache = (ROOT / "Tests" / "HermesAppKitTests" / "ConversationCacheTests.swift"
                 ).read_text(encoding="utf-8")
        for name in ("testReturningResumesWhenTheHostsNewestMessageIsUnknown",
                     "testReturningResumesWhenTheHostReportedANewerMessage",
                     "testReturningResumesWhenTheBotHasUnreadActivity",
                     "testACacheTheHostConfirmsIsCurrentIsNotReloaded"):
            self.assertIn(name, cache)

    def test_the_scripted_host_can_warm_and_release(self) -> None:
        host = (ROOT / "Tests" / "HermesAppKitTests" / "ScriptedHost.swift").read_text(encoding="utf-8")
        self.assertIn("private(set) var warmed: [(id: SessionID, profile: String)]", host,
                      "a test must be able to prove which bot each warm named")
        self.assertIn("var liveSessions: Set<SessionID>", host,
                      "a test must be able to say what the host already holds")
        self.assertIn("private(set) var closedSessions: [SessionID]", host)
        self.assertIn("var warmStaleIDs: Set<SessionID>", host)
        self.assertIn("var profileSessionsByCall: [[SessionSummary]]", host)


if __name__ == "__main__":
    unittest.main()
