"""Opening a long bot chat on the phone: the order of the open, and the host's page.

Reported 2026-11-25, again after the first round of fixes: a bot chat with thousands of rows still sat
on "Opening…" on a cold tap, and scrolling back through it meant tapping "load earlier" forty times.

What the open path actually did, in order:

  1. the disk copy was read in `openStoredConversation`, which sits **after** `loadModelLabel`
     (`model.options`) and `canonicalChatIdentity` (`session.list`) — two round trips of nothing on
     screen before the cache was even opened;
  2. the launch sweep warmed up to 24 bots one `session.resume` at a time, 150 ms apart, on the one
     socket, and a tap only stopped it starting the *next* one — the tapped resume queued behind the
     in-flight warm;
  3. the relay parsed the whole `session.resume` frame into 6,778 rows, sliced the newest page off it,
     and measured every row a second time to cache them: the page constants were applied after the
     full read;
  4. the on-disk cache kept 500 rows per chat and **dropped the paging cursor** when it trimmed, so a
     trimmed chat could never page from disk at all;
  5. `adoptResume` ran `SentAttachmentVault.decorate` synchronously on the main actor, over the whole
     transcript, at the exact moment the pane was being painted;
  6. a windowed resume carried the newest page and nothing else, and the rest cost 150 rows per tap.

What must stay true (each guard reads the source, not the behaviour):

  * the disk paint is the first `await` in the open path, ahead of both round trips;
  * a tap cancels the sweep's own task, so the walk stands down mid-flight rather than at its next
    iteration, and the shells start the sweep through the model so it can;
  * the relay pages a resume reply from its text, before anything materialises it, and a page's
    `total` is the counted conversation, not the length of what the connection keeps;
  * the cache keeps more than 500 rows and a trimmed transcript keeps a *moved* cursor;
  * `decorate` is never called on the main actor from the adopt path;
  * a windowed resume fills older pages on its own, bounded and cancellable, and a tap asks for a page
    worth having.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
CACHE = (ROOT / "Sources" / "HermesKit" / "CacheStore.swift").read_text(encoding="utf-8")
VAULT = (ROOT / "Sources" / "HermesKit" / "SentAttachment.swift").read_text(encoding="utf-8")
IOS_APP = (ROOT / "Apps" / "HermesMobile" / "HermesMobileApp.swift").read_text(encoding="utf-8")
MAC_APP = (ROOT / "Apps" / "HermesMac" / "HermesMacApp.swift").read_text(encoding="utf-8")
HISTORY = (ROOT / "hermeyd" / "src" / "history.rs").read_text(encoding="utf-8")
RELAY = (ROOT / "hermeyd" / "src" / "relay.rs").read_text(encoding="utf-8")


def body(text: str, signature: str) -> str:
    """One Swift/Rust function, signature to its closing brace.

    A brace counter that skips `//` comments and string literals, so a `{` inside a log line or a
    sentence cannot make a guard read past the member it names.
    """
    start = text.index(signature)
    open_at = text.index("{", start)
    depth = 0
    index = open_at
    in_string = False
    escaped = False
    in_line_comment = False
    while index < len(text):
        char = text[index]
        if in_line_comment:
            if char == "\n":
                in_line_comment = False
        elif in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "/" and text[index + 1 : index + 2] == "/":
            in_line_comment = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
        index += 1
    raise AssertionError(f"no closing brace for {signature!r}")


def position(text: str, needle: str, what: str) -> int:
    assert needle in text, f"{what} is missing: {needle!r}"
    return text.index(needle)


class ColdOpenPaintsTheDiskCopyFirst(unittest.TestCase):
    """1. The disk copy is on screen before `model.options` and `session.list` are awaited."""

    def setUp(self) -> None:
        self.open_path = body(
            MODEL, "public func endlessSession(for botID: String, select: Bool = true) async"
        )

    def test_the_paint_is_in_the_open_path(self) -> None:
        self.assertIn(
            "await paintDiskCopy(for: botID)",
            self.open_path,
            "the open path must paint the on-disk copy itself, not leave it to the resume",
        )

    def test_the_paint_precedes_both_round_trips(self) -> None:
        paint = position(self.open_path, "await paintDiskCopy(for: botID)", "the disk paint")
        label = position(self.open_path, "await loadModelLabel()", "the model-label read")
        identity = position(
            self.open_path, "await canonicalChatIdentity(for: botID)", "the identity read"
        )
        self.assertLess(
            paint,
            label,
            "the disk paint must run before `model.options`, or a cold tap waits a round trip for "
            "a cache it already has",
        )
        self.assertLess(
            paint,
            identity,
            "the disk paint must run before `session.list`, or a cold tap waits two round trips for "
            "a cache it already has",
        )

    def test_the_paint_is_keyed_by_the_remembered_id_not_a_lookup(self) -> None:
        helper = body(MODEL, "private func paintDiskCopy(for botID: String) async -> Bool")
        self.assertIn("Self.defaults.string(forKey: Self.endlessKey(botID))", helper)
        self.assertIn("paintCachedConversation", helper)
        self.assertNotIn(
            "canonicalChatIdentity",
            helper,
            "a paint that has to ask the host which chat this is is not a paint",
        )

    def test_the_paint_does_not_overwrite_a_warm_pane(self) -> None:
        helper = body(MODEL, "private func paintDiskCopy(for botID: String) async -> Bool")
        self.assertIn(
            "guard transcript.isEmpty else { return false }",
            helper,
            "a warm return, or a pick in All Sessions, must be left alone",
        )
        # The warm path is still the synchronous in-memory restore, unchanged and still first.
        self.assertIn("let restored = restoreConversation(for: botID)", self.open_path)
        self.assertLess(
            self.open_path.index("let restored = restoreConversation(for: botID)"),
            self.open_path.index("await paintDiskCopy(for: botID)"),
        )


class TheSweepYieldsToATap(unittest.TestCase):
    """2. A tap cancels the sweep's task; the shells go through the model so it can."""

    def test_begin_open_cancels_the_sweep_immediately(self) -> None:
        begin = body(MODEL, "public func beginOpen(_ botID: String) -> Bool {")
        self.assertIn("prefetchTask?.cancel()", begin, "a tap must stand the walk down mid-flight")
        self.assertLess(
            begin.index("prefetchTask?.cancel()"),
            begin.index("openingBotID = botID"),
            "the sweep must be cancelled before the open is announced",
        )

    def test_the_sweep_runs_under_a_task_the_model_owns(self) -> None:
        self.assertIn("private var prefetchTask: Task<Void, Never>?", MODEL)
        launcher = body(MODEL, "public func startPrefetch()")
        self.assertIn("prefetchTask = Task", launcher)
        self.assertIn("prefetchConversations()", launcher)

    def test_the_walk_stops_and_does_not_run_its_closing_lines(self) -> None:
        sweep = body(MODEL, "public func prefetchConversations() async {")
        self.assertIn(
            "if Task.isCancelled || openingBotID != nil || sweepUnder != userOpenGeneration { return }",
            sweep,
            "the loop must *return* on a tap (not merely `break`), and it must notice cancellation",
        )
        self.assertNotIn("sweepUnder != userOpenGeneration { break }", sweep)

    def test_the_shells_do_not_await_a_sweep_nobody_can_cancel(self) -> None:
        for name, text in (("iOS", IOS_APP), ("Mac", MAC_APP)):
            self.assertNotIn(
                "await app.model.prefetchConversations()",
                text,
                f"{name}: a sweep awaited by a `.task` cannot be stood down by a tap",
            )
            self.assertNotIn("await store.model.prefetchConversations()", text, name)
            self.assertIn(
                ".startPrefetch()",
                text,
                f"{name}: the shell must start the sweep through the model",
            )


class TheRelayPagesBeforeItMaterialises(unittest.TestCase):
    """3. The resume reply is windowed from its text, and `history.total` is a count."""

    def setUp(self) -> None:
        self.inspect = body(RELAY, "fn inspect_engine_text(state: &ConnectionState, text: &str)")

    def test_the_text_path_runs_before_any_full_parse(self) -> None:
        paged = position(self.inspect, "history::page_resume_text(", "the windowed page")
        parsed = position(self.inspect, "serde_json::from_str(text)", "the whole-frame parse")
        self.assertLess(
            paged,
            parsed,
            "the resume reply must be paged from its text; parsing the frame first materialises "
            "every row the page exists to avoid",
        )

    def test_the_windowed_page_is_what_gets_cached(self) -> None:
        self.assertIn("remember_window(key.clone(), paged.transcript.clone())", self.inspect)
        self.assertLess(
            self.inspect.index("remember_window(key.clone(), paged.transcript.clone())"),
            self.inspect.index("serde_json::from_str(text)"),
            "the rows must be cached from the windowed reply, not from a parsed one",
        )

    def test_the_page_is_built_from_raw_elements(self) -> None:
        pager = body(HISTORY, "pub fn page_resume_text(")
        self.assertIn(
            "Vec<&'a RawValue>",
            HISTORY,
            "messages must be borrowed as raw slices, not parsed into a tree",
        )
        self.assertIn("let total = rows.len();", pager)
        self.assertIn(
            "transcript.newest(max_messages, max_bytes)",
            pager,
            "only the newest page may be parsed",
        )

    def test_history_total_is_the_counted_conversation(self) -> None:
        pager = body(HISTORY, "pub fn page_resume_text(")
        self.assertIn('json!({ "total": total, "shown": shown, "cursor": cursor })', pager)
        self.assertIn(
            "total: cached.transcript.total()",
            HISTORY,
            "a page's total must come from the stored count, not the rows this cache holds",
        )
        self.assertNotIn("total: cached.rows.len()", HISTORY)

    def test_the_cache_no_longer_serialises_every_row_to_measure_it(self) -> None:
        remember = body(HISTORY, "pub fn remember_window(")
        self.assertNotIn(
            "encoded_size",
            remember,
            "the byte total arrives with the transcript; re-serialising every row to weigh the "
            "cache was the second full pass over the conversation",
        )


class TheCacheKeepsALongChatOpenable(unittest.TestCase):
    """4. More than 500 rows per chat, and a trim that keeps a usable cursor."""

    def test_the_per_chat_cap_is_raised(self) -> None:
        match = re.search(r"maxMessagesPerChat\s*=\s*(\d+)", CACHE)
        if match is None:
            self.fail("the per-chat cap must exist")
        cap = int(match.group(1))
        self.assertNotEqual(cap, 500, "500 rows is a page and a half of a long bot chat")
        self.assertGreaterEqual(cap, 1500)

    def test_a_trim_keeps_the_cursor_moved_forward(self) -> None:
        store = body(CACHE, "public func storeMessages(")
        self.assertIn("let dropped = entries.count - kept.count", store)
        self.assertIn("cursor.map { $0 + dropped }", store)
        self.assertNotIn(
            "truncated ? nil : cursor",
            store,
            "dropping the cursor on a trim is what left a long chat unable to page from disk",
        )

    def test_the_cached_copy_carries_the_cursor_to_the_pane(self) -> None:
        paint = body(MODEL, "private func paintCachedConversation(")
        self.assertIn("earlierCursor = cached.cursor", paint)


class DecorateStaysOffTheMainActor(unittest.TestCase):
    """5. `decorate` is not called on the main actor from the adopt path."""

    def test_adopt_resume_does_not_join_the_vault(self) -> None:
        adopt = body(
            MODEL,
            "private func adoptResume(_ entries: [TranscriptEntry], cursor: Int?, total: Int,",
        )
        self.assertNotIn(
            "SentAttachmentVault.decorate(",
            adopt,
            "the vault join reads files and decodes pictures; it must not run inside the adopt",
        )
        self.assertIn("scheduleDecoration(", adopt)

    def test_the_decoration_pass_is_detached_and_guarded(self) -> None:
        schedule = body(MODEL, "private func scheduleDecoration(for botID: String, sessionID: String)")
        self.assertIn("SentAttachmentVault.decorated(", schedule, "the detached door only")
        self.assertNotIn("SentAttachmentVault.decorate(", schedule)
        self.assertIn("guard generation == self.decorationGeneration", schedule)
        self.assertIn("self.transcript.count == rows.count", schedule)
        self.assertIn("SentAttachmentVault.hasRecords(", schedule, "nothing to join means no task")

    def test_the_pager_also_joins_off_main(self) -> None:
        pager = body(MODEL, "public func loadEarlierHistory(limit: Int = 400, silent: Bool = false)")
        self.assertIn("await SentAttachmentVault.decorated(fresh, sessionID: sid)", pager)
        self.assertNotIn("SentAttachmentVault.decorate(fresh", pager)


class OlderPagesFillThemselves(unittest.TestCase):
    """6. A windowed resume backfills, bounded, chunked and cancellable — and a tap is worth a page."""

    def test_a_page_is_worth_having(self) -> None:
        pager = body(MODEL, "public func loadEarlierHistory(limit: Int = 400, silent: Bool = false)")
        self.assertIn("limit: Int = 400", pager)

    def test_the_backfill_is_bounded_and_cancellable(self) -> None:
        backfill = body(MODEL, "public func scheduleHistoryBackfill()")
        self.assertIn("Self.autoBackfillRows", backfill)
        self.assertIn("Task.isCancelled", backfill)
        self.assertIn("self.selectedSessionID == sid", backfill, "a bot switch ends the fill")
        self.assertIn("silent: true", backfill)
        self.assertIn("Task.sleep", backfill, "one page, then a breath — not a burst")

    def test_the_fill_is_started_by_a_windowed_resume_and_stopped_by_leaving(self) -> None:
        adopt = body(
            MODEL,
            "private func adoptStoredConversation(_ stored: SessionID, botID: String,",
        )
        self.assertIn("scheduleHistoryBackfill()", adopt)
        for member in ("private func resetForBotSwitch()", "public func endOpen(_ botID: String) {"):
            text = body(MODEL, member)
            self.assertIn(
                "backfillTask?.cancel()",
                text,
                f"{member.split('(')[0]}: the fill belongs to the conversation it was started for",
            )

    def test_a_silent_page_does_not_yank_the_reader(self) -> None:
        pager = body(MODEL, "public func loadEarlierHistory(limit: Int = 400, silent: Bool = false)")
        self.assertIn("if !silent {", pager)
        self.assertIn("earlierLoads += 1", pager)


if __name__ == "__main__":
    unittest.main()
