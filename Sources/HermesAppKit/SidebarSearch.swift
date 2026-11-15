import Foundation
import HermesKit

/// What the bot panel's one field is showing, as one value the list can switch on.
///
/// The panel has three different sources of truth — the query that was typed, the query the host
/// last answered, and whether a request is in flight — and it has to say something sensible about
/// every combination. Keeping the decision here, instead of spreading `if`s through the view,
/// is what makes "no matches" impossible to say about a query nobody asked yet, and what lets the
/// rules be tested without a window.
public enum SidebarSearchPhase: Equatable, Sendable {
    /// Nothing typed. The panel is a plain roster.
    case idle
    /// One character. The host will not answer this (its own minimum is two), so the panel says so
    /// rather than claiming the phrase was searched and came back empty.
    case tooShort
    /// Typed, but the debounce has not handed it to the host yet.
    case waiting
    /// A request for this phrase is in flight.
    case searching
    /// The host answered with findings.
    case results
    /// The host answered this phrase with no findings, but bot names matched.
    case messagesEmpty
    /// Neither a message nor a bot name matched.
    case noMatches
}

/// One line of the panel's combined answer, in the order the keyboard walks it: findings about
/// messages first, then the bots whose names match.
public enum SidebarSearchRow: Hashable, Sendable {
    case message(BotSearchHit.ID)
    case bot(String)
}

/// The rules the panel's search follows, and nothing that needs SwiftUI.
public enum SidebarSearch {

    /// The host's own floor (`MIN_QUERY` in the bridge). Below it nothing is even asked, so the
    /// panel must not report an empty answer.
    public static let minimumQuery = 2

    /// The query without the whitespace around it. Whitespace is never a search.
    public static func trimmed(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Name first, then id: a bot called "Assistant" whose profile id is `assistant` answers to
    /// either, and to any casing of both. An empty query matches every bot, which is the unfiltered
    /// roster.
    public static func matches(_ bot: Bot, query: String) -> Bool {
        let needle = trimmed(query)
        guard !needle.isEmpty else { return true }
        return bot.displayName.localizedCaseInsensitiveContains(needle)
            || bot.id.localizedCaseInsensitiveContains(needle)
    }

    /// The state the panel is in, from the three facts it has.
    ///
    /// `answered` is the phrase the host's findings belong to, not the one in the field: showing
    /// "no matches" for a phrase typed a moment ago, before the request has left, is how a search
    /// for something present in the transcript got told it was absent.
    public static func phase(query: String,
                             answered: String,
                             running: Bool,
                             hits: Int,
                             botMatches: Int) -> SidebarSearchPhase {
        let needle = trimmed(query)
        if needle.isEmpty { return .idle }
        if needle.count < minimumQuery { return .tooShort }
        if hits > 0 { return .results }
        if running { return .searching }
        if trimmed(answered) != needle { return .waiting }
        return botMatches > 0 ? .messagesEmpty : .noMatches
    }

    /// The combined list the keyboard moves through: findings first, then bots.
    public static func rows(hits: [BotSearchHit], botIDs: [String]) -> [SidebarSearchRow] {
        let findings: [SidebarSearchRow] = hits.map { .message($0.id) }
        let bots: [SidebarSearchRow] = botIDs.map { .bot($0) }
        return findings + bots
    }
}

/// Where the cursor is in the panel's combined answer.
///
/// A value type rather than a pile of `@State` on the view: "the highlighted row" plus "the rows
/// that exist" is exactly the pair that goes out of step when the host answers a narrower query
/// while the chevrons are on row five.
public struct SidebarSearchSelection: Equatable {

    public private(set) var rows: [SidebarSearchRow]
    /// `nil` is the state the field starts in: nothing was highlighted by the keyboard yet, so a
    /// Return opens the first row rather than a row chosen under a query that no longer exists.
    public private(set) var highlighted: SidebarSearchRow?

    public init(rows: [SidebarSearchRow] = [], highlighted: SidebarSearchRow? = nil) {
        self.rows = rows
        self.highlighted = highlighted.flatMap { rows.contains($0) ? $0 : nil }
    }

    /// Adopt a new answer, keeping the highlight only while it still names a row that is there.
    ///
    /// Anchored on the row's identity rather than on its index: a finding arriving above the
    /// highlighted bot must not slide the cursor onto the finding above it.
    public mutating func update(rows: [SidebarSearchRow]) {
        self.rows = rows
        if let highlighted, !rows.contains(highlighted) { self.highlighted = nil }
    }

    /// The field was closed or emptied.
    public mutating func clear() {
        rows = []
        highlighted = nil
    }

    /// Up (`-1`) / down (`+1`), wrapping at both ends, and defined at every count including none.
    ///
    /// From "nothing highlighted" this is the field's usual arrival at the list: Down lands on the
    /// first row, Up on the last, so one key press is always enough to start walking.
    public mutating func move(by direction: Int) {
        guard !rows.isEmpty else {
            highlighted = nil
            return
        }
        guard let current = highlighted.flatMap({ rows.firstIndex(of: $0) }) else {
            highlighted = rows[direction < 0 ? rows.count - 1 : 0]
            return
        }
        let count = rows.count
        let next = ((current + direction) % count + count) % count
        highlighted = rows[next]
    }

    /// What Return should open: the highlighted row, or the first one when the keyboard has not
    /// chosen anything yet.
    public var opening: SidebarSearchRow? { highlighted ?? rows.first }
}
