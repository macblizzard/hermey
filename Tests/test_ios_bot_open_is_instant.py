"""Opening a bot from the phone's list is instant, and a tap storm is nothing.

Reported 2026-11-25: "the app sort of gets stuck sometimes when i click on a bot from the bot list
page. it stays stuck for 15-20 seconds sometimes and then that bot chat loads, and if i keep trying
to tap then it sort of crashed and i have to force close the app and open it again".

What the open path actually did, in order:

  1. the row started one `onGraphite` per tap, and every one of them appended the bot to the
     navigation stack — a tap storm during the push animation pushed a screen per tap;
  2. every pushed screen ran its own `openConversation`, and each of those entered
     `endlessSession(select: true)` on the *one shared* `AppModel`: capture, reset, select, resume.
     Two of them interleave at every `await`, each reset bumps `botEpoch` and makes the other's
     resume answer get dropped, and the pane is left saying "Opening…";
  3. the tap's resume queues on the host behind the launch sweep, which is walking the whole roster
     one `session.resume` at a time — and the client's own timer for that call is **120 s**, so a
     wait of 15-20 s had no end in sight and nothing to press;
  4. on the main actor, painting a transcript joined the sent-attachment vault (a JSON read plus the
     bytes of every picture the chat sent), and every user row re-read the bytes of every picture it
     referenced **in its body** — a new read on every body pass, including the 25 a second a
     streaming turn causes.

What must stay true:
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
LIST = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
APP = (ROOT / "Apps" / "HermesMobile" / "HermesMobileApp.swift").read_text(encoding="utf-8")
SCREEN = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
ROW = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text(encoding="utf-8")
VAULT = (ROOT / "Sources" / "HermesKit" / "SentAttachment.swift").read_text(encoding="utf-8")
LOG = (ROOT / "Sources" / "HermesKit" / "ClientLog.swift").read_text(encoding="utf-8")


def member(text: str, signature: str) -> str:
    """One 4-space-indented Swift member, from its signature to its closing brace."""
    start = text.index(signature)
    return text[start:][: text[start:].index("\n    }") + 1]


def between(text: str, start: str, end: str) -> str:
    """The slice between two markers, asserting both are there."""
    head = text.index(start)
    return text[head:text.index(end, head)]


#: Every member the open path runs through, in the order it runs them.
OPEN_PATH = {
    "beginOpen": "public func beginOpen(_ botID: String) -> Bool {",
    "openNow": "public func openNow(_ botID: String) async -> SessionID? {",
    "endOpen": "public func endOpen(_ botID: String) {",
    "restoreConversation": "public func restoreConversation(for botID: String) -> Bool {",
    "endlessSession": "public func endlessSession(for botID: String, select: Bool = true) async -> SessionID? {",
    "openStoredConversation": "func openStoredConversation(_ stored: SessionID, botID: String,",
    "paintCachedConversation": "private func paintCachedConversation(_ id: SessionID, botID: String? = nil) async -> Bool {",
}

BLOCKING = ("queue.sync", ".sync {", "DispatchQueue.main.sync", "semaphore", "Semaphore",
            "Thread.sleep", ".wait(timeout", "flushNow()", "ClientLog.shared.snapshot()")


class TheOpenPathBlocksNothing(unittest.TestCase):
    """A frozen screen is a synchronous wait, and there is exactly one of those in the app: none."""

    def test_no_blocking_wait_on_the_open_path(self) -> None:
        for name, signature in OPEN_PATH.items():
            body = member(MODEL, signature)
            for forbidden in BLOCKING:
                self.assertNotIn(forbidden, body,
                                 f"{name} blocks the main actor on {forbidden!r}")

    def test_the_log_on_that_path_never_waits_for_its_queue(self) -> None:
        # `ClientLog.note` -> `record` -> `queue.async`. `snapshot()`, `text()`, `isEmpty`, `clear()`
        # and `flushNow()` are the `queue.sync` half, and none of them may be reached from an open.
        record = LOG.split("public func record(", 1)[1].split("/// The entries, oldest first.", 1)[0]
        self.assertIn("queue.async {", record)
        self.assertNotIn("queue.sync", record)
        for signature in OPEN_PATH.values():
            body = member(MODEL, signature)
            for sync_door in ("snapshot()", ".text()", "flushNow()", "ClientLog.shared.isEmpty"):
                self.assertNotIn(sync_door, body, f"{signature} reaches a queue.sync door")

    def test_the_host_call_is_honoured_with_a_deadline_and_a_retry(self) -> None:
        # `session.resume` is answered on a 120 s client timer. The pane stops waiting `openDeadline`
        # later, says so, and offers the tap — it does not wait the transport out.
        self.assertIn("public static let openDeadline: TimeInterval = 12", MODEL)
        body = member(MODEL, OPEN_PATH["openNow"])
        self.assertIn("Task.sleep(for: .seconds(Self.openDeadline))", body)
        self.assertIn("openFailure = OpenFailure(botID: botID", body)
        self.assertIn('message: "the host has not answered in "', body)
        self.assertIn("public func retryOpen(_ botID: String) async -> SessionID?", MODEL)
        # And the screen renders it next to a Retry, not behind a toast nobody reads.
        self.assertIn("model.openFailure, failure.botID == bot.id", SCREEN)
        self.assertIn("private func openFailureBar(", SCREEN)
        self.assertIn('TextButton("Retry", tone: Tokens.accentText)', SCREEN)


class OneOpenAtATime(unittest.TestCase):
    """The tap storm. One open per bot, one screen per open, and a second tap is nothing."""

    def test_the_row_cannot_be_entered_twice_for_the_same_bot(self) -> None:
        begin = member(MODEL, OPEN_PATH["beginOpen"])
        self.assertIn("guard openingBotID != botID else { return false }", begin)
        self.assertIn("openTask?.cancel()", begin,
                      "a tap on a different row cancels the open in flight")

    def test_select_bot_refuses_a_second_entry_while_that_bot_is_opening(self) -> None:
        body = member(MODEL, "public func selectBot(_ id: String?) async {")
        guard = "if let resolved, resolved == openingBotID { return }"
        self.assertIn(guard, body)
        # It has to be before the capture/reset block, or the half-restored pane is filed as a
        # snapshot and the same conversation is resumed a second time.
        self.assertLess(body.index(guard), body.index("captureConversation(for: selectedBotID)"))

    def test_a_second_caller_joins_the_open_in_flight(self) -> None:
        body = member(MODEL, OPEN_PATH["openNow"])
        self.assertIn("else if let inFlight = openTask {", body)
        self.assertIn("return await inFlight.value", body,
                      "one open, shared — not two competing ones")

    def test_the_row_paints_and_pushes_through_the_one_gate(self) -> None:
        body = member(LIST, "private func openBot(_ bot: Bot) {")
        self.assertIn("guard model.beginOpen(bot.id) else { return }", body)
        self.assertLess(body.index("model.beginOpen(bot.id)"), body.index("onGraphite(bot)"),
                        "the cached paint has to happen before the screen is pushed")
        # And the row, the bell's waiting list and the banner all go through it.
        row = member(LIST, "private func row(for bot: Bot) -> some View {")
        self.assertIn("openBot(bot)", row)
        self.assertNotIn("onGraphite(bot)", row, "a row must not push on its own")
        self.assertIn("openBot(bot)", LIST.split("onOpen: { botID in", 1)[1].split("},", 1)[0])
        self.assertIn("_ = model.beginOpen(bot.id)", APP)

    def test_one_screen_per_open(self) -> None:
        body = member(APP, "private func openOnTheStack(_ bot: Bot) {")
        self.assertIn("if path.count > 0 { path.removeLast() }", body,
                      "a tap during the push animation must not stack a second screen")
        self.assertEqual(body.count("path.append(bot)"), 1)
        self.assertNotIn("onGraphite: { path.append($0) }", APP,
                         "the tab must push through the one-open helper")

    def test_the_row_shows_that_its_tap_landed(self) -> None:
        row = member(LIST, "private func row(for bot: Bot) -> some View {")
        self.assertIn("let opening = model.openingBotID == bot.id", row)
        self.assertIn('Text(opening ? "Opening…" : ', row)
        self.assertIn(".opacity(opening ? 0.6 : 1)", row)


class TheCachePaintsBeforeAnythingIsAwaited(unittest.TestCase):
    """A conversation this device already holds never shows an empty pane, not even for a frame."""

    def test_begin_open_is_synchronous_and_restores_last(self) -> None:
        self.assertNotIn("async", OPEN_PATH["beginOpen"],
                         "the paint may not be behind an await")
        body = member(MODEL, OPEN_PATH["beginOpen"])
        self.assertNotIn("await ", body)
        self.assertIn("restoreConversation(for: botID)", body)
        self.assertLess(body.index("captureConversation(for: selectedBotID)"),
                        body.index("resetForBotSwitch()"))
        self.assertLess(body.index("resetForBotSwitch()"),
                        body.index("restoreConversation(for: botID)"))

    def test_the_screen_no_longer_does_the_switch_itself(self) -> None:
        body = member(SCREEN, "private func openConversation() async {")
        self.assertIn("await model.openNow(bot.id)", body)
        self.assertNotIn("endlessSession(", body,
                         "the switch belongs to the tap, not to a view's .task")


class TheScreenCancelsItsOwnOpen(unittest.TestCase):
    def test_the_task_is_keyed_and_the_screen_ends_the_open_it_began(self) -> None:
        self.assertIn(".task(id: bot.id) {", SCREEN)
        task = between(SCREEN, ".task(id: bot.id) {", ".task {")
        self.assertIn("await openConversation()", task)
        disappear = between(SCREEN, ".onDisappear {", ".task(id: bot.id) {")
        self.assertIn("model.endOpen(bot.id)", disappear)
        end = member(MODEL, OPEN_PATH["endOpen"])
        self.assertIn("openTask?.cancel()", end)
        self.assertIn("guard openingBotID == botID else { return }", end,
                      "a screen that is leaving because the next one was pushed must not cancel it")

    def test_the_pushed_screen_still_asks_with_select_true(self) -> None:
        # [B2 navigation]: the screen *is* the navigation, and the door it uses is `openNow`.
        self.assertIn("await self.endlessSession(for: botID, select: true)",
                      member(MODEL, OPEN_PATH["openNow"]))


class NothingRasterisesOrReadsInABody(unittest.TestCase):
    """A body pass must not touch the disk. It happens 25 times a second while a turn streams."""

    def test_the_row_does_not_join_the_vault_in_its_body(self) -> None:
        body = member(ROW, "private var bubbleAttachments: [SentAttachment] {")
        self.assertNotIn("referenceAttachments", body,
                         "the reference join reads picture bytes; it cannot run in a body")
        self.assertIn("resolvedAttachments", body)
        resolver = member(ROW, "private func resolveReferencedAttachments() async {")
        self.assertIn("Task.detached", resolver)
        self.assertIn(".task(id: entry.id) { await resolveReferencedAttachments() }", ROW)

    def test_the_vault_memoises_its_reads_and_can_run_off_main(self) -> None:
        self.assertIn("public static func decorated(_ entries: [TranscriptEntry],", VAULT)
        self.assertIn("Task.detached(priority: .userInitiated)", VAULT)
        self.assertIn("private static var recordCache: [String: [Record]] = [:]", VAULT)
        self.assertIn("private static var imageCache: [String: Data] = [:]", VAULT)
        self.assertIn("private static let cacheLimit = 24", VAULT,
                      "an unbounded cache of picture bytes is a leak with extra steps")

    def test_the_open_path_uses_the_off_main_join(self) -> None:
        self.assertIn("await SentAttachmentVault.decorated(cached.messages, sessionID: id)",
                      member(MODEL, OPEN_PATH["paintCachedConversation"]))
        warm = member(MODEL, "private func warmConversation(_ botID: String, session: SessionID,")
        self.assertIn("await SentAttachmentVault.decorated(entries, sessionID: session)", warm)

    def test_no_avatar_is_rasterised_on_the_open_path(self) -> None:
        # `ImageRenderer` is main-actor work and belongs to the banner cache at launch, never to a
        # row or a body (see `BotAvatarIcon.png`, `MobileFaceCache.refresh`).
        row = member(LIST, "private func row(for bot: Bot) -> some View {")
        for forbidden in ("ImageRenderer", "BotAvatarIcon.png", "PushIcon.png", "MobileFaceCache"):
            self.assertNotIn(forbidden, row)
            self.assertNotIn(forbidden, member(SCREEN, "private func openConversation() async {"))


class TheSweepYieldsToThePerson(unittest.TestCase):
    def test_a_user_open_outranks_the_launch_sweep(self) -> None:
        prefetch = MODEL.split("public func prefetchConversations() async {", 1)[1]
        prefetch = prefetch.split("    /// The conversation the host says this bot has right now", 1)[0]
        self.assertIn("guard openingBotID == nil else { return }", prefetch,
                      "never start the sweep behind an open")
        self.assertIn("let sweepUnder = userOpenGeneration", prefetch)
        loop = prefetch.split("for bot in bots", 1)[1].split("// One line for the whole sweep", 1)[0]
        self.assertIn("if openingBotID != nil || sweepUnder != userOpenGeneration { break }", loop,
                      "a tap has to end the walk, not queue behind it")
        self.assertIn("catch is CancellationError {", prefetch)
        # And the bump itself lives in the gate the tap goes through.
        self.assertIn("userOpenGeneration &+= 1", member(MODEL, OPEN_PATH["beginOpen"]))


if __name__ == "__main__":
    unittest.main()
