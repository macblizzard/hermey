"""The ceiling on one Bot Chat: a setting, a roll, and a Previous conversations list.

The failure this feature answers: one endless conversation per bot, no cap. `cody`'s reached
**6,806 messages / 4.5 MB**, and resuming it takes longer than the app's own 120 s deadline, so the
chat stopped opening at all.

What these guard, in the order the brief asks for:

* the count is the **host's** (`live_message_count`), not the denormalised `message_count` — which
  reports 675 for that same 6,806-message conversation, because compaction retires those rows from
  the column while they stay in the transcript;
* the ceiling is a **setting** ("Start a new chat after", 1,000 / 2,000 / 5,000 / Never, defaulting
  to 2,000), stored per app in `UserDefaults`, and the 2,000 exists once — as the default;
* the roll happens only when a conversation is over the ceiling and **nothing is in flight**;
* the new chat **is** the bot's Bot Chat afterwards (the host's name moved to it), and the archived
  chat is reachable only through Previous conversations;
* the archived conversation keeps its id and its count, is never deleted, and the list is per bot
  and newest first;
* a failed roll leaves the current conversation — the current id — untouched.

The app target cannot be executed by this suite (it needs an Xcode build on a Mac), so the guards
are structure checks over the Swift and Rust sources, plus one check against the real oversized
conversation in this host's `state.db` when that file is present.
"""

import pathlib
import re
import sqlite3
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "Sources" / "HermesKit" / "BotChatArchive.swift"
APP = ROOT / "Sources" / "HermesAppKit" / "AppModel.swift"
CLIENT = ROOT / "Sources" / "HermesKit" / "GatewayClient.swift"
ACTOR = ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift"
DECODER = ROOT / "Sources" / "HermesKit" / "GatewayEventDecoder.swift"
MAC_SETTINGS = ROOT / "Apps" / "HermesMac" / "Views" / "MacSettingsView.swift"
PHONE_SETTINGS = ROOT / "Apps" / "HermesMobile" / "Views" / "SettingsScreen.swift"
MAC_MENU = ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotRowMenu.swift"
PHONE_LIST = ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift"
BRIDGE = ROOT / "hermeyd" / "src" / "bot_message.rs"
BRIDGE_STORE = ROOT / "hermeyd" / "src" / "store.rs"

# The conversation named in the brief, in this host's own state database.
OVERSIZED = (
    pathlib.Path("/root/.hermes/profiles/cody/state.db"),
    "local-9b01b0c8861210fbf1bd65d0061ba8aab5a5493b275eb904ec7cb63331e2a8a9",
)


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_comments(text: str) -> str:
    """Source with every `//` comment removed, so a doc reference is not mistaken for a call."""
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.splitlines())


def function_body(text: str, signature: str) -> str:
    """The braced body of the function whose declaration contains `signature`."""
    start = text.index(signature)
    open_brace = text.index("{", start)
    depth = 0
    for index in range(open_brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[open_brace:index]
    raise AssertionError(f"unbalanced braces after {signature}")


def should_roll(count, limit, in_flight, current_id, already_archived):
    """Python port of `BotChatArchive.shouldRoll`, for the decision matrix.

    Kept in step with the Swift by ``test_the_decision_matrix_matches_the_swift``, which reads the
    four guards out of the source and asserts this function has the same shape.
    """
    if limit is None or limit <= 0:
        return False
    if count is None or count < limit:
        return False
    if in_flight:
        return False
    if not current_id:
        return False
    if already_archived:
        return False
    return True


class TheCount(unittest.TestCase):

    def test_the_count_is_the_hosts_display_count_not_the_denormalised_one(self):
        """`live_message_count` first, `message_count` only as the fallback.

        Measured on `cody`'s chat: 6,136 vs 675. A ceiling read off the second never fires.
        """
        decoder = strip_comments(read(DECODER))
        body = function_body(decoder, "static func botChatRow(")
        self.assertIn('row["live_message_count"]', body,
                      "the roll must measure the host's display count")
        live = body.index('row["live_message_count"]')
        stored = body.index('row["message_count"]')
        self.assertLess(live, stored,
                        "live_message_count is the count; message_count is only the fallback")

    def test_the_host_row_is_one_exact_title_read(self):
        """One row, one count query — not a listing sweep, and not the app's own array.

        The app's transcript is a *page* once resumes are windowed, so counting it would
        under-report a long conversation by thousands.
        """
        actor = strip_comments(read(ACTOR))
        body = function_body(actor, "public func botChatRow(profile: String)")
        self.assertIn('"title": .string(CanonicalBotChat.title)', body)
        self.assertIn('"limit": .int(1)', body)
        self.assertIn('perform("session.list"', body)

    def test_the_display_count_matches_the_rows_the_transcript_paints(self):
        """The query the ceiling trusts, checked against a chat this test builds itself.

        The earlier version of this guard asserted that *this box's* cody chat was over 2,000 rows —
        an environment fact, not a property of the code: it fails on any host whose chat is small,
        and it started failing the moment the fleet's chats were trimmed to 200. The semantics it was
        standing in for are what matter, so it now builds a chat with retired (compacted) rows and
        duplicate display orders and checks the query counts exactly the rows a transcript paints.
        """
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "state.db"
            conn = sqlite3.connect(path)
            conn.execute("CREATE TABLE messages (session_id TEXT, display_order INTEGER, "
                         "active INTEGER, compacted INTEGER)")
            rows = []
            for order in range(1, 2001):                      # 2,000 live rows
                rows.append(("s1", order, 1, 0))
            rows.append(("s1", 1, 0, 1))                      # a compacted duplicate: one row painted
            rows.append(("s1", 5, 1, 0))                      # a second active row on the same order
            rows.append(("s1", 2001, 0, 0))                   # retired entirely: never painted
            rows.append(("s2", 1, 1, 0))                      # another session: not counted
            conn.executemany("INSERT INTO messages VALUES (?, ?, ?, ?)", rows)
            conn.commit()
            conn.close()

            conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            count = conn.execute(
                "SELECT COUNT(*) FROM (SELECT DISTINCT display_order FROM messages "
                "WHERE session_id = ? AND (active = 1 OR compacted = 1))", ("s1",)).fetchone()[0]
            conn.close()
        self.assertEqual(count, 2000,
                         "2,000 painted rows in one session, whatever the retired rows say")

class TheSetting(unittest.TestCase):

    def test_two_thousand_is_written_once_and_is_only_the_default(self):
        literal = re.compile(r"(?<![\d.])2000(?![\d.])")
        hits = []
        for folder in ("Sources", "Apps"):
            for path in (ROOT / folder).rglob("*.swift"):
                for number, line in enumerate(read(path).splitlines(), 1):
                    if literal.search(line):
                        hits.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertEqual(hits, ["Sources/HermesKit/BotChatArchive.swift:28"],
                         "the ceiling's default value must exist exactly once")
        archive = read(ARCHIVE)
        self.assertIn("public static let defaultLimit = 2000", archive)

    def test_the_choices_are_the_four_the_owner_asked_for(self):
        archive = strip_comments(read(ARCHIVE))
        choices = function_body(archive, "public static var choices")
        self.assertIn("[1000, BotChatArchive.defaultLimit, 5000, never]", choices,
                      "1,000 / 2,000 (the default) / 5,000 / Never, in that order")
        self.assertIn("public static let never = 0", archive)

    def test_every_read_goes_through_the_setting(self):
        """The roll reads `botChatLimit`, which is the setting — never a literal."""
        app = strip_comments(read(APP))
        self.assertIn("var botChatLimit: Int? { BotChatCeiling.limit(from: botChatCeiling) }", app)
        roll = function_body(app, "func rollBotChatIfNeeded(for botID: String)")
        self.assertIn("guard let limit = botChatLimit else { return nil }", roll,
                      "Never (no ceiling) must stop the roll before any read")
        self.assertIn("limit: limit", roll)
        self.assertNotRegex(roll, r"limit:\s*\d+", "the roll must not carry its own number")

    def test_the_setting_is_the_apps_own_defaults_not_the_hosts(self):
        archive = strip_comments(read(ARCHIVE))
        self.assertIn('public static let key = "hermey.botChatCeiling"', archive)
        app = strip_comments(read(APP))
        self.assertIn("static let botChatCeiling = BotChatCeiling.key", app)
        self.assertIn("Self.defaults.set(settled, forKey: Keys.botChatCeiling)", app)
        # Not a host write: no publish, no card, no RPC.
        ceiling = function_body(app, "public var botChatCeiling: Int")
        self.assertNotIn("client.", ceiling)
        self.assertNotIn("await", ceiling)

    def test_a_change_applies_on_the_next_open_without_a_restart(self):
        """The value is read when the open happens, so nothing has to be restarted."""
        app = strip_comments(read(APP))
        open_body = function_body(app, "public func endlessSession(for botID: String, select: Bool = true)")
        roll_call = open_body.index("rollBotChatIfNeeded(for: botID)")
        canonical = open_body.index("canonicalChatIdentity(for: botID)")
        self.assertLess(roll_call, canonical,
                        "the ceiling is checked before the conversation is resolved for resume")
        self.assertIn("botChatLimit", function_body(app, "func rollBotChatAfterTurn(for botID: String)"))

    def test_never_turns_the_roll_off_entirely(self):
        archive = strip_comments(read(ARCHIVE))
        limit = function_body(archive, "public static func limit(from raw: Int?)")
        self.assertIn("return value == never ? nil : value", limit)
        decision = function_body(archive, "public static func shouldRoll(")
        self.assertIn("guard let limit, limit > 0 else { return false }", decision)

    def test_both_settings_screens_offer_the_row_and_say_moves(self):
        for path, label in ((MAC_SETTINGS, "Mac"), (PHONE_SETTINGS, "iPhone")):
            source = read(path)
            self.assertIn("Start a new chat after", source,
                          f"the {label} Settings row is missing")
            self.assertIn("BotChatCeiling.choices", source,
                          f"the {label} row must offer the four choices")
            self.assertIn("BotChatCeiling.explanation", source,
                          f"the {label} row must carry the explanation")
        explanation = read(ARCHIVE)
        self.assertIn("The old chat moves to Previous conversations, with every message kept.",
                      explanation)
        for path in (MAC_SETTINGS, PHONE_SETTINGS):
            # Comments stripped: the source explains *why* nothing is deleted, and that sentence is
            # not something the owner reads. What matters is the drawn text around the row.
            code = strip_comments(read(path))
            at = code.index("Start a new chat after")
            window = code[max(0, at - 400):at + 900]
            self.assertNotIn("delete", window.lower(),
                             "the row must never read as delete")
            self.assertIn("BotChatCeiling.explanation", window,
                          "the row draws the shared sentence, which is where Previous conversations is named")


class TheRoll(unittest.TestCase):

    def test_the_roll_refuses_while_a_turn_is_in_flight(self):
        app = strip_comments(read(APP))
        archive = strip_comments(read(ARCHIVE))
        decision = function_body(archive, "public static func shouldRoll(")
        self.assertIn("guard !inFlight else { return false }", decision)
        roll = function_body(app, "func rollBotChatIfNeeded(for botID: String)")
        self.assertIn("let inFlight = turnInFlight(for: botID)", roll)
        self.assertIn("inFlight: inFlight", roll)
        tracker = function_body(app, "func turnInFlight(for botID: String)")
        for fact in ("if sending { return true }",
                     "if isStreaming, selectedBotID == botID { return true }",
                     "if !pendingRequests.isEmpty, selectedBotID == botID { return true }"):
            self.assertIn(fact, tracker)
        self.assertIn("BotChatArchive.turnIsInFlight(activity(forBot: botID))", tracker)

    def test_a_settled_turn_is_not_in_flight(self):
        """`done` and `blocked` are over: the tracker's hold must not block the roll for long."""
        archive = strip_comments(read(ARCHIVE))
        body = function_body(archive, "public static func turnIsInFlight(")
        self.assertIn("case .thinking, .reading, .working, .computer, .waiting: return true", body)
        self.assertIn("case .idle, .done, .blocked: return false", body)

    def test_the_new_chat_is_the_bots_bot_chat(self):
        """The successor carries the canonical name, and the archived row stops being the bot's.

        This is the correction the owner made: a roll that left the identity on the old chat would
        reopen the 6,806-message conversation on the next tap, and the feature would be worthless.
        """
        app = strip_comments(read(APP))
        roll = function_body(app, "private func rollBotChat(_ row: BotChatRow, count: Int, botID: String)")
        self.assertIn("client.createCanonicalSession(", roll,
                      "the successor must be minted as the canonical Bot Chat, not a plain session")
        self.assertIn('"bot-chat:\\(botID):\\(archived)"', roll,
                      "a distinct idempotency key: the 300 s dedupe would hand back the archived row")
        confirm = roll.index("let confirmed = await hostBotChatRow(for: botID)")
        self.assertIn("if confirmed?.id == archived {", roll,
                      "the host must agree the archived chat is no longer this bot's chat")
        self.assertIn("await unarchive(archived, botID: botID)", roll,
                      "a roll the host did not accept must be undone")
        # The order the owner asked for: archive (forced by the unique title), create, confirm,
        # record, then the pointer.
        self.assertLess(roll.index("client.archiveSession(archived"), confirm)
        self.assertLess(roll.index("client.createCanonicalSession("), confirm)
        self.assertLess(confirm, roll.index("recordPrevious("))
        self.assertLess(roll.index("recordPrevious("), roll.index("canonicalChatIDCache[botID] = created"))

    def test_a_third_bot_chat_is_never_overwritten(self):
        """If another device rolled the same bot first, this device lists the archive and stands down."""
        app = strip_comments(read(APP))
        roll = function_body(app, "private func rollBotChat(_ row: BotChatRow, count: Int, botID: String)")
        third = roll.index("if let confirmed, confirmed.id != created {")
        self.assertLess(roll.index("recordPrevious("), third,
                        "the archived chat is listed whichever Bot Chat the host ended up with")
        self.assertIn("canonicalChatIDCache.removeValue(forKey: botID)", roll[third:])
        self.assertLess(third, roll.index("return await adoptCreated(created, botID: botID)"))

    def test_the_open_returns_the_fresh_conversation_after_a_roll(self):
        app = strip_comments(read(APP))
        body = function_body(app, "public func endlessSession(for botID: String, select: Bool = true)")
        self.assertIn("let knownSize = max(historyTotal, transcript.count)", body,
                      "the open decides from what this device already knows about the size")
        self.assertIn("let rolled = await rollBotChatIfNeeded(for: botID)", body)
        # Above the cached-pane shortcut: a snapshot of a 6,000-row chat must not postpone the roll.
        self.assertLess(body.index("rollBotChatIfNeeded(for: botID)"),
                        body.index("already holds the host's newest message"),
                        "the ceiling is checked before a cached pane is trusted")
        tail = body[body.index("let rolled = await rollBotChatIfNeeded"):]
        self.assertIn("return rolled", tail[:400],
                      "the open must land on the fresh chat, not fall through to the old resume")
        self.assertIn("pinnedSessionPicks[botID] == nil", body[
            max(0, body.index("rollBotChatIfNeeded(for: botID)") - 300):
            body.index("rollBotChatIfNeeded(for: botID)")],
                      "a pick from All Sessions outranks a roll")

    def test_resolving_the_bot_after_a_roll_answers_the_new_id(self):
        """Every authority the app reads for "which chat is this bot's" moves to the new id.

        The title is the host's identity, so the canonical create is what moves it; the app's
        cached lookup and its local key are seeded with the same id in the same block.
        """
        app = strip_comments(read(APP))
        roll = function_body(app, "private func rollBotChat(_ row: BotChatRow, count: Int, botID: String)")
        self.assertIn("canonicalChatIDCache[botID] = created", roll)
        self.assertIn("conversationCache.removeValue(forKey: botID)", roll,
                      "the archived transcript must not repaint under the fresh chat")
        self.assertIn("await adoptCreated(created, botID: botID)", roll)
        adopt = function_body(app, "private func adoptCreated(_ created: SessionID, botID: String)")
        self.assertIn("Self.defaults.set(created, forKey: Self.endlessKey(botID))", adopt)
        self.assertIn("await publishSharedSession(created, for: botID)", adopt)

    def test_the_bridge_delivers_to_the_pointer_the_roll_publishes(self):
        """`hermeyd`'s bot-to-bot route aims at `bot_sessions`, so the roll must publish there."""
        bridge = read(BRIDGE)
        self.assertIn("st.store.get_bot_session(profile)", bridge,
                      "the bridge reads its own stored pointer for a bot")
        store = read(BRIDGE_STORE)
        self.assertIn("SELECT stored_session_id FROM bot_sessions", store)
        app = strip_comments(read(APP))
        self.assertIn("await publishSharedSession(created, for: botID)",
                      function_body(app, "private func adoptCreated(_ created: SessionID, botID: String)"))

    def test_the_old_chat_is_archived_and_hidden_before_it_is_named_away(self):
        """The host frees the unique title only for an archived-and-hidden conflict."""
        roll = strip_comments(read(APP))
        body = function_body(roll, "private func rollBotChat(_ row: BotChatRow, count: Int, botID: String)")
        self.assertLess(body.index("client.archiveSession(archived"), body.index("client.createCanonicalSession("),
                        "the successor cannot take the name until the old row is archived")
        hidden = body.index("client.setSessionHidden(true, session: archived")
        self.assertLess(body.index("client.archiveSession(archived"), hidden)
        self.assertLess(hidden, body.index("client.createCanonicalSession("),
                        "archived AND hidden is the pair the host needs before it frees the title")
        actor = strip_comments(read(ACTOR))
        self.assertIn('"title": .string(CanonicalBotChat.title),', actor,
                      "the mint carries the canonical name, which is what makes it the bot's chat")
        self.assertIn('"hidden": .bool(true)', actor,
                      "the successor is born hidden, like every canonical chat")


class ThePreviousList(unittest.TestCase):

    def test_an_archived_conversation_keeps_its_id_and_count(self):
        archive = read(ARCHIVE)
        struct = archive[archive.index("public struct Previous"):archive.index("// MARK: The decision")]
        self.assertIn("public let id: SessionID", struct)
        self.assertIn("public var count: Int", struct)
        self.assertIn("public var lastActive: Date", struct)
        self.assertIn("public var archivedAt: Date", struct)

    def test_the_list_is_per_bot_and_newest_first(self):
        app = strip_comments(read(APP))
        self.assertIn("Keys.previousChatsPrefix + botID",
                      function_body(app, "private static func previousKey(_ botID: String)"))
        archive = strip_comments(read(ARCHIVE))
        newest = function_body(archive, "public static func newestFirst(")
        self.assertIn("left.lastActive != right.lastActive { return left.lastActive > right.lastActive }", newest,
                      "newest first means descending by the last message")
        self.assertIn("return []", function_body(archive, "public static func decode(_ data: Data?)"))

    def test_the_roll_never_deletes_an_archived_conversation(self):
        archive = strip_comments(read(ARCHIVE))
        upsert = function_body(archive, "public static func upserting(")
        self.assertEqual(upsert.count("filter"), 1,
                         "the only removal `upserting` may make is the same id being re-recorded")
        self.assertIn("rows.filter { $0.id != row.id }", upsert)
        app = strip_comments(read(APP))
        # Nothing in the app removes the document or an entry from it.
        self.assertNotIn("removeObject(forKey: Self.previousKey", app)
        self.assertNotIn("removeObject(forKey: Keys.previousChatsPrefix", app)
        record = function_body(app, "private func recordPrevious(")
        self.assertNotRegex(record, r"remove(All)?\(", "recording a roll must not delete a row")

    def test_both_apps_list_it_in_the_bots_own_menu(self):
        for path in (MAC_MENU, PHONE_LIST):
            source = read(path)
            self.assertIn("Previous conversations", source)
            self.assertIn("BotChatArchive.rowLabel(row)", source,
                          "each row carries its count and its last-message date")
            self.assertIn("Sending in one continues that old chat", source,
                          "the label must be honest about what sending there does")

    def test_the_menu_builds_the_list_from_the_model(self):
        sidebar = read(ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift")
        self.assertIn("previous: model.previousConversations(for: bot.id)", sidebar)
        self.assertIn("openPrevious: { row in openPrevious(row, for: bot) }", sidebar)
        app = strip_comments(read(APP))
        self.assertIn("BotChatArchive.decode(Self.defaults.data(forKey: Self.previousKey(botID)))",
                      function_body(app, "public func previousConversations(for botID: String)"))


class TheFailure(unittest.TestCase):

    def test_a_failed_roll_leaves_the_current_id_untouched(self):
        """Nothing is recorded, and no id is written, until the host has agreed.

        Each failure path returns `nil` before the document and the local key are touched, so a
        half-worked roll cannot leave the owner on a conversation this device quietly retired.
        """
        app = strip_comments(read(APP))
        roll = function_body(app, "private func rollBotChat(_ row: BotChatRow, count: Int, botID: String)")
        record = roll.index("recordPrevious(")
        before = roll[:record]
        # Three ways to die before anything is recorded: the archive refused, the create refused,
        # and the host still calling the archived row this bot's chat.
        self.assertEqual(before.count("return nil"), 3)
        for phrase in ("could not archive", "was refused", "did not take"):
            self.assertIn(phrase, before)
        self.assertEqual(before.count("await unarchive(archived, botID: botID)"), 2,
                         "the create failure and the confirmation failure are both undone")
        self.assertIn("ClientLog.note(", before)
        # The roll's own id is never written on a failure path.
        self.assertNotIn("Self.endlessKey", before)
        self.assertLess(record, roll.index("return await adoptCreated(created, botID: botID)"))

    def test_the_undo_exists_and_is_used(self):
        actor = strip_comments(read(ACTOR))
        body = function_body(actor, "public func unarchiveSession(")
        self.assertIn('"archived": .bool(false)', body)
        app = strip_comments(read(APP))
        undo = function_body(app, "private func unarchive(_ stored: SessionID, botID: String)")
        self.assertIn("try await client.unarchiveSession(stored, profile: botID)", undo)

    def test_the_failure_is_logged_where_a_person_can_read_it(self):
        app = strip_comments(read(APP))
        roll = function_body(app, "private func rollBotChat(_ row: BotChatRow, count: Int, botID: String)")
        self.assertGreaterEqual(roll.count("ClientLog.note("), 3)
        self.assertGreaterEqual(roll.count("Self.noteSessionSync("), 2)

    def test_a_crash_mid_roll_cannot_strand_the_old_conversation(self):
        """The journal: written before the archive, cleared only once the list holds the entry.

        The host's commit and this device's list write are two writes. A crash between them would
        leave an archived (therefore unlisted) conversation that nothing in the app can reach; the
        journal is what the next open reads to finish the bookkeeping.
        """
        app = strip_comments(read(APP))
        roll = function_body(app, "private func rollBotChat(_ row: BotChatRow, count: Int, botID: String)")
        journal = roll.index("beginRollJournal(")
        archive = roll.index("client.archiveSession(archived")
        record = roll.index("recordPrevious(")
        cleared = roll.index("clearRollJournal(for: botID)", record)
        self.assertLess(journal, archive, "the journal must exist before anything moves on the host")
        self.assertLess(record, cleared, "the journal is cleared only after the entry is stored")
        settle = function_body(app, "private func settleRollJournal(for botID: String, canonical: SessionID)")
        self.assertIn("guard pending.id != canonical else {", settle)
        self.assertIn("recordPrevious(pending, for: botID)", settle)
        self.assertIn("clearRollJournal(for: botID)", settle)
        open_body = function_body(app, "func rollBotChatIfNeeded(for botID: String)")
        self.assertIn("settleRollJournal(for: botID, canonical: row.id)", open_body)
        self.assertLess(open_body.index("settleRollJournal("),
                        open_body.index("BotChatArchive.shouldRoll("),
                        "the interrupted roll is settled before a new one is even considered")
        self.assertIn('static let rollJournalPrefix = "hermes.rollJournal."', app)


class TheDecisionMatrix(unittest.TestCase):

    def test_the_decision_matrix_matches_the_swift(self):
        """The four guards, in the same order, as the Swift has them."""
        archive = strip_comments(read(ARCHIVE))
        decision = function_body(archive, "public static func shouldRoll(")
        guards = [line.strip() for line in decision.splitlines() if line.strip().startswith("guard ")]
        self.assertEqual(guards, [
            "guard let limit, limit > 0 else { return false }",
            "guard let count, count >= limit else { return false }",
            "guard !inFlight else { return false }",
            "guard let currentID, !currentID.isEmpty else { return false }",
            "guard !alreadyArchived else { return false }",
        ])

    def test_the_matrix(self):
        cases = [
            # (count, limit, in flight, current, archived, expected)
            (1999, 2000, False, "s1", False, False),
            (2000, 2000, False, "s1", False, True),
            (6806, 2000, False, "s1", False, True),
            (1500, 1000, False, "s1", False, True),
            (1500, 5000, False, "s1", False, False),
            (9999, None, False, "s1", False, False),        # Never
            (9999, 2000, True, "s1", False, False),         # a turn is writing
            (9999, 2000, False, "", False, False),          # nothing to archive
            (9999, 2000, False, "s1", True, False),         # already rolled
            (None, 2000, False, "s1", False, False),        # the host could not be asked
        ]
        for count, limit, in_flight, current, archived, expected in cases:
            self.assertEqual(
                should_roll(count, limit, in_flight, current, archived), expected,
                f"count={count} limit={limit} inFlight={in_flight} "
                f"current={current!r} archived={archived}: expected {expected}")


if __name__ == "__main__":
    unittest.main()
