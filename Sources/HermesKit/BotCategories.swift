import Foundation

/// One of the owner's own groups of bots.
///
/// A category is stored on the host, not on the device: the phone and the Mac show the same groups
/// because they read the same answer (see `Bridge/hermes_bridge/bot_categories.py`). Bots with no
/// assignment are *Uncategorized* — the app draws that group and the host never invents a row for
/// it.
public struct BotCategory: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The whole document: the groups, and which bot sits in which.
public struct BotCategoryState: Hashable, Sendable {
    public let categories: [BotCategory]
    /// profile id → category id
    public let assignments: [String: String]

    public static let empty = BotCategoryState(categories: [], assignments: [:])

    public init(categories: [BotCategory], assignments: [String: String]) {
        self.categories = categories
        self.assignments = assignments
    }

    public func categoryID(for profile: String) -> String? {
        assignments[profile]
    }

    /// The name to show for a bot, or `nil` when it is uncategorized.
    public func categoryName(for profile: String) -> String? {
        guard let id = assignments[profile] else { return nil }
        return categories.first { $0.id == id }?.name
    }

    /// The document as the bridge sends it: `{"categories": [...], "assignments": {...}}`.
    public static func decode(_ data: Data) throws -> BotCategoryState {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingFailure.notADocument
        }
        let categories = (root["categories"] as? [[String: Any]] ?? []).compactMap { entry -> BotCategory? in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
            return BotCategory(id: id, name: name)
        }
        var assignments: [String: String] = [:]
        for (profile, value) in (root["assignments"] as? [String: Any] ?? [:]) {
            if let category = value as? String, !category.isEmpty { assignments[profile] = category }
        }
        return BotCategoryState(categories: categories, assignments: assignments)
    }

    public enum DecodingFailure: LocalizedError {
        case notADocument
        public var errorDescription: String? {
            "The host's answer about categories was not a document."
        }
    }
}
