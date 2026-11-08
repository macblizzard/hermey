import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Mints the short-lived WebSocket ticket the bridge's relay demands.
///
/// The relay redeems a ticket **before** the upgrade, and a ticket is single-use and lives
/// 30 s (`Bridge/README.md`, "WebSocket relay"). A client that keeps one in its pocket can
/// therefore connect exactly once — so every connection mints a fresh one from the device's
/// refresh token:
///
///     POST /v1/token  {"device_id": …, "refresh_token": …}
///       → 200 {"access_token": …, "ws_ticket": …, "expires_in": …}
///
/// That contract is `Bridge/hermes_bridge/app.py` (`token()`), not a guess. Nothing else in
/// the app talks HTTP: this is the only non-socket request, and it happens only when the
/// user connects.
struct BridgeTokenExchange: Sendable {
    /// `https://host[:port]` — the same origin as the socket, with the WS scheme swapped.
    let origin: URL
    let deviceID: String
    let refreshToken: String

    enum Failure: LocalizedError, Equatable {
        case rejected(status: Int, detail: String?)
        case malformedResponse
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let status, let detail):
                let suffix = detail.map { ": \($0)" } ?? ""
                return "the host refused the device token (\(status))\(suffix)"
            case .malformedResponse:
                return "the host's token response had no ws_ticket"
            case .unreachable(let why):
                return "could not reach the host for a socket ticket (\(why))"
            }
        }
    }

    func mintTicket(timeout: TimeInterval = 15) async throws -> String {
        var request = URLRequest(url: origin.appendingPathComponent("v1/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(TokenRequest(deviceID: deviceID, refreshToken: refreshToken))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: BridgeTokenExchange.detail(from: data))
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !decoded.ticket.isEmpty else {
            throw Failure.malformedResponse
        }
        return decoded.ticket
    }

    /// FastAPI answers failures as `{"detail": "…"}`; the message is worth showing verbatim
    /// because it distinguishes "bad token" from "device revoked".
    private static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String { return detail }
        return nil
    }
}

private struct TokenRequest: Encodable {
    let deviceID: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case refreshToken = "refresh_token"
    }
}

private struct TokenResponse: Decodable {
    let ticket: String

    enum CodingKeys: String, CodingKey {
        case ticket = "ws_ticket"
    }
}
