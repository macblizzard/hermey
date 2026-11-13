import Foundation

/// One "a bot wrote something you are not reading" event, already decided.
///
/// Both shells need the same answer to the same three questions — *is this bot the one on
/// screen*, *is this bot quiet*, *how many things are waiting* — and the answer must not be
/// written twice, because two apps disagreeing about when a banner is legitimate is exactly the
/// kind of drift that reads as "notifications are random". The decision lives here; the shells
/// only own the platform delivery (`UNUserNotificationCenter`, the Dock tile, the app icon badge).
public struct ReplyNotification: Equatable, Sendable {
    /// The profile name the host uses — what a tap has to select.
    public let botID: String
    /// What the banner's title says: the bot's display name, never the raw profile id when one exists.
    public let botName: String
    /// The newest reply, flattened to its first line and clipped.
    public let body: String
    /// Everything waiting on this device at the moment the event was raised (bots + rooms).
    public let badge: Int
    /// The host's own timestamp for that reply, which is what makes the event identifiable.
    public let at: Date

    public init(botID: String, botName: String, body: String, badge: Int, at: Date) {
        self.botID = botID
        self.botName = botName
        self.body = body
        self.badge = badge
        self.at = at
    }

    /// One host message, one banner.
    ///
    /// The same reply reaches the model through more than one door — the bridge's previews
    /// sweep and, for the open session, `message.complete` — so the identity is the *host's*
    /// timestamp rather than "now", and a second report of the same message is dropped instead
    /// of buzzing the user twice.
    public var identity: String { "\(botID)#\(Int(at.timeIntervalSince1970))" }
}

/// The one place that decides whether a reply earns a banner, and what the badge reads.
public enum ReplyNotificationPolicy {

    /// iOS and macOS both draw three digits on an icon badge; past that the Dock prints `99+`
    /// anyway, so the count is clamped rather than lying about how many are waiting.
    public static let badgeCeiling = 99

    /// A banner body is one line. Longer than this and macOS truncates at a different point
    /// than iOS, so the two devices would show different sentences for the same reply.
    public static let bodyLimit = 160

    /// A reply deserves a banner when notifications are on, the bot is not the one on screen,
    /// and the user has not quieted that bot.
    ///
    /// `visibleBotID` is the literal reading of "not currently reading": a bot whose transcript
    /// is on screen has already told the user everything a banner would.
    public static func shouldDeliver(botID: String,
                                     visibleBotID: String?,
                                     enabled: Bool,
                                     muted: Set<String>) -> Bool {
        guard enabled, !botID.isEmpty else { return false }
        guard botID != visibleBotID else { return false }
        return !muted.contains(botID)
    }

    /// What the Dock tile and the app icon show: every waiting turn, bots and rooms together,
    /// because the user is looking at one number and it should be the whole truth.
    public static func badge(unread: [String: Int],
                            rooms: [String: Int] = [:],
                            ceiling: Int = badgeCeiling) -> Int {
        let bots = unread.values.reduce(0) { $0 + max(0, $1) }
        let rooms = rooms.values.reduce(0) { $0 + max(0, $1) }
        return min(max(0, bots + rooms), max(0, ceiling))
    }

    /// The banner's second line: the reply's first non-blank line, clipped, with the same
    /// ellipsis on both platforms.
    public static func body(_ line: String?, fallback: String = "New reply") -> String {
        guard let line else { return fallback }
        let first = line
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let first, !first.isEmpty else { return fallback }
        guard first.count > bodyLimit else { return first }
        let head = first.prefix(bodyLimit).trimmingCharacters(in: .whitespaces)
        return head + "…"
    }

    /// The banner's title: what the bot list calls it.
    public static func title(botName: String?, botID: String) -> String {
        if let botName, !botName.trimmingCharacters(in: .whitespaces).isEmpty { return botName }
        guard !botID.isEmpty else { return "Hermes" }
        return botID.prefix(1).uppercased() + botID.dropFirst()
    }
}
