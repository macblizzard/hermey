import Foundation

/// Searching inside one open conversation.
///
/// Each transcript — the phone's `ConversationScreen` and the Mac's `TranscriptScroll` — used to
/// carry its own copy of the filter, and both were `text.localizedCaseInsensitiveContains(query)`
/// over the row exactly as it is stored. Three things around that made a grown query lose its
/// answer:
///
/// * the comparison is **locale- and diacritic-sensitive**, so `cafe` only found `café` while the
///   host happened to render it unaccented, and a device set to a different language answered a
///   different question;
/// * the row was searched **as stored**, so a line the markdown renderer wrapped (`the vault` /
///   `holds the key`) answered nothing for `vault holds` even though both words are on the row;
/// * each platform grew its own clamp-and-reset rule around the index, so an index earned under a
///   wider query survived one that had fewer matches and the count read `4 of 2` instead of the
///   next result.
///
/// One matcher, used by both platforms, removes the disagreement rather than fixing it twice.
///
/// The contract, in full:
///
/// * an **empty or whitespace-only query is inactive** — no matches, no count, no "No matches";
/// * matching is a **substring** of the folded text (case-, diacritic- and width-insensitive, with
///   runs of whitespace collapsed to one space), so it answers at one character exactly as it does
///   at four, and a typed accent is not a different query from the unaccented letter;
/// * a query that **grows can only narrow** the answer: every row a longer query matches, the
///   shorter query matched too. The count may fall on a keystroke; it never rises, and a row that
///   matched at two characters cannot leave the answer unless the query genuinely stopped matching
///   it. That is the property the old per-platform code could not state, let alone test;
/// * **ids come back in transcript order**, with the live turn last, so next/previous walk the
///   conversation the way it is read;
/// * navigation is **defined at every length**, including none: `stepped` wraps, and a query that
///   narrowed clamps the index instead of pointing past the end.
public enum ConversationSearch {

    /// The one prompt both platforms put in their field. It says the *scope* — this conversation,
    /// not the host's bots — because that is the thing the two searches in the app were confusing
    /// (reported 2026-11-15, "search bot wasn't properly replaced with search conversation").
    public static let prompt = "Search this conversation"

    /// Pinned so the same query answers the same way on a phone set to Turkish and a Mac set to
    /// English: case folding must not depend on whose device is typing.
    private static let locale = Locale(identifier: "en_US_POSIX")

    /// Whether the field is doing anything at all. Whitespace is not a query.
    public static func isActive(_ query: String) -> Bool {
        !folded(query).isEmpty
    }

    /// What is actually compared: case-, diacritic- and width-folded, whitespace-collapsed.
    ///
    /// Pure ASCII takes the cheap path (`lowercased`), which is what almost every keystroke and
    /// almost every row are; folding is the Unicode path and only runs when it has work to do.
    /// Both sides of every comparison go through this one function, which is what makes the
    /// monotonicity property below hold.
    public static func folded(_ text: String) -> String {
        let lowered: String
        if text.unicodeScalars.allSatisfy({ $0.isASCII }) {
            lowered = text.lowercased()
        } else {
            lowered = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                   locale: locale)
        }
        return lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Does `text` contain `query`? False for an inactive query: an empty field matches nothing,
    /// rather than everything.
    public static func matches(_ query: String, in text: String) -> Bool {
        let needle = folded(query)
        guard !needle.isEmpty else { return false }
        return folded(text).contains(needle)
    }

    /// The ids of the rows that match, in the order given, then `extra` last.
    ///
    /// `extra` is the live turn: it is not in the transcript yet, but it is on screen and a person
    /// searching what they just watched streamed expects to land on it.
    public static func ids<Element>(matching query: String,
                                    in items: [Element],
                                    id: (Element) -> String,
                                    text: (Element) -> String,
                                    extra: (id: String, text: String)? = nil) -> [String] {
        let needle = folded(query)
        guard !needle.isEmpty else { return [] }
        var found: [String] = []
        found.reserveCapacity(items.count)
        for item in items where folded(text(item)).contains(needle) {
            found.append(id(item))
        }
        if let extra, folded(extra.text).contains(needle) {
            found.append(extra.id)
        }
        return found
    }

    /// An index that is safe to use against `count` results — `0` when there are none, so a caller
    /// can never subscript past the end after the query narrowed.
    public static func clamped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    /// The next (`+1`) or previous (`-1`) result, wrapping at both ends — and `0` when there is
    /// nothing to step through.
    public static func stepped(_ index: Int, count: Int, by direction: Int) -> Int {
        guard count > 0 else { return 0 }
        let base = clamped(index, count: count)
        return ((base + direction) % count + count) % count
    }

    /// What the field says beside it: nothing while inactive, `1 of 3` while there are results, and
    /// the query named out loud when there are none — "No matches" alone left the reader wondering
    /// whether the field had taken the last keystroke.
    public static func status(query: String, matched: Int, index: Int) -> String {
        guard isActive(query) else { return "" }
        guard matched > 0 else { return "No matches for “\(trimmed(query))”" }
        return "\(clamped(index, count: matched) + 1) of \(matched)"
    }

    /// The query as the reader typed it, minus the edges: the empty-answer sentence quotes what was
    /// actually searched, not the folded form.
    public static func trimmed(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
