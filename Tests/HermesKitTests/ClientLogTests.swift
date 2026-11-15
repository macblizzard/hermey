import XCTest
@testable import HermesKit

/// The log the Settings screen shows has to be readable after the thing that broke, which means
/// three promises: it is ordered, it is bounded, and it survives a relaunch.
final class ClientLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEntriesKeepTheirOrderAndLevel() {
        let log = ClientLog(capacity: 50, directory: directory)
        log.record("connecting", category: "connection")
        log.record("session.list failed", level: .error, category: "sessions")
        log.record("socket reconnecting (attempt 2)", level: .warning, category: "connection")

        let entries = log.snapshot()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.message),
                       ["connecting", "session.list failed", "socket reconnecting (attempt 2)"])
        XCTAssertEqual(entries.map(\.level), [.info, .error, .warning])
        XCTAssertEqual(entries.map(\.category), ["connection", "sessions", "connection"])
    }

    func testCapacityDropsTheOldestFirst() {
        let log = ClientLog(capacity: 50, directory: directory)
        for index in 0 ..< 60 { log.record("line \(index)") }

        let entries = log.snapshot()
        XCTAssertEqual(entries.count, 50)
        XCTAssertEqual(entries.first?.message, "line 10")
        XCTAssertEqual(entries.last?.message, "line 59")
    }

    func testLogSurvivesARelaunch() {
        let first = ClientLog(capacity: 50, directory: directory)
        first.record("before the crash", level: .error, category: "connection")
        first.flushNow()

        // A second instance over the same directory is what a relaunch is.
        let second = ClientLog(capacity: 50, directory: directory)
        let entries = second.snapshot()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.message, "before the crash")
        XCTAssertEqual(entries.first?.level, .error)
        XCTAssertEqual(entries.first?.category, "connection")
    }

    func testClearRemovesTheFileAsWellAsTheMemory() throws {
        let log = ClientLog(capacity: 50, directory: directory)
        log.record("something")
        log.flushNow()
        let path = try XCTUnwrap(log.fileLocation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        log.clear()
        XCTAssertTrue(log.snapshot().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testLineIsTheClockThenTheLevelThenTheCategory() {
        let entry = ClientLogEntry(at: Date(timeIntervalSince1970: 1_760_000_000),
                                   level: .error,
                                   category: "send",
                                   message: "prompt.submit failed: timed out")
        let line = entry.line
        XCTAssertTrue(line.hasSuffix("  E  send  prompt.submit failed: timed out"), line)
        // `12:04:11` style, then two spaces, then the marker: the reader compares the clock
        // against the moment they saw the error, so only the shape is asserted here.
        let clock = String(line.prefix(8))
        XCTAssertEqual(clock.filter { $0 == ":" }.count, 2, clock)
        XCTAssertTrue(line.count > 9 && line[line.index(line.startIndex, offsetBy: 8)] == " ", line)
    }

    func testTextIsOneLinePerEntry() {
        let log = ClientLog(capacity: 50, directory: directory)
        log.record("one")
        log.record("two")
        let lines = log.text().split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("one"))
        XCTAssertTrue(lines[1].hasSuffix("two"))
    }
}

// MARK: - Reading order and filters
//
// Build 442 reported two things in one sentence: the order control offered two choices that both
// read as newest-first, and choosing either left the list where it was. The ordering is a pure
// function of the entries, so it is pinned here rather than in a screenshot: a comparator that does
// not compare is a test failure, not a review note.

final class ClientLogOrderingTests: XCTestCase {
    private func entry(_ message: String,
                       level: ClientLogLevel = .info,
                       category: String = "app",
                       at offset: TimeInterval = 0) -> ClientLogEntry {
        ClientLogEntry(at: Date(timeIntervalSince1970: 1_760_000_000 + offset),
                       level: level,
                       category: category,
                       message: message)
    }

    /// Three lines, oldest first, as `snapshot()` hands them over.
    private func threeLines() -> [ClientLogEntry] {
        [entry("first", category: "connection", at: 0),
         entry("second", level: .error, category: "send", at: 1),
         entry("third", level: .warning, category: "connection", at: 2)]
    }

    // MARK: Order

    func testNewestFirstIsTheExactReverseOfTheFileOrder() {
        let lines = threeLines()
        XCTAssertEqual(ClientLogOrder.newestFirst.arrange(lines).map(\.message),
                       ["third", "second", "first"])
        // Reversing twice has to come back to where it started, or a toggle would drift.
        XCTAssertEqual(ClientLogOrder.newestFirst.arrange(ClientLogOrder.newestFirst.arrange(lines)),
                       lines)
    }

    func testOldestFirstLeavesTheFileOrderAlone() {
        let lines = threeLines()
        XCTAssertEqual(ClientLogOrder.oldestFirst.arrange(lines), lines)
    }

    func testAnEmptyOrSingleLineLogIsUnchangedByEitherOrder() {
        XCTAssertEqual(ClientLogOrder.newestFirst.arrange([]), [])
        XCTAssertEqual(ClientLogOrder.oldestFirst.arrange([]), [])
        let one = [entry("only")]
        XCTAssertEqual(ClientLogOrder.newestFirst.arrange(one), one)
    }

    /// The report's actual complaint: two menu items a reader cannot tell apart. Every choice must
    /// name its own end, and no choice may be a prefix of the other.
    func testTheOrderChoicesNameOppositeEnds() {
        let titles = ClientLogOrder.allCases.map(\.title)
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual(Set(titles).count, 2, "both options must read differently: \(titles)")
        XCTAssertFalse(titles[0].hasPrefix(titles[1]) || titles[1].hasPrefix(titles[0]))
        XCTAssertTrue(titles.contains("Newest first"))
        XCTAssertTrue(titles.contains("Oldest first"))
        // And each carries a sentence saying where the latest line ends up, so the selection is
        // never only implied by a highlight.
        for order in ClientLogOrder.allCases {
            XCTAssertTrue(order.detail.contains("latest line"), order.detail)
        }
        XCTAssertNotEqual(ClientLogOrder.newestFirst.detail, ClientLogOrder.oldestFirst.detail)
    }

    func testTheChoiceSurvivesARelaunchAndHonoursTheOldBool() throws {
        let name = "dev.hermey.order.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        // Nothing stored yet: the sheet's original order.
        XCTAssertEqual(ClientLogOrder.stored(in: defaults), .oldestFirst)

        // What build 442 wrote, read but never written again.
        defaults.set(true, forKey: ClientLogOrder.legacyStorageKey)
        XCTAssertEqual(ClientLogOrder.stored(in: defaults), .newestFirst)

        // The new key wins over the legacy one.
        ClientLogOrder.oldestFirst.store(in: defaults)
        XCTAssertEqual(defaults.string(forKey: ClientLogOrder.storageKey), "oldestFirst")
        XCTAssertEqual(ClientLogOrder.stored(in: defaults), .oldestFirst)

        ClientLogOrder.newestFirst.store(in: defaults)
        XCTAssertEqual(ClientLogOrder.stored(in: defaults), .newestFirst)
    }

    // MARK: Filtering

    func testTheLevelFilterDropsEveryOtherLevel() {
        let lines = threeLines()
        XCTAssertEqual(ClientLogQuery(level: .error).apply(to: lines).map(\.message), ["second"])
        XCTAssertEqual(ClientLogQuery(level: .info).apply(to: lines).map(\.message), ["first"])
        XCTAssertEqual(ClientLogQuery(level: nil).apply(to: lines).count, 3)
    }

    func testTheCategoryFilterIsExact() {
        let lines = threeLines()
        XCTAssertEqual(ClientLogQuery(category: "connection").apply(to: lines).map(\.message),
                       ["first", "third"])
    }

    func testSearchIgnoresCaseAndLooksAtWhatTheReaderSees() {
        let lines = threeLines()
        // The message, from memory and un-capitalised.
        XCTAssertEqual(ClientLogQuery(search: "SECOND").apply(to: lines).map(\.message), ["second"])
        // The category, which the log writes in lower case.
        XCTAssertEqual(ClientLogQuery(search: "SEND").apply(to: lines).map(\.message), ["second"])
        // The level, as the filter menu spells it.
        XCTAssertEqual(ClientLogQuery(search: "warnings").apply(to: lines).map(\.message), ["third"])
        // The clock, because "what happened at 12:04" is the question this log answers.
        let clock = String(lines[0].line.prefix(8))
        XCTAssertEqual(ClientLogQuery(search: clock).apply(to: lines).map(\.message), ["first"])
        // Nothing matching is an empty list, not the whole list.
        XCTAssertTrue(ClientLogQuery(search: "no such line").apply(to: lines).isEmpty)
    }

    func testASearchOfSpacesIsNotASearch() {
        let lines = threeLines()
        for blank in ["", "   ", "\n", " \t "] {
            let query = ClientLogQuery(search: blank)
            XCTAssertFalse(query.isFiltering, "\(blank.debugDescription) must not filter")
            XCTAssertEqual(query.apply(to: lines).count, 3)
        }
    }

    func testFiltersAndOrderCompose() {
        let lines = threeLines()
        // The two connection lines, newest at the top.
        XCTAssertEqual(ClientLogQuery(order: .newestFirst, category: "connection", search: "i")
            .apply(to: lines).map(\.message),
                       ["third", "first"])
        // Filtering then reversing is the same as reversing the filtered list.
        let query = ClientLogQuery(order: .newestFirst, level: .error)
        XCTAssertEqual(query.apply(to: lines), ClientLogOrder.newestFirst.arrange(
            ClientLogOrder.oldestFirst.arrange(lines).filter(query.matches)))
    }

    func testIsFilteringTracksTheNarrowing() {
        XCTAssertFalse(ClientLogQuery().isFiltering)
        XCTAssertTrue(ClientLogQuery(level: .info).isFiltering)
        XCTAssertTrue(ClientLogQuery(category: "send").isFiltering)
        XCTAssertTrue(ClientLogQuery(search: "x").isFiltering)
        // The order is not a filter: it moves lines, it does not hide them.
        XCTAssertFalse(ClientLogQuery(order: .newestFirst).isFiltering)
    }

    func testCategoriesComeBackAlphabeticalAndDeduplicated() {
        // `entry` defaults to the log's own "app" category, and "connection" appears twice.
        let lines = threeLines() + [entry("fourth", category: "audio"),
                                    entry("fifth")]
        XCTAssertEqual(ClientLog.categories(in: lines), ["app", "audio", "connection", "send"])
        XCTAssertEqual(ClientLog.categories(in: []), [])
    }

    // MARK: The live tail

    func testTheLiveTailSeesEveryNewLine() {
        let log = ClientLog(capacity: 50, directory: directory())
        let box = MessageBox()
        let token = log.observe { entry in box.append(entry.message) }

        log.record("one")
        log.record("two", level: .error)
        // `snapshot()` hops onto the log's own queue, so everything queued before it — the two
        // appends and their handler calls — has run by the time it answers.
        _ = log.snapshot()

        XCTAssertEqual(box.values, ["one", "two"])
        log.stopObserving(token)
    }

    func testStoppingTheTailStopsTheCalls() {
        let log = ClientLog(capacity: 50, directory: directory())
        let box = MessageBox()
        let token = log.observe { entry in box.append(entry.message) }

        log.record("before")
        _ = log.snapshot()
        log.stopObserving(token)
        log.record("after")
        _ = log.snapshot()

        XCTAssertEqual(box.values, ["before"])
        // Stopping twice is not an error: a sheet's `onDisappear` and its owner both call it.
        log.stopObserving(token)
    }

    func testTheTailCarriesTheLevelAndCategoryTheLineWasWrittenWith() {
        let log = ClientLog(capacity: 50, directory: directory())
        let box = EntryBox()
        let token = log.observe { entry in box.append(entry) }

        log.record("socket failed", level: .error, category: "connection")
        _ = log.snapshot()

        XCTAssertEqual(box.values.first?.level, .error)
        XCTAssertEqual(box.values.first?.category, "connection")
        log.stopObserving(token)
    }

    // MARK: What Copy hands over

    func testCopyTextIsTheListOnScreenNotTheWholeFile() {
        let lines = threeLines()
        let shown = ClientLogQuery(level: .error).apply(to: lines)
        let text = ClientLog.text(of: shown, header: "Hermey 0.1.442 (build 442)")
        let body = text.split(separator: "\n").filter { !$0.contains("build 442") }
        XCTAssertEqual(body.count, 1)
        XCTAssertTrue(body[0].hasSuffix("second"), String(body[0]))
        XCTAssertFalse(text.contains("first"))
        // An empty selection copies the header alone rather than a stray blank line.
        XCTAssertEqual(ClientLog.text(of: [], header: "h"), "h\n\n")
        XCTAssertEqual(ClientLog.text(of: []), "")
    }

    // MARK: Helpers

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-log-order-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A handler runs on the log's own queue; the test reads on the test thread.
private final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ value: String) {
        lock.lock(); items.append(value); lock.unlock()
    }

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

private final class EntryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClientLogEntry] = []

    func append(_ value: ClientLogEntry) {
        lock.lock(); items.append(value); lock.unlock()
    }

    var values: [ClientLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
