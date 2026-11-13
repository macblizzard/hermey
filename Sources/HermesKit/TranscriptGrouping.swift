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
