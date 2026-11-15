import Foundation

/// One finding inside a bot's conversation.
///
/// The list's search used to answer with *bot names*. What a person remembers is a phrase, so a
/// finding says which bot, when, who wrote it, and the line around the match — the four things
/// needed to recognise the conversation before opening it.
public struct BotSearchHit: Identifiable, Hashable, Sendable {
    public let profile: String
    public let sessionID: String
    public let role: String
    /// When the message was written, as the host timestamps it.
    public let at: Date
    public let snippet: String
    /// The matched text as it was written, for highlighting.
    public let match: String
    /// Stable enough for `List`: two hits in the same session at the same instant are rare, and a
    /// duplicate id would cost a row rather than break the screen.
    public var id: String { "\(profile)|\(sessionID)|\(at.timeIntervalSince1970)|\(snippet.prefix(24))" }

    public var isOwner: Bool { role == "user" }

    public init(profile: String, sessionID: String, role: String, at: Date,
                snippet: String, match: String) {
        self.profile = profile
        self.sessionID = sessionID
        self.role = role
        self.at = at
        self.snippet = snippet
        self.match = match
    }
}

/// A page of findings, as the host answers it.
public struct BotSearchPage: Hashable, Sendable {
    public let hits: [BotSearchHit]
    /// How many the host found in total, for "12 matches" rather than "12 shown".
    public let total: Int
    public let more: Bool

    public static let empty = BotSearchPage(hits: [], total: 0, more: false)

    public init(hits: [BotSearchHit], total: Int, more: Bool) {
        self.hits = hits
        self.total = total
        self.more = more
    }

    public static func decode(_ data: Data) throws -> BotSearchPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.notADocument
        }
        let rows = root["results"] as? [[String: Any]] ?? []
        let hits: [BotSearchHit] = rows.compactMap { row in
            guard let profile = row["profile"] as? String,
                  let snippet = row["snippet"] as? String else { return nil }
            let stamp = (row["at"] as? Double) ?? Double(row["at"] as? Int ?? 0)
            return BotSearchHit(profile: profile,
                                sessionID: (row["session_id"] as? String) ?? "",
                                role: (row["role"] as? String) ?? "user",
                                at: Date(timeIntervalSince1970: stamp),
                                snippet: snippet,
                                match: (row["match"] as? String) ?? "")
        }
        return BotSearchPage(hits: hits,
                             total: (root["total"] as? Int) ?? hits.count,
                             more: (root["more"] as? Bool) ?? false)
    }

    public enum Failure: LocalizedError {
        case notADocument
        public var errorDescription: String? { "The host's search answer was not a document." }
    }
}

/// One bot speaking to another, as the bridge recorded it.
public struct BotTransfer: Identifiable, Hashable, Sendable {
    public let fromProfile: String?
    public let fromLabel: String
    public let toProfile: String
    public let text: String
    public let at: Date

    public var id: String { "\(fromProfile ?? fromLabel)|\(toProfile)|\(at.timeIntervalSince1970)|\(text.prefix(16))" }

    public init(fromProfile: String?, fromLabel: String, toProfile: String, text: String, at: Date) {
        self.fromProfile = fromProfile
        self.fromLabel = fromLabel
        self.toProfile = toProfile
        self.text = text
        self.at = at
    }

    public static func decodeList(_ data: Data) throws -> [BotTransfer] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BotSearchPage.Failure.notADocument
        }
        let rows = root["entries"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let to = row["to_profile"] as? String, let text = row["text"] as? String else {
                return nil
            }
            let stamp = (row["at"] as? Double) ?? 0
            return BotTransfer(fromProfile: row["from_profile"] as? String,
                               fromLabel: (row["from_label"] as? String) ?? "assistant",
                               toProfile: to,
                               text: text,
                               at: Date(timeIntervalSince1970: stamp))
        }
    }
}

/// The label a bot-to-bot message carries in the target's own conversation:
/// `Assistant (cody) → Ops: the words`.
///
/// Parsing it is how a row written by a *bot* is told apart from one the owner typed — the
/// transcript stores both as a user row. The legacy label (no profile in brackets) still parses, so
/// messages written before this change keep their attribution; only the sender's profile is unknown.
public struct BotMessageLabel: Hashable, Sendable {
    public let senderLabel: String
    public let senderProfile: String?
    public let targetLabel: String
    public let body: String

    /// Prefix → the parsed label, or `nil` when this row was not written by another bot.
    public static func parse(_ text: String) -> BotMessageLabel? {
        // "Assistant (cody) → Ops: body" / "Assistant → Ops: body"
        guard let arrow = text.range(of: " → ") else { return nil }
        let sender = String(text[text.startIndex..<arrow.lowerBound])
        let rest = String(text[arrow.upperBound...])
        guard let colon = rest.range(of: ": ") else { return nil }
        let target = String(rest[rest.startIndex..<colon.lowerBound])
        let body = String(rest[colon.upperBound...])

        var senderLabel = sender
        var senderProfile: String?
        if let open = sender.firstIndex(of: "("),
           let close = sender.lastIndex(of: ")"), open < close {
            let inside = String(sender[sender.index(after: open)..<close])
            let name = String(sender[sender.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            // A profile id is the CLI's shape: lowercase, digits, dashes and underscores.
            if !inside.isEmpty, !name.isEmpty,
               inside.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_" }) {
                senderProfile = inside
                senderLabel = name
            }
        }
        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
        guard !senderLabel.isEmpty, !trimmedTarget.isEmpty, !body.isEmpty else { return nil }
        return BotMessageLabel(senderLabel: senderLabel,
                               senderProfile: senderProfile,
                               targetLabel: trimmedTarget,
                               body: body)
    }

    /// What the recipient's chat says above the words: `Message from <face> Cody`.
    public var incomingTitle: String {
        "Message from \(senderProfile.map { $0.capitalized } ?? senderLabel)"
    }

    /// What the sender's chat says: `Messaged <face> Aria`. The profile id is the stable name to
    /// show when the display name is not known yet.
    public var outgoingTitle: String { "Messaged \(targetLabel)" }
}
