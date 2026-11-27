import Foundation

/// The agent's own task list, read back out of the transcript it already streams.
///
/// The host's `todo_list` tool writes the *whole* board on every call — the list is replaced, not
/// appended to — so the newest row is the entire truth and no state has to be accumulated here.
/// That is what makes this safe across a resume: the board is derived from the rows the session
/// loaded, not from a side channel that a paging adopt would leave behind.
///
/// A `role: "tool"` row carries the call's arguments and (when the projection kept it) the tool's
/// result. For `todo_list` both are the same `{todos: […]}` board; the result is preferred, and the
/// arguments are the fallback because the display projection omits `content` for every tool that
/// is not an edit tool — without that fallback the strip would vanish on the next resume.
public struct TodoBoard: Sendable, Equatable {

    // MARK: Status

    public enum Status: String, Sendable, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled

        /// The wire spells it `in_progress`; a host that says `active` or `running` means the same.
        public init?(wire: String) {
            switch wire.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "pending", "todo", "open": self = .pending
            case "in_progress", "in-progress", "inprogress", "active", "running": self = .inProgress
            case "completed", "complete", "done": self = .completed
            case "cancelled", "canceled", "abandoned": self = .cancelled
            default: return nil
            }
        }
    }

    // MARK: Items

    public struct Item: Identifiable, Sendable, Equatable {
        public let id: String
        public let content: String
        public let status: Status
        /// The id of the item this one is nested under, when the board says so.
        public let parent: String?

        public init(id: String, content: String, status: Status, parent: String? = nil) {
            self.id = id
            self.content = content
            self.status = status
            self.parent = parent
        }
    }

    /// One drawn line: an item, and how far it is indented.
    public struct Row: Identifiable, Sendable, Equatable {
        public let item: Item
        public let depth: Int

        public var id: String { item.id }

        public init(item: Item, depth: Int) {
            self.item = item
            self.depth = depth
        }
    }

    public struct Counts: Sendable, Equatable {
        public let done: Int
        public let total: Int
        public let inProgress: Int
        public let cancelled: Int

        public init(done: Int, total: Int, inProgress: Int, cancelled: Int) {
            self.done = done
            self.total = total
            self.inProgress = inProgress
            self.cancelled = cancelled
        }
    }

    /// Every item, in the order the board lists them (list order is priority).
    public let items: [Item]
    /// The same items flattened for drawing: each parent immediately followed by its children,
    /// `depth` counting how deep under a root it sits.
    public let rows: [Row]
    public let counts: Counts

    /// Something the agent says it is doing right now. The strip opens for this and only this.
    public var isActive: Bool { counts.inProgress > 0 }

    /// Nothing is left to start: every item is completed or cancelled.
    public var isComplete: Bool {
        !items.isEmpty && counts.done + counts.cancelled == counts.total
    }

    public init(items: [Item]) {
        self.items = items
        self.rows = Self.nest(items)
        let done = items.filter { $0.status == .completed }.count
        let running = items.filter { $0.status == .inProgress }.count
        let cancelled = items.filter { $0.status == .cancelled }.count
        self.counts = Counts(done: done, total: items.count,
                             inProgress: running, cancelled: cancelled)
    }

    // MARK: Reading the transcript

    /// The board carried by the newest `todo_list` row, or nil when the session has none.
    ///
    /// Nil is the signal to draw nothing at all — not a placeholder, not an empty strip. A session
    /// with no board has no checklist; a board the agent cleared to `[]` is nil for the same reason.
    public static func board(from entries: [TranscriptEntry]) -> TodoBoard? {
        board(from: entries, live: [])
    }

    /// The same read across the stored transcript and the running turn's cards.
    ///
    /// The live cards are the newest rows (they become transcript rows only when the turn ends), so
    /// they are searched first. Nothing is concatenated: a resumed 6,400-row conversation must not
    /// be copied on every body pass just to look at its last board.
    public static func board(from entries: [TranscriptEntry],
                             live: [TranscriptEntry]) -> TodoBoard? {
        if let board = lastBoard(in: live) { return board }
        return lastBoard(in: entries)
    }

    private static func lastBoard(in entries: [TranscriptEntry]) -> TodoBoard? {
        for entry in entries.reversed() {
            guard entry.role == .tool,
                  let tool = entry.tool,
                  isTodoList(tool.name) else { continue }
            // The newest todo_list row is the board — even when it cannot be read, in which case
            // there is no board rather than a stale one from an older call.
            if let text = tool.content, let board = parse(text) { return board }
            if let text = tool.args, let board = parse(text) { return board }
            return nil
        }
        return nil
    }

    /// `todo_list` is the tool's name; a host that says `todos` or `todo list` means the same.
    static func isTodoList(_ name: String) -> Bool {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "todo_list", "todo-list", "todos", "todo list": return true
        default: return false
        }
    }

    /// A payload that is not JSON, not an object, or has no readable item is no board.
    public static func parse(_ text: String) -> TodoBoard? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return board(from: value)
    }

    static func board(from value: JSONValue) -> TodoBoard? {
        // The board is `{todos: […]}`; a bare array is the same list.
        let list: [JSONValue]
        if let todos = value["todos"]?.arrayValue {
            list = todos
        } else if case .array(let array) = value {
            list = array
        } else {
            return nil
        }

        var items: [Item] = []
        var seen = Set<String>()
        for (index, raw) in list.enumerated() {
            guard raw.objectValue != nil,
                  let content = (raw["content"]?.stringValue ?? raw["text"]?.stringValue)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }
            var id = raw["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if id.isEmpty { id = "item-\(index)" }
            // A duplicate id would make two rows share an identity (and confuse the nesting).
            guard seen.insert(id).inserted else { continue }
            let status = Status(wire: raw["status"]?.stringValue ?? "") ?? .pending
            let parent = raw["parent"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(Item(id: id,
                              content: content,
                              status: status,
                              parent: (parent?.isEmpty == false) ? parent : nil))
        }
        // A cleared board draws nothing: an empty strip is the placeholder the owner asked not to see.
        guard !items.isEmpty else { return nil }
        return TodoBoard(items: items)
    }

    /// Roots in list order, each followed by its children. A parent that is missing from the list
    /// (or a cycle) is treated as a root, so a malformed tree still draws every item exactly once.
    static func nest(_ items: [Item]) -> [Row] {
        let ids = Set(items.map(\.id))
        var effectiveParent: [String: String] = [:]
        for item in items {
            if let parent = item.parent, parent != item.id, ids.contains(parent) {
                effectiveParent[item.id] = parent
            }
        }

        var children: [String: [Item]] = [:]
        var roots: [Item] = []
        for item in items {
            if let parent = effectiveParent[item.id] {
                children[parent, default: []].append(item)
            } else {
                roots.append(item)
            }
        }

        var rows: [Row] = []
        var placed = Set<String>()
        func walk(_ item: Item, depth: Int) {
            guard depth < 8, placed.insert(item.id).inserted else { return }
            rows.append(Row(item: item, depth: depth))
            for child in children[item.id] ?? [] { walk(child, depth: depth + 1) }
        }
        for root in roots { walk(root, depth: 0) }
        // Whatever a cycle kept out of the walk is still shown, at the root level.
        for item in items where !placed.contains(item.id) {
            placed.insert(item.id)
            rows.append(Row(item: item, depth: 0))
        }
        return rows
    }
}
