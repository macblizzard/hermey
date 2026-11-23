"""Reaction sync: the host store, the one key rule, and the offline fallback.

Reactions used to live in each app's own `@AppStorage`, and the Mac's menu said so out loud —
"Remove **local** reaction" — because the two devices could not agree. They are the host's now, so
this file pins the four things that make that true, at the source, because the Swift compiler is
not on this box:

  * **the route surface** — `/v1/reactions` is mounted on hermeyd's router, behind the same bearer
    layer as every other `/v1` route, and answers GET (one conversation) and PUT (set or clear);
  * **the store** — one JSON document in hermeyd's state directory, written atomically and capped,
    so it cannot grow without bound, plus the live frame that reaches the other device;
  * **the key rule** — one shared Swift type, `ReactionKey`, and neither app building the composite
    itself any more (two copies of a key is how they drifted apart in the first place);
  * **the offline fallback** — the unpaired app still writes the device-local document, the paired
    app never does, and neither transcript row reaches for `@AppStorage`.

The behaviour is pinned by the Rust tests in `hermeyd/src/reactions.rs` and `relay.rs`
(`cargo test`), and by `Tests/HermesKitTests/ReactionKeyTests.swift` on CI. The names of the Rust
tests are asserted here so a tidy-up cannot quietly delete them.
"""
from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HERMEYD = ROOT / "hermeyd" / "src"
KIT = ROOT / "Sources" / "HermesKit"
APPKIT = ROOT / "Sources" / "HermesAppKit"
MAC = ROOT / "Apps" / "HermesMac"
PHONE = ROOT / "Apps" / "HermesMobile"

REACTIONS = (HERMEYD / "reactions.rs").read_text()
MAIN = (HERMEYD / "main.rs").read_text()
RELAY = (HERMEYD / "relay.rs").read_text()
ROUTES = (HERMEYD / "routes.rs").read_text()

KEY = (KIT / "Reactions.swift").read_text()
CLIENT = (KIT / "GatewayClient.swift").read_text()
DECODER = (KIT / "GatewayEventDecoder.swift").read_text()
ACTOR = (KIT / "GatewayClientActor.swift").read_text()
POINTER = (KIT / "EndlessSessionPointer.swift").read_text()
ACTIVITY = (KIT / "BotActivityTracker.swift").read_text()
MODEL = (APPKIT / "AppModel.swift").read_text()

MAC_ROW = (MAC / "Conversation" / "TranscriptRowView.swift").read_text()
MAC_SCROLL = (MAC / "Conversation" / "TranscriptScroll.swift").read_text()
PHONE_ROW = (PHONE / "Views" / "MobileTranscript.swift").read_text()

ROOT_TEST_FILE = ROOT / "Tests" / "HermesKitTests" / "ReactionKeyTests.swift"


def rust_handler(name: str) -> str:
    """One `pub async fn` from reactions.rs, up to the next top-level item."""
    start = REACTIONS.index(f"pub async fn {name}(")
    rest = REACTIONS[start:]
    end = rest.find("\n}\n")
    return rest[:end]


class RouteSurfaceTests(unittest.TestCase):
    def test_the_module_exists_and_is_mounted(self) -> None:
        self.assertTrue((HERMEYD / "reactions.rs").is_file())
        self.assertIn("mod reactions;", MAIN)
        # One route, two verbs: a read for the conversation and a write for one message.
        self.assertIn('"/v1/reactions"', MAIN)
        self.assertIn("get(reactions::get_reactions).put(reactions::put_reaction)", MAIN)

    def test_both_handlers_are_behind_the_device_bearer(self) -> None:
        # The whole point of a shared store is that only a paired device may read or write it; the
        # layer is the same `require_device` every other `/v1` route uses.
        for handler in ("get_reactions", "put_reaction"):
            body = rust_handler(handler)
            self.assertIn("require_device(&st, &headers)", body, handler)
            self.assertIn("State(st): State<Arc<AppState>>", body, handler)

    def test_the_contract_is_the_one_the_apps_decode(self) -> None:
        # GET: `{"reactions": {"<messageKey>": {"emoji", "by"}}}`, only for that bot and session.
        get = rust_handler("get_reactions")
        self.assertIn('json!({ "reactions": reactions })', get)
        self.assertIn('json!({ "emoji": entry.emoji, "by": entry.by })', REACTIONS)
        self.assertIn("st.reactions.conversation(&q.bot, &q.session)", get)

        # PUT: a message key, the emoji, and the device that did it. An empty emoji removes.
        put = rust_handler("put_reaction")
        for field in ('"message"', '"emoji"', '"by"', '"at"'):
            self.assertIn(field, put, field)
        self.assertIn("plan.emoji.as_deref()", put)
        self.assertIn("StatusCode::INTERNAL_SERVER_ERROR", put)

    def test_the_query_and_body_fields_are_the_documented_ones(self) -> None:
        self.assertIn("pub bot: String", REACTIONS)
        self.assertIn("pub session: String", REACTIONS)
        self.assertIn("pub message: String", REACTIONS)
        self.assertIn("pub emoji: String", REACTIONS)
        self.assertIn("pub by: String", REACTIONS)



class TheTestsThemselvesTests(unittest.TestCase):
    """`cargo test` is the behavioural gate; these are the cases it must keep running."""

    NAMES = (
        "a_reaction_is_put_read_and_replaced",
        "each_bot_and_session_keeps_its_own_reactions",
        "only_row_and_live_message_keys_are_accepted",
        "an_emoji_is_one_short_glyph_and_a_device_name_is_printable",
        "profiles_and_sessions_are_the_shapes_the_other_routes_accept",
        "every_bad_field_is_a_422_with_its_own_code",
        "a_request_without_a_device_bearer_is_refused",
        "the_store_survives_a_reopen_and_lives_in_one_atomic_file",
        "a_corrupt_document_is_ignored_and_the_next_write_replaces_it",
        "the_store_is_capped_and_evicts_the_oldest",
        "the_broadcast_frame_is_the_engine_event_envelope",
        "a_put_reaches_every_live_socket",
    )

    def test_every_reaction_case_is_still_there(self) -> None:
        for name in self.NAMES:
            self.assertIn(f"fn {name}()", REACTIONS, name)

    def test_the_relay_forwards_a_host_frame_to_the_app_socket(self) -> None:
        # The end-to-end half of the broadcast: a frame published by the host reaches a connected
        # app on the same wire the engine's events use.
        self.assertIn("fn a_host_originated_frame_reaches_the_app_socket()", RELAY)


class StoreTests(unittest.TestCase):
    def test_it_is_one_json_document_in_the_state_directory(self) -> None:
        # No database: the task is a handful of bytes per message, and a file is what an operator
        # can read, back up, or delete to clear every badge.
        self.assertIn('dir.into().join("reactions.json")', REACTIONS)
        self.assertIn("pub reactions: crate::reactions::Registry", ROUTES)
        self.assertIn("reactions: reactions::Registry::in_dir(home.clone())", MAIN)

    def test_the_write_is_atomic(self) -> None:
        # Temp file, then rename: a reader (or a crash) never sees half a document.
        write = REACTIONS[REACTIONS.index("fn write_document"):]
        self.assertIn("std::fs::write(&temp, text)", write)
        self.assertIn("std::fs::rename(&temp, path)", write)
        self.assertIn("json.tmp-", write)

    def test_it_is_capped_so_it_cannot_grow_without_bound(self) -> None:
        self.assertIn("pub const MAX_REACTIONS: usize = 5_000;", REACTIONS)
        # Evicted from the front (oldest first), and the in-memory copy is capped on load too, so a
        # hand-edited file cannot restore what was evicted.
        record = REACTIONS[REACTIONS.index("pub fn record("):REACTIONS.index("fn load(&self)")]
        self.assertIn("while next.len() > MAX_REACTIONS", record)
        self.assertIn("next.pop_front()", record)
        self.assertIn("while entries.len() > MAX_REACTIONS", REACTIONS)

    def test_one_emoji_per_message_and_a_replacement_wins(self) -> None:
        record = REACTIONS[REACTIONS.index("pub fn record("):REACTIONS.index("fn load(&self)")]
        self.assertIn("!(e.bot == bot && e.session == session && e.message == message)", record)
        self.assertIn("next.push_back(Entry {", record)

    def test_the_store_is_only_reachable_through_the_lock(self) -> None:
        # Two devices reacting at the same moment must not interleave a read-modify-write.
        self.assertIn("inner: Mutex<Mem>", REACTIONS)
        self.assertIn("poisoned.into_inner()", REACTIONS)


class ValidationTests(unittest.TestCase):
    def test_only_row_and_live_message_keys_are_accepted(self) -> None:
        self.assertIn('const MESSAGE_PREFIXES: [&str; 2] = ["row:", "live:"];', REACTIONS)
        self.assertIn("pub fn valid_message(", REACTIONS)
        # Both prefixes are now the apps' own rule (`ReactionKey.message`), which is why the host
        # checks the same two.
        self.assertIn("strip_prefix(prefix)", REACTIONS)

    def test_an_emoji_is_one_short_glyph(self) -> None:
        self.assertIn("const MAX_EMOJI_BYTES: usize = 8;", REACTIONS)
        self.assertIn("!emoji.is_empty() && emoji.len() <= MAX_EMOJI_BYTES", REACTIONS)

    def test_the_ids_are_bounded_the_way_the_other_routes_bound_them(self) -> None:
        self.assertIn("const MAX_SESSION_LEN: usize = 128;", REACTIONS)
        self.assertIn("pub fn valid_bot(", REACTIONS)
        self.assertIn("pub fn valid_session(", REACTIONS)
        # A profile name never becomes a path (`cards.rs` / `bot_message.rs` do the same check).
        self.assertIn("b'_' | b'.' | b'-'", REACTIONS)


class BroadcastTests(unittest.TestCase):
    def test_the_frame_is_the_engine_envelope_the_apps_already_decode(self) -> None:
        self.assertIn('"method": "event"', REACTIONS)
        self.assertIn('"type": "reaction.updated"', REACTIONS)
        for field in ('"bot"', '"session"', '"message"', '"emoji"', '"by"'):
            frame = REACTIONS[REACTIONS.index("pub fn frame("):]
            self.assertIn(field, frame[:1200], field)

    def test_it_is_published_to_every_live_socket(self) -> None:
        self.assertIn("pub fn publish(&self, line: String) -> usize", RELAY)
        self.assertIn("pub fn subscribe(&self) -> broadcast::Receiver<String>", RELAY)
        self.assertIn("host_frames.recv()", RELAY)
        # Newline-terminated, like every other app-facing frame: the client's buffer only yields a
        # frame when it sees 0x0A.
        self.assertIn("client_tx.send(text_frame(line)).await", RELAY)

    def test_a_publish_never_blocks_a_route(self) -> None:
        # The reaction is already in the store; a socket that is gone must not fail the write.
        self.assertIn("self.host_frames.send(line).unwrap_or(0)", RELAY)
        put = rust_handler("put_reaction")
        self.assertIn("let _ = st.relay_sockets.publish(", put)


class KeyRuleTests(unittest.TestCase):
    def test_one_shared_type_holds_the_rule(self) -> None:
        self.assertIn("public struct ReactionKey: Hashable, Sendable", KEY)
        self.assertIn("public let host: String", KEY)
        self.assertIn("public let bot: String", KEY)
        self.assertIn("public let session: String", KEY)
        self.assertIn("public let message: String", KEY)
        # Length-prefixed, exactly as both apps wrote it, so a device's existing local reactions
        # keep matching after the upgrade.
        self.assertIn('.map { "\\($0.utf8.count):\\($0)" }', KEY)
        self.assertIn(".joined()", KEY)

    def test_the_message_half_is_row_or_live(self) -> None:
        self.assertIn("public static func message(rowID: Int?, entryID: String) -> String", KEY)
        self.assertIn('return "row:\\(rowID)"', KEY)
        self.assertIn('return "live:\\(entryID)"', KEY)
        self.assertIn("public static func isValidMessage(", KEY)

    def test_neither_app_builds_the_composite_itself(self) -> None:
        # The regression this file exists for: two copies of one key rule, each drifting.
        for source, name in ((MAC_ROW, "mac row"), (PHONE_ROW, "phone row")):
            self.assertNotIn("utf8.count", source, name)
            self.assertIn("ReactionKey.message(rowID: entry.rowID", source, name)
            self.assertIn("ReactionKey(host:", source, name)
            self.assertNotIn("row:\\($0)", source, name)

    def test_the_host_keys_the_message_and_scopes_it_by_bot_and_session(self) -> None:
        # The wire key is the message half: the host scopes by bot and session in the query, which
        # is what lets a Mac and a phone whose host labels differ still agree.
        self.assertIn("public var wireMessage: String { message }", KEY)
        get = rust_handler("get_reactions")
        self.assertIn("&q.bot, &q.session", get)


class ClientTests(unittest.TestCase):
    def test_the_protocol_has_a_read_a_write_and_the_bridge_question(self) -> None:
        self.assertIn("func reactions(bot: String, session: SessionID) async throws -> [String: Reaction]",
                      CLIENT)
        self.assertIn("func setReaction(bot: String, session: SessionID, message: String,", CLIENT)
        self.assertIn("var bridgeAvailable: Bool { get }", CLIENT)

    def test_a_client_with_no_bridge_answers_no_rather_than_guessing(self) -> None:
        self.assertIn("var bridgeAvailable: Bool { false }", CLIENT)
        self.assertIn("throw ReactionSyncError.noBridge", CLIENT)

    def test_the_actor_and_the_pointer_store_implement_both_verbs(self) -> None:
        self.assertIn("public nonisolated var bridgeAvailable: Bool { sessionPointer != nil }", ACTOR)
        self.assertIn("return try await sessionPointer.reactions(bot: bot, session: session)", ACTOR)
        self.assertIn("try await sessionPointer.setReaction(bot: bot, session: session", ACTOR)
        # And the HTTP route itself, through the one place a single-use ticket is minted.
        self.assertIn('"v1/reactions?bot=', POINTER)
        self.assertIn('bridgePUT("v1/reactions"', POINTER)
        # A value that could reshape the query is percent-encoded.
        self.assertIn("static func queryValue(_ raw: String) -> String", POINTER)

    def test_the_socket_event_is_decoded_and_modelled(self) -> None:
        self.assertIn("case reactionUpdated(bot: String, session: SessionID, message: String, "
                      "emoji: String?, by: String)", CLIENT)
        self.assertIn('case "reaction.updated":', DECODER)
        self.assertIn("ReactionKey.isValidMessage(message)", DECODER)
        # Not a bot's activity, and not transcript content: an emoji arriving must not light a
        # "typing" face or repaint a row's body.
        self.assertIn(".reactionUpdated", ACTIVITY)


class OfflineFallbackTests(unittest.TestCase):
    def test_the_unpaired_app_still_writes_the_device_document(self) -> None:
        self.assertIn("private let reactionLocal: ReactionLocalStore", MODEL)
        self.assertIn("reactionLocal.set(emoji, for: key.storageKey)", MODEL)
        self.assertIn("guard client.bridgeAvailable else {", MODEL)
        # The key each app already wrote, so an upgrade finds the reactions a device had.
        self.assertIn('return "mac.messageReactions.v1"', MODEL)
        self.assertIn('return "mobile.messageReactions.v1"', MODEL)

    def test_neither_transcript_row_writes_reactions_straight_to_storage(self) -> None:
        for source, name in ((MAC_ROW, "mac row"), (PHONE_ROW, "phone row")):
            # A declaration, not the word: the file may mention `@AppStorage` in a comment about
            # what it replaced, and that comment is worth keeping.
            self.assertNotIn('@AppStorage("', source, name)
            self.assertNotIn("storedReactions", source, name)
            self.assertNotIn("JSONDecoder().decode([String: String]", source, name)
        # The Mac's own wording: the menu said "local" because it was, and no longer is.
        self.assertNotIn("local reaction", MAC_ROW.lower())
        self.assertNotIn("Add Local Reaction", MAC_ROW)

    def test_the_row_reads_the_models_map(self) -> None:
        self.assertIn("var reaction: (ReactionKey) -> String?", MAC_ROW)
        self.assertIn("var onReact: (ReactionKey, String?) -> Void", MAC_ROW)
        self.assertIn("reaction: { model.reaction(for: $0) }", MAC_SCROLL)
        self.assertIn("Task { await model.setReaction(emoji, for: key) }", MAC_SCROLL)
        self.assertIn("app.model.reaction(for: key)", PHONE_ROW)
        self.assertIn("await app.model.setReaction(next, for: key)", PHONE_ROW)

    def test_a_paired_write_is_optimistic_and_reverted_on_failure(self) -> None:
        body = MODEL[MODEL.index("public func setReaction("):]
        body = body[:body.index("private func refreshReactions")]
        # Painted first…
        self.assertIn("let previous = reactions[key.storageKey]", body)
        self.assertIn("apply(emoji, to: key.storageKey)", body)
        self.assertIn("try await client.setReaction(", body)
        # …and put back when the host refuses, so a badge is never a local-only lie.
        self.assertIn("apply(previous, to: key.storageKey)", body)
        self.assertIn("could not save the reaction", body)

    def test_the_host_is_the_truth_when_paired(self) -> None:
        self.assertIn("let rows = try await client.reactions(bot: bot, session: session)", MODEL)
        # One import of what the device kept, then never again: a re-send would resurrect a
        # reaction the other device has since cleared.
        self.assertIn("private func importLocalReactions(bot: String, session: SessionID, epoch: Int)",
                      MODEL)
        self.assertIn("guard !reactionsImported.contains(conversation)", MODEL)
        self.assertIn("reactionsImported.insert(conversation)", MODEL)

    def test_switching_bot_drops_the_previous_badge(self) -> None:
        reset = MODEL[MODEL.index("private func resetForBotSwitch"):]
        reset = reset[:reset.index("\n    }")]
        self.assertIn("reactions = []", reset)


class ContractAgreementTests(unittest.TestCase):
    """The host and the clients must agree on the two strings that identify a reaction."""

    def test_the_two_message_prefixes_are_the_same_on_both_sides(self) -> None:
        host = set(re.findall(r'"(row:|live:)"', REACTIONS))
        swift = set(re.findall(r'"(row:|live:)"', KEY))
        self.assertEqual(host, {"row:", "live:"})
        self.assertEqual(swift, {"row:", "live:"})

    def test_both_sides_bound_a_message_key_the_same_way(self) -> None:
        self.assertIn("const MAX_MESSAGE_LEN: usize = 160;", REACTIONS)
        self.assertIn("message.utf8.count <= 160", KEY)

    def test_the_xctest_for_the_key_rule_is_where_ci_runs_it(self) -> None:
        self.assertTrue(ROOT_TEST_FILE.is_file())
        source = ROOT_TEST_FILE.read_text()
        self.assertIn("final class ReactionKeyTests: XCTestCase", source)
        self.assertIn("4:casa4:cody22:20261123_101500_ab12cd6:row:41", source)


class NoNewDependencyTests(unittest.TestCase):
    def test_the_store_uses_only_crates_the_service_already_had(self) -> None:
        # Nothing was added to `Cargo.toml` for this: the store is `std::fs` plus `serde`.
        cargo = (ROOT / "hermeyd" / "Cargo.toml").read_text()
        for imported in re.findall(r"^use (?:crate|std|axum|serde|serde_json|tokio)::", REACTIONS,
                                   re.MULTILINE):
            self.assertTrue(imported)
        # No new crate name appears in the file.
        crates = set(re.findall(r"^([a-z0-9_]+) =", cargo, re.MULTILINE))
        used = set(re.findall(r"^use ([a-z0-9_]+)::", REACTIONS, re.MULTILINE))
        used -= {"crate", "std"}
        self.assertTrue(used.issubset(crates | {"axum", "serde", "serde_json"}), used)


if __name__ == "__main__":
    unittest.main()
