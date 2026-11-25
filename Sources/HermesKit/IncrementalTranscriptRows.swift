import Foundation

/// The drawn transcript, maintained instead of rebuilt.
///
/// `TranscriptGrouping.rows` walked the whole conversation, and both shells call it from a view
/// body — so every publish of `AppModel` regrouped 6,400 rows to draw ten. The old answer was a
/// cache keyed on `(count, lastID)`, which is enough while a turn appends and useless the moment a
/// page lands *above* the reader: a prepend changes the count and not the last id, so the whole
/// transcript was regrouped again, and the array SwiftUI then diffed was brand new each time.
/// Scrolled back through a long chat that is a full regroup per page plus a full re-diff, on the
/// main actor, while the finger is still moving (reported 2026-11-25: "stuck after scrolling for
/// some time for up to 30 seconds").
///
/// So the cache keeps the entries it was given and the rows it made from them, and asks
/// `TranscriptSplices` what changed:
///
/// * `.unchanged` — nothing at all, not even a copy. A body pass with no transcript change costs a
///   few nanoseconds now.
/// * `.appended(k)` — group only the `k` new rows, after un-folding the one run they can still join.
/// * `.prepended(k)` — group only the `k` new rows, and re-form the single run at the join if the
///   page ends in tool calls and the old rows start with them.
/// * `.replaced` — the full pass, which is what a resume, a switch or a withdrawal deserves.
///
/// The work is bounded by the page, not by the conversation. The one asymmetry that remains is tool
/// runs: a page boundary cut through a run of commands re-groups *that run*, which is why the
/// boundary helpers below walk a run and not the transcript.
///
/// `appending:` is the live cards from a running turn. They are grouped separately every pass —
/// they are a handful of rows and their durations change — so `visibleTranscript + liveToolEntries`
/// never has to allocate a six-thousand-element copy on a body pass again.
public final class TranscriptRowCache {
    /// The transcript without the live cards, and the rows it produced.
    private var entries: [TranscriptEntry] = []
    private var headRows: [TranscriptRow] = []
    private var running: Set<String> = []
    /// Whether `headRows` has ever been built, so an empty transcript is not confused with a virgin
    /// cache.
    private var built = false

    public init() {}

    /// The rows for `entries` plus any live cards, regrouping only what changed.
    public func rows(_ entries: [TranscriptEntry], running: Set<String> = []) -> [TranscriptRow] {
        rows(entries, appending: [], running: running)
    }

    /// `entries` with `tail` on the end, without copying the whole list when `tail` is empty.
    public func rows(_ entries: [TranscriptEntry],
                     appending tail: [TranscriptEntry],
                     running: Set<String> = []) -> [TranscriptRow] {
        defer { TranscriptBuildMeter.buildFinished() }
        return TranscriptBuildMeter.measure(\.groupingNS, note: "group") {
            regroupHead(entries, running: running)
            guard !tail.isEmpty else { return headRows }
            // The run the tail can still join: the head's trailing tool calls, which occupy exactly
            // one row (a lone card, or their run).
            let trailing = Self.trailingToolCount(entries)
            guard trailing > 0, !headRows.isEmpty else {
                return headRows + TranscriptGrouping.rows(tail, running: running)
            }
            let kept = Array(headRows[0..<(headRows.count - 1)])
            let joined = Array(entries[(entries.count - trailing)...]) + tail
            TranscriptBuildMeter.count { $0.rowsWalked += joined.count }
            return kept + TranscriptGrouping.rows(joined, running: running)
        }
    }

    // MARK: The head

    private func regroupHead(_ entries: [TranscriptEntry], running: Set<String>) {
        if built {
            switch TranscriptSplices.detect(previous: self.entries, entries: entries) {
            case .unchanged:
                if running != self.running { headRows = patchRunning(running) }
            case .appended(let count):
                appendRows(Array(entries[(entries.count - count)...]), running: running)
            case .prepended(let count):
                prependRows(Array(entries[0..<count]), running: running)
            case .replaced:
                replaceAll(entries, running: running)
            }
        } else {
            replaceAll(entries, running: running)
        }
        self.entries = entries
        self.running = running
        self.built = true
    }

    private func replaceAll(_ entries: [TranscriptEntry], running: Set<String>) {
        TranscriptBuildMeter.count {
            $0.replaced += 1
            $0.rowsWalked += entries.count
        }
        headRows = TranscriptGrouping.rows(entries, running: running)
    }

    /// New rows on the end: group them, and re-form the one run they can join.
    private func appendRows(_ fresh: [TranscriptEntry], running: Set<String>) {
        TranscriptBuildMeter.count { $0.appended += 1 }
        let trailing = Self.trailingToolCount(entries)
        guard trailing > 0, !headRows.isEmpty else {
            headRows += TranscriptGrouping.rows(fresh, running: running)
            return
        }
        let kept = Array(headRows[0..<(headRows.count - 1)])
        let joined = Array(entries[(entries.count - trailing)...]) + fresh
        TranscriptBuildMeter.count { $0.rowsWalked += joined.count }
        headRows = kept + TranscriptGrouping.rows(joined, running: running)
    }

    /// New rows at the front: group them, and merge the run the page boundary cut in half.
    private func prependRows(_ fresh: [TranscriptEntry], running: Set<String>) {
        TranscriptBuildMeter.count { $0.prepended += 1 }
        let freshTrailing = Self.trailingToolCount(fresh)
        let oldLeading = Self.leadingToolCount(entries)
        guard freshTrailing > 0, oldLeading > 0, !headRows.isEmpty else {
            headRows = TranscriptGrouping.rows(fresh, running: running) + headRows
            return
        }
        let head = Array(fresh[0..<(fresh.count - freshTrailing)])
        let join = Array(fresh[(fresh.count - freshTrailing)...]) + Array(entries[0..<oldLeading])
        TranscriptBuildMeter.count { $0.rowsWalked += join.count }
        headRows = TranscriptGrouping.rows(head, running: running)
            + TranscriptGrouping.rows(join, running: running)
            + Array(headRows[1...])
    }

    /// Only the set of running calls changed: patch the flags, do not regroup.
    private func patchRunning(_ running: Set<String>) -> [TranscriptRow] {
        var patched = headRows
        var changed = false
        for index in patched.indices {
            guard case .toolRun(let run) = patched[index] else { continue }
            let isRunning = run.entries.contains { running.contains($0.id) }
            guard isRunning != run.isRunning else { continue }
            patched[index] = .toolRun(ToolRun(entries: run.entries, isRunning: isRunning))
            changed = true
        }
        return changed ? patched : headRows
    }

    // MARK: Boundaries

    /// How many of the last entries are tool calls — the run a new row can still join.
    static func trailingToolCount(_ entries: [TranscriptEntry]) -> Int {
        var count = 0
        for entry in entries.reversed() {
            guard entry.role == .tool else { break }
            count += 1
        }
        return count
    }

    /// How many of the first entries are tool calls — the half of a run a prepended page joins.
    static func leadingToolCount(_ entries: [TranscriptEntry]) -> Int {
        var count = 0
        for entry in entries {
            guard entry.role == .tool else { break }
            count += 1
        }
        return count
    }
}

/// The drawn rows *before* folding, kept the same way.
///
/// `AppModel.visibleTranscript` re-ran three whole-array filters whenever `transcript` changed, and
/// a page landing changes `transcript` — so every 400 rows of history cost a walk of the 6,400 rows
/// already on screen. Visibility is a per-row decision with no boundary coupling, so an appended or
/// prepended page only has to be filtered itself and spliced on.
public final class TranscriptVisibilityCache {
    private var entries: [TranscriptEntry] = []
    private var rows: [TranscriptEntry] = []
    private var showToolCalls: Bool?
    private var showReasoning: Bool?
    private var built = false

    public init() {}

    public func rows(_ entries: [TranscriptEntry],
                     showToolCalls: Bool,
                     showReasoning: Bool) -> [TranscriptEntry] {
        if !built || showToolCalls != self.showToolCalls || showReasoning != self.showReasoning {
            let fresh = TranscriptVisibility.rows(entries,
                                                  showToolCalls: showToolCalls,
                                                  showReasoning: showReasoning)
            TranscriptBuildMeter.count { $0.visibilityRowsWalked += entries.count }
            self.entries = entries
            self.rows = fresh
            self.showToolCalls = showToolCalls
            self.showReasoning = showReasoning
            self.built = true
            return fresh
        }
        let done: [TranscriptEntry]
        switch TranscriptSplices.detect(previous: self.entries, entries: entries) {
        case .unchanged:
            return self.rows
        case .appended(let count):
            done = self.rows + filter(Array(entries[(entries.count - count)...]))
        case .prepended(let count):
            done = filter(Array(entries[0..<count])) + self.rows
        case .replaced:
            done = TranscriptVisibility.rows(entries,
                                             showToolCalls: showToolCalls,
                                             showReasoning: showReasoning)
            TranscriptBuildMeter.count { $0.visibilityRowsWalked += entries.count }
        }
        self.entries = entries
        self.rows = done
        return done
    }

    private func filter(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        TranscriptBuildMeter.count { $0.visibilityRowsWalked += entries.count }
        return TranscriptVisibility.rows(entries,
                                         showToolCalls: showToolCalls ?? true,
                                         showReasoning: showReasoning ?? true)
    }
}
