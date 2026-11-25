import Foundation

// MARK: - What the host answers
//
// Two verbs the engine has never had, owned by the host because it is the only place two devices
// meet (`hermeyd/src/messages.rs`):
//
//     POST /v1/messages/delete    {"bot", "session", "message_ids": [41, 42]}
//     POST /v1/messages/truncate  {"bot", "session", "from_message_id": 41}
//       -> 200 {"bot", "session", "retired": 2, "display_count": 104}
//       -> 409 {"error": "turn_running", "detail": …}   a turn is answering; nothing changed
//
// The rows are **retired**, not removed: the host writes `active=0, compacted=0`, which is what the
// engine's own rewind and undo write, so the transcript stops painting them on every device and the
// bytes stay in the database. Both routes close the engine's live copy first, so the resume that
// follows rebuilds from those rows — which is why the app can simply re-resume and be right.

/// The host's answer to a retire.
public struct MessageRetireResult: Sendable, Equatable {
    /// The bot whose conversation this is.
    public let bot: String
    /// The conversation, as the request named it (the stored id).
    public let session: String
    /// How many rows this call turned invisible. Never rows that were already retired.
    public let retired: Int
    /// The conversation's display size now — the same number a resume reports as `history.total`.
    public let displayCount: Int

    public init(bot: String, session: String, retired: Int, displayCount: Int) {
        self.bot = bot
        self.session = session
        self.retired = retired
        self.displayCount = displayCount
    }

    /// Decode leniently: a `retired` with no count is still a successful retire, so the count is
    /// defaulted rather than turned into a failure the owner would read as "it did not work".
    public static func decode(_ data: Data) -> MessageRetireResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bot = object["bot"] as? String,
              let session = object["session"] as? String
        else { return nil }
        return MessageRetireResult(bot: bot,
                                   session: session,
                                   retired: (object["retired"] as? NSNumber)?.intValue ?? 0,
                                   displayCount: (object["display_count"] as? NSNumber)?.intValue ?? 0)
    }
}

/// Why a retire could not be made. Only the write path has anything to say: it is the one a person
/// asked for and the one that must not look like it worked.
public enum MessageRetireError: Error, Sendable, Equatable, LocalizedError {
    /// This connection has no host route — an unpaired app, a preview, a test double. The verbs are
    /// then not offered at all (the menus ask `bridgeAvailable` first), so reaching this is a bug,
    /// not a state the owner should be shown.
    case noBridge
    /// The host answered and refused. Its own sentence is the one to show: `409 turn_running` says
    /// "wait for the turn to finish", a `404` says the message is not in that conversation.
    case refused(status: Int, detail: String?)
    /// The host answered something this client cannot read. Nothing was changed, so the safe thing
    /// is to say so rather than draw a conversation that may not match.
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .noBridge:
            return "This host cannot change messages. Update hermeyd on the host."
        case .refused(let status, let detail):
            if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return detail
            }
            return "The host refused the change (\(status)). Nothing was changed."
        case .unreadable:
            return "The host's answer could not be read, so nothing was changed."
        }
    }
}

// MARK: - The confirmation

/// A destructive message verb, waiting for the owner to confirm it.
///
/// One type for both shells and both verbs, because the *sentence* is the feature: a delete must say
/// what it retires before anything is sent, and "edit and resend" must say how many later messages
/// the rewrite takes with it. Neither shell spells its own wording — this is the one place.
public struct PendingMessageAction: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Retire this one message.
        case delete
        /// Retire this message and everything after it, then send the edited text as a new turn.
        case editAndResend
    }

    public let id: UUID
    public let kind: Kind
    /// The message's durable row id — the only id the host accepts.
    public let rowID: Int64
    /// The message's own words, for the composer (edit) and for the snippet (both).
    public let text: String
    /// How many messages are painted *after* this one. Counted from the transcript on this device
    /// when the verb was chosen, and stated in the sentence below — a silent destructive tap is the
    /// thing this type exists to prevent.
    public let trailing: Int

    public init(kind: Kind, rowID: Int64, text: String, trailing: Int) {
        self.id = UUID()
        self.kind = kind
        self.rowID = rowID
        self.text = text
        self.trailing = max(0, trailing)
    }

    /// What the card is called.
    public var title: String {
        switch kind {
        case .delete: return "Delete this message?"
        case .editAndResend: return "Edit and resend?"
        }
    }

    /// What will happen, in full. Written once so the Mac and the phone cannot disagree about it.
    public var message: String {
        let quote = "“\(snippet)”"
        switch kind {
        case .delete:
            return "\(quote) will be retired from this conversation on both devices. Nothing else "
                + "is touched, and the text stays in the host's database."
        case .editAndResend:
            let later = trailing == 0
                ? ""
                : " and the \(trailing == 1 ? "1 message" : "\(trailing) messages") after it"
            return "\(quote)\(later) will be retired when you send the edited text, which then "
                + "runs as a new turn. Retired messages stay in the host's database."
        }
    }

    /// The button that does it. Not "OK": the verb is on the button, so a hurried press still reads
    /// as the destructive thing it is.
    public var confirmTitle: String {
        switch kind {
        case .delete: return "Delete"
        case .editAndResend: return "Edit"
        }
    }

    /// The first line of the message, whitespace collapsed and bounded — a bubble can be 30,000
    /// characters, and a confirmation is one sentence with a quotation in it.
    public var snippet: String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "(no text)" }
        return collapsed.count > 80 ? String(collapsed.prefix(80)) + "…" : collapsed
    }
}
