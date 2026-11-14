import Foundation

/// A run of tool calls, drawn as one line in the transcript instead of twenty cards.
///
/// One request can be thirty commands: `rsync`, then a `grep`, then three `read_file`s. Each is
/// worth reading when you want it, and none of them is worth the space while you are reading the
/// answer — so consecutive calls fold into a run with a count, and the cards stay behind it.
public struct ToolRun: Identifiable, Hashable, Sendable {
    /// The first call's id: stable while the run grows, so the disclosure stays open.
    public let id: String
    public let entries: [TranscriptEntry]
    /// At least one call in this run has not finished. A run that is still going says so.
    public let isRunning: Bool

    public var count: Int { entries.count }

    public init(entries: [TranscriptEntry], isRunning: Bool = false) {
        self.id = "run-" + (entries.first?.id ?? UUID().uuidString)
        self.entries = entries
        self.isRunning = isRunning
    }
}

/// One line of the transcript: either a message, or a folded run of tool calls.
public enum TranscriptRow: Identifiable, Hashable, Sendable {
    case entry(TranscriptEntry)
    case toolRun(ToolRun)

    public var id: String {
        switch self {
        case .entry(let entry): return entry.id
        case .toolRun(let run): return run.id
        }
    }
}

public enum TranscriptGrouping {
    /// Two or more consecutive tool calls become one row; a lone call stays a card, because a
    /// container around a single command is a click with nothing behind it.
    ///
    /// `running` names the rows that have not finished, so a run knows whether to say "Running".
    public static func rows(_ entries: [TranscriptEntry], running: Set<String> = []) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var pending: [TranscriptEntry] = []

        func flush() {
            guard !pending.isEmpty else { return }
            if pending.count == 1 {
                rows.append(.entry(pending[0]))
            } else {
                rows.append(.toolRun(ToolRun(entries: pending,
                                             isRunning: pending.contains { running.contains($0.id) })))
            }
            pending.removeAll()
        }

        for entry in entries {
            if entry.role == .tool {
                pending.append(entry)
            } else {
                flush()
                rows.append(.entry(entry))
            }
        }
        flush()
        return rows
    }
}


/// One grouping pass per *change*, not per body evaluation.
///
/// `TranscriptGrouping.rows` walked the whole transcript every time a view's body was evaluated,
/// and a body is evaluated on every publish of `AppModel` — which during a streaming turn is every
/// 40 ms. On a long conversation that is a full walk to draw a caret (the jitter reported
/// 2026-11-14). The rows are append-only within a conversation, so a cheap signature is enough to
/// know whether the last pass still applies.
public final class TranscriptRowCache {
    private var signature: Signature?
    private var cached: [TranscriptRow] = []

    private struct Signature: Equatable {
        let count: Int
        let lastID: String?
        let running: [String]
    }

    public init() {}

    public func rows(_ entries: [TranscriptEntry], running: Set<String> = []) -> [TranscriptRow] {
        let next = Signature(count: entries.count,
                             lastID: entries.last?.id,
                             running: running.sorted())
        if next == signature { return cached }
        let fresh = TranscriptGrouping.rows(entries, running: running)
        signature = next
        cached = fresh
        return fresh
    }
}
