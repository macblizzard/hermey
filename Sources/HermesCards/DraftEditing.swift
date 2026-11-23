import Foundation

/// Which part a draft's buttons play.
///
/// The card owns its buttons' words, so the role is read from the *label the card wrote* — never
/// from a fixed index and never from `send`, which is a transport token (`SEND c-7e`) that a bot
/// can spell however it likes. The first word decides: "Edit", "edit draft" and "EDIT" are all the
/// edit button; "Send", "send it" and "Send email" are all the send.
///
/// A live draft draws neither of those labels — its fields are always editable, and its two
/// buttons are Send and Discard — so the only thing this type is still used for is recognising the
/// token that should lead the composed block: an `Edit` action carries no send worth posting.
public enum DraftActionRole: Sendable, Equatable {
    case edit
    case send
    case other

    public init(label: String) {
        let word = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let head = word.components(separatedBy: " ").first ?? word
        switch head {
        case "edit": self = .edit
        case "send": self = .send
        default: self = .other
        }
    }
}

public extension Card.Action {
    /// What this button means on a draft.
    var draftRole: DraftActionRole { DraftActionRole(label: label) }
}

public extension Card {
    /// The action whose `send` token leads the block a typed draft posts.
    ///
    /// The file's words vary — "Send", "Approve", "Send email" — and the live card ignores them
    /// for its two labels, but the agent must still be handed the card's own intent. So the choice
    /// is positional and by emphasis, not by label: a primary action first, then the first action
    /// that is not destructive, never the `Edit` action (it only ever meant "let me type", which
    /// is now what the card already is).
    ///
    /// `nil` when the file wrote no usable action at all — the send is then the instruction alone,
    /// which is still a complete thing to ask for.
    var draftSendAction: Action? {
        let candidates = actions.filter { $0.draftRole != .edit }
        if let primary = candidates.first(where: { $0.style == .primary }) {
            return primary
        }
        return candidates.first(where: { $0.style != .danger }) ?? candidates.first
    }
}

/// The owner's draft, while he is the one typing it.
///
/// A plain value, deliberately: the editable fields are UI state and nothing else. There is no
/// write back to the bot's file, no preferences store, no round trip — the card the host wrote is
/// never mutated, so what the owner typed can be dropped at any time and the original draft is
/// still there.
public struct DraftEditor: Sendable, Equatable {
    public var to: String
    public var cc: String
    public var subject: String
    public var body: String

    /// The line that tells the agent to paste the draft it is given rather than paraphrase it.
    public static let instruction = "send this email exactly as written:"

    public init(to: String = "", cc: String = "", subject: String = "", body: String = "") {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
    }

    /// The draft as the card drew it. A field the file left out is an empty field, which is what
    /// the owner sees and can type into.
    public init(email: Card.Email) {
        self.init(to: email.to ?? "",
                  cc: email.cc ?? "",
                  subject: email.subject ?? "",
                  body: email.bodyText ?? "")
    }

    /// The editor this card can be typed into, or `nil` when it cannot: only a `draft-email` with
    /// an `email` block is a draft, and a resolved card is answered — its note replaces its fields.
    public static func editor(for card: Card) -> DraftEditor? {
        guard card.kind == .draftEmail, let email = card.email, !card.isResolved else { return nil }
        return DraftEditor(email: email)
    }

    /// The turn a typed draft sends.
    ///
    /// `lead` is the card's own `send` token, kept verbatim as the first line so the agent still
    /// sees the intent (and the card id the token names). The rest is one deterministic block — no
    /// JSON, no quoting, nothing to interpret: headers, a `---` rule, then the message. `Cc:` is
    /// omitted when empty, because a blank recipient is not a fact about the draft.
    public func composedSend(lead: String?) -> String {
        var lines: [String] = []
        if let lead = lead?.trimmingCharacters(in: .whitespacesAndNewlines), !lead.isEmpty {
            lines.append(lead)
        }
        lines.append(DraftEditor.instruction)
        lines.append("To: " + DraftEditor.singleLine(to))
        let copied = DraftEditor.singleLine(cc)
        if !copied.isEmpty {
            lines.append("Cc: " + copied)
        }
        lines.append("Subject: " + DraftEditor.singleLine(subject))
        lines.append("---")

        let message = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = lines.joined(separator: "\n")
        // A draft with no body is still a sendable draft; it just ends after the rule.
        return message.isEmpty ? header : header + "\n" + message
    }

    /// A header field is one line by definition: a pasted line break would move the rest of the
    /// draft into the wrong header (or into the body) and make the block ambiguous.
    private static func singleLine(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
