import Foundation
@testable import HermesKit

/// The recorded handshake, byte for byte, from `fixtures/m0-handshake.ndjson`.
///
/// Copied rather than read from disk on purpose: a SwiftPM test target cannot reach the repository
/// root without declaring a resource in `Package.swift`, and these five lines are the contract this
/// suite exists to pin. If the fixture file changes, this copy must change with it.
enum Fixtures {
    /// `gateway.ready`, then replies to ping (id 1), client.capabilities (id 2), an unknown method
    /// (id 4) and gateway.capabilities (id 5).
    static let handshake: [String] = [
        #"{"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {"skin": {"name": "default"}, "change_events": true, "replay_epoch": "probe"}}}"#,
        #"{"jsonrpc": "2.0", "id": 1, "result": {"pong": true}}"#,
        #"{"jsonrpc": "2.0", "id": 2, "result": {"server_requests": ["approval", "clarify", "display.install.sudo", "preview.act", "preview.read", "secret", "setup_beat", "sudo", "terminal.read", "theme.apply", "theme.pick", "tour", "vault.code", "vault.save_login", "vault.unlock_prompt", "window.read"], "declines_not_shown": true, "canonical_clarify_batch": true}}"#,
        #"{"jsonrpc": "2.0", "id": 4, "error": {"code": -32601, "message": "unknown method: no.such.method — not available on this Hermes backend"}}"#,
        #"{"jsonrpc": "2.0", "id": 5, "result": {"per_session_exclusive_submit": true}}"#,
    ]

    /// The capabilities reply body from line 3, as the gateway actually sent it.
    static var capabilitiesResult: JSONValue {
        guard case .response(_, let result, _)? = try? JSONRPCCodec.decodeLine(Data(handshake[2].utf8)) else {
            return .null
        }
        return result ?? .null
    }

    static func frame(_ index: Int) throws -> IncomingFrame {
        guard let frame = try JSONRPCCodec.decodeLine(Data(handshake[index].utf8)) else {
            throw FixtureError.empty
        }
        return frame
    }

    enum FixtureError: Error { case empty }
}
