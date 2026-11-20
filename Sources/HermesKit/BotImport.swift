import Foundation

/// One bot the import would create or change, as the host reports it.
public struct BotImportChange: Codable, Hashable, Sendable {
    public let profile: String
    public let reason: String?
    public let from: String?

    public var id: String { profile }
}

/// `POST /v1/backup/import` — the plan a dry run returns, or the result of applying it.
///
/// The same shape for both on purpose: the preview the owner approves is the work that then happens, rather
/// than a second description that could disagree with it.
public struct BackupImportResult: Codable, Sendable {
    public let mode: String
    public let dryRun: Bool
    public let created: [BotImportChange]
    public let updated: [BotImportChange]
    public let skipped: [BotImportChange]
    public let documents: [String]
    public let icons: [String]
    public let routinesAdded: Int
    public let restartRequired: Bool

    public enum CodingKeys: String, CodingKey {
        case mode, created, updated, skipped, documents, icons
        case dryRun = "dry_run"
        case routinesAdded = "routines_added"
        case restartRequired = "restart_required"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "merge"
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        created = try container.decodeIfPresent([BotImportChange].self, forKey: .created) ?? []
        updated = try container.decodeIfPresent([BotImportChange].self, forKey: .updated) ?? []
        skipped = try container.decodeIfPresent([BotImportChange].self, forKey: .skipped) ?? []
        documents = try container.decodeIfPresent([String].self, forKey: .documents) ?? []
        icons = try container.decodeIfPresent([String].self, forKey: .icons) ?? []
        routinesAdded = try container.decodeIfPresent(Int.self, forKey: .routinesAdded) ?? 0
        restartRequired = try container.decodeIfPresent(Bool.self, forKey: .restartRequired) ?? false
    }

    public static func decode(_ data: Data) throws -> BackupImportResult {
        try JSONDecoder().decode(BackupImportResult.self, from: data)
    }

    /// What the owner reads before pressing the button.
    public var preview: String {
        var parts: [String] = []
        if !created.isEmpty { parts.append("create \(created.count)") }
        if !updated.isEmpty { parts.append("fill in \(updated.count)") }
        if skipped.isEmpty == false { parts.append("skip \(skipped.count)") }
        if routinesAdded > 0 { parts.append("add \(routinesAdded) routine(s)") }
        if icons.isEmpty == false { parts.append("restore \(icons.count) icon(s)") }
        return parts.isEmpty ? "nothing would change" : parts.joined(separator: ", ")
    }
}

/// How an import treats a bot that is already here. The owner picks; the host never guesses.
public enum BotImportMode: String, CaseIterable, Identifiable, Sendable {
    /// Create what is missing and fill only what is empty — a live bot keeps its own words.
    case merge
    /// Also replace a bot's soul, memory and notes from the file.
    case overwrite
    /// Never touch an existing bot: each one lands beside it as name-2.
    case copy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .merge: return "Keep mine (fill gaps)"
        case .overwrite: return "Replace with the file"
        case .copy: return "Import as separate bots"
        }
    }
}
