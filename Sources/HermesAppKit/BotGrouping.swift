import Foundation
import HermesKit

/// One heading in the bot list: a category, or one of the two groups the app owns.
public struct BotGroup: Identifiable, Hashable, Sendable {
    /// The category's id, or a reserved id for a group the app draws itself.
    public let id: String
    public let name: String
    public let bots: [Bot]
    /// Uncategorized is drawn last and cannot be renamed or deleted.
    public let isUncategorized: Bool
    /// Pinned is the app's own heading, above every category.
    public let isPinned: Bool

    public init(id: String, name: String, bots: [Bot], isUncategorized: Bool = false, isPinned: Bool = false) {
        self.id = id
        self.name = name
        self.bots = bots
        self.isUncategorized = isUncategorized
        self.isPinned = isPinned
    }
}

/// Folds the bot list into the owner's categories.
///
/// The order is the one the list promises: **Pinned** first (when anything is pinned), then the
/// categories in the owner's arrangement — alphabetically until they move one — then
/// **Uncategorized** last — the group a bot lands in until it is sorted,
/// and the one that always exists. A category with no bots still comes back, so an empty group can
/// be seen (and filled) rather than silently disappearing.
///
/// The input order inside a group is the one it is handed: `AppModel.orderedBots` is already
/// "pinned, then last message", and re-sorting here would fight it.
public enum BotGrouping {
    /// Reserved ids, namespaced so a category id can never collide with them.
    public static let pinnedID = "__pinned"
    public static let uncategorizedID = "__uncategorized"
    public static let pinnedName = "Pinned"
    public static let uncategorizedName = "Uncategorized"
    /// The heading over the group chats. Not a category — a room has no category on the host — but
    /// it is the third heading the app draws itself, and both surfaces must spell it the same way.
    public static let roomsID = "__rooms"
    public static let roomsName = "Group chats"

    public static func groups(bots: [Bot],
                              state: BotCategoryState,
                              pinned: Set<String>) -> [BotGroup] {
        let botsByID = Dictionary(uniqueKeysWithValues: bots.map { ($0.id, $0) })

        // Pinned first, in the order the caller gave.
        var groups: [BotGroup] = []
        let pinnedBots = bots.filter { pinned.contains($0.id) }
        if !pinnedBots.isEmpty {
            groups.append(BotGroup(id: pinnedID, name: pinnedName, bots: pinnedBots, isPinned: true))
        }

        // Then the categories, by name, case-insensitively — "work" and "Work" sit together.
        var byCategory: [String: [Bot]] = [:]
        var uncategorized: [Bot] = []
        for bot in bots {
            // A pinned bot is in the Pinned heading; showing it twice would be a second row that
            // opens the same chat.
            if pinned.contains(bot.id) { continue }
            if let category = state.categoryID(for: bot.id), botsByID[bot.id] != nil {
                byCategory[category, default: []].append(bot)
            } else {
                uncategorized.append(bot)
            }
        }

        for category in arranged(state.categories, by: state.order) {
            groups.append(BotGroup(id: category.id,
                                   name: category.name,
                                   bots: byCategory[category.id] ?? []))
        }

        // Uncategorized last, even when it is empty: it is where an unsorted bot goes, and a group
        // that appears only once it has a member looks like the app forgot about it.
        groups.append(BotGroup(id: uncategorizedID,
                               name: uncategorizedName,
                               bots: uncategorized,
                               isUncategorized: true))
        return groups
    }


    /// The categories in the order the owner arranged, or alphabetically when they have not.
    ///
    /// An empty arrangement is not "no categories" — it is "nobody has moved anything", which has to
    /// keep looking alphabetical so an existing install does not silently reorder itself. A category
    /// missing from the arrangement (created on another device since the app read it) takes its
    /// alphabetical place among the others rather than jumping to the end.
    static func arranged(_ categories: [BotCategory], by order: [String]) -> [BotCategory] {
        let alphabetical = categories.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !order.isEmpty else { return alphabetical }
        var rank: [String: Int] = [:]
        for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
        return alphabetical.enumerated().sorted { left, right in
            let leftRank = rank[left.element.id] ?? Int.max
            let rightRank = rank[right.element.id] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// The collapse key for a group's remembered state.
    public static func collapseKey(host: String, group: String) -> String {
        "hermey.collapsedGroups.\(host).\(group)"
    }
}
