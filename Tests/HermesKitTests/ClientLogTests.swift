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
