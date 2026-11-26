import Foundation

/// One saved secret, as both apps see it (`GET /v1/vault`, see `hermeyd/src/vault.rs`).
///
/// This type has **no field for a value**, and that is the whole safety argument: the vault's only
/// promise is that a value never leaves the host, so the app's copy of a row could not hold one even
/// if a later edit asked it to. What a row carries is a name, a kind, when it was saved, and — when the
/// card that saved it knew — where it is for and what asked for it.
///
/// The Mac's Vault tab and the phone's Vault screen both decode **this** type through
/// `VaultItem.list(from:)`, so the two platforms cannot drift: a field added here appears on both, and a
/// field the host stops sending becomes `nil` on both rather than failing one of them.
public struct VaultItem: Identifiable, Codable, Hashable, Sendable {
    /// The item's label, e.g. `openai.main` or `doctolib.de/password`. Unique; the row's identity.
    public let name: String
    /// What asked for it: `secret`, `login`, … (the card's `kind`). Defaults to `secret`.
    public let kind: String
    /// Unix seconds. For an entry saved before the host kept labels this is the store's own timestamp,
    /// which is the best the host has — it is shown as a date, never as a claim about one write.
    public let addedAt: Double
    /// The origin the card was about, when there was one. `nil` for an entry with no label.
    public let site: String?
    /// The card's one-line note, when it had one.
    public let note: String?

    public var id: String { name }

    /// `addedAt` as a date, for a row that says "added 3 Nov".
    public var addedOn: Date { Date(timeIntervalSince1970: addedAt) }

    public enum CodingKeys: String, CodingKey {
        case name, kind, addedAt, site, note
    }

    public init(name: String, kind: String, addedAt: Double, site: String?, note: String?) {
        self.name = name
        self.kind = kind
        self.addedAt = addedAt
        self.site = site
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "secret"
        addedAt = try container.decodeIfPresent(Double.self, forKey: .addedAt) ?? 0
        site = try container.decodeIfPresent(String.self, forKey: .site)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    /// `{"items": [{…}]}` from `GET /v1/vault`.
    ///
    /// A missing `items` key is an **error**, not an empty vault: the host always sends one, so its
    /// absence means the answer was not the vault's — and an empty list is exactly the reading that
    /// would make a broken connection look like a tidy vault.
    public static func list(from data: Data) throws -> [VaultItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["items"] as? [[String: Any]] else {
            throw VaultReadError.notTheVault
        }
        let decoder = JSONDecoder()
        return try rows.map { row in
            let body = try JSONSerialization.data(withJSONObject: row)
            return try decoder.decode(VaultItem.self, from: body)
        }
    }
}

/// Why a list could not be read. Thrown instead of returning `[]`, so a pane has to decide what to say.
public enum VaultReadError: Error, LocalizedError {
    case notTheVault

    public var errorDescription: String? {
        "The host's answer was not a vault listing."
    }
}

/// The vault's name rule, mirroring `hermeyd/src/secrets.rs` `valid_name`.
///
/// Both the host and the pane check the same pattern, and for different reasons: the host so a name can
/// never be a path, the pane so a form does not invite a name that will be refused after the value has
/// been typed. Keeping the rule in one shared type is what stops the two ends disagreeing about what
/// "valid" means.
public enum VaultName {
    /// `MAX_NAME_BYTES` in `secrets.rs`.
    public static let maxLength = 96

    /// The sentence a refused name is shown with — the host's own words.
    public static var rule: String {
        "A name is letters, digits, '.', '_', '-' and one '/', up to \(maxLength) characters."
    }

    /// Is this a name the host's vault will hold? Empty, too long, a leading or trailing `/`, `//`,
    /// `..`, or anything outside the alphabet is refused.
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maxLength else { return false }
        guard !name.hasPrefix("/"), !name.hasSuffix("/") else { return false }
        guard !name.contains("//"), !name.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Trim what a field collects around a name: a trailing newline pasted in is not part of it.
    public static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One sentence for a vault pane when a call failed.
///
/// Both platforms show this exact text, so "the host is unreachable" means the same thing on a Mac and a
/// phone. The distinction it protects is the one that matters most in this pane: an empty vault and a
/// vault that could not be read are different facts, and neither may be drawn as the other.
public enum VaultFailure {
    public static func sentence(_ error: Error) -> String {
        if error is URLError {
            return "The host could not be reached, so the vault is not shown. This is not an empty vault."
        }
        if error is BotAdminUnavailable {
            return "This host's bridge does not serve the vault yet. Update hermeyd on the host."
        }
        if let failure = error as? BridgeBotSessionPointer.Failure {
            switch failure {
            case .rejected(let status, let detail):
                let why = detail.map { ": \($0)" } ?? "."
                return "The host refused to show the vault (\(status))\(why)"
            case .notHTTP, .malformedResponse:
                return "The host's answer was not a vault listing."
            case .noProfile:
                return "This app is not pointed at a bot, so it cannot reach the host's vault."
            }
        }
        return "The host could not show the vault: \(error.localizedDescription)"
    }

    /// One sentence for a change the host refused — an edit, not a read.
    ///
    /// `sentence(_:)` says the vault could not be *shown*, which is the wrong verb for a sheet that asked
    /// the host to rename something; the reasons are the same, so they are answered the same way and only
    /// the sentence changes. Both platforms show this text, so a refusal reads the same on a Mac and a
    /// phone, and it always ends by saying that nothing was changed.
    public static func refused(_ error: Error) -> String {
        if error is URLError {
            return "The host could not be reached, so nothing was changed."
        }
        if error is BotAdminUnavailable {
            return "This host's bridge does not serve the vault yet, so nothing was changed. "
                + "Update hermeyd on the host."
        }
        if let failure = error as? BridgeBotSessionPointer.Failure {
            switch failure {
            case .rejected(let status, let detail):
                let why = detail.map { ": \($0)" } ?? "."
                return "The host refused the change (\(status))\(why)"
            case .notHTTP, .malformedResponse:
                return "The host's answer was not what an edit gets, so nothing was changed."
            case .noProfile:
                return "This app is not pointed at a bot, so it cannot reach the host's vault."
            }
        }
        return "The host could not make the change: \(error.localizedDescription)"
    }
}
