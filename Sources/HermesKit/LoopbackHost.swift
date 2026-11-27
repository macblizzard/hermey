import Foundation

/// Whether a host names this machine and nothing else.
///
/// One rule, in one place, because it decides whether a socket may be opened in plaintext. The
/// pairing path, the display viewer and the mobile bridge all had their own idea of "loopback"
/// (`127.0.0.1` compared as a string, `[::1]` with its brackets still on), and a copy that drifts
/// is how one of them ends up dialling a tailnet host over `ws`.
///
/// What counts: `localhost` and anything under it, all of `127.0.0.0/8` (not only `.0.1` — the
/// whole block is this machine on a Mac, and `127.1` works), and the IPv6 loopback in the forms
/// `URLComponents` hands back (`::1`, without brackets) or a person types (`[::1]`, `0:0:0:0:0:0:0:1`).
///
/// What does not: a tailnet name (`hermes.example.ts.net`), a LAN address (`192.168.1.10`), the
/// unspecified address (`0.0.0.0` — that is "listen here", not "this is me"), and anything else.
/// A host that is not loopback is reached over the network, so its frames are `wss://` or nothing.
public enum LoopbackHost {
    /// - Parameter host: a host as `URLComponents.host` returns it, or as a person typed it.
    public static func isLoopback(_ host: String?) -> Bool {
        guard let host else { return false }
        let name = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        if name == "::1" || name == "0:0:0:0:0:0:0:1" { return true }
        // 127.0.0.0/8, written in full by URLComponents (`127.0.0.1`) and abbreviated by people.
        if name.hasPrefix("127.") {
            let octets = name.split(separator: ".", omittingEmptySubsequences: false)
            // `127.1` is shorthand for `127.0.0.1`; `127.0.0.1.evil.example` is not loopback.
            return octets.count <= 4
                && octets.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isNumber } }
        }
        return false
    }
}
