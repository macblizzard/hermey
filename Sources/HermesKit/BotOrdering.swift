import Foundation

/// The bot list's single ordering rule: pinned first, then by the last message exchanged.
///
/// Pinning is an explicit user decision, so it outranks recency; within the pinned group the most
/// recently used still comes first. Bots with no message history keep the host's own order at the
/// bottom, and a hidden bot is dropped before ordering so it cannot occupy a slot.
public enum BotOrdering {
    public static func order(_ bots: [Bot],
                             activity: [String: Date],
                             pinned: Set<String> = [],
                             hidden: Set<String> = []) -> [Bot] {

        let visible = bots.filter { !hidden.contains($0.id) }

        let indexed = visible.enumerated().map { (index, bot) -> (Bot, Bool, Date?, Int) in
            (bot, pinned.contains(bot.id), activity[bot.id], index)
        }

        return indexed.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 }          // pinned above unpinned
            switch (lhs.2, rhs.2) {
            case let (left?, right?):
                if left != right { return left > right }
                return lhs.3 < rhs.3
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.3 < rhs.3
            }
        }.map(\.0)
    }
}
