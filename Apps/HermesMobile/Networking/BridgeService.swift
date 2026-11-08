import Foundation

/// What the app needs from the bridge's HTTP surface, and nothing more.
///
/// Deliberately not a general HTTP client: pairing, a ticket, the device list, a revoke.
/// The JSON-RPC leg is `GatewayClient`'s job and never passes through here. Every screen
/// takes this protocol, so previews and the UI can run against `PreviewBridgeService`
/// with no socket and no loopback server.
protocol BridgeServiceProtocol: Sendable {
    /// `POST /v1/pair/claim` — redeems a single-use pairing code for a device row.
    func claim(code: String, host: String, deviceName: String) async throws -> PairClaim
    /// `POST /v1/token` — refresh token → a 30-second, single-use websocket ticket,
    /// returned as the URL the gateway transport should open.
    func websocketURL(for host: PairedHost, refreshToken: String) async throws -> URL
    func devices(for host: PairedHost, refreshToken: String) async throws -> [PairedDevice]
    /// Revoke a device using a fresh single-use ticket; revoking this phone invalidates its
    /// refresh token immediately after this request succeeds.
    func revoke(deviceID: String, on host: PairedHost, refreshToken: String) async throws
    /// Permanently remove one already-revoked device using a fresh single-use ticket.
    func removeRevoked(deviceID: String, on host: PairedHost, refreshToken: String) async throws
}

struct PairClaim {
    let host: PairedHost
    let refreshToken: String
}

enum BridgeError: LocalizedError {
    case noHost
    case invalidHost(String)
    case keyUnavailable
    case http(status: Int, message: String?)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .noHost:
            return "No host is paired yet."
        case .invalidHost(let value):
            return "“\(value)” is not a host address. Use the name shown by `tailscale serve`, e.g. hermes.example.ts.net."
        case .keyUnavailable:
            return "This device cannot create a signing key."
        case .http(let status, let message):
            if let message, !message.isEmpty { return message }
            switch status {
            case 401: return "That pairing code is wrong or has expired."
            case 403: return "The host refused the request."
            case 404: return "The host does not know that device."
            case 409: return "The host is at its device limit — revoke one first."
            case 429: return "Too many attempts. Wait a minute and try again."
            default: return "The host answered \(status)."
            }
        case .malformedResponse:
            return "The host sent an answer this app does not understand."
        }
    }
}

// MARK: - Live

struct LiveBridgeService: BridgeServiceProtocol, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.httpAdditionalHeaders = ["Accept": "application/json"]
            self.session = URLSession(configuration: configuration)
        }
    }

    func claim(code: String, host: String, deviceName: String) async throws -> PairClaim {
        guard let base = PairedHost.baseURL(fromHost: host) else {
            throw BridgeError.invalidHost(host)
        }
        let publicKey = try DeviceKey.publicKeyBase64()
        let body = ClaimBody(code: code,
                             publicKey: publicKey,
                             deviceName: deviceName,
                             platform: "ios")
        let response: ClaimResponse = try await post("v1/pair/claim", base: base, body: body)
        return PairClaim(host: PairedHost(deviceID: response.deviceID,
                                          deviceName: deviceName,
                                          host: PairedHost.displayHost(from: host),
                                          baseURL: base,
                                          platform: "ios",
                                          pairedAt: Date(),
                                          protocolVersion: response.protocolVersion),
                         refreshToken: response.refreshToken)
    }

    func websocketURL(for host: PairedHost, refreshToken: String) async throws -> URL {
        let body = TokenBody(deviceID: host.deviceID, refreshToken: refreshToken)
        let response: TokenResponse = try await post("v1/token", base: host.baseURL, body: body)

        guard var components = URLComponents(url: host.baseURL, resolvingAgainstBaseURL: false) else {
            throw BridgeError.invalidHost(host.host)
        }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/v1/ws"
        components.queryItems = [URLQueryItem(name: "ticket", value: response.wsTicket)]
        guard let url = components.url else { throw BridgeError.malformedResponse }
        return url
    }

    func devices(for host: PairedHost, refreshToken: String) async throws -> [PairedDevice] {
        let data = try await authenticatedRequest("v1/devices", host: host, refreshToken: refreshToken)
        let rows = try decode([DeviceDTO].self, from: data)
        return rows.map(\.model)
    }

    func revoke(deviceID: String, on host: PairedHost, refreshToken: String) async throws {
        _ = try await authenticatedRequest("v1/devices/\(deviceID)", host: host,
                                           refreshToken: refreshToken, method: "DELETE")
    }

    func removeRevoked(deviceID: String, on host: PairedHost, refreshToken: String) async throws {
        do {
            let body = TokenBody(deviceID: host.deviceID, refreshToken: refreshToken)
            let ticket: TokenResponse = try await post("v1/token", base: host.baseURL, body: body)
            let url = host.baseURL.appendingPathComponent("v1/devices")
                .appendingPathComponent(deviceID).appendingPathComponent("revoked")
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(ticket.wsTicket)", forHTTPHeaderField: "Authorization")
            _ = try await send(request)
        } catch BridgeError.http(status: 401, message: _) {
            throw BridgeError.http(status: 401, message: "Authentication failed. Reconnect or pair this phone again.")
        } catch BridgeError.http(status: 409, message: let detail) {
            throw BridgeError.http(status: 409, message: detail ?? "The device cannot be removed because it is not revoked.")
        }
    }

    private func authenticatedRequest(_ path: String, host: PairedHost, refreshToken: String,
                                      method: String = "GET") async throws -> Data {
        do {
            let body = TokenBody(deviceID: host.deviceID, refreshToken: refreshToken)
            let ticket: TokenResponse = try await post("v1/token", base: host.baseURL, body: body)
            var request = URLRequest(url: host.baseURL.appendingPathComponent(path))
            request.httpMethod = method
            request.setValue("Bearer \(ticket.wsTicket)", forHTTPHeaderField: "Authorization")
            return try await send(request)
        } catch BridgeError.http(status: 401, message: _) {
            throw BridgeError.http(status: 401, message: "Authentication failed. Reconnect or pair this phone again.")
        }
    }

    // MARK: Plumbing

    private func post<Body: Encodable, Response: Decodable>(_ path: String,
                                                            base: URL,
                                                            body: Body) async throws -> Response {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await send(request)
        return try decode(Response.self, from: data)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            throw BridgeError.http(status: http.statusCode, message: detail(from: data))
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BridgeError.malformedResponse
        }
    }

    /// FastAPI puts the human-readable reason in `detail`.
    private func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["detail"] as? String
    }
}

// MARK: - Wire shapes

private struct ClaimBody: Encodable {
    let code: String
    let publicKey: String
    let deviceName: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case code
        case publicKey = "public_key"
        case deviceName = "device_name"
        case platform
    }
}

private struct ClaimResponse: Decodable {
    let deviceID: String
    let refreshToken: String
    let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case refreshToken = "refresh_token"
        case protocolVersion = "protocol_version"
    }
}

private struct TokenBody: Encodable {
    let deviceID: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case refreshToken = "refresh_token"
    }
}

private struct TokenResponse: Decodable {
    let wsTicket: String

    enum CodingKeys: String, CodingKey {
        case wsTicket = "ws_ticket"
    }
}

private struct DeviceDTO: Decodable {
    let deviceID: String
    let name: String
    let platform: String
    let createdAt: Double?
    let lastSeenAt: Double?
    let revoked: Bool

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case platform
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
        case revoked
    }

    var model: PairedDevice {
        PairedDevice(deviceID: deviceID,
                     name: name,
                     platform: platform,
                     createdAt: createdAt.map { Date(timeIntervalSince1970: $0) },
                     lastSeenAt: lastSeenAt.map { Date(timeIntervalSince1970: $0) },
                     revoked: revoked)
    }
}

// MARK: - Preview

/// No network, canned devices: every screen previews against this.
struct PreviewBridgeService: BridgeServiceProtocol {
    var pairedHost: PairedHost? {
        PairedHost.baseURL(fromHost: "hermes.example.ts.net").map {
            PairedHost(deviceID: "dev-preview",
                       deviceName: "Assistant's iPhone",
                       host: "hermes.example.ts.net",
                       baseURL: $0,
                       platform: "ios",
                       pairedAt: Date().addingTimeInterval(-86_400 * 3),
                       protocolVersion: 1)
        }
    }

    func claim(code: String, host: String, deviceName: String) async throws -> PairClaim {
        guard let base = PairedHost.baseURL(fromHost: host) else {
            throw BridgeError.invalidHost(host)
        }
        let paired = PairedHost(deviceID: "dev-preview",
                                deviceName: deviceName,
                                host: PairedHost.displayHost(from: host),
                                baseURL: base,
                                platform: "ios",
                                pairedAt: Date(),
                                protocolVersion: 1)
        return PairClaim(host: paired, refreshToken: "preview-refresh-token")
    }

    func websocketURL(for host: PairedHost, refreshToken: String) async throws -> URL {
        guard let url = URL(string: "ws://preview.invalid/v1/ws?ticket=preview") else {
            throw BridgeError.malformedResponse
        }
        return url
    }

    func devices(for host: PairedHost, refreshToken: String) async throws -> [PairedDevice] {
        [PairedDevice(deviceID: "dev-preview",
                      name: "Assistant's iPhone",
                      platform: "ios",
                      createdAt: Date().addingTimeInterval(-86_400 * 3),
                      lastSeenAt: Date().addingTimeInterval(-90),
                      revoked: false),
         PairedDevice(deviceID: "dev-mac",
                      name: "Studio Mac",
                      platform: "macos",
                      createdAt: Date().addingTimeInterval(-86_400 * 30),
                      lastSeenAt: Date().addingTimeInterval(-3_600 * 6),
                      revoked: false),
         PairedDevice(deviceID: "dev-old",
                      name: "Old iPad",
                      platform: "ios",
                      createdAt: Date().addingTimeInterval(-86_400 * 200),
                      lastSeenAt: Date().addingTimeInterval(-86_400 * 40),
                      revoked: true)]
    }

    func revoke(deviceID: String, on host: PairedHost, refreshToken: String) async throws {}
    func removeRevoked(deviceID: String, on host: PairedHost, refreshToken: String) async throws {}
}
