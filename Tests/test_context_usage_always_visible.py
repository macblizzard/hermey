"""The context count is on screen at all times, from the last number the app actually knows.

Asked 2026-11-25: "could you make the token usage visible all the time on both mac and iphone
instead of only after each turn?"

What was wrong: `contextUsed`/`contextMax` had exactly one source — the `usage` block on a
`message.complete` frame, emitted by the host when a turn finishes. Nothing the app calls when it
*opens* a bot carries it (`session.resume` decodes rows, an inflight turn, open requests, a cursor
and a total; a `session.list` row carries a title, a preview and a message count; the providers'
`usage` field is credential usage, not context), so a fresh launch — and every first open of a bot —
drew the model alone until somebody sent a message. `ConversationSnapshot` already carried the pair
per bot, which made a *return* visit inside one process work and a relaunch not.

What this holds, and why each rule is a rule:

* **Per bot, on disk.** The last reported pair is stored per bot in the `UserDefaults` this app
  already keeps its per-bot facts in (`botActivity`, the unread stamps, the endless session id).
  Another bot's number under this bot's name is worse than no number.
* **Restored before the first host call.** Both open paths (`beginOpen` on the phone,
  `endlessSession` on both) go through `restoreConversation`, which is synchronous. An `await`
  before the paint is the bug being fixed: the row must read `394k/1M Tokens` on the first frame.
* **The session travels with the number.** A count measured on a conversation the bot no longer owns
  describes a different chat. The record carries its session id, a mismatch is never painted, and
  when the app *learns* that the conversation changed (the id on screen moved to a concrete other
  one, a reset, a compaction) the stored copy is deleted so the next launch cannot resurrect it. A
  glance at another session of the same bot is not a change of ownership: the bot's record survives
  it untouched.
* **Nothing is invented.** The only writer is the host's own `usage`. A transcript's length measures
  how much was said, not how much of the window it filled, and no number is ever derived from it.
* **Both apps, one model.** The Mac and the phone read `AppModel`; the views are untouched.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")

MAC_BAR = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerBar.swift").read_text(encoding="utf-8")
PHONE_SCREEN = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
MAC_STORE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
PHONE_APP = (ROOT / "Apps" / "HermesMobile" / "HermesMobileApp.swift").read_text(encoding="utf-8")
ROW = (ROOT / "Sources" / "HermeyUI" / "ComposerSessionRow.swift").read_text(encoding="utf-8")
DECODER = (ROOT / "Sources" / "HermesKit" / "GatewayEventDecoder.swift").read_text(encoding="utf-8")
CLIENT = (ROOT / "Sources" / "HermesKit" / "GatewayClient.swift").read_text(encoding="utf-8")


def member(text: str, signature: str) -> str:
    """One 4-space-indented Swift member, from its signature to its closing brace."""
    start = text.index(signature)
    body = text[start:]
    return body[: body.index("\n    }\n") + len("\n    }\n")]


def code(text: str) -> str:
    """The source with its `//` comments stripped: a guard about code must not read prose."""
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


#: Every member the open path runs, in the order the phone and the Mac run them.
RESTORE_PATH = {
    "beginOpen": "public func beginOpen(_ botID: String) -> Bool {",
    "endlessSession": "public func endlessSession(for botID: String, select: Bool = true) async -> SessionID? {",
    "restoreConversation": "public func restoreConversation(for botID: String) -> Bool {",
}

#: The only values `contextUsed`/`contextMax` may be given, and where each one comes from: the
#: host's own `usage` on the turn that just finished, the snapshot captured with its session, or the
#: record this device stored from a host answer. Nothing else may reach the pair.
ALLOWED_VALUES = {
    "used",                                   # the host's `context_used`
    "max",                                    # the host's `context_max`
    "snapshot.contextUsed",                   # a snapshot's copy of the host's number
    "snapshot.contextMax",
    "record.used",                            # the stored copy of the host's number
    "record.max > 0 ? record.max : nil",      # a stored `context_max`, 0 meaning "not given"
}


class TheNumberIsKeptPerBot(unittest.TestCase):
    """A record per bot, holding the pair and the conversation it was measured on."""

    def test_the_record_carries_the_session_it_belongs_to(self) -> None:
        record = member(MODEL, "private struct ContextUsageRecord: Codable, Equatable {")
        for field in ("var session: SessionID", "var used: Int", "var max: Int"):
            self.assertIn(field, record,
                          f"a number without {field!r} can describe the wrong chat")

    def test_it_is_a_map_keyed_by_bot(self) -> None:
        self.assertIn("private var contextUsageRecords: [String: ContextUsageRecord] = [:]", MODEL,
                      "one bot's count must never be shown under another bot's name")

    def test_the_one_writer_files_it_under_the_bot_on_screen(self) -> None:
        claim = member(MODEL, "private func claimContextUsage(used: Int, max: Int, session: SessionID, botID: String?) {")
        self.assertIn("contextUsageRecords[botID] = ContextUsageRecord(", code(claim))
        self.assertIn("saveContextUsage()", claim, "a claim nobody stored is invisible after a relaunch")

    def test_the_host_usage_event_is_the_only_writer(self) -> None:
        case = MODEL.split("case .contextUsage(let session, let used, let max, _):", 1)[1]
        case = case.split("case .toolStart", 1)[0]
        self.assertIn("claimContextUsage(used: used, max: max, session: session, botID: selectedBotID)",
                      case,
                      "the pair, its session and the stored copy must move together")

    def test_it_lives_in_the_defaults_the_app_already_owns(self) -> None:
        load = member(MODEL, "private func loadContextUsage() {")
        save = member(MODEL, "private func saveContextUsage() {")
        self.assertIn("Self.defaults.data(forKey: contextUsageKey)", load)
        self.assertIn("Self.defaults.set(data, forKey: contextUsageKey)", save)
        self.assertIn('private var contextUsageKey: String { "hermes.contextUsage.\\(hostName)" }', MODEL,
                      "two paired hosts must not share one bot's numbers")
        self.assertIn("loadContextUsage()", member(MODEL, "public init(client: GatewayClientProtocol,"),
                      "a record nobody reads on launch is a file, not a feature")


class TheRestoreComesFirst(unittest.TestCase):
    """On screen before the host is asked, and never with a second formatter."""

    def test_the_open_paths_restore_synchronously(self) -> None:
        for name in ("beginOpen", "restoreConversation"):
            body = member(MODEL, RESTORE_PATH[name])
            self.assertNotIn("await ", code(body), f"{name} must not wait for anything")
        for name in ("beginOpen", "endlessSession"):
            body = member(MODEL, RESTORE_PATH[name])
            self.assertIn("restoreConversation(for: botID)", code(body),
                          f"{name} is an open, and the paint belongs to it")

    def test_the_open_restores_before_its_first_await(self) -> None:
        switch = member(MODEL, RESTORE_PATH["endlessSession"])
        switch = switch.split("guard select else { return await conversationID(for: botID) }", 1)[1]
        self.assertLess(switch.index("restoreConversation(for: botID)"), switch.index("await "),
                        "an await before the paint is the empty row this exists to remove")

    def test_the_restore_paints_before_it_looks_for_a_transcript(self) -> None:
        body = code(member(MODEL, RESTORE_PATH["restoreConversation"]))
        self.assertIn("restoreContextUsage(for: botID, session:", body)
        self.assertLess(body.index("restoreContextUsage"),
                        body.index("guard let snapshot = conversationCache[botID]"),
                        "a cold launch has no snapshot at all, and that is the case that was broken")

    def test_a_launch_that_has_never_heard_usage_draws_nothing(self) -> None:
        body = member(MODEL, "private func restoreContextUsage(for botID: String?, session: SessionID?) -> Bool {")
        self.assertIn("guard let botID, let record = contextUsageRecords[botID] else { return false }", body,
                      "no record must mean the model alone, exactly as before")

    def test_the_one_formatter_is_still_the_composer_rows(self) -> None:
        self.assertIn("SessionLine.context(used: used, limit: limit)", ROW)
        self.assertNotIn("Tokens", code(MODEL),
                         "the model formats the number nowhere: `SessionLine`/`TokenCount` are the only ones")
        self.assertNotIn("TokenCount", code(MODEL), "a second formatter is a second answer")


class TheSessionTravelsWithTheNumber(unittest.TestCase):
    """A restored number may not describe a conversation it was not measured on."""

    def test_a_different_session_drops_the_pair(self) -> None:
        observer = MODEL.split("@Published public var selectedSessionID: SessionID? {", 1)[1]
        observer = observer.split("\n    }\n", 1)[0]
        self.assertIn("guard let shown = contextUsageSession", observer)
        self.assertIn("now != shown", observer)
        self.assertIn("contextUsed = nil", observer)
        self.assertIn("forgetContextUsage(for: selectedBotID, keeping: now)", observer,
                      "dropping it on screen only lets the next launch resurrect it")

    def test_a_restore_refuses_a_record_measured_elsewhere(self) -> None:
        body = member(MODEL, "private func restoreContextUsage(for botID: String?, session: SessionID?) -> Bool {")
        self.assertIn("if let known = session ?? selectedSessionID, known != record.session", body)
        refusal = body.split("known != record.session", 1)[1].split("contextUsed = record.used", 1)[0]
        self.assertIn("return false", refusal, "the refusal has to happen before anything is painted")
        self.assertNotIn("removeValue", refusal,
                         "a glance at another conversation of the same bot must not delete its number")

    def test_a_pick_does_not_destroy_the_bot_record(self) -> None:
        pick = member(MODEL, "public func select(_ id: SessionID) async {")
        self.assertLess(pick.index("clearContextUsage()"), pick.index("selectedSessionID = id"),
                        "the claim has to be dropped before the id moves, or the pick deletes the "
                        "record of the conversation it will return to")

    def test_the_resolved_conversation_checks_the_stored_number(self) -> None:
        open = member(MODEL, "private func adoptStoredConversation(_ stored: SessionID, botID: String,")
        self.assertIn("restoreContextUsage(for: botID, session: stored)", open,
                      "the host names the conversation on open, and that is when a stored number is "
                      "either put back or left alone")

    def test_a_mismatch_deletes_the_stored_copy(self) -> None:
        forget = member(MODEL, "private func forgetContextUsage(for botID: String?, keeping session: SessionID) {")
        self.assertIn("record.session != session", forget)
        self.assertIn("contextUsageRecords.removeValue(forKey: botID)", forget)
        self.assertIn("saveContextUsage()", forget)

    def test_a_reset_or_a_compaction_forgets_it_outright(self) -> None:
        reset = member(MODEL, "public func resetEndlessSession(")
        self.assertIn("forgetContextUsage(for: botID)", reset,
                      "a deleted conversation must not come back as a number")
        compact = MODEL.split("await refreshTranscript(sid)", 1)[1]
        compact = compact.split("compactionNotice = \"conversation compacted\"", 1)[0]
        self.assertIn("forgetContextUsage(for: selectedBotID)", compact,
                      "a pre-compaction size is not the size of this chat")

    def test_a_bot_switch_claims_nothing_on_the_way_out(self) -> None:
        reset = member(MODEL, "private func resetForBotSwitch() {")
        self.assertIn("clearContextUsage()", reset)


class NothingIsInvented(unittest.TestCase):
    """Every number on screen comes from the host, or from what the host said last time."""

    def test_no_number_is_derived_from_the_transcript(self) -> None:
        # Every non-nil assignment, with its right-hand side. The allowed ones are the host's own
        # numbers (`used`, `max`), the snapshot's (captured with its session) and the stored record's.
        written = [(m.group(1), m.group(2).strip().rstrip("}").strip())
                   for m in re.finditer(r"context(Used|Max)\s*=\s*(.+)", code(MODEL))]
        written = [(field, value) for field, value in written if value != "nil"]
        self.assertGreaterEqual(len(written), 5, "the pair has to be assigned somewhere")
        for field, value in written:
            self.assertIn(value, ALLOWED_VALUES,
                          f"`context{field} = {value}` is neither the host's answer nor a stored one")
            self.assertNotIn("transcript", value, f"`context{field}` measures how much was said")
            self.assertNotIn("count", value, f"`context{field}` counts rows, not tokens")

    def test_the_host_report_is_the_only_shape_it_understands(self) -> None:
        self.assertIn('guard let usage = payload["usage"]?.objectValue', DECODER)
        self.assertIn('let used = usage["context_used"]?.intValue', DECODER,
                      "`context_used` on `message.complete` is the only source")
        self.assertIn("case .contextUsage(let session, let used, let max, _):", MODEL)

    def test_nothing_on_open_reports_it_so_the_stored_number_stands(self) -> None:
        # The report is honest about this: `session.resume` carries no usage, so a resumed
        # conversation keeps the number it was last measured at until the next turn corrects it.
        resume = CLIENT.split("public struct SessionResume: Sendable {", 1)[1]
        resume = resume.split("public init(id: SessionID", 1)[0]
        for field in ("public let id: SessionID", "public let entries: [TranscriptEntry]",
                      "public let inflight: InflightTurn?", "public let openRequests: [ServerRequest]",
                      "public let earlierCursor: Int?", "public let historyTotal: Int"):
            self.assertIn(field, resume)
        self.assertNotIn("usage", resume.lower(),
                         "if `session.resume` ever carries usage, restore from it instead of the disk")
        summary = CLIENT.split("public struct SessionSummary: Identifiable, Hashable, Sendable {", 1)[1]
        summary = summary.split("public init(id: SessionID", 1)[0]
        self.assertNotIn("usage", summary.lower(),
                         "a `session.list` row carries no context usage on this host")

    def test_a_resume_does_not_wipe_the_restored_number(self) -> None:
        for signature in ("private func adoptResume(",
                          "private func paintCachedConversation(",
                          "private func adoptStoredConversation("):
            body = member(MODEL, signature)
            self.assertNotIn("contextUsed = nil", body,
                             f"{signature} clears a number that no open call can replace")


class BothAppsGetItFromTheModel(unittest.TestCase):
    """One change in `AppModel`, nothing in a view."""

    def test_both_composers_still_read_the_model(self) -> None:
        for source, name in ((MAC_BAR, "the Mac's composer bar"), (PHONE_SCREEN, "the phone's screen")):
            self.assertIn("used: model.contextUsed", source, name)
            self.assertIn("limit: model.contextMax", source, name)
            self.assertIn("ComposerSessionRow(", source, name)

    def test_no_view_writes_the_pair(self) -> None:
        for source, name in ((MAC_BAR, "the Mac's composer bar"),
                             (PHONE_SCREEN, "the phone's screen"),
                             (MAC_STORE, "the Mac's workspace"),
                             (PHONE_APP, "the phone's app")):
            self.assertNotIn("contextUsed =", source, f"{name} must not own the number")
            self.assertNotIn("contextMax =", source, f"{name} must not own the number")

    def test_both_apps_open_through_the_model(self) -> None:
        self.assertIn("await self.openConversation(for: id)", MAC_STORE)
        self.assertIn("_ = await model.endlessSession(for: botID, select: true)", MAC_STORE,
                      "the Mac's open is the model's open")
        self.assertIn("_ = model.beginOpen(bot.id)", PHONE_APP,
                      "the phone's open is the model's open")


if __name__ == "__main__":
    unittest.main()
