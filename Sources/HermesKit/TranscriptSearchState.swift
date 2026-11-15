import Foundation

/// The Mac's in-chat search as a value, instead of three `@State` fields inside the view.
///
/// `ConversationSearch` answers *what* matches and *where* the cursor may land; this owns the part
/// around it that the desktop reading surface has to get right — whether the bar is up, what is in
/// its field, which result the chevrons are on — and it does so outside SwiftUI so the rules can be
/// tested without a window, a run loop or a Mac.
///
/// The rules it states, each one a bug that a plain `@State` trio could not prevent:
///
/// * **opening twice keeps what was typed.** ⌘F, the bot panel row and the Conversation menu are
///   all the same door: a second press has to put the caret back in the field, not silently wipe the
///   query the reader was midway through;
/// * **closing clears everything** — the field, the answer and the cursor. A bar that reopens on
///   the last search but reports `2 of 5` with no answer on screen is the "search looks broken"
///   shape;
/// * **an open bar owns the scroll position even while the field is empty.** Auto-follow is what
///   pulled the transcript to the bottom a heartbeat after a match was scrolled to, and "the field
///   is up but nothing has been typed yet" is exactly when a streaming turn lands;
/// * **the cursor is clamped, never trusted.** A query that narrows leaves an index earned under a
///   wider one, and `clamped` is what keeps it on a row that still matches (`TranscriptSearchState`
///   is the only writer of `index`, so no view can skip it);
/// * **a different conversation is a different search.** Opening a bot's chat closes the bar rather
///   than leaving a query behind that describes rows no longer on screen.
///
/// The phone keeps the same four values inline in `ConversationScreen`; it is one screen with one
/// search, and its `@State` is already local. The Mac has three doors into the same bar, which is
/// why the state is named here.
public struct TranscriptSearchState: Equatable {

    /// Whether the bar is on screen. `ConversationSearch.isActive(query)` is a different question —
    /// a bar can be open with an empty field, and then it still owns the transcript.
    public private(set) var isOpen = false

    /// What is in the field, exactly as typed. Assigning it puts the cursor back on the first
    /// result: the answer under a new query is a new list, and holding an old position in it is how
    /// a count came to read `4 of 2`.
    public var query: String = "" {
        didSet { if query != oldValue { index = 0 } }
    }

    /// Which result the chevrons are on. Private so every write goes through `reconcile` or `step`.
    public private(set) var index = 0

    public init() {}

    // MARK: - What the bar is telling the transcript

    /// True while there is a query to answer. An open bar with an empty field is not this.
    public var isActive: Bool { ConversationSearch.isActive(query) }

    /// True while the transcript must not be yanked around by new content.
    ///
    /// Deliberately the *bar*, not the query: the reader opened a search and is reading; a token
    /// that lands mid-search must not move the row they just scrolled to, and the gap between ⌘F
    /// and the first keystroke is when that most often happens.
    public var ownsScrollPosition: Bool { isOpen }

    // MARK: - The doors

    /// ⌘F, the bot panel's "Search this conversation", the Conversation menu. Idempotent on
    /// purpose: all three bump the same request, and the second press must only re-focus.
    public mutating func open() { isOpen = true }

    /// Done, Escape, or a different bot's conversation. Everything goes, so the next open starts
    /// from an empty field rather than from the last answer.
    public mutating func close() {
        isOpen = false
        query = ""
        index = 0
    }

    /// A conversation changed under the bar: same as `close()`, named for the caller's reason so
    /// the intent survives a refactor that stops closing on session change.
    public mutating func resetForConversationChange() { close() }

    // MARK: - Moving through the answer

    /// Fold `count` — the answer to the query in the field *right now* — into the cursor.
    ///
    /// Called on every change of the match list, including when it empties: `0` is a legal cursor
    /// for no matches, and pointing past the end is how a search "loses" its last result.
    public mutating func reconcile(count: Int) {
        index = ConversationSearch.clamped(index, count: count)
    }

    /// Next (`+1`) / previous (`-1`), wrapping, and a no-op that lands on `0` when nothing matches.
    public mutating func step(by direction: Int, count: Int) {
        index = ConversationSearch.stepped(index, count: count, by: direction)
    }

    /// The row to scroll to and light up, if any: nothing while the bar is closed, and nothing when
    /// the answer is empty — the two cases where a stale id used to stay highlighted.
    public func selected(in ids: [String]) -> String? {
        guard isOpen, ids.indices.contains(index) else { return nil }
        return ids[index]
    }

    /// What the bar says beside the field — `1 of 3`, `No matches for “leak”`, or nothing at all.
    /// One sentence for the view, from the shared matcher, so the count cannot disagree with the
    /// rows it counts.
    public func status(matched: Int) -> String {
        ConversationSearch.status(query: query, matched: matched, index: index)
    }
}
