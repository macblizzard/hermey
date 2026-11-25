import Foundation

/// What happened to a transcript between two builds.
///
/// The transcript is append-only in practice — a turn's rows go on the end, an earlier page goes on
/// the front, and everything else (a resume, a switch, a cache paint) *replaces* it. Saying which of
/// those happened costs three id comparisons; discovering it by comparing every row costs a walk of
/// the whole conversation, and on a 6,400-row chat that walk was happening several times a second
/// while a page was landing above the reader.
///
/// The check is structural, not a fingerprint: an append has to still have the old last row at the
/// old last index, and a prepend has to still have the old first row shifted by exactly the number
/// of rows that arrived. A transcript that was edited in place therefore fails both tests and is
/// treated as replaced, which is the safe answer.
public enum TranscriptSplice: Equatable, Sendable {
    /// Same rows, same order — nothing to rebuild.
    case unchanged
    /// `count` rows arrived at the front; everything the reader was looking at is still there.
    case prepended(Int)
    /// `count` rows arrived at the end.
    case appended(Int)
    /// Anything else: a resume, a session switch, a cache paint, a withdrawal.
    case replaced

    /// How many rows the change added to the drawn list (negative for nothing, since a removal is
    /// a replacement).
    public var added: Int {
        switch self {
        case .appended(let count), .prepended(let count): return count
        case .unchanged, .replaced: return 0
        }
    }
}

public enum TranscriptSplices {
    /// Which of the four changes turned `previous` into `entries`.
    ///
    /// `generation` is bumped by the model whenever the transcript is *replaced*, because a
    /// replacement can keep both end ids (a resume that re-sends an identical page) and ids alone
    /// cannot see that its rows were re-decorated.
    public static func detect(previous: [TranscriptEntry],
                              entries: [TranscriptEntry],
                              sameGeneration: Bool = true) -> TranscriptSplice {
        guard sameGeneration else { return .replaced }
        if previous.count == entries.count {
            guard !entries.isEmpty else { return .unchanged }
            return entries.first?.id == previous.first?.id && entries.last?.id == previous.last?.id
                ? .unchanged
                : .replaced
        }
        guard entries.count > previous.count, !previous.isEmpty,
              let oldFirst = previous.first?.id,
              let oldLast = previous.last?.id else { return .replaced }
        // Both splices leave the tail alone: the row that was last is still last.
        guard entries.last?.id == oldLast else { return .replaced }
        let arrived = entries.count - previous.count

        // Appended: the old last row still sits at the old last index.
        if entries[previous.count - 1].id == oldLast {
            return .appended(arrived)
        }
        // Prepended: the old first row moved down by exactly as many rows as arrived. (The *new*
        // first row is the page's own first row, so it says nothing about this.)
        if entries[entries.count - previous.count].id == oldFirst {
            return .prepended(arrived)
        }
        return .replaced
    }
}
