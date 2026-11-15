import Foundation

/// The soul a new bot starts from — one text, on the host, so a bot created on either device begins
/// with the same instructions (asked for 2026-11-15).
public struct BotDefaultSoul: Codable, Sendable, Equatable {
    public var text: String
    public var chars: Int
    public var present: Bool
    public var updatedAt: Date?

    public init(text: String = "", chars: Int = 0, present: Bool = false, updatedAt: Date? = nil) {
        self.text = text
        self.chars = chars
        self.present = present
        self.updatedAt = updatedAt
    }

    /// What a new bot starts from when the owner has not written anything here.
    public static let none = BotDefaultSoul()
}

/// `GET /v1/bot-defaults`: the owner's text, and the one Hermes itself would use.
public struct BotDefaults: Codable, Sendable, Equatable {
    public var soul: BotDefaultSoul
    /// Nil when the host could not read Hermes's own default — the screen then says "Hermes's
    /// default" instead of inventing a paragraph.
    public var builtIn: String?

    public init(soul: BotDefaultSoul = .none, builtIn: String? = nil) {
        self.soul = soul
        self.builtIn = builtIn
    }

    public static let empty = BotDefaults()

    private enum CodingKeys: String, CodingKey {
        case soul
        case builtIn = "built_in"
    }

    public static func decode(_ data: Data) throws -> BotDefaults {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BotDefaults.self, from: data)
    }
}

/// `POST /v1/backup/restore`: what the host did with a file, bot by bot.
public struct BackupRestoreResult: Codable, Sendable, Equatable {
    public struct Created: Codable, Sendable, Equatable {
        public var profile: String
        public var by: String
    }

    public struct Updated: Codable, Sendable, Equatable {
        public var profile: String
        public var wrote: [String]
    }

    public struct Skipped: Codable, Sendable, Equatable {
        public var profile: String?
        public var reason: String
    }

    public var created: [Created]
    public var updated: [Updated]
    public var skipped: [Skipped]
    public var routinesAdded: Int
    /// The scheduler keeps its jobs in memory: a routine written into `jobs.json` is real after the
    /// host restarts, and the screen says so rather than pretending it is running.
    public var restartRequired: Bool

    public init(created: [Created] = [], updated: [Updated] = [], skipped: [Skipped] = [],
                routinesAdded: Int = 0, restartRequired: Bool = false) {
        self.created = created
        self.updated = updated
        self.skipped = skipped
        self.routinesAdded = routinesAdded
        self.restartRequired = restartRequired
    }

    public static func decode(_ data: Data) throws -> BackupRestoreResult {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(BackupRestoreResult.self, from: data)
    }
}
