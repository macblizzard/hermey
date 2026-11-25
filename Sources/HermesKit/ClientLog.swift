import Foundation
#if canImport(os)
import os
#endif

/// How loud one line is. Three levels, because a user reading this wants to spot the failure, not
/// classify it.
public enum ClientLogLevel: String, Codable, Sendable, CaseIterable {
    case info, warning, error

    /// The one character the line carries in place of a word.
    public var marker: String {
        switch self {
        case .info: return "·"
        case .warning: return "!"
        case .error: return "E"
        }
    }

    /// What the level filter calls it. Plural, because choosing a level chooses every line at it.
    public var filterName: String {
        switch self {
        case .info: return "Info"
        case .warning: return "Warnings"
        case .error: return "Errors"
        }
    }
}

/// Which end of the log reads first.
///
/// The two choices are named for their *opposites*, not for the same end twice: a menu reading
/// "Newest first / Newest last" gives the reader nothing to tell apart, and a control whose two
/// halves look identical is a control nobody can use (reported 2026-11-15, build 442).
///
/// Stored as its `rawValue` (see `ClientLogOrder.storageKey`), because a preference in
/// `UserDefaults` outlives the shape of the enum that wrote it.
public enum ClientLogOrder: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    /// The latest line at the top — what a reader wants when the failure just happened.
    case newestFirst
    /// The order the file is written in, oldest at the top — the sheet's original behaviour.
    case oldestFirst

    /// Where the choice is remembered, per device.
    public static let storageKey = "hermey.logOrder"
    /// The key build 442 and earlier wrote the same choice to, as a Bool. Read, never written.
    public static let legacyStorageKey = "hermey.logNewestFirst"

    public var id: String { rawValue }

    /// What the segmented control and the menu say. Two different words, both about an end.
    public var title: String {
        switch self {
        case .newestFirst: return "Newest first"
        case .oldestFirst: return "Oldest first"
        }
    }

    /// One line of reassurance under the control and in the VoiceOver value, so the choice is
    /// never only implied by a highlight.
    public var detail: String {
        switch self {
        case .newestFirst: return "The latest line is at the top"
        case .oldestFirst: return "The latest line is at the bottom"
        }
    }

    /// The entries in this order. `ClientLog.snapshot()` hands them over oldest first, so only one
    /// of the two cases has anything to do.
    public func arrange(_ entries: [ClientLogEntry]) -> [ClientLogEntry] {
        switch self {
        case .newestFirst: return Array(entries.reversed())
        case .oldestFirst: return entries
        }
    }

    /// The stored choice, falling back to the Bool that earlier builds wrote and then to the
    /// sheet's original order.
    public static func stored(in defaults: UserDefaults = .standard) -> ClientLogOrder {
        if let raw = defaults.string(forKey: storageKey), let saved = ClientLogOrder(rawValue: raw) {
            return saved
        }
        return defaults.bool(forKey: legacyStorageKey) ? .newestFirst : .oldestFirst
    }

    /// Remember the choice. Written through rather than batched: it is one tap, and a reader who
    /// force-quits the app right after tapping it expects the next open to agree with them.
    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

/// What the reader has narrowed the log to: an order, at most one level, at most one category, and
/// a search phrase.
///
/// The whole of it is data with no view attached, which is the point: "does the list really
/// re-sort, and does the filter really filter" is a question about these three functions, and it
/// can be answered without a simulator (see `ClientLogTests`).
public struct ClientLogQuery: Equatable, Sendable {
    public var order: ClientLogOrder
    /// `nil` shows every level.
    public var level: ClientLogLevel?
    /// `nil` shows every category.
    public var category: String?
    /// The phrase, as typed. Whitespace-only is treated as no search.
    public var search: String

    public init(order: ClientLogOrder = .oldestFirst,
                level: ClientLogLevel? = nil,
                category: String? = nil,
                search: String = "") {
        self.order = order
        self.level = level
        self.category = category
        self.search = search
    }

    /// A search of spaces is not a search: a field the reader tabbed through must not empty the
    /// list.
    public var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether anything is hidden — what the sheet's "N of M" line and its "Show all" control read.
    public var isFiltering: Bool {
        level != nil || category != nil || !trimmedSearch.isEmpty
    }

    /// Whether one line survives the filter. The order is not part of this: it moves lines, it does
    /// not drop them.
    public func matches(_ entry: ClientLogEntry) -> Bool {
        if let level, entry.level != level { return false }
        if let category, entry.category != category { return false }

        let phrase = trimmedSearch
        if !phrase.isEmpty {
            // Case- and width-insensitive: the reader is typing a fragment of a line they half
            // remember, and the log writes categories in lower case.
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive,
                                                  .widthInsensitive]
            let inMessage = entry.message.range(of: phrase, options: options) != nil
            let inCategory = entry.category.range(of: phrase, options: options) != nil
            let inLevel = entry.level.filterName.range(of: phrase, options: options) != nil
            // The clock is searchable too: "what happened at 12:04" is a real question, and
            // `line` is what the reader is looking at.
            let inClock = entry.line.range(of: phrase, options: options) != nil
            if !(inMessage || inCategory || inLevel || inClock) { return false }
        }
        return true
    }

    /// The lines the reader should see, in the order they asked for.
    public func apply(to entries: [ClientLogEntry]) -> [ClientLogEntry] {
        order.arrange(entries.filter(matches))
    }

    /// The same list, keeping only the newest `limit` lines the filter admits.
    ///
    /// "Last 100 lines" means the newest hundred of the log **as filtered**, not the newest hundred of
    /// the file: a reader who narrowed the sheet to errors and asked for the tail wants the tail of the
    /// errors, which is the list in front of them. The tail is taken before the order is applied,
    /// because "newest" is a fact about `at` and not about which end of the sheet is on screen —
    /// otherwise "last 100" would copy the oldest hundred whenever the reader flipped to newest-first.
    public func apply(to entries: [ClientLogEntry], limit: Int?) -> [ClientLogEntry] {
        let matched = entries.filter(matches)
        guard let limit, limit > 0, matched.count > limit else { return order.arrange(matched) }
        return order.arrange(Array(matched.suffix(limit)))
    }
}

/// Which of the four copies a press asked for.
///
/// The sheet used to offer two — *shown* and *all* — and the owner asked for a portion instead of the
/// whole thing: "would be better if i could just copy a portion of the log like last 100 lines and so
/// on instead of copying the whole thing and paste here on chat". A scope therefore carries both the
/// list it copies (`lineLimit`) and the words the menu uses, because a label built anywhere else
/// drifts from the list the press actually writes.
///
/// Every scope is applied to the *filtered* log: the level, category and search the reader chose
/// narrow all four, which is what makes "the tail of what he sees" true rather than a tail of the
/// whole file he had just narrowed away.
public enum ClientLogCopyScope: String, CaseIterable, Identifiable, Sendable {
    /// The newest 100 lines the filter admits.
    case last100
    /// The newest 500 — more than the ring holds today (400), so on a full log it is everything.
    case last500
    /// The lines on screen: the filter applied to the live feed.
    case shown
    /// Everything the filter admits in the log itself, paused-held lines included.
    case all

    public var id: String { rawValue }

    /// How many of the newest lines this scope keeps, or `nil` for "all of them".
    public var lineLimit: Int? {
        switch self {
        case .last100: return 100
        case .last500: return 500
        case .shown, .all: return nil
        }
    }

    /// What the menu item says. `available` is the pool the press would read — the filtered log for
    /// the tails and *all*, the filtered feed for *shown* — so the reader can see how much of what he
    /// is looking at the item would take. Zero draws no parenthetical: "(of 0)" is a label that
    /// invites a press that can only do nothing.
    public func title(available: Int) -> String {
        let base: String
        switch self {
        case .last100: base = "Copy last 100 lines"
        case .last500: base = "Copy last 500 lines"
        case .shown: base = "Copy shown"
        case .all: base = "Copy all"
        }
        guard available > 0 else { return base }
        // A tail is a *portion of* the pool; the other two are the pool.
        return lineLimit == nil ? "\(base) (\(available))" : "\(base) (of \(available))"
    }

    /// What the count line says for a moment after the press: how much left the sheet, and which list.
    public func receipt(count: Int) -> String {
        let noun = count == 1 ? "line" : "lines"
        switch self {
        case .shown: return "Copied \(count) \(noun) shown"
        // Short enough to survive a narrow phone at one line: the entry count is the other half of
        // this column, and a message that truncates is a message that did not say what happened.
        case .all: return "Copied all \(count) \(noun)"
        case .last100, .last500: return "Copied last \(count) \(noun)"
        }
    }
}

/// One recorded fact: when, how loud, from which part of the app, and what happened.
public struct ClientLogEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let at: Date
    public let level: ClientLogLevel
    public let category: String
    public let message: String

    public init(id: UUID = UUID(), at: Date = Date(),
                level: ClientLogLevel = .info,
                category: String = "app",
                message: String) {
        self.id = id
        self.at = at
        self.level = level
        self.category = category
        self.message = message
    }

    /// `12:04:11  E  bridge  session.resume failed: timeout`
    ///
    /// Built from calendar components rather than a shared `DateFormatter`: a formatter is not
    /// `Sendable` and this line is rendered from whatever thread asks for it.
    public var line: String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: at)
        let clock = String(format: "%02d:%02d:%02d",
                           parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return "\(clock)  \(level.marker)  \(category)  \(message)"
    }
}

/// A registered live tail. Hold on to it: `ClientLog.stopObserving` is what a closing sheet calls,
/// and dropping the token without calling it would leave the handler registered for the life of
/// the process.
public struct ClientLogObserver: Sendable, Hashable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// What the app did, in the order it did it.
///
/// A failure on the phone reaches the user as "something went wrong" — the reason lives in a code
/// path they never see. Settings → View log is where that reason is written down: a bounded,
/// timestamped ring of the decisions and failures worth explaining later, kept on disk so a
/// relaunch (or a crash) does not erase the cause of the problem they are reporting.
///
/// Three rules, each of which keeps the log useful instead of noisy:
///
/// * **Bounded.** `capacity` entries, oldest dropped first, and the file is rewritten from the
///   buffer rather than appended to — it can never grow without limit on a phone with no space.
/// * **Cheap.** Recording is a queue hop and an array append; the disk write is debounced, so a
///   path that logs on every event cannot turn logging into I/O.
/// * **Readable by a person.** One line per entry, with the clock time first: the user can compare
///   it against the moment they saw the error.
public final class ClientLog: @unchecked Sendable {
    public static let shared = ClientLog()

    /// Where the app writes the log. `Application Support/Hermey/logs/client.log` — inside the
    /// app's own container on iOS, and `~/Library/Application Support/…` on the Mac.
    public static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Hermey", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    /// The newest lines kept. 400 is a few screens of scrolling and well under a megabyte.
    public let capacity: Int

    private let queue = DispatchQueue(label: "dev.hermey.client-log", qos: .utility)
    private let fileURL: URL?
    private var buffer: [ClientLogEntry] = []
    /// Live-tail handlers, touched only on `queue`. Keyed by token so a viewer that goes away can
    /// take its handler with it — a sheet opened a dozen times must not leave a dozen closures.
    private var observerStore: [UUID: @Sendable (ClientLogEntry) -> Void] = [:]
    private var flushScheduled = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(capacity: Int = 400, directory: URL? = ClientLog.defaultDirectory()) {
        self.capacity = max(50, capacity)
        let folder = directory
        self.fileURL = folder?.appendingPathComponent("client.log")
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // The tail of the previous run is the context for whatever is about to happen.
        self.buffer = Array(ClientLog.load(from: fileURL).suffix(max(50, capacity)))
    }

    /// Record one fact. Safe from any thread, any actor.
    public func record(_ message: String,
                       level: ClientLogLevel = .info,
                       category: String = "app") {
        let entry = ClientLogEntry(level: level, category: category, message: message)
        queue.async {
            self.buffer.append(entry)
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
            self.scheduleFlushLocked()
            // After the buffer, so a handler that asks the sheet to redraw sees the line it was
            // told about. Never before the append: a live tail that fires early shows the reader a
            // list that is one line behind, which is indistinguishable from a broken tail.
            for handler in self.observerStore.values { handler(entry) }
        }
        #if canImport(os)
        // The same line in the system log, so `log stream --predicate 'subsystem == "dev.hermey.app"'`
        // explains a running app without the user opening Settings.
        os.Logger(subsystem: "dev.hermey.app", category: category)
            .log("\(message, privacy: .public)")
        #endif
    }

    /// The entries, oldest first.
    public func snapshot() -> [ClientLogEntry] {
        queue.sync { buffer }
    }

    /// The whole log as text: what Copy and Share hand over.
    public func text() -> String {
        let lines = snapshot().map(\.line)
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The file this log is written to, for a user who wants to attach it by hand.
    public var fileLocation: String? { fileURL?.path }

    public var isEmpty: Bool { queue.sync { buffer.isEmpty } }

    /// Forget everything, on disk included.
    public func clear() {
        queue.sync {
            buffer.removeAll()
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        }
    }

    // MARK: Live tail

    /// Every line recorded from now on, handed to `handler` as it is appended.
    ///
    /// The log sheet is open precisely when the failure it is open for happens, which is why a
    /// list that only re-reads on a button press shows the reader everything except the line they
    /// are waiting for (reported 2026-11-15).
    ///
    /// The handler runs **on the log's own serial queue**, so it must not call back into
    /// `snapshot()`, `text()` or any other `queue.sync` method — that deadlocks. Hop to the main
    /// queue first; the viewer does exactly that.
    public func observe(_ handler: @escaping @Sendable (ClientLogEntry) -> Void) -> ClientLogObserver {
        let token = ClientLogObserver(id: UUID())
        queue.async { self.observerStore[token.id] = handler }
        return token
    }

    /// Stop the live tail. Safe to call twice, and safe from `deinit` of whatever held the token.
    public func stopObserving(_ token: ClientLogObserver) {
        queue.async { self.observerStore[token.id] = nil }
    }

    /// Write the buffer out now, debounce or not.
    public func flushNow() {
        queue.sync { writeLocked() }
    }

    // MARK: Storage

    private func scheduleFlushLocked() {
        guard !flushScheduled, fileURL != nil else { return }
        flushScheduled = true
        // A second is long enough that a burst becomes one write, and short enough that killing the
        // app right after the failure still leaves the failure on disk.
        queue.asyncAfter(deadline: .now() + 1.0) {
            self.flushScheduled = false
            self.writeLocked()
        }
    }

    private func writeLocked() {
        guard let fileURL else { return }
        let lines = buffer.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let text = lines.joined(separator: "\n")
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func load(from url: URL?) -> [ClientLogEntry] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(ClientLogEntry.self, from: data)
        }
    }
}

public extension ClientLog {
    /// One-line convenience for call sites that do not want to name the shared instance.
    static func note(_ message: String,
                     level: ClientLogLevel = .info,
                     category: String = "app") {
        shared.record(message, level: level, category: category)
    }
}

public extension ClientLog {
    /// Every category present in `entries`, alphabetically — the contents of the category filter.
    ///
    /// Derived from what is in the log rather than from a registry, so the menu can never offer a
    /// category nothing has written yet.
    static func categories(in entries: [ClientLogEntry]) -> [String] {
        Array(Set(entries.map(\.category))).sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    /// The lines `entries` turn into, in the order given: what Copy and Share hand over.
    ///
    /// Takes the entries rather than reading the buffer, so the sheet copies *what is on screen*
    /// — including the reader's order and filter — instead of a log they never saw.
    static func text(of entries: [ClientLogEntry], header: String = "") -> String {
        let body = entries.map(\.line).joined(separator: "\n")
        let head = header.isEmpty ? "" : header + "\n\n"
        guard !body.isEmpty else { return head }
        return head + body + "\n"
    }
}
