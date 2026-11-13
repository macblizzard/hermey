import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `::blocks{id="…"}` tag in a reply, and the bridge calls a native card needs.
///
/// The `hermes-genui` plugin never puts a board in the message: the model calls `show_blocks`, the
/// plugin stores the JSON, and the reply carries one directive line naming it. The desktop app
/// swaps that line for the drawn blocks; a native client has to do the same, which is two jobs —
/// find the tag, and hand a webview a URL it can load.
///
/// The URL carries a **card session**, not a device credential: a ticket is single-use and a page
/// makes five requests, so the bridge mints a session (`POST /v1/genui/session`) that reads genui
/// boards and expires in two minutes.
public enum GenUITag {
    /// Eight lowercase hex characters, the plugin's own id shape (`core/store.py`).
    static let pattern = #"::blocks\{[^}]*id\s*=\s*["']([0-9a-f]{8})["'][^}]*\}"#

    /// The first board named in this text, or nil. A reply draws one board; a second tag is ignored.
    public static func boardID(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let idRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[idRange])
    }

    /// The text with the directive lines taken out: the card replaces them, and a raw
    /// `::blocks{id="…"}` under a drawn board is the one thing the plugin exists to avoid.
    public static func textWithoutTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        // The tag sat on its own line; removing it leaves that line blank, and two blank lines in a
        // row read as a paragraph break that is not in the message.
        return stripped
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The colours a card paints itself with. The plugin reads the host's CSS variables, so the app
/// hands over its own palette instead of the card guessing light or dark.
public struct GenUIPalette: Sendable, Equatable {
    public var ink: String
    public var background: String
    public var accent: String
    public var muted: String
    public var good: String
    public var scheme: String

    public init(ink: String, background: String, accent: String, muted: String, good: String,
                scheme: String = "dark") {
        self.ink = ink
        self.background = background
        self.accent = accent
        self.muted = muted
        self.good = good
        self.scheme = scheme
    }

    /// The card's query items, in one place so both platforms send the same thing.
    public var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "ink", value: ink),
         URLQueryItem(name: "bg", value: background),
         URLQueryItem(name: "accent", value: accent),
         URLQueryItem(name: "muted", value: muted),
         URLQueryItem(name: "good", value: good),
         URLQueryItem(name: "scheme", value: scheme)]
    }
}

/// Mints card sessions and builds the URL a card is loaded from.
public struct GenUICards: Sendable {
    /// `https://host` — the bridge's origin, the same one `/v1/token` hangs off.
    public let origin: URL
    public let deviceID: String
    public let refreshToken: String

    public init(origin: URL, deviceID: String, refreshToken: String) {
        self.origin = origin
        self.deviceID = deviceID
        self.refreshToken = refreshToken
    }

    /// A session good for two minutes, cached per bot so a transcript full of cards mints one.
    ///
    /// Returns nil rather than throwing: a card that cannot load is a note in the transcript, not an
    /// error the chat has to explain.
    public func session(for bot: String) async -> String? {
        if let cached = await GenUISessionCache.shared.live(bot: bot) { return cached }
        guard let minted = try? await mint(bot: bot) else { return nil }
        await GenUISessionCache.shared.store(bot: bot, session: minted)
        return minted
    }

    /// The page URL for one board: the bridge's shell, the board, the bot and the palette.
    public func cardURL(bot: String, block: String, session: String,
                        palette: GenUIPalette) -> URL? {
        guard var components = URLComponents(url: origin.appendingPathComponent("v1/genui/host"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "block", value: block),
                                 URLQueryItem(name: "bot", value: bot),
                                 URLQueryItem(name: "session", value: session)] + palette.queryItems
        return components.url
    }

    private func mint(bot: String) async throws -> String {
        guard var components = URLComponents(url: origin.appendingPathComponent("v1/genui/session"),
                                             resolvingAgainstBaseURL: false) else {
            throw GenUICardsError.malformedURL
        }
        components.queryItems = [URLQueryItem(name: "bot", value: bot)]
        guard let url = components.url else { throw GenUICardsError.malformedURL }

        // One ticket, used here and nowhere else: the session is what the page holds.
        let ticket = try await BridgeTicket.exchange(origin: origin, deviceID: deviceID,
                                                     refreshToken: refreshToken)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer " + ticket, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GenUICardsError.refused
        }
        guard let payload = try? JSONDecoder().decode(SessionResponse.self, from: data),
              !payload.session.isEmpty else { throw GenUICardsError.malformedResponse }
        return payload.session
    }

    private struct SessionResponse: Decodable { let session: String }
}

public enum GenUICardsError: LocalizedError {
    case malformedURL, refused, malformedResponse

    public var errorDescription: String? {
        switch self {
        case .malformedURL: return "the host address is not a URL"
        case .refused: return "the host refused a card session"
        case .malformedResponse: return "the host's session response had no session"
        }
    }
}

/// `POST /v1/token` — the one request a card needs before it can load.
///
/// Duplicated from the Mac's `BridgeTokenExchange` on purpose: that one lives in the Mac target and
/// is not visible to the phone, and this is the whole contract (a body, a bearer, a `ws_ticket`).
enum BridgeTicket {
    static func exchange(origin: URL, deviceID: String, refreshToken: String) async throws -> String {
        var request = URLRequest(url: origin.appendingPathComponent("v1/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": deviceID, "refresh_token": refreshToken,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GenUICardsError.refused
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ticket = object["ws_ticket"] as? String, !ticket.isEmpty else {
            throw GenUICardsError.malformedResponse
        }
        return ticket
    }
}

/// Card sessions, kept for slightly less than their two minutes so a reload still has one.
actor GenUISessionCache {
    static let shared = GenUISessionCache()

    /// The bridge's session lives 120 s; a cached one is handed out for 90 of them, so a page that
    /// loads late still has 30 s of life in it.
    private static let lifetime: TimeInterval = 90

    private var entries: [String: (session: String, until: Date)] = [:]

    func live(bot: String) -> String? {
        guard let entry = entries[bot] else { return nil }
        guard entry.until > Date() else {
            entries[bot] = nil
            return nil
        }
        return entry.session
    }

    func store(bot: String, session: String) {
        if entries.count > 64 { entries.removeAll() }
        entries[bot] = (session, Date().addingTimeInterval(Self.lifetime))
    }
}
