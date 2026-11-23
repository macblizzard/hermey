import Foundation

// MARK: - The key

/// One message's identity for a reaction, in one place.
///
/// Both apps used to build this string themselves — `TranscriptRowView.reactionKey` on the Mac and
/// `MobileTranscript.reactionKey` on the phone — from the same four parts, which is why a reaction
/// made on one device was never found by the other: they were persisted locally, and even the
/// spelling of the key was each shell's private business.
///
/// The parts:
///   * `host` — the paired host's label. A device can be paired to more than one host, and the two
///     hosts' bots are different bots even when they share a name.
///   * `bot` — the Hermes profile whose conversation this is.
///   * `session` — the conversation. The *stored* id: the one the session list shows and a later
///     resume accepts.
///   * `message` — the message half, from ``message(rowID:entryID:)``.
///
/// `storageKey` is length-prefixed rather than joined with a separator, so two different
/// four-tuples cannot produce one string even when an identifier contains the separator (a session
/// id containing `-`, a bot named `row`). That rule is unchanged from what both apps already
/// wrote, so a device's existing local reactions keep matching after the upgrade.
public struct ReactionKey: Hashable, Sendable {
    public let host: String
    public let bot: String
    public let session: String
    /// `row:<rowID>` or `live:<entry.id>` — see ``message(rowID:entryID:)``.
    public let message: String

    public init(host: String, bot: String, session: String, message: String) {
        self.host = host
        self.bot = bot
        self.session = session
        self.message = message
    }

    /// The message half of the key.
    ///
    /// `row:<rowID>` when the host gave the row a durable id, because that is what survives a
    /// reload; `live:<entry.id>` while a row has no host id yet, so a message that is still
    /// streaming can be reacted to. Both apps already used exactly this, and the host validates the
    /// same two prefixes — a key it cannot place is refused rather than stored under a name nothing
    /// will ever look up.
    /// `Int64?` because that is what the transcript row carries; converting at the call site would put
    /// a `.map(Int.init)` in two apps and a widening cast in the one place that owns the rule.
    public static func message(rowID: Int64?, entryID: String) -> String {
        if let rowID { return "row:\(rowID)" }
        return "live:\(entryID)"
    }

    /// The device-local identity: what `@AppStorage` held before the host owned reactions.
    public var storageKey: String {
        [host, bot, session, message]
            .map { "\($0.utf8.count):\($0)" }
            .joined()
    }

    /// What the host stores it under. The host scopes a reaction by bot and session (they are in
    /// the query), so the message half is the whole key on that side — which is what makes a Mac
    /// and a phone agree even when their labels for the host differ.
    public var wireMessage: String { message }

    /// Every key in one conversation starts with this. The message half is last and is itself
    /// length-prefixed, so a prefix match cannot reach another conversation.
    public static func conversationPrefix(host: String, bot: String, session: String) -> String {
        [host, bot, session]
            .map { "\($0.utf8.count):\($0)" }
            .joined()
    }

    /// The four parts back out of a storage key, or `nil` when the string is not one.
    ///
    /// Needed by the one-time import: the device's local document is keyed by storage key, and the
    /// host needs the message half to accept a write. Parsed by **UTF-8 bytes**, because that is
    /// what `storageKey` counted — and it is what makes a bot named `row` and a session containing
    /// `-` unambiguous, rather than splitting on a separator.
    public static func parse(_ storageKey: String) -> ReactionKey? {
        let bytes = Array(storageKey.utf8)
        var offset = 0
        var parts: [String] = []
        for _ in 0..<4 {
            guard let colon = bytes[offset...].firstIndex(of: UInt8(ascii: ":")),
                  colon > offset else { return nil }
            let digits = bytes[offset..<colon]
            // A bare number, no sign and no spaces: a length, not an expression.
            guard digits.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let length = Int(String(decoding: digits, as: UTF8.self)) else { return nil }
            let start = colon + 1
            guard start + length <= bytes.count else { return nil }
            parts.append(String(decoding: bytes[start..<(start + length)], as: UTF8.self))
            offset = start + length
        }
        guard offset == bytes.count else { return nil }
        return ReactionKey(host: parts[0], bot: parts[1], session: parts[2], message: parts[3])
    }

    /// Whether the host would accept this message half (`row:`/`live:` and a bounded id).
    public static func isValidMessage(_ message: String) -> Bool {
        guard !message.isEmpty, message.utf8.count <= 160 else { return false }
        let rest: Substring
        if let tail = message.dropPrefixIfPresent("row:") {
            rest = tail
        } else if let tail = message.dropPrefixIfPresent("live:") {
            rest = tail
        } else {
            return false
        }
        guard !rest.isEmpty else { return false }
        return rest.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber
                                  || "-_.:".contains(character))
        }
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}

// MARK: - One reaction

/// One message's reaction: the emoji, and the device that set it.
public struct Reaction: Sendable, Equatable {
    public let emoji: String
    /// The device's own name, as it named itself ("Mo's Mac", "iPhone"). It is what the *other*
    /// device can show, so a reaction reads as somebody's rather than as an anonymous glyph.
    public let by: String

    public init(emoji: String, by: String) {
        self.emoji = emoji
        self.by = by
    }

    /// The `{"emoji": …, "by": …}` object the host answers with, decoded leniently: a row without
    /// an emoji is not a reaction at all, so it is dropped rather than drawn empty.
    public static func decode(_ value: Any?) -> Reaction? {
        guard let object = value as? [String: Any],
              let emoji = object["emoji"] as? String,
              !emoji.isEmpty else { return nil }
        return Reaction(emoji: emoji, by: object["by"] as? String ?? "")
    }
}

/// Why a reaction could not be written or read. Only the write path has anything to say: it is the
/// one the app undoes, and the one a person can be told about.
public enum ReactionSyncError: Error, Sendable, Equatable, LocalizedError {
    /// This connection has no bridge — an unpaired app, a preview, a test double. Not a failure:
    /// the app keeps behaving exactly as it did before the host owned reactions.
    case noBridge
    /// The host refused the write (`422 bad_emoji`, `bad_message`, …) or was not reachable.
    case refused(status: Int, detail: String?)

    public var errorDescription: String? {
        switch self {
        case .noBridge:
            return "this connection has no host to keep reactions on"
        case .refused(let status, let detail):
            if let detail, !detail.isEmpty { return detail }
            return "the host refused the reaction (\(status))"
        }
    }
}

// MARK: - The device-local copy

/// The `@AppStorage` document both apps used to write, kept for the one job it still has: the
/// unpaired app.
///
/// An unpaired app has no host to agree with, so it must behave exactly as it did before reactions
/// were synced — same storage key, same JSON shape, same "one emoji per message". Nothing here is
/// ever merged back over a host's answer except the one-time import described in `AppModel`.
///
/// The storage key is the app's own (`mac.messageReactions.v1` / `mobile.messageReactions.v1`), so
/// an upgrade finds the reactions a device already had instead of losing them.
public struct ReactionLocalStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    /// The app's own local document key. Callers pass their historical one; this is the fallback for
    /// a caller with no opinion (a test, a preview).
    public static let defaultKey = "hermes.messageReactions.v1"

    /// Every local reaction, keyed by ``ReactionKey/storageKey``.
    public func all() -> [String: String] {
        guard let text = defaults.string(forKey: key),
              let data = text.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return values
    }

    /// The local reactions of one conversation. Its keys carry the conversation as a length-prefixed
    /// prefix, so no other conversation's entry can match.
    public func entries(forConversation prefix: String) -> [String: String] {
        all().filter { $0.key.hasPrefix(prefix) }
    }

    public func emoji(for storageKey: String) -> String? {
        all()[storageKey]
    }

    /// Set one emoji, or remove it with `nil`. Writes the whole document, exactly as the views did.
    public func set(_ emoji: String?, for storageKey: String) {
        var values = all()
        if let emoji, !emoji.isEmpty {
            values[storageKey] = emoji
        } else {
            values.removeValue(forKey: storageKey)
        }
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: key)
    }
}
