import Foundation

/// One read of the bridge's card route: the document, plus the two facts a poller would need.
///
/// `card` is the raw JSON object the bot wrote, left undecoded on purpose. `CardModel` lives in
/// `HermesCards`, and `HermesKit` must not depend on the renderer: a caller that can draw a card
/// decodes it with `CardModel.decode(_:)`, and one that cannot still has `mtime` and `final`.
public struct CardFetch: Sendable, Equatable {
    /// The `card.v1` document, exactly as the file held it.
    public let card: Data
    /// The file's modification time, `2026-11-22T21:04:06.120Z` — the host's own string.
    public let mtime: String
    /// `true` when the card can never change again (resolved, `done` or `error`). P1 never polls;
    /// the flag is here so one read is a complete answer rather than half of one.
    public let final: Bool

    public init(card: Data, mtime: String, final: Bool) {
        self.card = card
        self.mtime = mtime
        self.final = final
    }
}

/// Why a card could not be read — one case per way the transcript has to degrade.
///
/// The route already tells these apart (`no_such_card`, `bad_id`, `too_large`, `outside_base`,
/// `bad_card`), and collapsing them into one error is what leaves a bubble looking like it is
/// still loading. Every case draws the same line for the reader — `Card not available` — but they
/// are different facts, and a log line should not have to re-parse a body to say which happened.
public enum CardFetchError: Error, Sendable, Equatable, LocalizedError {
    /// `404 no_such_card`: the file is gone and no snapshot exists for this message.
    case noSuchCard
    /// `400 bad_id`: the id is not the shape the route will turn into a path.
    case badId
    /// `413 too_large`: the file is past the route's 32 KB ceiling.
    case tooLarge
    /// `403 outside_base`: the file (or the `cards` directory) resolves outside the session base.
    case outsideBase
    /// `422 bad_card`: the file is not a JSON object.
    case badCard
    /// Any other refusal — an unpaired device (401), a route this bridge does not serve (404 with
    /// no code), a host that answered something unexpected.
    case refused(status: Int, code: String?)
    /// No readable answer at all: no transport, a non-HTTP response, or a body without a card.
    case unreachable(String)

    /// The id shape the route accepts, checked before a path is ever built on the host. `CardMarker`
    /// already refuses anything else, so this only fires for a caller that skipped the parser.
    public static let idPattern = #"^[A-Za-z0-9_-]{1,40}$"#

    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.range(of: idPattern, options: .regularExpression) != nil
    }

    /// The route's refusal, read off the status *and* its `{"error": "…"}` body.
    ///
    /// The code wins when it is present: the route's own mapping is the contract, and a proxy in
    /// front of the bridge may have restated the status. The status is the fallback for a refusal
    /// whose body was not JSON — an auth page, an old bridge, a 502.
    public init(status: Int, body: Data) {
        switch Self.code(in: body) ?? "" {
        case "no_such_card": self = .noSuchCard
        case "bad_id": self = .badId
        case "too_large": self = .tooLarge
        case "outside_base": self = .outsideBase
        case "bad_card": self = .badCard
        default:
            switch status {
            case 400: self = .badId
            case 403: self = .outsideBase
            case 404: self = .noSuchCard
            case 413: self = .tooLarge
            case 422: self = .badCard
            default: self = .refused(status: status, code: Self.code(in: body))
            }
        }
    }

    /// The wire code when there was one, for logs — never for a decision the case above cannot make.
    public var code: String? {
        switch self {
        case .noSuchCard: return "no_such_card"
        case .badId: return "bad_id"
        case .tooLarge: return "too_large"
        case .outsideBase: return "outside_base"
        case .badCard: return "bad_card"
        case .refused(_, let code): return code
        case .unreachable: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noSuchCard: return "the card file is gone and this message has no snapshot"
        case .badId: return "the card id is not one the route accepts"
        case .tooLarge: return "the card file is larger than 32 KB"
        case .outsideBase: return "the card file resolves outside the cards directory"
        case .badCard: return "the card file is not a JSON object"
        case .refused(let status, let code):
            if let code, !code.isEmpty { return "the host refused the card (\(status)): \(code)" }
            return "the host refused the card (\(status))"
        case .unreachable(let why): return why
        }
    }

    private static func code(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let code = object["error"] as? String,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return code
    }
}
