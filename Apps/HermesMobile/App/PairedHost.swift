import Foundation

// MARK: - Paired host

/// One host this phone is paired with, plus the device row the host knows it by.
///
/// `baseURL` is what every bridge call hangs off (`/v1/token`, `/v1/devices`). The
/// refresh token is *not* here: it lives in the Keychain and is handed to
/// `BridgeService` explicitly, so a `PairedHost` can be logged or shown without leaking
/// a credential.
struct PairedHost: Codable, Equatable, Identifiable {
    let deviceID: String
    var deviceName: String
    /// Display host, e.g. `hermes.example.ts.net` — never includes a scheme.
    var host: String
    var baseURL: URL
    var platform: String
    var pairedAt: Date
    var protocolVersion: Int

    var id: String { deviceID }

    /// `https://host` in, `wss://host/v1/ws` out. Anything that parsed as http(s) maps to
    /// its socket twin; a bare host gets https unless it is a loopback address, which is
    /// the only case the bridge itself allows in the clear.
    static func baseURL(fromHost raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            let loopback = text.hasPrefix("localhost")
                || text.hasPrefix("127.0.0.1")
                || text.hasPrefix("[::1]")
            text = (loopback ? "http://" : "https://") + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else { return nil }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func displayHost(from raw: String) -> String {
        baseURL(fromHost: raw)?.host ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Devices

/// A row from `GET /v1/devices`. Revocation is one-way on the bridge, so this is the
/// only mutable field the UI ever flips.
struct PairedDevice: Identifiable, Equatable {
    let deviceID: String
    let name: String
    let platform: String
    let createdAt: Date?
    let lastSeenAt: Date?
    var revoked: Bool

    var id: String { deviceID }

    var platformLabel: String {
        switch platform.lowercased() {
        case "ios": return "iPhone / iPad"
        case "macos": return "Mac"
        case "": return "Unknown device"
        default: return platform
        }
    }
}

// MARK: - Pairing payload

/// What a pairing QR or a pasted code contains.
///
/// The host mints an 8-digit, 120-second, single-use code; the QR the desktop shows is
/// that code plus the host it belongs to. Several shapes are accepted because the host
/// side has not frozen one yet — a deep link (`hermes://pair?host=…&code=…`), an https
/// URL with the code in the query, a JSON object, or the bare digits.
struct PairingPayload: Equatable {
    var host: String?
    var code: String

    static func parse(_ raw: String) -> PairingPayload? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("{"), let payload = parseJSON(text) {
            return payload
        }

        if let components = URLComponents(string: text),
           components.scheme != nil,
           let code = code(in: components.queryItems) {
            let host = host(in: components.queryItems) ?? components.host
            return PairingPayload(host: host, code: code)
        }

        if let digits = normalizeCode(text) {
            return PairingPayload(host: nil, code: digits)
        }
        return nil
    }

    /// Codes are digits only once a human has typed them; spaces and dashes are noise.
    static func normalizeCode(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        return digits.count >= 4 && digits.count <= 12 ? digits : nil
    }

    private static func parseJSON(_ text: String) -> PairingPayload? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rawCode = (object["code"] as? String)
            ?? (object["pairing_code"] as? String)
            ?? (object["pairingCode"] as? String)
            ?? ""
        guard let code = normalizeCode(rawCode) else { return nil }
        let host = (object["host"] as? String)
            ?? (object["url"] as? String)
            ?? (object["base_url"] as? String)
        return PairingPayload(host: host.flatMap { $0.isEmpty ? nil : $0 }, code: code)
    }

    private static func code(in items: [URLQueryItem]?) -> String? {
        guard let items else { return nil }
        for name in ["code", "pairing_code", "pairingCode"] {
            if let value = items.first(where: { $0.name == name })?.value,
               let normalized = normalizeCode(value) {
                return normalized
            }
        }
        return nil
    }

    private static func host(in items: [URLQueryItem]?) -> String? {
        guard let items else { return nil }
        for name in ["host", "url", "base_url"] {
            if let value = items.first(where: { $0.name == name })?.value, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

// MARK: - Persistence

/// The paired host, as the app remembers it between launches.
///
/// Public fields in `UserDefaults` (host, device id, name); the refresh token in the
/// Keychain, through `SecretStore`. `@Published` so Settings, the connection banner and
/// the transport factory all see a pairing change without a relaunch.
@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var host: PairedHost?

    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let hostKey = "hermes.pairedHost"
    private let tokenKey = "hermes.refreshToken"

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        if let data = defaults.data(forKey: hostKey),
           let decoded = try? JSONDecoder().decode(PairedHost.self, from: data) {
            host = decoded
        }
    }

    var refreshToken: String? {
        guard let data = secrets.data(for: tokenKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var isPaired: Bool { host != nil }

    func save(host: PairedHost, refreshToken: String) {
        self.host = host
        if let data = try? JSONEncoder().encode(host) {
            defaults.set(data, forKey: hostKey)
        }
        if let data = refreshToken.data(using: .utf8) {
            secrets.set(data, for: tokenKey)
        }
    }

    func clear() {
        host = nil
        defaults.removeObject(forKey: hostKey)
        secrets.remove(tokenKey)
    }

    // MARK: Previews

    static func preview(paired: Bool = true) -> HostStore {
        let defaults = UserDefaults(suiteName: "hermes.mobile.preview") ?? .standard
        defaults.removePersistentDomain(forName: "hermes.mobile.preview")
        let store = HostStore(defaults: defaults, secrets: MemorySecretStore())
        guard paired, let base = PairedHost.baseURL(fromHost: "hermes.example.ts.net") else {
            return store
        }
        store.save(host: PairedHost(deviceID: "dev-preview",
                                    deviceName: "Assistant's iPhone",
                                    host: "hermes.example.ts.net",
                                    baseURL: base,
                                    platform: "ios",
                                    pairedAt: Date().addingTimeInterval(-86_400 * 3),
                                    protocolVersion: 1),
                   refreshToken: "preview-refresh-token")
        return store
    }
}

/// The transport factory runs off the main actor, so the current credentials are mirrored
/// into this actor whenever they change. One writer (`AppEnvironment`), one reader (the
/// `GatewayClient` factory).
actor CredentialBox {
    private var host: PairedHost?
    private var token: String?

    func update(host: PairedHost?, token: String?) {
        self.host = host
        self.token = token
    }

    func credentials() -> (host: PairedHost, token: String)? {
        guard let host, let token, !token.isEmpty else { return nil }
        return (host, token)
    }
}
