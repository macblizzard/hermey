import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One question to a bot, and whatever it answered in time.
///
/// This is the desktop pet's whole conversation model. `POST /v1/bots/{profile}/ask` takes
/// `{question, from, timeout}` and answers
/// `{profile, from, session_id, question, reply, answered}`. A timeout is an *answer*
/// (`answered == false`, `reply == null`), not a failure: the question was delivered, and the
/// balloon says so instead of spinning for ever.
public struct BotAnswer: Sendable, Equatable {
    public let profile: String
    public let from: String
    public let sessionID: String?
    public let question: String
    /// `nil` when the host delivered the question but the bot had not answered by the timeout.
    public let reply: String?
    public let answered: Bool

    public init(profile: String,
                from: String,
                sessionID: String?,
                question: String,
                reply: String?,
                answered: Bool) {
        self.profile = profile
        self.from = from
        self.sessionID = sessionID
        self.question = question
        self.reply = reply
        self.answered = answered
    }

    /// The documented body. `reply: null` and an absent `answered` together mean "delivered, no
    /// answer yet" — the shape the host sends on a timeout.
    public static func decode(_ data: Data,
                              fallbackProfile: String,
                              fallbackFrom: String,
                              fallbackQuestion: String) -> BotAnswer? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // A reply that is `null`, missing or blank is no reply at all: the pet must not show an
        // empty bubble and call it an answer.
        let rawReply = object["reply"] as? String
        let reply = (rawReply?.isEmpty == false) ? rawReply : nil
        let answered = (object["answered"] as? Bool) ?? (reply != nil)
        return BotAnswer(profile: (object["profile"] as? String) ?? fallbackProfile,
                         from: (object["from"] as? String) ?? fallbackFrom,
                         sessionID: object["session_id"] as? String,
                         question: (object["question"] as? String) ?? fallbackQuestion,
                         reply: reply,
                         answered: answered && reply != nil)
    }
}

/// What went wrong, in the three ways a pet cares about.
///
/// The host's own sentence travels verbatim in `.host`: a refusal ("no conversation yet", "this
/// bot is off") is a sentence written for a person, and decorating it would only make it longer.
public enum BotAskError: Error, Equatable, LocalizedError {
    /// Nothing answered the socket at all — no host, no bridge, a dropped connection.
    case unreachable
    /// The profile cannot be put in a path. Not something a user can act on; a bug guard.
    case badProfile
    /// The host answered with a refusal, and this is its `detail`, unchanged.
    case host(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable: return "Can't reach the host right now."
        case .badProfile: return "That bot's name cannot be used in a question."
        case .host(let detail): return detail.isEmpty ? "The host refused the question." : detail
        }
    }
}

/// The wire shape of `/v1/bots/{profile}/ask`, in one place so the route, the body and the
/// `from` label are asserted rather than retyped.
public enum BotAsk {
    /// How a desktop pet signs its questions. The host writes it into the target bot's transcript,
    /// which is how a pet's question is told apart from one typed into the app.
    public static let fromDesktopPet = "desktop-pet"

    /// How long a pet waits for an answer before reporting "sent, no answer yet". The host caps it
    /// at 300 s; 120 is long enough for a tool-using bot and short enough for a balloon.
    public static let defaultTimeout: Double = 120

    public static func url(base: URL, profile: String) throws -> URL {
        let name = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw BotAskError.badProfile
        }
        return base
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent(name)
            .appendingPathComponent("ask")
    }

    public static func body(question: String, from: String, timeout: Double) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "question": question,
            "from": from,
            "timeout": timeout,
        ])
    }
}
