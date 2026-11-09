import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - The bridge's pointer

/// Which stored session is *this bot's* one conversation, as the bridge knows it.
///
/// The apps used to answer that question from their own `UserDefaults`, one key per bot per
/// device, so the phone and the Mac minted two different sessions for one bot. The bridge now
/// owns the answer (`GET`/`PUT /v1/bots/{profile}/session`, device-authenticated like `/v1/devices`)
/// and this protocol is the only thing `GatewayClient` needs from it.
///
/// Deliberately tiny and transport-shaped: the decision of *what to do* with the answer lives in
/// `EndlessSessionPolicy`, and the HTTP leg in `BridgeBotSessionPointer`, so both are testable
/// without a socket and without a device.
/// The newest message of a bot's conversation, as the bridge reads it off the host.
///
/// The gateway's own `session.list` preview is the *first* user message of a session (a title
/// stand-in), so a bot row built from it repeats what was asked days ago. This is the other end of
/// the conversation, whatever role it came from.
public struct BotConversationPreview: Hashable, Sendable {
    public let text: String
    /// `user` or `assistant`; the host stores nothing else for a message a list row should show.
    public let role: String
    public let timestamp: Double?

    public init(text: String, role: String, timestamp: Double? = nil) {
        self.text = text
        self.role = role
        self.timestamp = timestamp
    }
}

/// One round trip's worth of bot-list state: every row's third line, and how much each bot said
/// after this device last looked at it.
///
/// The two travel together on purpose. A count computed against a preview from a different moment
/// is the kind of number a user can catch being wrong — they open the bot, count two messages, and
/// the badge said three.
public struct BotPreviewFeed: Sendable, Equatable {
    public let previews: [String: BotConversationPreview]
    /// Profile name -> unread turns. Absent means zero, and zero is never sent.
    public let unread: [String: Int]

    public init(previews: [String: BotConversationPreview] = [:], unread: [String: Int] = [:]) {
        self.previews = previews
        self.unread = unread
    }

    /// Read either shape the bridge can answer with: `GET /v1/bots/previews` (previews only, older
    /// hosts) or `POST /v1/bots/previews` (previews + `unread`).
    public static func decode(_ data: Data) -> BotPreviewFeed {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return BotPreviewFeed()
        }
        var previews: [String: BotConversationPreview] = [:]
        if let rows = object["previews"] as? [String: Any] {
            for (profile, value) in rows {
                guard let row = value as? [String: Any],
                      let text = (row["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else { continue }
                previews[profile] = BotConversationPreview(
                    text: text,
                    role: (row["role"] as? String) ?? "assistant",
                    timestamp: row["at"] as? Double
                )
            }
        }
        var unread: [String: Int] = [:]
        if let counts = object["unread"] as? [String: Any] {
            for (profile, value) in counts {
                // JSON may hand back Int, NSNumber or Double; anything that is not a positive
                // whole number means "nothing waiting".
                let raw = (value as? Int) ?? (value as? NSNumber)?.intValue ?? Int((value as? Double) ?? 0)
                if raw > 0 { unread[profile] = raw }
            }
        }
        return BotPreviewFeed(previews: previews, unread: unread)
    }
}

public protocol BotSessionPointerStore: Sendable {
    /// `GET /v1/bots/{profile}/session` — the shared stored session id, or `nil` when the bridge
    /// has none for this bot yet (unset, or a route the deployed bridge does not serve).
    func storedSessionID(for profile: String) async throws -> String?

    /// `PUT /v1/bots/{profile}/session` — publish `storedSessionID` so the other device adopts it.
    /// `nil` clears the pointer, which is what a reset means.
    func publish(storedSessionID: String?, for profile: String) async throws

    /// `GET /v1/bots/previews` — every bot's newest message, keyed by profile.
    ///
    /// Defaulted to empty so a pointer store that predates the route (or a test double) simply
    /// means "no previews from here", which sends the caller to the gateway's coarse fallback.
    func previews() async throws -> [String: BotConversationPreview]

    /// `POST /v1/bots/previews {"since": {profile: epoch}}` — the same rows, plus how many turns
    /// each bot wrote after the mark this device holds for it.
    ///
    /// Defaulted to the plain previews so a store that predates the route (or a test double) simply
    /// reports nothing unread instead of failing the list.
    func previews(since marks: [String: Double]) async throws -> BotPreviewFeed

    /// `POST /v1/bots/{profile}/purge` — delete a bot's profile on the host.
    ///
    /// The bridge archives the profile before it asks the host to remove it, so this is a real
    /// delete with a safety net, not a hide. Defaulted to a refusal: a store that predates the
    /// route must fail loudly rather than pretend a bot was deleted.
    func deleteBot(_ profile: String) async throws

    /// `POST /v1/bots/{profile}/state` — turn a bot off (its schedules paused) or back on.
    func setBotEnabled(_ profile: String, enabled: Bool) async throws

    /// `GET /v1/bots/disabled` — which bots are off, so the list can mark them without asking
    /// once per bot.
    func disabledBots() async throws -> Set<String>

    /// `GET /v1/rooms` — the group chats this host hosts.
    ///
    /// These four are protocol requirements, not free functions on an extension: a requirement that
    /// only exists in an extension is chosen statically, so a call through `any
    /// BotSessionPointerStore` would silently take the *default* and report "this host's bridge does
    /// not support" while the concrete store had a working implementation all along.
    func rooms() async throws -> [RoomSummary]

    /// `POST /v1/rooms` — open a room with 2–6 bots.
    func createRoom(name: String, members: [String]) async throws -> RoomSummary

    /// `GET /v1/rooms/{id}/log?since_seq=` — one page of a room's spoken log.
    func roomPage(_ roomID: String, since: Int?) async throws -> RoomPage

    /// `POST /v1/rooms/{id}/send` — one message; the bots it names answer.
    func sendRoomMessage(_ roomID: String, text: String) async throws

    /// The same message with files: the bridge stores them and puts their paths in the text.
    func sendRoomMessage(_ roomID: String, text: String, attachments: [RoomAttachment]) async throws

    /// `POST /v1/rooms/{id}/disband` — remove a group chat from every device.
    func disbandRoom(_ roomID: String) async throws

    /// `POST /v1/rooms/{id}/rename` — change the room's name on the host.
    func renameRoom(_ roomID: String, name: String) async throws
}

public extension BotSessionPointerStore {
    func deleteBot(_ profile: String) async throws { throw BotAdminUnavailable() }
    func setBotEnabled(_ profile: String, enabled: Bool) async throws { throw BotAdminUnavailable() }
    func disabledBots() async throws -> Set<String> { [] }
}

/// Thrown by a pointer store that has no admin routes (older bridge, test double).
public struct BotAdminUnavailable: LocalizedError {
    public init() {}
    public var errorDescription: String? {
        "This host's bridge does not support managing bots. Update the bridge on the host."
    }
}

extension BotSessionPointerStore {
    public func previews() async throws -> [String: BotConversationPreview] { [:] }

    public func previews(since marks: [String: Double]) async throws -> BotPreviewFeed {
        BotPreviewFeed(previews: try await previews())
    }
}

/// The real pointer: one HTTP request, one freshly minted single-use ticket.
///
/// Same credential shape as `VoiceService` and `BotIconService` on the app side — the caller
/// resolves *where* the bridge is and *what* ticket to present at request time, because a ticket
/// that went to a websocket (or to the previous request) is already spent and the paired host can
/// change while the client lives. Nothing is cached here, and nothing throws for a merely missing
/// value: "no pointer" is a normal answer, not an error.
public struct BridgeBotSessionPointer: BotSessionPointerStore {

    /// Everything one request needs, resolved per request.
    public typealias Endpoint = @Sendable () async throws -> (baseURL: URL, ticket: String)


enum Failure: Error, Equatable, LocalizedError {
        case noProfile
        case notHTTP
        case rejected(status: Int, detail: String?)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .noProfile: return "no bot was named for the shared conversation"
            case .notHTTP: return "the host's shared-conversation answer was not HTTP"
            case .rejected(let status, let detail):
                if let detail, !detail.isEmpty { return "the host refused the shared conversation (\(status)): \(detail)" }
                return "the host refused the shared conversation (\(status))"
            case .malformedResponse: return "the host's shared-conversation answer was not readable"
            }
        }
    }

    private let endpoint: Endpoint
    private let session: URLSession

    public init(endpoint: @escaping Endpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func storedSessionID(for profile: String) async throws -> String? {
        // Resolved once: a ticket is single-use, so asking the provider twice would mint a second
        // ticket that no request ever spends.
        let endpoint = try await endpoint()
        let url = try Self.url(for: profile, base: endpoint.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        // An older bridge has no such route; an unset pointer may also be spelled 404. Neither is
        // an error the user should ever see — it just means "ask the local cache instead".
        if http.statusCode == 404 || http.statusCode == 204 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        // A body this client cannot read is "no usable answer", not a failure: the pointer is an
        // optimisation, and opening a conversation must never depend on parsing it.
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // `stored_session_id` is the contract; `session_id` is tolerated because the bridge's own
        // session rows spell it that way and a mixed deployment must not fork the conversation.
        let raw = (object["stored_session_id"] as? String) ?? (object["session_id"] as? String)
        return EndlessSessionPolicy.storedID(raw)
    }

    public func publish(storedSessionID: String?, for profile: String) async throws {
        let endpoint = try await endpoint()
        let url = try Self.url(for: profile, base: endpoint.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        // Explicit `null` clears the pointer; the key is always present so the bridge never has to
        // guess whether an absent field meant "leave it alone".
        let body: [String: Any] = ["stored_session_id": storedSessionID.map { $0 as Any } ?? NSNull()]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        if storedSessionID == nil, http.statusCode == 400 || http.statusCode == 422 {
            // The deployed route has no "clear": a null is rejected rather than deleting the row
            // ("never a delete" in `bot_sessions.py`). Nothing the caller can act on — the reset
            // device keeps a local tombstone — and a bridge that learns to clear simply answers 2xx.
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
    }

    /// `GET /v1/bots/previews` — one request for every bot's newest message.
    ///
    /// One call, not one per bot: the bridge reads each profile's message table directly, so the
    /// round trip is the only cost. A bridge without the route, or a body this client cannot read,
    /// answers empty rather than throwing — the bot list keeps its two lines instead of showing a
    /// failure over a decoration.
    public func previews() async throws -> [String: BotConversationPreview] {
        let endpoint = try await endpoint()
        let url = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent("previews")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        if http.statusCode == 404 || http.statusCode == 204 { return [:] }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return BotPreviewFeed.decode(data).previews
    }

    /// `POST /v1/bots/previews` — rows plus counts, in the one round trip the list already makes.
    ///
    /// An older bridge answers 404 to the POST: fall back to its `GET` so the rows still appear and
    /// the badges simply stay empty until the host is updated.
    public func previews(since marks: [String: Double]) async throws -> BotPreviewFeed {
        let endpoint = try await endpoint()
        let url = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent("previews")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["since": marks])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        if http.statusCode == 404 || http.statusCode == 204 {
            return BotPreviewFeed(previews: try await previews())
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return BotPreviewFeed.decode(data)
    }

    /// `POST /v1/bots/{profile}/purge`.
    ///
    /// A delete can take a while on the host (tombstone, multiplexer release, archive), so the
    /// request timeout is generous — and a timeout is reported as *unknown*, never as success.
    public func deleteBot(_ profile: String) async throws {
        let endpoint = try await endpoint()
        var url = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent(profile)
            .appendingPathComponent("purge")
        url = try Self.encoded(url, profile: profile)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
    }

    /// `POST /v1/bots/{profile}/state`.
    public func setBotEnabled(_ profile: String, enabled: Bool) async throws {
        let endpoint = try await endpoint()
        var url = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent(profile)
            .appendingPathComponent("state")
        url = try Self.encoded(url, profile: profile)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["enabled": enabled])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
    }

    /// `GET /v1/bots/disabled`.
    public func disabledBots() async throws -> Set<String> {
        let endpoint = try await endpoint()
        let url = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent("disabled")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = object["disabled"] as? [String]
        else { return [] }
        return Set(names)
    }

    /// Percent-encode the profile segment: the path is built from a name the user typed.
    private static func encoded(_ url: URL, profile: String) throws -> URL {
        guard let escaped = profile.addingPercentEncoding(withAllowedCharacters: URLPath.componentAllowed),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Failure.noProfile
        }
        // Replace the final two segments (`<profile>/<verb>`) with the escaped name.
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { throw Failure.noProfile }
        components.path = "/" + parts.dropLast(2).joined(separator: "/").split(separator: "/").joined(separator: "/")
            + "/" + escaped + "/" + (parts.last.map(String.init) ?? "")
        guard let rebuilt = components.url else { throw Failure.noProfile }
        return rebuilt
    }

    // MARK: Generic bridge calls

    /// One authenticated GET against the bridge. Internal, because the room routes live in their
    /// own file and a ticket must still be minted *after* the endpoint is resolved.
    func bridgeGET(_ path: String, timeout: TimeInterval = 20) async throws -> Data {
        let endpoint = try await endpoint()
        var request = URLRequest(url: Self.bridgeURL(endpoint.baseURL, path))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return data
    }

    /// One authenticated POST against the bridge, JSON in and JSON out.
    func bridgePOST(_ path: String, body: [String: Any], timeout: TimeInterval = 60) async throws -> Data {
        let endpoint = try await endpoint()
        var request = URLRequest(url: Self.bridgeURL(endpoint.baseURL, path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return data
    }

    /// `/v1/rooms/<id>/log?since_seq=12` appended to whatever base the endpoint gives.
    static func bridgeURL(_ base: URL, _ path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: base.absoluteString + "/" + trimmed) else { return base }
        return url
    }

    // MARK: Plumbing

    private static func url(for profile: String, base: URL) throws -> URL {
        let name = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.noProfile }
        // Component by component, so a profile with a space or a slash is percent-encoded rather
        // than reshaping the path.
        return base
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent(name)
            .appendingPathComponent("session")
    }

    private static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["detail"] as? String
    }
}

// MARK: - What to do with the answer

/// What the bridge said about this bot's conversation.
public enum EndlessSessionPointerState: Equatable, Sendable {
    /// The bridge answered with an id. It is authoritative — the other device may be on it now.
    case value(SessionID)
    /// The bridge answered, and has no id for this bot yet.
    case absent
    /// The bridge could not be asked (offline, no route, unreadable answer). Not an error the user
    /// sees: the local cache answers instead and nothing is published, so a read we could not
    /// trust never overwrites the other device's pointer.
    case unavailable
}

/// The decision `AppModel.endlessSession(for:)` carries out.
public struct EndlessSessionPlan: Equatable, Sendable {

    public enum Step: Equatable, Sendable {
        /// Resume this stored id (never a runtime id — see the design note §5.6).
        case resume(SessionID)
        /// Mint a new conversation.
        case create
    }

    public enum Origin: Equatable, Sendable {
        /// The bridge's pointer.
        case host
        /// This device's `UserDefaults` cache.
        case local
        /// Neither: the conversation is about to be created.
        case none
    }

    public let step: Step
    public let origin: Origin
    /// Whether the resulting stored id must be written back to the bridge, so the other device
    /// adopts it on its next open.
    public let publish: Bool

    public init(step: Step, origin: Origin, publish: Bool) {
        self.step = step
        self.origin = origin
        self.publish = publish
    }

    public var resumedID: SessionID? {
        if case .resume(let id) = step { return id }
        return nil
    }
}

/// Which stored session to open, given the bridge's pointer and this device's cache.
///
/// The rules, in the order they matter:
///
/// 1. **Host wins.** A value the bridge holds is the shared answer; a stale local key is replaced.
/// 2. **Local is the fallback.** With no host value (or an unaskable host) the last id this device
///    used still opens — that is what keeps the app working offline and on an older bridge.
/// 3. **Publish what the host does not know.** After a create, and after a local id was adopted
///    because the bridge answered "nothing", the result is written back so the other device
///    converges. Nothing is published when the host supplied the id (it already knows) nor when
///    the read failed (that value may exist and must not be clobbered).
public enum EndlessSessionPolicy {

    /// A usable stored id, or `nil` for anything a resume could not be trusted with.
    ///
    /// The host's stored keys look like `20261106_165329_293f4b`; a trimmed, non-empty token of
    /// path-safe characters is the whole contract. Empty strings, whitespace, embedded newlines,
    /// path separators and absurdly long values are treated as "no pointer" rather than passed
    /// through to `session.resume` — a malformed answer must degrade to the local cache, never
    /// break the open.
    public static func storedID(_ raw: String?) -> SessionID? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...128).contains(trimmed.count) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        guard !trimmed.hasPrefix(".") else { return nil }
        return trimmed
    }

    public static func plan(host: EndlessSessionPointerState, local: String?) -> EndlessSessionPlan {
        let localID = storedID(local)

        switch host {
        case .value(let raw):
            guard let id = storedID(raw) else {
                // The bridge answered with something unusable; fall through to the same rules as
                // "no value", including publishing whatever we end up on so it is repaired.
                return planWithoutHost(localID)
            }
            return EndlessSessionPlan(step: .resume(id), origin: .host, publish: false)

        case .absent:
            return planWithoutHost(localID)

        case .unavailable:
            // Fail open: the local id still opens the conversation, but a read we could not
            // trust must not overwrite a pointer that may exist.
            if let localID {
                return EndlessSessionPlan(step: .resume(localID), origin: .local, publish: false)
            }
            return EndlessSessionPlan(step: .create, origin: .none, publish: true)
        }
    }

    private static func planWithoutHost(_ localID: SessionID?) -> EndlessSessionPlan {
        if let localID {
            return EndlessSessionPlan(step: .resume(localID), origin: .local, publish: true)
        }
        return EndlessSessionPlan(step: .create, origin: .none, publish: true)
    }
}

/// Characters allowed inside one URL path *component* supplied by the host.
///
/// `urlPathAllowed` deliberately keeps `/`, so a value meant to be a single segment can escape onto
/// another path. Subtracting the separator keeps it one segment; letters, digits, `-`, `_` and `.`
/// survive.
public enum URLPath {
    public static let componentAllowed: CharacterSet = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/"))
}
