import Foundation

/// A login card waiting for the owner (see `docs/CREDENTIALS.md`).
///
/// This is the app's copy of a card. It deliberately has **no field for a value**: a card announces
/// what it wants, the app asks the owner, and what they type goes straight back to the bridge. There is
/// no place in this type to keep a secret, which is the cheapest way to be sure the app cannot leak one.
public struct CredentialCard: Identifiable, Codable, Hashable, Sendable {
    /// `choice` asks which sign-in method; `secret` asks for masked fields; `confirm` asks yes/no.
    public let kind: String
    public let id: String
    /// The origin the bot is on, shown on every card so a prompt is never ambiguous.
    public let site: String
    /// For `secret`: the field names to collect ("password", "username", "one-time code").
    public let fields: [String]
    /// For `choice`: the methods the page actually offers.
    public let options: [String]
    public let note: String
    public let askedBy: String
    public let state: String
    public let expiresAt: Double

    public enum CodingKeys: String, CodingKey {
        case kind, id, site, fields, options, note, state
        case askedBy = "asked_by"
        case expiresAt = "expires_at"
    }

    public var isExpired: Bool { Date().timeIntervalSince1970 >= expiresAt }

    /// `{"cards": [...]}` from `GET /v1/credentials/cards`.
    public static func list(from data: Data) throws -> [CredentialCard] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["cards"] as? [[String: Any]] else { return [] }
        let decoder = JSONDecoder()
        return rows.compactMap { row in
            guard let body = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? decoder.decode(CredentialCard.self, from: body)
        }
    }
}
