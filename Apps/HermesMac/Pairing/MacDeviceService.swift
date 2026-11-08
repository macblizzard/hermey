import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MacPairedDevice: Decodable, Identifiable {
    let deviceID: String
    let name: String
    let platform: String
    let createdAt: Double?
    let lastSeenAt: Double?
    let revoked: Bool
    var id: String { deviceID }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", name, platform, revoked
        case createdAt = "created_at", lastSeenAt = "last_seen_at"
    }
}

/// Every management request consumes a fresh single-use ticket, just like iOS.
struct MacDeviceService {
    let address: PairingAddress
    let session: URLSession

    init(address: PairingAddress, session: URLSession = .shared) {
        self.address = address
        self.session = session
    }

    enum Failure: LocalizedError {
        case devicePairingRequired, malformedResponse
        case rejected(Int, String?)

        var errorDescription: String? {
            switch self {
            case .devicePairingRequired: return "Device management requires a device ID and refresh token, not a one-use ticket."
            case .malformedResponse: return "The host returned an unexpected response."
            case .rejected(let status, let detail):
                if status == 401 { return "Authentication failed. Pair this Mac again." }
                return "The host refused the request (\(status))" + (detail.map { ": \($0)" } ?? ".")
            }
        }
    }

    func devices() async throws -> [MacPairedDevice] {
        let data = try await request(components: ["v1", "devices"], method: "GET")
        guard let rows = try? JSONDecoder().decode([MacPairedDevice].self, from: data) else { throw Failure.malformedResponse }
        return rows
    }

    func revoke(_ id: String) async throws {
        _ = try await request(components: ["v1", "devices", id], method: "DELETE")
    }

    func removeRevoked(_ id: String) async throws {
        _ = try await request(components: ["v1", "devices", id, "revoked"], method: "DELETE")
    }

    private func request(components: [String], method: String) async throws -> Data {
        guard !address.isTicketOnly else { throw Failure.devicePairingRequired }
        let origin = try address.apiOrigin()
        var tokenRequest = URLRequest(url: origin.appendingPathComponent("v1/token"))
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = try JSONSerialization.data(withJSONObject: ["device_id": address.deviceID, "refresh_token": address.token])
        let tokenData = try await send(tokenRequest)
        guard let object = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let ticket = object["ws_ticket"] as? String, !ticket.isEmpty else { throw Failure.malformedResponse }
        let url = components.reduce(origin) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw Failure.rejected(http.statusCode, object?["detail"] as? String)
        }
        return data
    }
}
