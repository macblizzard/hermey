import Foundation

/// A login card waiting for the owner (see `docs/CREDENTIALS.md`).
///
/// This is the app's copy of a card. It deliberately has **no field for a value**: a card announces
/// what it wants, the app asks the owner, and what they type goes straight back to the bridge. There is
/// no place in this type to keep a secret, which is the cheapest way to be sure the app cannot leak one.
///
/// Two things the host decides and this type only carries:
///
/// * `masked` — which of `fields` are secrets. The app no longer recognises a field by calling it
///   "password": the host names the masked ones, so a card asking for an `api key` is a secure field
///   without an app release, and an older host that names nothing still gets everything but the
///   ordinary fields masked (`CredentialCard.plainFields`).
/// * `store` — whether the answer is saved to the host's vault (`true`) or typed into a page once
///   (`false`). It changes the sheet's words and nothing else: a stored answer never comes back to the
///   app or the bot, only the name it was saved under.
public struct CredentialCard: Identifiable, Codable, Hashable, Sendable {
    /// `choice` asks which sign-in method; `secret` asks for masked fields; `confirm` asks yes/no.
    public let kind: String
    public let id: String
    /// The origin the bot is on, shown on every card so a prompt is never ambiguous.
    public let site: String
    /// For `secret`: the field names to collect ("password", "username", "one-time code", "api key").
    public let fields: [String]
    /// For `secret`: the field names to draw as secure inputs. From the host, which knows what it is
    /// asking for; absent on an older host, and then `defaultMasked` decides.
    public let masked: [String]
    /// For `secret`: save the answer in the host's vault instead of filling it into a page.
    public let store: Bool
    /// The submit button's words, decided by the host so a bot cannot relabel a vault save as a fill.
    public let submit: String
    /// For `choice`: the methods the page actually offers.
    public let options: [String]
    public let note: String
    public let askedBy: String
    public let state: String
    public let expiresAt: Double

    public enum CodingKeys: String, CodingKey {
        case kind, id, site, fields, masked, store, submit, options, note, state
        case askedBy = "asked_by"
        case expiresAt = "expires_at"
    }

    /// Field names that are ordinary, visible text. The same list the host masks by
    /// (`hermeyd/src/secrets.rs`), repeated so an older host still hides an API key rather than
    /// drawing it in the clear.
    public static let plainFields: Set<String> = ["username", "user", "email", "site", "host", "account", "login"]

    public var isExpired: Bool { Date().timeIntervalSince1970 >= expiresAt }

    /// Is this field a secret? The host's own list wins; without one, mask anything that is not a
    /// known-plain name, because the safe answer is the default.
    public func isMasked(_ field: String) -> Bool {
        if !masked.isEmpty { return masked.contains(field) }
        return CredentialCard.defaultMasked([field]).contains(field)
    }

    /// Masked field names for a card that did not name them: every field that is not plain.
    public static func defaultMasked(_ fields: [String]) -> [String] {
        fields.filter { !plainFields.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    /// The line under the form: where the value is about to go. It is the one promise the sheet makes,
    /// so it names the destination rather than a slogan.
    public var destinationNote: String {
        store
            ? "Saved to the vault on this host — the bot gets its name, never the value."
            : "Typed straight into the page — it never enters the chat."
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        id = try container.decode(String.self, forKey: .id)
        site = try container.decode(String.self, forKey: .site)
        fields = try container.decodeIfPresent([String].self, forKey: .fields) ?? []
        masked = try container.decodeIfPresent([String].self, forKey: .masked)
            ?? CredentialCard.defaultMasked(fields)
        store = try container.decodeIfPresent(Bool.self, forKey: .store) ?? false
        submit = try container.decodeIfPresent(String.self, forKey: .submit)
            ?? (store ? "Save to the vault" : "Fill it in")
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        askedBy = try container.decodeIfPresent(String.self, forKey: .askedBy) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "pending"
        expiresAt = try container.decodeIfPresent(Double.self, forKey: .expiresAt) ?? 0
    }

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
