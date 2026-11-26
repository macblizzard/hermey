import Foundation

/// One line in the pet's chat: something the owner typed, or something the bot answered.
///
/// The pet's conversation is not the bot's conversation. It has its own bounded session on the host
/// (the `desktop-pet` ask route) and its own little transcript here, and the two never share a row:
/// what the owner says to a pet is a short question, not a turn in the chat he reads on the Mac.
public struct PetMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case owner
        case bot
    }

    public let id: UUID
    public let role: Role
    public let text: String
    /// When it was said. Kept so a stored transcript keeps its order even if a file is ever merged;
    /// nothing in the UI reads it.
    public let at: Date

    public init(id: UUID = UUID(), role: Role, text: String, at: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
    }
}

/// A pet's whole chat, as a value.
///
/// One rule lives here and nowhere else: **a conversation is at most twenty messages**, the owner's
/// and the bot's counted together. The cap is on messages rather than on exchanges because that is
/// what the owner asked for, and because a failed turn leaves one message without its pair — a limit
/// counted in exchanges would have to guess what a half-exchange is.
///
/// A question is only allowed when its answer still fits too: at 18 messages the field closes, so a
/// nineteenth question cannot arrive with nowhere for the twentieth message to go. That is why
/// `isFull` is `!canAddExchange` and not `count == maxMessages` — the two differ by exactly one
/// question, and this is the side that never eats a reply.
public struct PetConversation: Codable, Equatable, Sendable {

    /// The one number. Twenty messages, both roles included.
    public static let maxMessages = 20

    public private(set) var messages: [PetMessage]

    public init(messages: [PetMessage] = []) {
        // A file from a future or a hand-edited one cannot widen the cap: the newest messages are
        // the ones worth keeping, and the rule holds on the way in as well as on the way out.
        self.messages = Array(messages.suffix(Self.maxMessages))
    }

    public var count: Int { messages.count }
    public var isEmpty: Bool { messages.isEmpty }

    public var lastBotMessage: PetMessage? { messages.last { $0.role == .bot } }
    public var lastOwnerMessage: PetMessage? { messages.last { $0.role == .owner } }

    /// Whether one more question **and its answer** fit in the remaining room.
    ///
    /// This is the rule the compose field is disabled by. Eighteen messages means two slots left,
    /// which is one question and one answer: the last exchange this conversation can hold.
    public var canAddExchange: Bool { messages.count + 2 <= Self.maxMessages }

    /// No room for another exchange. The field greys out and `New` is the way forward.
    public var isFull: Bool { !canAddExchange }

    /// Append one message. Returns false — and changes nothing — at the cap.
    @discardableResult
    public mutating func append(_ message: PetMessage) -> Bool {
        guard messages.count < Self.maxMessages else { return false }
        messages.append(message)
        return true
    }

    /// Start over. The only thing that empties a conversation; a dismissal never does.
    public mutating func reset() {
        messages.removeAll()
    }
}

/// How much of a bot's answer the balloon shows.
///
/// The pet's ask carries the rule the model is asked to obey (a sentence limit, plain text, no
/// lists — see the host's `PET_BREVITY`), but a model is not a contract: this is the backstop that
/// keeps one long answer from turning a speech bubble into a page. It is here, in the Kit, rather
/// than in the view because it is a rule about the conversation's content, and the view's job is
/// only to draw what it is given (a `lineLimit` on the bubble and the full text on hover).
///
/// Clamping is display-only: `PetMessage.text` keeps every word, so Copy and the hover tooltip give
/// the owner the whole answer.
public enum PetBrevity {
    /// The most sentences a bubble shows. Two: a direct answer, and the one qualification that
    /// makes it true.
    public static let sentenceLimit = 2
    /// The most characters a bubble shows, after the sentence cut.
    public static let characterLimit = 320
    /// The most lines a bubble draws before it is clipped by the view.
    public static let lineLimit = 4

    /// The first paragraph, at most `sentenceLimit` sentences, at most `characterLimit` characters,
    /// with an ellipsis when something was cut.
    public static func clamp(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            // One paragraph: a list, a table or an essay's second paragraph is not a pet's answer.
            .prefix(1)
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "" }

        let (sentences, cutSentences) = sentencePrefix(of: flattened, limit: sentenceLimit)
        var shown = sentences
        var truncated = cutSentences

        if shown.count > characterLimit {
            let head = String(shown.prefix(characterLimit))
            let cut = head.lastIndex(of: " ") ?? head.endIndex
            shown = String(head[..<cut]).trimmingCharacters(in: .whitespaces)
            truncated = true
        }
        return truncated ? shown + "…" : shown
    }

    /// The text up to and including `limit` sentence terminators, and whether anything was left.
    ///
    /// A terminator only ends a sentence when it is followed by a space or by the end of the text,
    /// so `3.5` and `tinker.v2` are not two sentences.
    private static func sentencePrefix(of text: String, limit: Int) -> (String, Bool) {
        let characters = Array(text)
        var sentences = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "." || character == "!" || character == "?" else {
                index += 1
                continue
            }
            var next = index + 1
            while next < characters.count, "\"')”’".contains(characters[next]) { next += 1 }
            guard next >= characters.count || characters[next] == " " else {
                index += 1
                continue
            }
            sentences += 1
            index = next
            if sentences == limit { break }
        }
        let prefix = String(characters[0..<min(index, characters.count)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (prefix, index < characters.count)
    }
}
