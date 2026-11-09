import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Models

/// Who is driving the screen. One lease for the whole host: with a shared desktop, a takeover
/// refuses `computer_use` for **every** bot until it is handed back.
public struct BotComputerLease: Decodable, Sendable, Equatable {
    public let holder: String
    public let epoch: Int
    public let since: Double?
    public let viewerHash: String?

    public init(holder: String, epoch: Int, since: Double? = nil, viewerHash: String? = nil) {
        self.holder = holder
        self.epoch = epoch
        self.since = since
        self.viewerHash = viewerHash
    }

    public var isHuman: Bool { holder == "human" }
}

/// `GET /v1/display/status` — the gateway's own snapshot, passed through by the bridge.
public struct BotComputerStatus: Decodable, Sendable, Equatable {
    public let profile: String?
    public let running: Bool
    public let installed: Bool
    /// `:20` while running; nil when stopped.
    public let display: String?
    public let geometry: String?
    /// Why starting would refuse right now (host memory), for the pane to show instead of Start.
    public let blocker: String?
    public let lease: BotComputerLease?

    public init(profile: String? = nil, running: Bool, installed: Bool = true,
                display: String? = nil, geometry: String? = nil, blocker: String? = nil,
                lease: BotComputerLease? = nil) {
        self.profile = profile
        self.running = running
        self.installed = installed
        self.display = display
        self.geometry = geometry
        self.blocker = blocker
        self.lease = lease
    }

    public var headline: String {
        if !installed { return "not installed on the host" }
        if let blocker, !blocker.isEmpty { return blocker }
        if !running { return "stopped" }
        if lease?.isHuman == true { return "you are in control" }
        return "the bot has control"
    }
}

/// `POST /v1/display/observe` — what the viewer needs and nothing else. The gateway's own ticket
/// never reaches the app; `ticket` here is the bridge's, single-use and good for a minute.
public struct BotComputerTicket: Sendable, Equatable {
    public let ticket: String
    public let path: String
    public let viewerID: String
    public let expiresIn: Double
    public let status: BotComputerStatus?

    public init(ticket: String, path: String, viewerID: String, expiresIn: Double,
                status: BotComputerStatus? = nil) {
        self.ticket = ticket
        self.path = path
        self.viewerID = viewerID
        self.expiresIn = expiresIn
        self.status = status
    }
}

// MARK: - Errors

public enum BotComputerError: Error, Equatable, LocalizedError {
    case notHTTP
    case rejected(status: Int, detail: String?)
    case malformedResponse
    case noSocketURL

    public var errorDescription: String? {
        switch self {
        case .notHTTP:
            return "the host's screen answer was not HTTP"
        case .rejected(let status, let detail):
            if let detail, !detail.isEmpty { return "the host refused the screen (\(status)): \(detail)" }
            return "the host refused the screen (\(status))"
        case .malformedResponse:
            return "the host's screen answer was not readable"
        case .noSocketURL:
            return "the host's address cannot carry the screen"
        }
    }
}

// MARK: - Client

/// The Bot Computer half of the bridge: `/v1/display/*` plus the WebSocket the viewer dials.
///
/// Every HTTP call mints its **own** single-use ticket (the endpoint closure), because the bridge
/// spends it on that one request — sharing one across calls is the bug that reads as a revoked
/// device. The socket is different: it carries the ticket `observe` returned, in the query string,
/// because noVNC owns its `WebSocket` and cannot set a header.
public struct BotComputerClient: Sendable {
    public typealias Endpoint = @Sendable () async throws -> (baseURL: URL, ticket: String)

    private let endpoint: Endpoint
    private let session: URLSession

    public init(endpoint: @escaping Endpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    // MARK: Reads

    public func status(profile: String) async throws -> BotComputerStatus {
        try await get("v1/display/status", query: [URLQueryItem(name: "profile", value: profile)],
                      as: BotComputerStatus.self)
    }

    /// One JPEG data URL, or nil while stopped or while a human holds control (the frame could be
    /// showing what they are typing).
    public func thumbnail(profile: String) async throws -> String? {
        struct Reply: Decodable { let dataUrl: String? }
        let reply = try await get("v1/display/thumbnail",
                                  query: [URLQueryItem(name: "profile", value: profile)],
                                  as: Reply.self)
        return reply.dataUrl
    }

    // MARK: Commands

    @discardableResult
    public func start(profile: String) async throws -> BotComputerStatus {
        try await post("v1/display/start", body: ["profile": profile], as: BotComputerStatus.self)
    }

    @discardableResult
    public func stop(profile: String, confirm: Bool = false) async throws -> BotComputerStatus {
        // `confirm` is the "a human may be holding it" acknowledgement; the host refuses without it.
        try await post("v1/display/stop", body: ["profile": profile, "confirm": confirm],
                       as: BotComputerStatus.self)
    }

    @discardableResult
    public func lease(profile: String, acquire: Bool, viewerID: String) async throws -> BotComputerLease? {
        struct Reply: Decodable { let lease: BotComputerLease? }
        let reply = try await post("v1/display/lease",
                                   body: ["profile": profile,
                                          "action": acquire ? "acquire" : "release",
                                          "viewer_id": viewerID],
                                   as: Reply.self)
        return reply.lease
    }

    public func observe(profile: String, viewerID: String? = nil) async throws -> BotComputerTicket {
        struct TicketBody: Decodable {
            let ticket: String
            let path: String
            let viewerId: String
            let expiresIn: Double
            let status: BotComputerStatus?
        }
        var body: [String: String] = ["profile": profile]
        if let viewerID, !viewerID.isEmpty { body["viewer_id"] = viewerID }
        let reply = try await post("v1/display/observe", body: body, as: TicketBody.self)
        return BotComputerTicket(ticket: reply.ticket, path: reply.path, viewerID: reply.viewerId,
                                 expiresIn: reply.expiresIn, status: reply.status)
    }

    // MARK: The socket

    /// `https://host:8443` + `/v1/display/ws?display_ticket=…` -> `wss://host:8443/…`.
    public func socketURL(baseURL: URL, path: String, ticket: String) -> URL? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "display_ticket", value: ticket)]
        return components.url
    }

    /// Observe and hand back the socket to dial, in one step.
    ///
    /// The view must not build this itself: the socket has to be derived from the *same* base URL
    /// the observe request went to, and a second implementation of that rule is how a viewer ends
    /// up dialling a stale host after a re-pair.
    public func streamURL(profile: String, viewerID: String? = nil) async throws
        -> (url: URL, ticket: BotComputerTicket) {
        let endpoint = try await endpoint()          // spent by the observe below
        let observed = try await observe(profile: profile, viewerID: viewerID)
        guard let url = socketURL(baseURL: endpoint.baseURL, path: observed.path,
                                  ticket: observed.ticket) else {
            throw BotComputerError.noSocketURL
        }
        return (url, observed)
    }

    // MARK: Plumbing

    private func request(_ path: String, method: String,
                         query: [URLQueryItem] = []) async throws -> (Data, Int) {
        let endpoint = try await endpoint()          // one ticket, one request
        var url = endpoint.baseURL.appendingPathComponent(path)
        if !query.isEmpty,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            if let built = components.url { url = built }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = method == "GET" ? 12 : 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BotComputerError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw BotComputerError.rejected(status: http.statusCode,
                                            detail: Self.detail(from: data))
        }
        return (data, http.statusCode)
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem],
                                   as type: T.Type) async throws -> T {
        let (data, _) = try await request(path, method: "GET", query: query)
        return try Self.decode(data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any],
                                    as type: T.Type) async throws -> T {
        let encoded = try JSONSerialization.data(withJSONObject: body)
        let prepared = try await prepare(path)
        var request = URLRequest(url: prepared.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(prepared.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = encoded
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BotComputerError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw BotComputerError.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return try Self.decode(data)
    }

    private func prepare(_ path: String) async throws -> (url: URL, ticket: String) {
        let endpoint = try await endpoint()
        return (endpoint.baseURL.appendingPathComponent(path), endpoint.ticket)
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        // The bridge speaks snake_case (`viewer_id`, `expires_in`, `viewer_path`); the models are
        // Swift-named. Decoding is where a wrong key becomes "the answer was not readable", so it
        // is one place and it is tested.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BotComputerError.malformedResponse
        }
    }

    private static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String { return detail }
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["detail"] as? String)
        }
        return object["message"] as? String
    }
}
