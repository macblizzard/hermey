import Foundation

/// One connectable service on the Integrations screen (see `docs/INTEGRATIONS.md`).
///
/// `available` is separate from `connected` on purpose: a host with no Composio key can still *show*
/// Gmail, but the button must not look like it will work. `configured` on the state carries the same
/// fact for the whole screen.
public struct IntegrationService: Identifiable, Codable, Hashable, Sendable {
    public let slug: String
    public let name: String
    public let blurb: String
    public let connected: Bool
    public let accountID: String?
    public let available: Bool

    public var id: String { slug }

    public enum CodingKeys: String, CodingKey {
        case slug, name, blurb, connected, available
        case accountID = "account_id"
    }
}

/// `GET /v1/integrations` — what the screen renders, and whether this host can connect anything at all.
public struct IntegrationsState: Codable, Sendable {
    public let configured: Bool
    public let user: String
    public let services: [IntegrationService]

    public static func from(_ data: Data) throws -> IntegrationsState {
        try JSONDecoder().decode(IntegrationsState.self, from: data)
    }
}
