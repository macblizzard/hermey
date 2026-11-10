import CryptoKit
import Foundation

/// Redeems a pairing code for a device row on the host — the step the Mac sheet could not do, and
/// the reason a code from `hermey pair` was useless on this platform.
///
/// The request is the same one the phone makes: `POST /v1/pair/claim` with the code, a device name,
/// the platform and an Ed25519 public key. The bridge records the key but does not yet challenge the
/// device to prove it holds the private half (`docs/SECURITY.md`, G1), so the key is generated per
/// claim and thrown away with it: inventing a lie about proof-of-possession would be worse than
/// sending none.
enum PairingClaim {
    struct Result: Sendable {
        let deviceID: String
        let refreshToken: String
    }

    enum Failure: LocalizedError {
        case badCode
        case unreachable
        case refused(Int, String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .badCode:
                return "That code has expired or was already used. Mint a new one with `hermey pair`."
            case .unreachable:
                return "Could not reach the host. Check the address and that Tailscale is connected."
            case let .refused(status, detail):
                return detail.isEmpty ? "The host refused the pairing (HTTP \(status))."
                                    : "The host refused the pairing: \(detail)"
            case .malformed:
                return "The host answered something this app did not understand."
            }
        }
    }

    private struct ClaimResponse: Decodable {
        let deviceID: String
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case refreshToken = "refresh_token"
        }
    }

    static func claim(code: String, host: String, deviceName: String) async throws -> Result {
        guard let url = URL(string: host.hasSuffix("/") ? host + "v1/pair/claim" : host + "/v1/pair/claim") else {
            throw Failure.unreachable
        }

        let key = Curve25519.Signing.PrivateKey()
        // The host's field names are snake_case and `PairClaimBody` owns them: spelling them here as
        // `publicKey`/`deviceName` is what the host answered 422 to.
        let body = PairClaimBody(code: code,
                                 publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
                                 deviceName: deviceName,
                                 platform: "macos")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try body.encoded()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        guard (200..<300).contains(http.statusCode) else {
            // Every refusal carries the host's own words when it wrote any — a 422 used to reach the
            // screen as a bare status code because its `detail` is an array, not a string.
            let detail = PairClaimBody.detail(in: data)
            if http.statusCode == 400 || http.statusCode == 404 || http.statusCode == 409 {
                throw Failure.badCode
            }
            throw Failure.refused(http.statusCode, detail)
        }
        guard let decoded = try? JSONDecoder().decode(ClaimResponse.self, from: data) else {
            throw Failure.malformed
        }
        return Result(deviceID: decoded.deviceID, refreshToken: decoded.refreshToken)
    }
}
