import Foundation

/// The two things a pairing handoff carries: which host, and the single-use code that redeems a
/// device row on it.
///
/// The host can hand this over in three shapes and the sheet must not care which:
///
/// * the deep link the phone already understands —
///   `hermes://pair?host=https%3A%2F%2Fhermes.example.ts.net%3A8443&code=12345678`;
/// * a bare code (`12345678`), pasted from `hermey pair` or read out loud — the host then comes from
///   the host this Mac was last paired with;
/// * an ordinary URL carrying `?code=` (`https://hermes.example.ts.net:8443/?code=12345678`), which
///   is what a browser or a `curl` transcript tends to contain.
///
/// Parsing is pure and lives here rather than in the sheet so it can be tested without a socket, and
/// so `hermes://` links mean the same thing on both apps.
public struct PairingLink: Equatable, Sendable {
    /// The host, normalised to an `https://` base with no trailing slash — the form the claim
    /// request needs. The socket base is `websocketBase`.
    public let host: String
    /// The code as written, digits only.
    public let code: String

    public init(host: String, code: String) {
        self.host = PairingLink.normalised(host)
        self.code = code
    }

    /// `https://…` — where `POST /v1/pair/claim` lives.
    public var httpBase: String {
        PairingLink.rewritingScheme(of: host, to: "https")
    }

    /// `wss://…` — what `PairingAddress` wants.
    public var websocketBase: String {
        PairingLink.rewritingScheme(of: host, to: "wss")
    }

    /// What a paste turns out to be.
    ///
    /// `parse` answers only what can be delivered, which loses a distinction the sheet needs: a code
    /// with nowhere to send it is not a *wrong* code. Reporting it as one ("That is not a pairing
    /// code") left a fresh Mac unable to pair from `hermey pair`'s digits at all — the code was
    /// refused on the device and never reached the host.
    public enum Input: Equatable, Sendable {
        /// Everything the claim needs.
        case link(PairingLink)
        /// Eight digits (or a future length), and no address to claim it against. Keep the code and
        /// ask for the address; do not call the code invalid.
        case codeNeedingHost(String)
        /// Neither a code nor a link carrying one.
        case unusable
    }

    /// - Parameter defaultHost: the host to use when the input is only a code (or a link that omits
    ///   `host=`). Pass the address typed in the sheet first, then the host this Mac was last
    ///   paired with — an address somebody just typed beats one that was remembered.
    public static func classify(_ raw: String, defaultHost: String? = nil) -> Input {
        let text = cleaned(raw)
        guard !text.isEmpty else { return .unusable }

        // A bare code. The digits are the whole message; the host is the context.
        if isCode(text) {
            guard let fallback = defaultHost.map(normalised), !fallback.isEmpty else {
                return .codeNeedingHost(text)
            }
            return .link(PairingLink(host: fallback, code: text))
        }

        guard let link = parseLink(text, defaultHost: defaultHost) else { return .unusable }
        return .link(link)
    }

    /// The old entry point: the link, or nil when there is not enough to claim one.
    public static func parse(_ raw: String, defaultHost: String? = nil) -> PairingLink? {
        if case .link(let link) = classify(raw, defaultHost: defaultHost) { return link }
        return nil
    }

    private static func parseLink(_ text: String, defaultHost: String?) -> PairingLink? {
        // Anything else has to be a URL carrying `code=` (with `host=` optional). A paste without a
        // scheme (`hermes.example.ts.net:8443/?code=…`) is still a URL — add the scheme the host
        // actually serves before asking `URLComponents`, which would otherwise read the host as one.
        var candidate = text
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let components = URLComponents(string: candidate) else { return nil }
        let items = components.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value.map(cleaned), isCode(code) else {
            return nil
        }

        if let explicit = items.first(where: { $0.name == "host" })?.value.map(cleaned), !explicit.isEmpty {
            return PairingLink(host: explicit, code: code)
        }
        // `hermes://pair?code=…` names no host, but `https://host/?code=…` names one implicitly.
        if let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss",
           let host = components.host {
            var rebuilt = URLComponents()
            rebuilt.scheme = scheme
            rebuilt.host = host
            rebuilt.port = components.port
            if let string = rebuilt.string {
                return PairingLink(host: string, code: code)
            }
        }
        // An address typed into the sheet, or the one this Mac remembers. Empty is not an address.
        if let fallback = defaultHost.map(normalised), !fallback.isEmpty {
            return PairingLink(host: fallback, code: code)
        }
        return nil
    }

    /// Trim what a paste picks up — newlines, quotes, the angle brackets of a mail client.
    private static func cleaned(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The bridge mints eight digits today; accept a little either side so a future length change
    /// does not turn every code into "bad code".
    static func isCode(_ text: String) -> Bool {
        (6...12).contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Add a scheme if the paste had none, force `https`, and drop a trailing slash.
    static func normalised(_ host: String) -> String {
        var text = cleaned(host)
        if text.isEmpty { return text }
        if !text.contains("://") { text = "https://" + text }
        text = rewritingScheme(of: text, to: "https")
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func rewritingScheme(of url: String, to scheme: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let host = components.host else { return url }
        var rebuilt = "\(scheme)://\(host)"
        if let port = components.port { rebuilt += ":\(port)" }
        return rebuilt
    }
}
