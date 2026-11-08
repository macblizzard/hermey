import Foundation

/// Where this Mac is pointed: the host's WebSocket URL and the credentials it presents.
///
/// Deliberately a value type with no socket in it, so the pair sheet can validate a pasted
/// address without touching the network and the shell can be previewed offline.
///
/// Two shapes are accepted, because the host hands out two different things:
///
/// - **Device** (`deviceID` + `token` = refresh token): the app mints a fresh 30 s socket
///   ticket per connection (`BridgeTokenExchange`). This is the durable pairing.
/// - **Ticket** (`deviceID` empty, `token` = a ticket, or a URL that already carries
///   `?ticket=`): good for one connection only — the relay burns it on upgrade. Kept as a
///   deliberate escape hatch for a hand-issued ticket, and labelled as such in the sheet.
struct PairingAddress: Equatable, Sendable, Codable {
    /// The normalised base URL, e.g. `wss://hermes.example.ts.net` or
    /// `wss://hermes.example.ts.net/v1/ws`.
    let baseURL: String
    /// The bridge's device id, from `pair/claim`. Empty for a one-shot ticket.
    var deviceID: String = ""
    /// The refresh token, or a one-shot ticket when `deviceID` is empty.
    let token: String

    /// The first DNS label: `hermes.example.ts.net` → `hermes`. That is the name the
    /// connection chip shows; the full host is in the context panel.
    var displayHost: String {
        let host = URLComponents(string: baseURL)?.host ?? baseURL
        guard let first = host.split(separator: ".").first, !first.isEmpty else { return host }
        return String(first)
    }

    var isTicketOnly: Bool {
        deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where the relay is mounted on the bridge.
    static let relayPath = "/v1/ws"

    /// The socket URL for one connection, with its ticket attached.
    ///
    /// The bridge's relay takes the credential as `?ticket=` (`Bridge/README.md`,
    /// "Endpoints"). A pasted URL that already carries a ticket keeps it.
    func webSocketURL(ticket: String) throws -> URL {
        guard var components = URLComponents(string: baseURL) else {
            throw PairingError.malformedURL
        }
        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "wss" || scheme == "ws" else {
            throw PairingError.unsupportedScheme(components.scheme ?? "none")
        }
        guard components.host?.isEmpty == false else {
            throw PairingError.missingHost
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = PairingAddress.relayPath
        }
        var items = components.queryItems ?? []
        let hasTicket = items.contains { $0.name == "ticket" && !($0.value ?? "").isEmpty }
        if !hasTicket, !ticket.isEmpty {
            items.append(URLQueryItem(name: "ticket", value: ticket))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw PairingError.malformedURL }
        return url
    }

    /// A ticket good for one upgrade: reused when we only have one, minted when we have a
    /// refresh token.
    func mintedTicket() async throws -> String {
        guard !isTicketOnly else { return token }
        let exchange = BridgeTokenExchange(origin: try apiOrigin(),
                                          deviceID: deviceID,
                                          refreshToken: token)
        return try await exchange.mintTicket()
    }

    /// The socket URL for a connection attempt, minting a ticket first when we can.
    func socketURL() async throws -> URL {
        let ticket = try await mintedTicket()
        return try webSocketURL(ticket: ticket)
    }

    /// `wss://host` → `https://host`; `ws://127.0.0.1:8787` → `http://127.0.0.1:8787`. The
    /// path is dropped because `/v1/token` hangs off the origin, not off `/v1/ws`.
    func apiOrigin() throws -> URL {
        guard var components = URLComponents(string: baseURL) else {
            throw PairingError.malformedURL
        }
        switch (components.scheme ?? "").lowercased() {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        case let other: throw PairingError.unsupportedScheme(other.isEmpty ? "none" : other)
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw PairingError.malformedURL }
        return url
    }

    /// Validate what the sheet has, before anything is persisted or dialled.
    ///
    /// A bare host is accepted (`hermes.ts.net`); the scheme is then assumed to be `wss`,
    /// because a Hermes host on a tailnet is TLS or nothing.
    static func parse(_ rawURL: String, deviceID rawDeviceID: String = "", token rawToken: String) throws -> PairingAddress {
        var text = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PairingError.missingURL }
        if !text.contains("://") {
            text = "wss://" + text
        }
        guard let components = URLComponents(string: text) else {
            throw PairingError.malformedURL
        }
        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "wss" || scheme == "ws" else {
            throw PairingError.unsupportedScheme(components.scheme ?? "none")
        }
        guard components.host?.isEmpty == false else {
            throw PairingError.missingHost
        }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTicket = (components.queryItems ?? []).contains {
            $0.name == "ticket" && !($0.value ?? "").isEmpty
        }
        guard hasTicket || !token.isEmpty else { throw PairingError.missingToken }

        return PairingAddress(baseURL: components.url?.absoluteString ?? text,
                              deviceID: rawDeviceID.trimmingCharacters(in: .whitespacesAndNewlines),
                              token: token)
    }
}

enum PairingError: LocalizedError, Equatable {
    case missingURL
    case malformedURL
    case unsupportedScheme(String)
    case missingHost
    case missingToken

    var errorDescription: String? {
        switch self {
        case .missingURL:
            return "Enter the host's WebSocket URL."
        case .malformedURL:
            return "That URL cannot be read. It should look like wss://hermes.example.ts.net."
        case .unsupportedScheme(let scheme):
            return "Use wss:// (or ws:// on your own loopback) — not \(scheme)://."
        case .missingHost:
            return "The URL has no host in it."
        case .missingToken:
            return "Paste the device token from your host, or a URL that already carries ?ticket=…"
        }
    }

    var code: String {
        switch self {
        case .missingURL: return "missing-url"
        case .malformedURL: return "bad-url"
        case .unsupportedScheme: return "bad-scheme"
        case .missingHost: return "no-host"
        case .missingToken: return "no-token"
        }
    }
}
