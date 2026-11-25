import Foundation

// MARK: - The ceiling on one Bot Chat

/// At what size a bot's one endless conversation is rolled over, and what the roll leaves behind.
///
/// One conversation per bot per device is the whole product idea (`docs/ENDLESS-CHAT.md`), and it
/// has no ceiling of its own: `cody`'s reached **6,806 messages / 4.5 MB**, and a resume of it takes
/// longer than the app's own 120 s deadline, so the chat stopped opening at all. Compaction is not a
/// substitute — it shrinks what the model *reads*, not what the transcript *holds*, so the frame
/// keeps growing.
///
/// So the conversation is rolled: at the ceiling the host is told to archive the chat it calls
/// `Bot Chat`, which frees the name, and a fresh canonical chat is minted. The archived one keeps
/// every message, its id and its count, and is listed under the bot's **Previous conversations**.
/// Nothing is deleted, ever: this file has no delete, and the roll has nowhere to put one.
///
/// Everything here is a pure function of values it is handed — no clock, no defaults, no socket —
/// so the decision, the ordering and the encoding are testable without a device.
public enum BotChatArchive {

    /// The ceiling a fresh install rolls at, and the only 2,000 in the codebase.
    ///
    /// This is a *default value*, not the ceiling: the owner picks the real one in Settings
    /// ("Start a new chat after", 1,000 / 2,000 / 5,000 / Never), stored per app in `UserDefaults`,
    /// and every read of the ceiling goes through that setting (see ``BotChatCeiling``). A guard
    /// test asserts the literal appears exactly once, here.
    public static let defaultLimit = 2000

    /// One conversation that has been rolled out of the way.
    ///
    /// Written at the moment the roll succeeds and never removed: the id is what `session.resume`
    /// accepts, so the transcript stays openable for as long as the host keeps the row, and the
    /// count is the host's own figure from the moment it was archived, refreshed from the host's
    /// resume total whenever the owner opens it again.
    public struct Previous: Codable, Hashable, Sendable, Identifiable {
        /// The stored session id — the durable key, not a runtime id (see `EndlessSessionPolicy`).
        /// Immutable on purpose: an archived conversation that changed its id would be a different
        /// conversation, and this record is the only index of the ones the host no longer lists.
        public let id: SessionID
        /// How many messages the host held for it when it was archived (its own count, see
        /// `AppModel`). Refreshed from a later resume of the same conversation.
        public var count: Int
        /// The host's stamp for its newest message — the date a "last message" line shows.
        public var lastActive: Date
        /// When this device rolled it over. Used only to break ties between two chats that claim the
        /// same `lastActive`, so the list's order is total and stable.
        public var archivedAt: Date

        public init(id: SessionID, count: Int, lastActive: Date, archivedAt: Date = Date()) {
            self.id = id
            self.count = count
            self.lastActive = lastActive
            self.archivedAt = archivedAt
        }
    }

    // MARK: The decision

    /// Whether this conversation has reached the chosen ceiling and may be rolled **now**.
    ///
    /// All four facts are required, and each one is the reason for a reported failure:
    ///
    /// * `count` is at or past `limit` — and `nil` (the host could not be asked) never rolls. A
    ///   roll started on a guessed number is a roll that can strand a live conversation.
    ///   `limit` is the owner's setting as ``BotChatCeiling`` sanitises it; `nil` means **Never**,
    ///   which turns the roll off entirely and leaves the windowed resume as the only protection.
    /// * nothing is in flight. A turn is writing into the conversation this would archive, and
    ///   archiving the row under a running turn loses the turn's own rows.
    /// * there is a conversation to archive (an empty `currentID` is a bot that has none yet).
    /// * this very conversation has not been rolled already — answered from the list the roll
    ///   writes, so the guard survives a relaunch and cannot disagree with what the owner sees.
    public static func shouldRoll(count: Int?, limit: Int?, inFlight: Bool,
                                  currentID: SessionID?,
                                  alreadyArchived: Bool) -> Bool {
        guard let limit, limit > 0 else { return false }
        guard let count, count >= limit else { return false }
        guard !inFlight else { return false }
        guard let currentID, !currentID.isEmpty else { return false }
        guard !alreadyArchived else { return false }
        return true
    }

    /// Whether a bot's face means a turn is still writing.
    ///
    /// `done` is *not* in flight: the tracker holds it for a few seconds after a turn settles, which
    /// is exactly the moment a roll is safe. `blocked` is over too — the run ended in an error.
    /// `waiting` is, because the host is holding a half-finished turn open for an approval.
    public static func turnIsInFlight(_ activity: BotAvatarActivity) -> Bool {
        switch activity {
        case .thinking, .reading, .working, .computer, .waiting: return true
        case .idle, .done, .blocked: return false
        }
    }

    // MARK: The list

    /// The list as the owner reads it: newest conversation first.
    ///
    /// `lastActive` descending, then `archivedAt` descending, then `id` — a total order, so two rows
    /// stamped in the same second cannot swap places between two reads of the same document.
    public static func newestFirst(_ rows: [Previous]) -> [Previous] {
        rows.sorted { left, right in
            if left.lastActive != right.lastActive { return left.lastActive > right.lastActive }
            if left.archivedAt != right.archivedAt { return left.archivedAt > right.archivedAt }
            return left.id > right.id
        }
    }

    /// Add one conversation to the list, keeping every one already there.
    ///
    /// The only removal is a row with the **same id** — re-rolling a conversation that is already
    /// archived would otherwise list it twice. A different id is never dropped: that is the whole
    /// promise ("no cap on how many archived conversations exist"), and a guard test reads this
    /// function to prove it.
    public static func upserting(_ row: Previous, into rows: [Previous]) -> [Previous] {
        newestFirst(rows.filter { $0.id != row.id } + [row])
    }

    /// One row's numbers, re-read from the host. Never touches its id or its place in the list.
    public static func refreshing(_ rows: [Previous], id: SessionID,
                                  count: Int, lastActive: Date?) -> [Previous] {
        rows.map { row in
            guard row.id == id else { return row }
            var refreshed = row
            refreshed.count = count
            if let lastActive { refreshed.lastActive = lastActive }
            return refreshed
        }
    }

    // MARK: The document

    public static func decode(_ data: Data?) -> [Previous] {
        guard let data, !data.isEmpty,
              let rows = try? JSONDecoder().decode([Previous].self, from: data) else { return [] }
        return newestFirst(rows)
    }

    public static func encode(_ rows: [Previous]) -> Data? {
        try? JSONEncoder().encode(newestFirst(rows))
    }

    // MARK: The label

    /// "2026-11-14 · 2,140 messages" — the line both apps' menus draw for one archived chat.
    ///
    /// Here rather than in each app so the Mac and the phone cannot word the same row differently,
    /// and so a test can pin the shape without a view. The formatters are built per call: this runs
    /// when a menu opens, not in a list's body, and a static `DateFormatter` is shared mutable state.
    public static func rowLabel(_ row: Previous) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return "\(day.string(from: row.lastActive)) · \(countLabel(row.count))"
    }

    public static func countLabel(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let number = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return count == 1 ? "\(number) message" : "\(number) messages"
    }
}

// MARK: - The setting

/// **Settings → "Start a new chat after"**: when a bot's one conversation is rolled over.
///
/// The owner's choice, stored per app under one `UserDefaults` key — not on the host and not in a
/// card, because it is a preference about this app's behaviour, and a phone that wants a smaller
/// chat than the Mac is entitled to one. `AppModel.botChatCeiling` is the property both apps' rows
/// write; every read of a ceiling goes through it, so a change takes effect on the next open with no
/// restart.
public enum BotChatCeiling {

    /// The key both apps read and write. One key, one document.
    public static let key = "hermey.botChatCeiling"

    /// `Never`: no ceiling at all. The roll never fires and the windowed resume is the only
    /// protection against a slow open. Deliberately a stored value rather than a missing one — a
    /// default that silently reappears on the next launch is not a choice.
    public static let never = 0

    /// The row's choices, in the order it draws them. `defaultLimit` is the shipped default and the
    /// only place 2,000 is written down; this list refers to it rather than repeating it.
    public static var choices: [Int] { [1000, BotChatArchive.defaultLimit, 5000, never] }

    /// What the stored value means, with anything unrecognised treated as the default.
    ///
    /// A key written by a newer build, a corrupted value or a string that is not a number must not
    /// turn the roll off *or* set it to an absurd ceiling: the default is the only answer that is
    /// safe in both directions.
    public static func sanitised(_ raw: Int?) -> Int {
        guard let raw, choices.contains(raw) else { return BotChatArchive.defaultLimit }
        return raw
    }

    /// The value the roll reads: the choice, with `never` expressed as `nil` ("no ceiling"), which
    /// is what ``BotChatArchive/shouldRoll(count:limit:inFlight:currentID:alreadyArchived:)``
    /// requires to stay quiet.
    public static func limit(from raw: Int?) -> Int? {
        let value = sanitised(raw)
        return value == never ? nil : value
    }

    /// One choice, as the settings row draws it. "Never" says what it costs, because a row that only
    /// says "Never" reads as a setting that does nothing.
    public static func label(_ raw: Int) -> String {
        raw == never ? "Never" : BotChatArchive.countLabel(raw)
    }

    /// The sentence under the row. It says **moves**, never *delete*: the archived conversation is
    /// kept in full and stays one tap away, and a control that suggested otherwise would be a lie
    /// about the owner's own history.
    public static let explanation =
        "A bot's conversation starts fresh once it reaches this many messages. "
        + "The old chat moves to Previous conversations, with every message kept."
}
