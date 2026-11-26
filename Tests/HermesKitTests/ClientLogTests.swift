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


// MARK: - The four copies

/// The owner's complaint was that a copy always took the whole log: "would be better if i could just
/// copy a portion of the log like last 100 lines and so on instead of copying the whole thing". These
/// pin the portion, the pool it is taken from, and the words the menu and the receipt use — the three
/// things a menu can quietly get wrong while still looking right in a screenshot.
final class ClientLogCopyScopeTests: XCTestCase {
    private func entries(_ count: Int, level: ClientLogLevel = .info) -> [ClientLogEntry] {
        (0 ..< count).map { index in
            ClientLogEntry(at: Date(timeIntervalSince1970: TimeInterval(index)),
                           level: level, category: "bridge", message: "line \(index)")
        }
    }

    func testTheFourCopiesAreOfferedAndOnlyTheTailsHaveALimit() {
        XCTAssertEqual(ClientLogCopyScope.allCases, [.last100, .last500, .shown, .all])
        XCTAssertEqual(ClientLogCopyScope.last100.lineLimit, 100)
        XCTAssertEqual(ClientLogCopyScope.last500.lineLimit, 500)
        XCTAssertNil(ClientLogCopyScope.shown.lineLimit)
        XCTAssertNil(ClientLogCopyScope.all.lineLimit)
    }

    func testTheLabelCarriesTheSizeOfThePoolItWouldTake() {
        XCTAssertEqual(ClientLogCopyScope.last100.title(available: 812), "Copy last 100 lines (of 812)")
        XCTAssertEqual(ClientLogCopyScope.last500.title(available: 812), "Copy last 500 lines (of 812)")
        XCTAssertEqual(ClientLogCopyScope.shown.title(available: 812), "Copy shown (812)")
        XCTAssertEqual(ClientLogCopyScope.all.title(available: 812), "Copy all (812)")
        // Nothing to copy: no "(of 0)" inviting a press that can only do nothing.
        XCTAssertEqual(ClientLogCopyScope.last100.title(available: 0), "Copy last 100 lines")
    }

    func testATailIsTheNewestLinesOfThePool() {
        let pool = entries(300)
        let query = ClientLogQuery(order: .oldestFirst)
        let tail = query.apply(to: pool, limit: 100)
        XCTAssertEqual(tail.count, 100)
        // The newest hundred, in file order: 200…299.
        XCTAssertEqual(tail.first?.message, "line 200")
        XCTAssertEqual(tail.last?.message, "line 299")
    }

    func testTheTailIsTheSameHundredWhicheverEndReadsFirst() {
        // "Last" is a fact about the clock, not about which end of the sheet is on screen: flipped to
        // newest-first the same hundred lines come back, reversed for reading.
        let pool = entries(300)
        let newestFirst = ClientLogQuery(order: .newestFirst).apply(to: pool, limit: 100)
        XCTAssertEqual(newestFirst.count, 100)
        XCTAssertEqual(newestFirst.first?.message, "line 299")
        XCTAssertEqual(newestFirst.last?.message, "line 200")
    }

    func testEveryScopeIsNarrowedByTheFilter() {
        var pool = entries(300)
        pool += (0 ..< 30).map { index in
            ClientLogEntry(at: Date(timeIntervalSince1970: TimeInterval(1000 + index)),
                           level: .error, category: "sessions", message: "failure \(index)")
        }
        let errorsOnly = ClientLogQuery(order: .oldestFirst, level: .error)
        XCTAssertEqual(errorsOnly.apply(to: pool, limit: nil).count, 30)
        XCTAssertEqual(errorsOnly.apply(to: pool, limit: 100).count, 30)
        XCTAssertEqual(errorsOnly.apply(to: pool, limit: 10).count, 10)
        // The tail of the filter, not of the file: the newest ten failures, all of them errors.
        XCTAssertEqual(errorsOnly.apply(to: pool, limit: 10).map(\.level), Array(repeating: .error, count: 10))
        XCTAssertEqual(errorsOnly.apply(to: pool, limit: 10).last?.message, "failure 29")

        let searched = ClientLogQuery(order: .oldestFirst, search: "failure 1")
        XCTAssertEqual(searched.apply(to: pool, limit: nil).count, 11)   // failure 1, 10…19
        XCTAssertTrue(searched.apply(to: pool, limit: nil).allSatisfy { $0.message.contains("failure 1") })
    }

    func testATailBiggerThanThePoolKeepsEverything() {
        let pool = entries(40)
        XCTAssertEqual(ClientLogQuery().apply(to: pool, limit: 100).count, 40)
        XCTAssertEqual(ClientLogQuery().apply(to: pool, limit: 500).count, 40)
        XCTAssertEqual(ClientLogQuery().apply(to: pool, limit: nil).count, 40)
        XCTAssertEqual(ClientLogQuery().apply(to: [], limit: 100).count, 0)
    }

    func testTheReceiptSaysWhichListLeft() {
        XCTAssertEqual(ClientLogCopyScope.last100.receipt(count: 100), "Copied last 100 lines")
        XCTAssertEqual(ClientLogCopyScope.last500.receipt(count: 1), "Copied last 1 line")
        XCTAssertEqual(ClientLogCopyScope.shown.receipt(count: 42), "Copied 42 lines shown")
        XCTAssertEqual(ClientLogCopyScope.all.receipt(count: 400), "Copied all 400 lines")
    }
}

// MARK: - Saving the log on the host

/// The upload is a plain bearer POST with the copy's own bytes in it, and the host's answer is the
/// path it wrote. Both halves are pinned here: the body without a socket, the request and the answer
/// through a stubbed `URLProtocol`.
final class ClientLogUploadTests: XCTestCase {
    private func payload(text: String = "12:04:11  ·  bridge  line\n") -> ClientLogUploadPayload {
        ClientLogUploadPayload(device: "Mo’s iPhone",
                               appVersion: "0.1.662",
                               appBuild: "662",
                               osVersion: "iOS 18.2",
                               scope: .all,
                               level: "Errors",
                               category: "bridge",
                               search: "timeout",
                               capturedAt: Date(timeIntervalSince1970: 1_764_123_456),
                               text: text)
    }

    func testTheBodyCarriesTheLogVerbatimBesideTheHeaderFacts() throws {
        let text = "12:04:11  ·  bridge  line\n12:04:12  E  bridge  failed\n"
        let data = try ClientLogUploadClient.encodedBody(of: payload(text: text))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // The bytes a copy would write, unchanged — no reformatting on the way to the wire.
        XCTAssertEqual(object["text"] as? String, text)
        XCTAssertEqual(object["device"] as? String, "Mo’s iPhone")
        XCTAssertEqual(object["appVersion"] as? String, "0.1.662")
        XCTAssertEqual(object["appBuild"] as? String, "662")
        XCTAssertEqual(object["osVersion"] as? String, "iOS 18.2")
        XCTAssertEqual(object["scope"] as? String, "all")
        XCTAssertEqual(object["level"] as? String, "Errors")
        XCTAssertEqual(object["category"] as? String, "bridge")
        XCTAssertEqual(object["search"] as? String, "timeout")
        XCTAssertEqual(object["capturedAt"] as? Double, 1_764_123_456.0)
        // No field for a credential: the envelope cannot carry one even if a later edit asked.
        for forbidden in ["value", "secret", "password", "card", "token"] {
            XCTAssertNil(object[forbidden], "\(forbidden) must not be part of a log upload")
        }
    }

    func testAnOversizedLogIsRefusedWithoutAskingTheHostForATicket() async {
        let text = String(repeating: "x", count: ClientLogUploadClient.maximumBytes + 1)
        // An endpoint that throws if it is ever reached: a refusal that asked for a ticket first
        // would fail this test with `NoTicket` rather than with the size sentence.
        struct NoTicket: Error {}
        let client = ClientLogUploadClient(endpoint: { throw NoTicket() })
        do {
            _ = try await client.send(payload(text: text))
            XCTFail("a log over the ceiling must not be sent")
        } catch let error as ClientLogUploadError {
            guard case let .tooLarge(bytes, limit) = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
            XCTAssertEqual(bytes, ClientLogUploadClient.maximumBytes + 1)
            XCTAssertEqual(limit, 2 * 1024 * 1024)
            XCTAssertTrue(error.localizedDescription.contains("Copy a portion"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTheRequestIsABearerPostAndThePathIsReturned() async throws {
        StubProtocol.reply = .init(status: 201,
                                   body: Data(#"{"path":"/var/log/hermey/client-moes-iphone-20261125T2130Z.log","bytes":1462}"#.utf8))
        let client = ClientLogUploadClient(endpoint: { (URL(string: "http://host.test")!, "fresh-ticket") },
                                           session: StubProtocol.session())
        let receipt = try await client.send(payload())
        XCTAssertEqual(receipt.path, "/var/log/hermey/client-moes-iphone-20261125T2130Z.log")
        XCTAssertEqual(receipt.bytes, 1462)

        let seen = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(seen.path, "/v1/client-logs")
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.authorization, "Bearer fresh-ticket")
        XCTAssertEqual(seen.contentType, "application/json")
        // The log travels verbatim, in the body, under the header facts the host writes above it.
        let body = try XCTUnwrap(seen.jsonBody)
        XCTAssertEqual(body["text"] as? String, "12:04:11  ·  bridge  line\n")
    }

    func testARefusalKeepsTheHostsOwnSentence() async {
        // A 413 is the one refusal the reader can act on, so the host's words reach the sheet.
        StubProtocol.reply = .init(status: 413,
                                   body: Data(#"{"detail":"this log is 2097153 bytes, over the 2097152 a host will store"}"#.utf8))
        let client = ClientLogUploadClient(endpoint: { (URL(string: "http://host.test")!, "t") },
                                           session: StubProtocol.session())
        do {
            _ = try await client.send(payload())
            XCTFail("a 413 must throw")
        } catch let error as ClientLogUploadError {
            XCTAssertEqual(error.localizedDescription,
                           "this log is 2097153 bytes, over the 2097152 a host will store")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testACollisionSaysNothingWasOverwritten() async {
        StubProtocol.reply = .init(status: 409, body: Data(#"{"detail":"… already exists …"}"#.utf8))
        let client = ClientLogUploadClient(endpoint: { (URL(string: "http://host.test")!, "t") },
                                           session: StubProtocol.session())
        do {
            _ = try await client.send(payload())
            XCTFail("a 409 must throw")
        } catch let error as ClientLogUploadError {
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        // A 409 with no detail still says what happened rather than "HTTP 409".
        XCTAssertEqual(ClientLogUploadError.rejected(status: 409, detail: nil).localizedDescription,
                       "The host already has a log with that name, and nothing was overwritten.")
    }

    func testAnUnreachableHostIsItsOwnSentence() async {
        let client = ClientLogUploadClient(endpoint: { (URL(string: "http://127.0.0.1:1")!, "t") },
                                           session: StubProtocol.session(error: URLError(.cannotConnectToHost)))
        do {
            _ = try await client.send(payload())
            XCTFail("an unreachable host must throw")
        } catch let error as ClientLogUploadError {
            guard case .unreachable = error else { return XCTFail("expected unreachable, got \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("nothing was saved"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

/// One canned answer for every request, and the last request it was handed.
///
/// A `URLProtocol` rather than a live host: these tests are about the shape of the call and the
/// reading of the answer, and neither needs a socket to be true. Static state is behind a lock, the
/// way the other stubs in this suite are, because a protocol handler runs on its own thread.
final class StubProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let body: Data
    }

    struct Recorded {
        let method: String
        let path: String
        let authorization: String?
        let contentType: String?
        let body: Data?

        var jsonBody: [String: Any]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    private static let lock = NSLock()
    private static var storedReply = Reply(status: 200, body: Data())
    private static var storedError: Error?
    private static var recorded: [Recorded] = []

    static var reply: Reply {
        get { lock.lock(); defer { lock.unlock() }; return storedReply }
        set { lock.lock(); storedReply = newValue; lock.unlock() }
    }

    static var lastRequest: Recorded? {
        lock.lock(); defer { lock.unlock() }
        return recorded.last
    }

    static func session(error: Error? = nil) -> URLSession {
        lock.lock()
        // **Not** the reply: every test sets `reply` *before* it asks for a session, so resetting it
        // here silently replaced the answer under the test — which is why the 201 case saw an empty
        // 200 and reported `malformedResponse`, and the 413 case was treated as a success.
        storedError = error
        recorded = []
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.drain)
        let record = Recorded(method: request.httpMethod ?? "",
                              path: request.url?.path ?? "",
                              authorization: request.value(forHTTPHeaderField: "Authorization"),
                              contentType: request.value(forHTTPHeaderField: "Content-Type"),
                              body: body)
        Self.lock.lock()
        Self.recorded.append(record)
        let failure = Self.storedError
        let reply = Self.storedReply
        Self.lock.unlock()

        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                             httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A `URLSession` moves the body onto a stream, so this is where the bytes are readable.
    private static func drain(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
