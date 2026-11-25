import Foundation

/// Counting the main actor's transcript work, so a freeze can be attributed instead of guessed at.
///
/// Every number here is a counter or a `DispatchTime` pair — a handful of nanoseconds — and the
/// summary is written to `ClientLog` once every `reportEvery` builds. It exists because the scroll
/// freeze on a 6,400-row chat (reported 2026-11-25: "stuck after scrolling for some time for up to
/// 30 seconds") had four candidate causes and no evidence for which one it was: grouping the whole
/// transcript, re-parsing markdown per row, rebuilding the drawn list, and the background fill.
///
/// Off unless `HERMEY_SCROLL_METER` is set, so a release build pays nothing.
public enum TranscriptBuildMeter {
    /// Set `HERMEY_SCROLL_METER=1` in the scheme (or `defaults write … HERMEY_SCROLL_METER -bool
    /// YES`) to make the app log a breakdown of what its main actor did.
    public static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["HERMEY_SCROLL_METER"] == "1"
            || UserDefaults.standard.bool(forKey: "HERMEY_SCROLL_METER")
    }()

    /// One line per this many builds. A build happens per body pass, so 240 is ~4 s at 60 fps.
    public static let reportEvery = 240

    public struct Snapshot: Sendable {
        public var builds = 0
        /// Rows walked by a *full* regrouping pass (the number that must not scale with history).
        public var rowsWalked = 0
        public var regroupedRowsBuilt = 0
        /// Rows walked by the visibility filter.
        public var visibilityRowsWalked = 0
        /// Incremental splices, by kind.
        public var appended = 0
        public var prepended = 0
        public var replaced = 0
        public var unchanged = 0
        /// Nanoseconds, the four phases.
        public var groupingNS = 0
        public var visibilityNS = 0
        public var markdownNS = 0
        public var payloadNS = 0
        /// The worst single main-actor slice seen since the last report.
        public var worstSliceNS = 0
        public var worstSliceNote = ""
        /// Pages that landed: the fill and the "load earlier" row.
        public var pageLands = 0
        /// Markdown parses served from the shared store instead of the parser.
        public var markdownHits = 0
        public var markdownMisses = 0
        /// Tool payloads parsed, and the bytes they held.
        public var payloadParses = 0
        public var payloadBytes = 0

        public var summary: String {
            let ms = { (ns: Int) in String(format: "%.1f", Double(ns) / 1_000_000) }
            return "transcript build x\(builds): regroup \(ms(groupingNS)) ms over \(rowsWalked) rows"
                + " (\(appended) appended, \(prepended) prepended, \(replaced) replaced, "
                + "\(unchanged) unchanged), visible \(ms(visibilityNS)) ms / \(visibilityRowsWalked)"
                + " rows, markdown \(ms(markdownNS)) ms (\(markdownHits) hit/\(markdownMisses) miss),"
                + " payload \(ms(payloadNS)) ms / \(payloadParses) calls / "
                + "\(payloadBytes / 1024) KiB, worst slice \(ms(worstSliceNS)) ms"
                + (worstSliceNote.isEmpty ? "" : " [\(worstSliceNote)]")
                + ", pages \(pageLands)"
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current = Snapshot()
    nonisolated(unsafe) private static var sinceReport = 0

    /// Run `body`, adding its time to `phase` and to the worst-slice figure.
    static func measure<T>(_ phase: WritableKeyPath<Snapshot, Int>,
                           note: String = "",
                           _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        let elapsed = Int(DispatchTime.now().uptimeNanoseconds - start)
        lock.lock()
        current[keyPath: phase] += elapsed
        if elapsed > current.worstSliceNS {
            current.worstSliceNS = elapsed
            current.worstSliceNote = note
        }
        lock.unlock()
        return result
    }

    /// Count something that is not timed. `mutate` runs under the lock.
    static func count(_ mutate: (inout Snapshot) -> Void) {
        guard isEnabled else { return }
        lock.lock()
        mutate(&current)
        lock.unlock()
    }

    /// Called at the end of every build: rolls the report over when it is due.
    static func buildFinished() {
        guard isEnabled else { return }
        lock.lock()
        current.builds += 1
        sinceReport += 1
        let due = sinceReport >= reportEvery
        let snapshot = current
        if due {
            current = Snapshot()
            sinceReport = 0
        }
        lock.unlock()
        guard due else { return }
        ClientLog.note(snapshot.summary, level: .info, category: "scroll")
    }
}
