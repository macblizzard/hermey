"""Edit-and-resend and delete-message, pinned across the two languages that implement them.

The engine has no message-level edit or delete, so the two verbs are a host route plus two menus:
`hermeyd` retires rows (never removes them) and each app draws the verb. Neither side can be checked
by the other's compiler, and there is no Swift compiler on this box — `swift build` on CI is the only
one — so this file reads all four sources as text and pins the facts that a tidy-up can quietly undo:

* both routes exist, are device-authenticated, and are **not** in the loopback-only group;
* both refuse a running turn (409) and close the engine's live copy **before** a row moves;
* the only write either route makes is `active=0, compacted=0` — there is no `DELETE FROM`, ever;
* the app re-resumes after a retire, and a failed truncate leaves the composer holding the text;
* both platforms carry the two rows with their glyphs, and neither offers Delete while a turn is
  answering;
* the confirmation's count is computed from the transcript, not guessed;
* the two languages spell the route the same way, and the host's version moved because its code did.

The behaviour behind those facts is exercised where it runs: `hermeyd/src/messages.rs` has the Rust
tests (a fake engine that asserts the rows are untouched when it is asked to close), and the Swift
suites cover `PendingMessageAction`'s wording.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

MAIN = (ROOT / "hermeyd" / "src" / "main.rs").read_text(encoding="utf-8")
ROUTE = (ROOT / "hermeyd" / "src" / "messages.rs").read_text(encoding="utf-8")
CARGO = (ROOT / "hermeyd" / "Cargo.toml").read_text(encoding="utf-8")
DOCS = (ROOT / "docs" / "HERMEYD.md").read_text(encoding="utf-8")

MENU = (ROOT / "Sources" / "HermeyUI" / "MessageMenuRow.swift").read_text(encoding="utf-8")
WIRE = (ROOT / "Sources" / "HermesKit" / "MessageRetire.swift").read_text(encoding="utf-8")
POINTER = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text(encoding="utf-8")
GATEWAY = (ROOT / "Sources" / "HermesKit" / "GatewayClient.swift").read_text(encoding="utf-8")
ACTOR = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")

MAC_ROW = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift").read_text(encoding="utf-8")
MAC_SCROLL = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptScroll.swift").read_text(encoding="utf-8")
MAC_PANE = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationPane.swift").read_text(encoding="utf-8")
MAC_MENU = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MessageContextMenu.swift").read_text(encoding="utf-8")

IOS_ROW = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text(encoding="utf-8")
IOS_SCREEN = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
IOS_BUBBLE = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileMarkdown.swift").read_text(encoding="utf-8")


def block(source: str, start: str, end: str) -> str:
    """The text between two markers, or "" when either is missing."""
    first = source.find(start)
    if first < 0:
        return ""
    second = source.find(end, first)
    return source[first:] if second < 0 else source[first:second]


def body_of(source: str, signature: str) -> str:
    """A function's body, from its signature to the next line that is exactly `}` at column 0."""
    start = source.find(signature)
    if start < 0:
        return ""
    end = source.find("\n}\n", start)
    return source[start:] if end < 0 else source[start:end]


class TheRoutes(unittest.TestCase):
    def test_both_routes_are_mounted(self) -> None:
        self.assertTrue('.route("/v1/messages/delete", post(messages::post_delete))' in MAIN,
                        "the delete route is not mounted")
        self.assertTrue('.route("/v1/messages/truncate", post(messages::post_truncate))' in MAIN,
                        "the truncate route is not mounted")
        self.assertTrue("mod messages;" in MAIN, "the module must be part of the binary")

    def test_both_routes_are_device_authenticated(self) -> None:
        # `require_device` is the one credential check the apps' routes use (a 30s single-use ticket
        # or a paired device's access token). A handler without it is open to any local process.
        for handler in ("post_delete", "post_truncate"):
            body = body_of(ROUTE, f"pub async fn {handler}(")
            self.assertTrue(body, handler)
            self.assertIn("require_device(&st, &headers)?", body, handler)

    def test_neither_route_is_loopback_only(self) -> None:
        # The bot-to-bot routes are loopback-only because they carry no device credential. These two
        # are the apps' and must never take that path: `require_loopback` would refuse the phone.
        self.assertNotIn("require_loopback", ROUTE)
        self.assertNotIn("ConnectInfo", ROUTE)

    def test_the_route_never_takes_a_path(self) -> None:
        # Ids only. A `Path` extractor, a filename or a directory in the body would put a caller's
        # string in front of the filesystem, which is the one thing this route must not allow.
        self.assertNotIn("Path<", ROUTE)
        self.assertNotIn("axum::extract::Path", ROUTE)
        self.assertIn("\"bot\"", ROUTE)
        self.assertIn("\"session\"", ROUTE)
        self.assertIn("\"message_ids\"", ROUTE)
        self.assertIn("\"from_message_id\"", ROUTE)
        # …and the only filesystem path is built from the validated bot name.
        self.assertIn('st.engine_home.join("profiles").join(bot).join("state.db")', ROUTE)


class TheEngineIsAskedFirst(unittest.TestCase):
    def test_a_running_turn_is_a_409(self) -> None:
        self.assertIn("StatusCode::CONFLICT", ROUTE)
        self.assertIn('"turn_running"', ROUTE)
        # The decision comes from the engine's own live registry, not from a guess about the rows.
        self.assertIn('"session.active_list"', ROUTE)
        # Any status that is not `idle` is a turn — including `waiting` (parked on an approval) and
        # `starting`, which are just as much a turn owning the history it will flush.
        self.assertIn('if status == "idle" && !id.is_empty()', ROUTE)
        self.assertIn("Live::Busy", ROUTE)

    def test_an_engine_that_does_not_answer_refuses_rather_than_guesses(self) -> None:
        self.assertIn('"engine_unavailable"', ROUTE)
        self.assertIn("StatusCode::SERVICE_UNAVAILABLE", ROUTE)
        self.assertIn('"engine_refused"', ROUTE)
        # Both refusals say so in words, because the app shows them verbatim.
        self.assertIn("Nothing was changed.", ROUTE)

    def test_the_close_comes_before_any_row_is_touched(self) -> None:
        run = body_of(ROUTE, "async fn run(")
        self.assertTrue(run, "run() is the shared body of both routes")
        prepare_at = run.find("prepare(")
        retire_at = run.find("retire(")
        db_at = run.find("db_path(")
        self.assertGreaterEqual(prepare_at, 0, "the engine must be asked")
        self.assertGreaterEqual(retire_at, 0)
        self.assertLess(prepare_at, retire_at,
                        "the engine is asked before the rows are retired")
        self.assertLess(prepare_at, db_at,
                        "the database is not even opened until the engine has cleared the way")

    def test_the_close_takes_the_runtime_id_the_registry_named(self) -> None:
        # The stored id and the runtime id are two namespaces that look alike; `session.close` takes
        # the runtime one, and it is read from the same live row rather than assumed to be equal.
        self.assertIn('"session.close"', ROUTE)
        self.assertIn('json!({ "session_id": runtime_id })', ROUTE)
        self.assertIn("Ok(Live::Idle(runtime_id)) => engine.close(&runtime_id)", ROUTE)


class RowsAreRetiredNeverRemoved(unittest.TestCase):
    def test_the_only_write_is_active_and_compacted(self) -> None:
        for statement in re.findall(r"UPDATE messages[^\"]*", ROUTE):
            self.assertTrue("active = 0, compacted = 0" in statement,
                            f"a write other than the retire reached messages: {statement[:120]}")
        self.assertTrue("UPDATE messages SET active = 0, compacted = 0" in ROUTE,
                        "the retire statement is gone")

    def test_no_row_is_ever_deleted(self) -> None:
        # The whole promise of the feature: a mis-tap costs a repaint, not a conversation.
        self.assertIsNone(re.search(r"\bDELETE\s+FROM\b", ROUTE, re.IGNORECASE),
                          "a hard delete reached the message route")
        self.assertIsNone(re.search(r"\bDROP\s+TABLE\b|\bTRUNCATE\s+TABLE\b", ROUTE, re.IGNORECASE))

    def test_the_retire_is_one_transaction(self) -> None:
        retire = body_of(ROUTE, "fn retire(")
        self.assertIn("conn.transaction()", retire)
        self.assertIn("tx.commit()", retire)
        # A miss rolls back instead of leaving a half-applied answer: the early return drops `tx`.
        self.assertIn("if visible == 0", retire)

    def test_the_database_is_never_created_by_this_route(self) -> None:
        # A route that mints an empty `state.db` would hand the engine a second, empty history.
        self.assertIn("SQLITE_OPEN_READ_WRITE)", ROUTE)
        self.assertNotIn("SQLITE_OPEN_CREATE", ROUTE)
        self.assertIn("if !path.is_file()", ROUTE)

    def test_the_scope_is_the_conversation_and_its_compression_chain(self) -> None:
        # A truncate must not reach another conversation's rows, and a compressed chat's transcript
        # spans a chain of sessions — the chain is walked, a `/branch` copy is not.
        self.assertIn("WITH RECURSIVE", ROUTE)
        self.assertIn("s.parent_session_id", ROUTE)
        self.assertIn("end_reason = 'compression'", ROUTE)
        self.assertIn("session_id IN ({scope})", ROUTE)

    def test_truncate_orders_by_the_slot_the_transcript_orders_by(self) -> None:
        self.assertIn("COALESCE(display_order, id)", ROUTE)
        self.assertIn("COALESCE(display_order, id) >= ?", ROUTE)

    def test_the_answer_carries_the_display_count(self) -> None:
        self.assertIn('"retired": retired.retired', ROUTE)
        self.assertIn('"display_count": retired.display_count', ROUTE)
        # The count a resume reports as `history.total`, from the same definition.
        self.assertIn("AND (active = 1 OR compacted = 1)", ROUTE)


class TheAppConverges(unittest.TestCase):
    def test_the_client_spells_the_routes_the_host_mounted(self) -> None:
        for path in ("v1/messages/delete", "v1/messages/truncate"):
            self.assertIn(f'"{path}"', POINTER, path)
            self.assertIn(f"/{path}", MAIN.replace('"/v1/messages/delete"', f'"/{path}"'), path)

    def test_the_client_sends_ids_and_never_a_path(self) -> None:
        self.assertIn('"message_ids": messageIDs', POINTER)
        self.assertIn('"from_message_id": fromMessageID', POINTER)
        self.assertNotIn("path:", block(POINTER, "public func deleteMessages(", "func truncateMessages("))

    def test_both_verbs_are_protocol_requirements_so_the_real_implementation_runs(self) -> None:
        # A requirement that exists only in an extension is chosen statically; a call through
        # `any GatewayClientProtocol` would then report "this host cannot" while the actor could.
        for name in ("func deleteMessages(bot: String, session: SessionID, messageIDs: [Int64])",
                     "func truncateMessages(bot: String, session: SessionID, fromMessageID: Int64)"):
            self.assertIn(name, GATEWAY)
            self.assertIn(name, POINTER)
        self.assertIn("sessionPointer.deleteMessages(", ACTOR)
        self.assertIn("sessionPointer.truncateMessages(", ACTOR)

    def test_the_app_re_resumes_after_a_retire(self) -> None:
        self.assertIn("public func reloadAfterRetire() async -> Bool", MODEL)
        self.assertIn("return await refreshTranscript(sid)", MODEL)
        # Delete: the host moved the rows, so the open transcript is rebuilt from what is left.
        delete = body_of(MODEL, "public func deleteMessage(rowID: Int64) async")
        self.assertLess(delete.find("client.deleteMessages("), delete.find("reloadAfterRetire()"),
                        "the resume must follow the retire")
        # Edit-and-resend: the route closed the engine's copy, so the resume is what puts a session
        # back on the socket for the prompt that follows.
        send = body_of(MODEL, "public func send() async")
        self.assertLess(send.find("client.truncateMessages("), send.find("reloadAfterRetire()"))

    def test_a_failed_truncate_leaves_the_text_in_the_composer(self) -> None:
        send = body_of(MODEL, "public func send() async")
        truncate_at = send.find("client.truncateMessages(")
        self.assertGreaterEqual(truncate_at, 0, "sending an edit truncates first")
        # The window from the truncate to the message that starts the ordinary send: everything the
        # failure path does lives in between.
        window = send[truncate_at:send.find("let attachedNames")]
        self.assertTrue(window, "the truncate is followed by the ordinary send")
        self.assertIn("draft = text", window, "the words go back into the composer")
        self.assertIn("return", window, "and nothing is sent")
        # The draft is only cleared after the truncate succeeded: the send path's `draft = ""` must
        # come later in the function than the truncate call.
        self.assertLess(truncate_at, send.find('draft = ""'))
        self.assertIn("pendingEdit = nil", send)

    def test_the_composer_is_prefilled_from_the_message(self) -> None:
        confirm = body_of(MODEL, "public func confirmMessageAction() async")
        self.assertIn("draft = action.text", confirm)
        self.assertIn("PendingEdit(rowID: action.rowID, session: session)", confirm)


class TheMenus(unittest.TestCase):
    def test_the_two_rows_have_glyphs(self) -> None:
        self.assertIn('static func editAndResend(', MENU)
        self.assertIn('"Edit and resend", symbol: "square.and.pencil"', MENU)
        self.assertIn('static func deleteMessage(', MENU)
        self.assertIn('"Delete", symbol: "trash"', MENU)

    def test_the_mac_menu_carries_both(self) -> None:
        items = body_of(MAC_ROW, "private var menuItems: [MessageMenuItem] {")
        self.assertIn(".editAndResend {", items)
        self.assertIn(".deleteMessage {", items)
        # …and the real `NSMenu` is still the Mac's path, with `NSMenuItem.image` set from the row's
        # symbol: the glyphs are the whole reason that file exists.
        self.assertIn("nsItem.image = Self.glyph(item.symbol", MAC_MENU)

    def test_the_phone_menu_and_the_long_press_card_carry_both(self) -> None:
        self.assertIn("MessageMenuRow(.editAndResend {", IOS_ROW)
        self.assertIn("MessageMenuRow(.deleteMessage {", IOS_ROW)
        self.assertIn('actionRow("Edit and resend", systemImage: "square.and.pencil")', IOS_ROW)
        self.assertIn('actionRow("Delete", systemImage: "trash")', IOS_ROW)
        # The row is still raised by a long press.
        self.assertIn("onLongPressGesture", IOS_ROW)

    def test_edit_and_resend_is_only_offered_on_the_owners_own_words(self) -> None:
        # A message another bot sent arrives as a user row; rewriting it would be rewriting somebody
        # else's message, so the same label test that draws it with the sender's face excludes it.
        self.assertIn("let ownerTyped = entry.role == .user "
                      "&& BotMessageLabel.parse(entry.text) == nil", MAC_ROW)
        self.assertIn("if ownerTyped, !turnRunning, entry.rowID != nil", MAC_ROW)
        self.assertIn("if entry.role == .user, BotMessageLabel.parse(entry.text) == nil", IOS_ROW)

    def test_delete_is_never_offered_while_a_turn_is_answering(self) -> None:
        self.assertIn("var turnRunning: Bool = false", MAC_ROW)
        self.assertIn("var turnRunning: Bool = false", IOS_ROW)
        for row in (MAC_ROW, IOS_ROW):
            self.assertIn("if !turnRunning, entry.rowID != nil", row)
        # Both shells say which conversation is answering, from the model's own turn state.
        self.assertIn("turnRunning: model.isStreaming", MAC_SCROLL)
        self.assertIn("turnRunning: model.isStreaming", IOS_SCREEN)
        # And the message being written cannot carry the verb at all: the streaming bubble is a view
        # of its own, not a transcript row, so it builds no message menu (`MessageContextMenu` is
        # built in exactly one place — the row — and the phone's bubble has no `contextMenu`).
        self.assertEqual(MAC_ROW.count("MessageContextMenu("), 1)
        self.assertNotIn("contextMenu", block(MAC_SCROLL, "struct StreamingAssistantBubble: View {",
                                              "var body: some View {"))
        self.assertNotIn("contextMenu", body_of(IOS_BUBBLE, "struct MobileStreamingBubble: View {"))

    def test_a_row_with_no_durable_id_offers_neither(self) -> None:
        # A message still on its way has no row to address; the host only accepts ids.
        self.assertIn("entry.rowID != nil", MAC_ROW)
        self.assertIn("entry.rowID != nil", IOS_ROW)


class TheConfirmation(unittest.TestCase):
    def test_one_sentence_for_both_shells(self) -> None:
        self.assertIn("public struct PendingMessageAction", WIRE)
        self.assertIn("var message: String", WIRE)
        # Both shells draw the alert, and both take the words from the shared type.
        for shell in (MAC_PANE, IOS_SCREEN):
            self.assertIn(".alert(model.pendingMessageAction?.title ?? \"\"", shell)
            self.assertIn("Text(action.message)", shell)
            self.assertIn("await model.confirmMessageAction()", shell)
        # Both offer a way out that changes nothing.
        for shell in (MAC_PANE, IOS_SCREEN):
            self.assertIn('Button("Cancel", role: .cancel)', shell)

    def test_the_count_is_computed_from_the_transcript(self) -> None:
        self.assertIn("public func trailingMessages(after entry: TranscriptEntry) -> Int", MODEL)
        self.assertIn("transcript.firstIndex(where: { $0.id == entry.id })", MODEL)
        self.assertIn("transcript.count - index - 1", MODEL)
        self.assertIn("trailing: trailingMessages(after: entry)", MODEL)
        # …and the sentence states it, in messages, before anything is sent.
        self.assertIn('"messages") after it', WIRE.replace("\\(trailing) ", ""))

    def test_the_sentence_says_what_will_happen(self) -> None:
        self.assertIn("will be retired from this conversation on both devices", WIRE)
        self.assertIn("will be retired when you send the edited text", WIRE)
        self.assertIn("stays in the host's database", WIRE)
        self.assertIn("stay in the host's database", WIRE)

    def test_a_delete_is_drawn_as_destructive_and_an_edit_is_not(self) -> None:
        for shell in (MAC_PANE, IOS_SCREEN):
            self.assertIn('role: action.kind == .delete ? .destructive : nil', shell)


class TheHostVersion(unittest.TestCase):
    def test_hermeyd_moved_its_patch_version(self) -> None:
        # Host code changed, so `hermeyd --version` has to say so — that is how a deployed binary is
        # told apart from the one in the repo (Tools/check_hermeyd_version_bump.py enforces it in CI).
        # At least the version this feature arrived in: later releases bump past it, and pinning the
        # literal here made the guard fail on the next unrelated bump instead of on a missing one.
        found = re.search(r'^version = "(\d+)\.(\d+)\.(\d+)"', CARGO, re.M)
        self.assertIsNotNone(found, "hermeyd's Cargo.toml has no version")
        self.assertGreaterEqual(tuple(int(part) for part in found.groups()), (0, 8, 8),
                                "hermeyd must be at least 0.8.8: the message routes are host code")

    def test_the_routes_are_documented(self) -> None:
        self.assertIn("## Editing and deleting a message — `POST /v1/messages/delete`", DOCS)
        for phrase in ('/v1/messages/truncate', "active = 0, compacted = 0", "session.active_list",
                       "turn_running", "no `DELETE`"):
            self.assertIn(phrase, DOCS, phrase)


if __name__ == "__main__":
    unittest.main()
