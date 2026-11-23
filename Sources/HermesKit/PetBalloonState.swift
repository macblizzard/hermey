import Foundation

/// The balloon's one job, as a value: idle → asking → answered / sent-but-silent / failed.
///
/// One question at a time per pet. The field is disabled while `isAsking`, so a second Return
/// cannot open a second turn behind the first; `ask` also refuses it, because a state machine that
/// trusts the view to gate it is a state machine with two entrance doors.
///
/// The two sentences the design fixed live here rather than in the view, so a test pins the words
/// the owner actually reads.
public enum PetBalloonState: Equatable, Sendable {
    case idle
    case asking(question: String)
    case answered(question: String, reply: String)
    /// Delivered, but the bot had not answered by the timeout — an answer in its own right.
    case unanswered(question: String)
    /// The host refused in its own words (`.failed(message)`), or nothing answered at all.
    case failed(question: String, message: String)

    /// What a timeout says. Not an error: the question reached the bot.
    public static let unansweredText = "Sent — it hasn't answered yet."
    /// What a dead socket says. Never a spinner that cannot end.
    public static let unreachableText = "Can't reach the host right now."

    public var isAsking: Bool {
        if case .asking = self { return true }
        return false
    }

    /// The question this balloon is about, if any — what Retry re-sends.
    public var question: String? {
        switch self {
        case .idle: return nil
        case .asking(let question), .answered(let question, _),
             .unanswered(let question), .failed(let question, _):
            return question
        }
    }

    /// The answer to show, when there is one.
    public var answer: String? {
        if case .answered(_, let reply) = self { return reply }
        return nil
    }

    /// The sentence under a failure, when there is one. The host's own words, or the two fixed
    /// lines above.
    public var failure: String? {
        switch self {
        case .unanswered: return Self.unansweredText
        case .failed(_, let message): return message
        default: return nil
        }
    }

    /// True after a timeout or a refusal: both are retryable with the same question.
    public var canRetry: Bool {
        switch self {
        case .unanswered, .failed: return true
        default: return false
        }
    }

    /// Whether the text field takes input.
    public var acceptsInput: Bool { !isAsking }

    /// Begin a question. Returns false — and changes nothing — for blank text or while one is in
    /// flight.
    @discardableResult
    public mutating func ask(_ question: String) -> Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAsking else { return false }
        self = .asking(question: trimmed)
        return true
    }

    /// Re-send the question this balloon already holds. False when there is nothing to retry or a
    /// turn is already running.
    @discardableResult
    public mutating func retry() -> Bool {
        guard canRetry, let question else { return false }
        self = .asking(question: question)
        return true
    }

    /// The host answered. A missing or blank reply from a turn that was asked is a timeout, not an
    /// empty answer, so it lands in `.unanswered`.
    public mutating func receive(reply: String?) {
        guard case .asking(let question) = self else { return }
        let trimmed = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self = trimmed.isEmpty
            ? .unanswered(question: question)
            : .answered(question: question, reply: trimmed)
    }

    /// The question could not be asked, or was refused. Only a running question can fail; a late
    /// error for a balloon that was dismissed must not reopen it.
    public mutating func fail(_ message: String) {
        guard case .asking(let question) = self else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self = .failed(question: question,
                       message: trimmed.isEmpty ? Self.unreachableText : trimmed)
    }

    /// Back to an empty field. Escape, a click away, and the pet's own dismissal all land here.
    public mutating func dismiss() {
        self = .idle
    }
}
