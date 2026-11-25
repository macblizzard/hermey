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
PHONE_SCREEN = (PHONE / "Views" / "ConversationScreen.swift").read_text()
PHONE_APP = (PHONE / "HermesMobileApp.swift").read_text()

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
        "two_devices_agree_on_one_reaction_and_on_its_removal",
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
        self.assertIn("public static func message(rowID: Int64?, entryID: String) -> String", KEY,
                      "the row id is Int64?, and the key rule owns the conversion")
        self.assertIn('return "row:\\(rowID)"', KEY)
        self.assertIn('return "live:\\(entryID)"', KEY)
        self.assertIn("public static func isValidMessage(", KEY)

    def test_neither_app_builds_the_composite_itself(self) -> None:
        # The regression this file exists for: two copies of one key rule, each drifting — and, after
        # that, one shell assembling the composite while the other asked the model. Neither row
        # builds a key now: both hand the model the message half and nothing else.
        for source, name in ((MAC_ROW, "mac row"), (PHONE_ROW, "phone row")):
            self.assertNotIn("utf8.count", source, name)
            self.assertNotIn("ReactionKey(host:", source, name)
            self.assertNotIn("row:\\($0)", source, name)
        # The Mac's row computes the *message half* from the shared rule and nothing more.
        self.assertIn("ReactionKey.message(rowID: entry.rowID, entryID: entry.id)", MAC_ROW)
        # The phone's row does not even do that: it is handed the emoji and reports the tap.
        self.assertNotIn("ReactionKey(", PHONE_ROW)

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
        # Both rows are told the emoji and report the tap; the model owns the key. The Mac's closures
        # take the message half, the phone's a plain value and a glyph.
        self.assertIn("var reaction: (String) -> String? = { _ in nil }", MAC_ROW)
        self.assertIn("var onReact: (String, String?) -> Void = { _, _ in }", MAC_ROW)
        self.assertIn("reaction: { model.reaction(forMessage: $0) }", MAC_SCROLL)
        self.assertIn("Task { await model.setReaction(emoji, forMessage: message) }", MAC_SCROLL)
        self.assertIn("var reaction: String? = nil", PHONE_ROW)
        self.assertIn("reaction: model.reaction(forRowID: entry.rowID,", PHONE_SCREEN)
        self.assertIn("await model.react(emoji, rowID: entry.rowID,", PHONE_SCREEN)

    def test_the_model_is_the_one_place_a_key_is_built_for_a_row(self) -> None:
        self.assertIn("public func reaction(forMessage message: String) -> String?", MODEL)
        self.assertIn("public func setReaction(_ emoji: String?, forMessage message: String) async", MODEL)
        self.assertIn("public func reaction(forRowID rowID: Int64?, entryID: String) -> String?", MODEL)
        self.assertIn("public func react(_ emoji: String, rowID: Int64?, entryID: String) async", MODEL)
        self.assertIn("private func conversationReactionKey(_ message: String) -> ReactionKey?", MODEL)
        self.assertIn("ReactionKey(host: hostName, bot: bot, session: session, message: message)",
                      MODEL)

    def test_a_paired_write_is_optimistic_and_reverted_when_the_host_refuses(self) -> None:
        body = MODEL[MODEL.index("public func setReaction("):]
        body = body[:body.index("public func refreshReactions")]
        # Painted first…
        self.assertIn("let previous = reactions[key.storageKey]", body)
        self.assertIn("apply(emoji, to: key.storageKey)", body)
        self.assertIn("try await client.setReaction(", body)
        # …and put back when the host actually refuses, so a badge is never a local-only lie.
        self.assertIn("catch ReactionSyncError.refused(let status, let detail)", body)
        self.assertIn("apply(previous, to: key.storageKey)", body)
        self.assertIn("could not save the reaction", body)
        # A host that never answered is not a refusal: the tap is kept on this device and the
        # conversation is un-marked so the next open hands it over, rather than blinking away.
        self.assertIn("reactionLocal.set(emoji, for: key.storageKey)", body)
        self.assertIn("reactionsImported.remove(conversationID(bot: key.bot, session: key.session))",
                      body)
        self.assertIn("saved on this device; it will sync when the host is reached", body)

    def test_the_host_is_the_truth_when_paired(self) -> None:
        self.assertIn("let rows = try await client.reactions(bot: bot, session: session)", MODEL)
        # One hand-over of what the device kept, then never again: a re-send would resurrect a
        # reaction the other device has since cleared. Only keys the host answered nothing for are
        # pushed — a key the host already has is the host's answer.
        self.assertIn("private func importLocalReactions(bot: String, session: SessionID,", MODEL)
        self.assertIn("known: Set<String>, epoch: Int) async -> [String: String]", MODEL)
        self.assertIn("guard !reactionsImported.contains(conversation) else { return [:] }", MODEL)
        self.assertIn("!known.contains(key.message)", MODEL)
        self.assertIn("reactionsImported.insert(conversation)", MODEL)

    def test_the_open_conversation_is_read_from_the_host_the_moment_it_opens(self) -> None:
        # The read used to hang off `select()` and the socket's `ready` alone, and neither app's
        # endless open goes through `select()` — so opening a bot never asked the host, which is
        # exactly the "it did not sync" report.
        opened = MODEL[MODEL.index("private func adoptStoredConversation("):]
        opened = opened[:opened.index("private func forgetStoredConversation(")]
        self.assertIn("refreshReactions()", opened)
        moved = MODEL[MODEL.index("private func paintAdoptedConversation("):]
        moved = moved[:moved.index("private func followMovedConversation(")]
        self.assertIn("refreshReactions()", moved)
        self.assertIn("public func refreshReactions()", MODEL)
        # And the phone asks again whenever it comes back to the front: a socket that stayed up
        # sends no `ready`, so nothing else would ask.
        self.assertIn("app.model.refreshReactions()", PHONE_APP)

    def test_the_local_document_is_a_copy_of_the_hosts_answer(self) -> None:
        # Paired, the device's document follows the host: written on every accepted change and
        # replaced by every read, so an offline launch draws the same badges and a reaction cleared
        # on the other device cannot come back from this device's cache.
        self.assertIn("reactionLocal.set(emoji, for: key.storageKey)\n        } catch ReactionSyncError.refused",
                      MODEL)
        self.assertIn("reactionLocal.replaceConversation(", MODEL)
        self.assertIn("ReactionKey.conversationPrefix(host: hostName, bot: bot, session: session)",
                      MODEL)
        store = (KIT / "Reactions.swift").read_text()
        self.assertIn("public func replaceConversation(_ prefix: String, with values: [String: String])",
                      store)

    def test_switching_bot_drops_the_previous_badge(self) -> None:
        reset = MODEL[MODEL.index("private func resetForBotSwitch"):]
        reset = reset[:reset.index("\n    }")]
        self.assertIn("reactions = [:]", reset,
                      "a dictionary is emptied with [:]; [] is an array and would not compile")


class LivePathTests(unittest.TestCase):
    """The last mile — the parts the host cannot do for the apps.

    The store, the route and the broadcast were already pinned above, and none of them was broken:
    a reaction was written, read back and pushed to both sockets. What was missing was on the device
    side, so these guards point at the three hops between a frame and a badge — a tap that reaches
    the host, a frame that is applied to the conversation on screen, and a row that repaints when
    the map it draws from changes.
    """

    def branch(self, opener: str, closer: str) -> str:
        start = MODEL.index(opener)
        return MODEL[start:MODEL.index(closer, start)]

    @property
    def reaction_branch(self) -> str:
        return self.branch("case .reactionUpdated(", "case .error(let session")

    def test_a_tap_writes_the_host_and_not_only_the_device(self) -> None:
        body = self.branch("public func setReaction(", "public func refreshReactions")
        # The host first: a write that only touched the device is the original bug.
        self.assertIn("try await client.setReaction(bot: key.bot, session: key.session,", body)
        after_write = body[body.index("try await client.setReaction("):]
        self.assertIn("reactionLocal.set(emoji, for: key.storageKey)", after_write[:400],
                      "the device's copy follows the host's write, never replaces it")
        # And no transcript row writes a reaction itself.
        for source, name in ((MAC_ROW, "mac row"), (PHONE_ROW, "phone row")):
            self.assertNotIn("@AppStorage(\"", source, name)

    def test_a_frame_from_the_other_device_is_applied_to_the_open_conversation(self) -> None:
        branch = self.reaction_branch
        self.assertIn("guard bot.isEmpty || bot == selectedBotID,", branch)
        # The session is resolved through the alias table, exactly as a host error is: the two apps
        # are attached at different moments, so one conversation arrives under two runtime ids.
        self.assertIn("let named = Self.resolveSession(session, aliases: sessionAliases)", branch)
        self.assertIn("guard named == filed || named == selectedSessionID else { return }", branch)
        # And the badge goes in under the durable id the rows look up.
        self.assertIn("let key = ReactionKey(host: hostName, bot: botID, session: filed, "
                      "message: message)", branch)
        self.assertIn("apply(emoji, to: key.storageKey)", branch)
        # Both apps apply it: the branch is `AppModel`'s, and both shells are built on it.
        self.assertIn("AppModel(", (MAC / "Workspace" / "WorkspaceStore.swift").read_text())
        self.assertIn("AppModel(", (PHONE / "App" / "AppEnvironment.swift").read_text())

    def test_a_removal_arrives_as_nil_and_clears_the_same_key(self) -> None:
        # The decoder keeps "cleared" apart from "not about me": a null is a removal, and the branch
        # has no second path that could forget to remove.
        self.assertIn('let emoji = payload["emoji"]?.stringValue', DECODER)
        self.assertIn('"emoji": emoji', REACTIONS)
        branch = self.reaction_branch
        self.assertIn("apply(emoji, to: key.storageKey)", branch)
        apply_body = MODEL[MODEL.index("private func apply(_ emoji: String?"):]
        apply_body = apply_body[:apply_body.index("\n    }")]
        self.assertIn("reactions.removeValue(forKey: storageKey)", apply_body)

    def test_only_the_shared_rule_spells_a_message_key(self) -> None:
        # `row:<id>` / `live:<id>` are one rule, in `Reactions.swift`. A second spelling anywhere in
        # either app is how one row was keyed two ways — the reaction was stored under a name the
        # other device never looked up.
        offenders = []
        for folder in ("Sources", "Apps"):
            for path in (ROOT / folder).rglob("*.swift"):
                if path.name == "Reactions.swift":
                    continue
                text = path.read_text(encoding="utf-8", errors="replace")
                if '"row:\\(' in text or '"live:\\(' in text:
                    offenders.append(str(path.relative_to(ROOT)))
        self.assertEqual(offenders, [], "the message halves live in ReactionKey.message only")

    def test_a_reaction_is_filed_under_the_durable_session_id(self) -> None:
        # The runtime id is minted per attach, so the Mac and the phone hold different ones for one
        # conversation. A reaction filed under it is invisible to the other device's read — the (d)
        # half of "it did not sync". Every reaction key is built from `reactionSession`.
        self.assertIn("private var durableIDs: [SessionID: SessionID] = [:]", MODEL)
        self.assertIn("durableIDs[session] = resumed.storedSessionID ?? session", MODEL)
        self.assertIn("guard let bot = selectedBotID, let session = reactionSession else { return nil }",
                      MODEL)
        self.assertIn("guard let session = selectedSessionID else { return nil }\n        return durableIDs[session] ?? session",
                      MODEL)
        # The read and the frame's guard both use it, so they cannot disagree with the rows.
        self.assertIn("guard let bot = selectedBotID, let session = reactionSession else {", MODEL)
        self.assertIn("guard epoch == botEpoch, reactionSession == session, selectedBotID == bot",
                      MODEL)

    def test_the_row_a_badge_lands_on_is_the_row_that_repaints(self) -> None:
        # A row that reads the map through a model it does not observe never repaints: the phone's
        # badge used to appear only on the next scroll or launch. The phone's row is handed a value
        # (`reaction:`) by the screen that does observe the model, and reports the tap back.
        self.assertIn("var reaction: String? = nil", PHONE_ROW)
        self.assertNotIn("app.model.reaction(for:", PHONE_ROW)
        self.assertIn("reaction: model.reaction(forRowID: entry.rowID,", PHONE_SCREEN)
        self.assertIn("onReact: { emoji in", PHONE_SCREEN)
        # The Mac's row is built by a pane that observes the model, with a closure that re-reads it.
        self.assertIn("reaction: { model.reaction(forMessage: $0) }", MAC_SCROLL)

    def test_the_phone_also_asks_again_when_it_comes_back_to_the_front(self) -> None:
        # A socket that stayed up sends no `ready`, so the live frame is the only other trigger —
        # and a phone that was asleep has nothing to replay. One read on every foreground is the
        # fallback the requirement names.
        self.assertIn("app.model.refreshReactions()", PHONE_APP)
        foreground = PHONE_APP[PHONE_APP.index("if phase == .active { Task { await app.updates.check() } }"):]
        self.assertIn("app.model.refreshReactions()", foreground[:2000])


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
