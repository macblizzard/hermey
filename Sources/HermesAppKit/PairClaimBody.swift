import Foundation

/// The body `POST /v1/pair/claim` takes, and the one place its field names live.
///
/// The host's model is snake_case (`public_key`, `device_name`); Swift's default key encoding is
/// camelCase, and the Mac app posted `publicKey`/`deviceName` — the host answered **422** for the
/// missing `public_key` and the sheet could only say "The host refused the pairing (HTTP 422)". The
/// phone had always spelled the keys itself, so only one of the two clients was broken.
///
/// Encoding a request body is not a view's job, so it lives here where a test can hold it to the
/// wire format without a socket or a Mac.
public struct PairClaimBody: Encodable, Equatable, Sendable {
    public let code: String
    public let publicKey: String
    public let deviceName: String
    public let platform: String

    public init(code: String, publicKey: String, deviceName: String, platform: String) {
        self.code = code
        self.publicKey = publicKey
        self.deviceName = deviceName
        self.platform = platform
    }

    enum CodingKeys: String, CodingKey {
        case code
        case publicKey = "public_key"
        case deviceName = "device_name"
        case platform
    }

    /// The bytes to send: exactly these four keys, snake_case, in a stable order.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// What went wrong, out of a refusal the host wrote.
    ///
    /// FastAPI answers a validation failure with `{"detail": [{"loc": ["body", "public_key"], "msg":
    /// "field required"}]}` and a handled refusal with `{"detail": "pairing code invalid or
    /// expired"}`. Reading only the string shape is how the 422 above reached the screen with no
    /// reason attached, so both shapes are read, and anything unrecognised yields "" rather than a
    /// lie.
    public static func detail(in data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = root["detail"] else { return "" }

        if let text = detail as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let items = detail as? [[String: Any]] {
            let lines = items.compactMap { item -> String? in
                let message = (item["msg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let field = (item["loc"] as? [Any])?
                    .compactMap { $0 as? String }
                    .filter { $0 != "body" }
                    .joined(separator: ".")
                guard let message, !message.isEmpty else { return nil }
                guard let field, !field.isEmpty else { return message }
                return "\(field): \(message)"
            }
            return lines.joined(separator: "; ")
        }
        return ""
    }
}
