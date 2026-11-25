"""A long conversation opens, and a slow open says so.

Reported 2026-11-25 (iPhone 0.1.668, iOS 27.0.1, host hermes.corvus-vibes.ts.net): cody's Bot Chat
took very long to load, and the log repeated

    session.resume timed out after 120s
    the host's own Bot Chat for cody (local-9b01…) would not open; falling back to the remembered ids
    no cached conversation for cody: the pane has to wait for a resume

What was actually happening, measured on the host (`Tools/bench_resume.py`):

  * the conversation holds 6,794 rows (5,463 of them compacted by an in-place compaction, ~4.5 MB
    of text); reading every row out of state.db is 0.03 s, so the database was never the problem;
  * `session.resume` builds the display projection for the WHOLE lineage — `_history_to_messages`
    over 6,099 messages, 6.2-9.2 s of pure Python per resume — then serialises 7.5 MiB into one
    frame. Three sent together answered at 6.2 s, 12.6 s and 18.5 s: the gateway renders them in
    turn, and the projection holds the interpreter for all of it;
  * the app asks more than once while it waits (a deadline Retry, a banner, a reconnect). Each retry
    was a fresh full render queued behind the last, so a 6 s answer became a 120 s timeout;
  * `hermeyd` already pages the *reply* to its newest page, and the app already pages older rows
    back over `session.history`. What was missing was (a) not paying for N renders and (b) saying
    what the wait is.

What must stay true:

  1. the resume the phone receives is WINDOWED — a page size constant, never the whole history —
     and the reply says how many rows exist and where the page starts, so "load earlier" can
     reach every one of them;
  2. the window is a view, not a copy: the relay keeps the full reply, so paging back is answered
     from it and no message becomes unreachable;
  3. one conversation being resumed is one engine request: a retry joins the call in flight
     instead of starting a second render, and every id that asked is answered;
  4. the first paint never waits for the history: the cache is painted before the resume is
     awaited, and the pane counts the wait out loud (with the Retry) instead of spinning in
     silence;
  5. the client's resume timeout is a NAMED constant that is not zero, so the pane's own deadline
     and the transport's ceiling stay two separate decisions.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HISTORY = (ROOT / "hermeyd" / "src" / "history.rs").read_text(encoding="utf-8")
RELAY = (ROOT / "hermeyd" / "src" / "relay.rs").read_text(encoding="utf-8")
ACTOR = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
SCREEN = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(
    encoding="utf-8")

#: The conversation this was reported on. Only used to make "a page is smaller than the history"
#: a real comparison rather than a vibe.
REPORTED_ROWS = 6778


def member(text: str, signature: str) -> str:
    """One 4-space-indented Swift member, from its signature to its closing brace."""
    start = text.index(signature)
    return text[start:][: text[start:].index("\n    }\n") + 1]


def rust_fn(text: str, signature: str) -> str:
    """A Rust function body, from its `fn` line to the closing brace in column 0."""
    start = text.index(signature)
    end = text.index("\n}\n", start)
    return text[start:end]


def constant(text: str, name: str) -> int:
    """`pub const NAME: usize = 123;` as an int — the page size, read rather than assumed."""
    found = re.search(rf"pub const {name}: usize = ([0-9_]+);", text)
    assert found, f"{name} is declared as a named usize constant"
    return int(found.group(1).replace("_", ""))


class TheResumeIsWindowed(unittest.TestCase):
    """The phone never receives a whole 6,778-row conversation in one frame."""

    def test_the_page_size_is_a_constant_and_not_the_whole_history(self) -> None:
        page = constant(HISTORY, "PAGE_MESSAGES")
        self.assertGreater(page, 0)
        self.assertLess(page, REPORTED_ROWS // 4,
                        "a page that large is the whole transcript with extra steps")
        self.assertIn("/// Rows per page.", HISTORY,
                      "the reason for the number is written next to it, not in a commit message")

    def test_a_resume_reply_is_paged_with_the_page_constant(self) -> None:
        # Every place the relay pages a reply — the tracked resume and the restart replay — must
        # cut to the page constant; one forgotten call site is a whole transcript on the wire.
        calls = RELAY.count("history::page_resume_response(")
        self.assertGreaterEqual(calls, 2)
        self.assertEqual(RELAY.count("history::PAGE_MESSAGES"), calls,
                         "each page_resume_response call is cut to PAGE_MESSAGES")
        self.assertGreaterEqual(RELAY.count("history::PAGE_BYTES"), calls,
                                "and to the byte budget as well")

    def test_the_page_tells_the_client_where_it_is_and_how_much_there_is(self) -> None:
        # Without `history`, 200 rows look like the whole conversation and nothing older is asked
        # for: the user's own messages would read as deleted.
        body = rust_fn(HISTORY, "pub fn page_resume_response(")
        self.assertIn('"history".to_string()', body)
        self.assertIn('"total": total', body)
        self.assertIn('"shown": shown', body)
        self.assertIn('"cursor": cursor', body)

    def test_the_window_is_a_view_and_the_whole_reply_is_kept(self) -> None:
        # Paging back is answered from the relay's own copy of the reply, so the rows the page
        # dropped must be remembered — a window that forgets is data loss with a smaller frame.
        body = RELAY.split("Ok((paged, rows)) =>", 1)[1].split("return fan_resume_reply", 1)[0]
        self.assertIn("lock(&state.cache).remember(key.clone(), rows.clone())", body,
                      "every row is remembered under the resume's own key")
        self.assertIn("HistoryKey::new(fresh, &key.profile), rows", body,
                      "and under the runtime id the app pages with")


class OneConversationIsOneRender(unittest.TestCase):
    """A retry joins the resume in flight; it does not queue another full transcript build."""

    def test_a_duplicate_resume_is_parked_before_it_reaches_the_engine(self) -> None:
        self.assertIn('if method == "session.resume" && park_duplicate_resume(state, &frame)',
                      RELAY)
        helper = rust_fn(RELAY, "fn park_duplicate_resume(")
        self.assertIn("lock(&state.parked).park(&key, id)", helper)
        self.assertIn("ClientAction::Drop", RELAY.split("park_duplicate_resume", 1)[1][:1200],
                      "a parked frame is not forwarded")
        self.assertIn("HistoryKey::from_params(frame.get(\"params\"))", helper,
                      "coalescing is per conversation, never per socket")

    def test_the_parked_ids_are_answered_from_the_one_reply(self) -> None:
        body = rust_fn(RELAY, "fn inspect_engine_text(")
        self.assertIn("lock(&state.parked).answer(id)", body)
        self.assertIn("fan_resume_reply(&paged, &waiters)", body)
        fan = rust_fn(RELAY, "fn fan_resume_reply(")
        self.assertIn('object.insert("id".to_string(), rpc_id_value(waiter))', fan,
                      "each retry sees an answer for its own request id")
        self.assertIn("lines.push('\\n')", fan,
                      "several answers ride one write; the clients split NDJSON on 0x0A")

    def test_the_wait_list_is_bounded_so_nothing_is_dropped_silently(self) -> None:
        limit = constant(HISTORY, "MAX_PARKED_RESUMES")
        self.assertGreaterEqual(limit, 2)
        park = rust_fn(HISTORY, "    pub fn park(")
        self.assertIn("waiting.len() >= self.max_waiters", park)
        self.assertIn("return false", park,
                      "past the cap the duplicate is forwarded — slow beats unanswered")

    def test_an_engine_restart_answers_whoever_was_waiting(self) -> None:
        body = rust_fn(RELAY, "fn process_engine_frame(")
        self.assertIn("lock(&state.parked).pending_for(&target.key())", body)
        self.assertIn("fan_resume_reply(&paged, &waiting)", body,
                      "the app's own resume id is answered from the replay's reply")

    def test_the_client_also_joins_the_call_in_flight(self) -> None:
        # The relay protects a shipped app; the client must not produce the storm in the first
        # place. One resume per (profile, stored id), and every caller gets the same answer.
        self.assertIn("private var resumeFlights: [ResumeKey: Task<GatewayPayloadDecoder.Resume, Error>]",
                      ACTOR)
        once = member(ACTOR, "    private func resumeOnce(_ id: SessionID,")
        self.assertIn("if let flight = resumeFlights[key]", once)
        self.assertIn("try await flight.value", once)
        self.assertIn("resumeFlights[key] = flight", once)
        self.assertIn("defer { resumeFlights[key] = nil }", once)
        self.assertIn("try await resumeOnce(id, profile: profile ?? boundProfile)", ACTOR,
                      "the open's resume goes through the shared call")
        warm = member(ACTOR, "    public func warmResume(_ id: SessionID, profile: String)")
        self.assertIn("try await resumeOnce(id, profile: profile)", warm,
                      "and so does the launch sweep: warming must not queue behind an open")


class TheFirstPaintNeverWaitsForTheHistory(unittest.TestCase):
    def test_the_cache_is_painted_before_the_resume_is_awaited(self) -> None:
        body = MODEL.split("func openStoredConversation(_ stored: SessionID, botID: String,", 1)[1]
        body = body.split("    /// One resume, applied to the screen.", 1)[0]
        self.assertLess(body.index("await paintCachedConversation(stored, botID: botID)"),
                        body.index("await adoptStoredConversation(stored"),
                        "the rows this device already has go on screen before the host is asked")

    def test_the_pane_counts_the_wait_and_offers_the_retry(self) -> None:
        self.assertIn("public static let slowOpenNotice: TimeInterval", MODEL)
        self.assertIn("@Published public private(set) var openStartedAt: Date?", MODEL)
        open_now = member(MODEL, "    public func openNow(_ botID: String) async -> SessionID? {")
        self.assertIn("openStartedAt = Date()", open_now, "the clock starts with the open")
        # And it is cleared wherever the open ends, or the next open would inherit a stale count.
        self.assertIn("openStartedAt = nil", member(MODEL, "    public func endOpen(_ botID: String) {"))
        self.assertGreaterEqual(MODEL.count("openStartedAt = nil"), 2,
                                "both the finished open and the cancelled one clear it")

        state = member(SCREEN, "    private var openingState: some View {")
        self.assertIn("TimelineView(.periodic(from: .now, by: 1))", state,
                      "a spinner with no number is a frozen screen with an animation on it")
        self.assertIn('"the host is sending this chat\'s history — \\(Int(waited))s"', state)
        self.assertIn("model.openStartedAt", state)
        self.assertIn('accessibilityIdentifier("openingState")', state)
        # The Retry after the deadline is the other half of "never a blank 120-second wait".
        self.assertIn("model.openFailure, failure.botID == bot.id", SCREEN)
        self.assertIn('TextButton("Retry", tone: Tokens.accentText)', SCREEN)

    def test_a_timed_out_resume_keeps_the_pane_usable(self) -> None:
        # The deadline does not abandon the call: a resume that answers late still fills the chat,
        # and the sentence goes away when it does.
        open_now = member(MODEL, "    public func openNow(_ botID: String) async -> SessionID? {")
        self.assertIn("let watchdog = Task { @MainActor in", open_now)
        self.assertIn("self.openFailure = OpenFailure(botID: botID", open_now)
        self.assertIn("openFailure = nil", open_now.split("let opened = await work.value", 1)[1])
        self.assertIn("public func retryOpen(_ botID: String) async -> SessionID?", MODEL)


class TheTimeoutIsANamedNumber(unittest.TestCase):
    def test_the_client_resume_timeout_is_named_and_not_zero(self) -> None:
        found = re.search(r"public static let resumeTimeout: TimeInterval = ([0-9.]+)", ACTOR)
        self.assertIsNotNone(found, "the resume ceiling is a named constant")
        assert found is not None
        seconds = float(found.group(1))
        self.assertGreater(seconds, 0, "a zero timeout aborts every resume it was meant to allow")
        self.assertGreaterEqual(seconds, 30,
                                "the host needs seconds per resume; a smaller ceiling is a bug")

    def test_the_timeouts_struct_defaults_to_that_constant(self) -> None:
        self.assertIn("sessionResume: TimeInterval = Timeouts.resumeTimeout", ACTOR)
        self.assertNotRegex(ACTOR, r"sessionResume: TimeInterval = [0-9]",
                            "no second, unlabelled copy of the number")
        init = member(ACTOR, "        public init(call: TimeInterval = 30,")
        self.assertIn("self.sessionResume = sessionResume", init)

    def test_the_pane_deadline_is_shorter_than_the_transport_ceiling(self) -> None:
        # Two different promises: the pane stops looking frozen at `openDeadline`, the call itself
        # is allowed `resumeTimeout`. Reversing them is a blank wait again.
        open_found = re.search(r"public static let openDeadline: TimeInterval = ([0-9.]+)", MODEL)
        resume_found = re.search(r"public static let resumeTimeout: TimeInterval = ([0-9.]+)", ACTOR)
        assert open_found is not None and resume_found is not None
        deadline = float(open_found.group(1))
        ceiling = float(resume_found.group(1))
        self.assertLess(deadline, ceiling)
        self.assertGreater(deadline, 0)


if __name__ == "__main__":
    unittest.main()
