import Foundation

/// One connectable service on the Integrations screen (see `docs/INTEGRATIONS.md`).
///
/// `available` is separate from `connected` on purpose: a host with no Composio key can still *show*
/// Gmail, but the button must not look like it will work. `configured` on the state carries the same
/// fact for the whole screen.
/// One connected account for a service. Two Gmails are normal; the label is what the owner recognises.
public struct IntegrationAccount: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let label: String
}

public struct IntegrationService: Identifiable, Codable, Hashable, Sendable {
    public let slug: String
    public let name: String
    public let blurb: String
    public let connected: Bool
    public let accountID: String?
    public let available: Bool
    /// Every connected account: empty, one, or several. `connected` is derived from this on the host.
    public let accounts: [IntegrationAccount]
    /// True when this service is connected by a key the owner pastes, not by a hosted sign-in page.
    public let keyBased: Bool

    public var id: String { slug }

    public enum CodingKeys: String, CodingKey {
        case slug, name, blurb, connected, available, accounts, keyBased
        case accountID = "account_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decode(String.self, forKey: .name)
        blurb = try container.decode(String.self, forKey: .blurb)
        connected = try container.decode(Bool.self, forKey: .connected)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? true
        accounts = try container.decodeIfPresent([IntegrationAccount].self, forKey: .accounts) ?? []
        // An older host does not send this; absent means "use the browser", not "decode failed".
        keyBased = try container.decodeIfPresent(Bool.self, forKey: .keyBased) ?? false
    }
}

/// One input a key-based service wants, as Composio defines it — never hard-coded in the app.
public struct IntegrationKeyField: Identifiable, Codable, Hashable, Sendable {
    public let name: String
    public let label: String
    public let required: Bool
    public let secret: Bool

    public var id: String { name }
}

public struct IntegrationKeyFields: Codable, Sendable {
    public let slug: String
    public let fields: [IntegrationKeyField]
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
