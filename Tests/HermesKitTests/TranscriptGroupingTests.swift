import XCTest
@testable import HermesKit

/// Folding a run of tool calls into one line, and leaving everything else alone.
///
/// The rule is deliberately narrow: only *consecutive* tool rows fold, and only two or more of
/// them. A transcript that grouped across a message would hide the answer between its calls, and a
/// container around a single command is a click with nothing behind it.
final class TranscriptGroupingTests: XCTestCase {
    private func tool(_ id: String, name: String = "bash") -> TranscriptEntry {
        TranscriptEntry(id: id, role: .tool, text: name + " · echo hi",
                        tool: TranscriptEntry.ToolDetail(name: name, context: "echo hi"))
    }

    private func message(_ id: String, _ role: TranscriptEntry.Role = .assistant) -> TranscriptEntry {
        TranscriptEntry(id: id, role: role, text: "hello")
    }

    func testTwoCallsBecomeOneRow() {
        let rows = TranscriptGrouping.rows([tool("a"), tool("b")])
        XCTAssertEqual(rows.count, 1)
        guard case .toolRun(let run) = rows[0] else { return XCTFail("expected a run") }
        XCTAssertEqual(run.count, 2)
        XCTAssertEqual(run.entries.map(\.id), ["a", "b"])
    }

    func testALoneCallStaysACard() {
        let rows = TranscriptGrouping.rows([tool("a")])
        XCTAssertEqual(rows.count, 1)
        guard case .entry(let entry) = rows[0] else { return XCTFail("expected a plain card") }
        XCTAssertEqual(entry.id, "a")
    }

    func testMessagesAreNeverFolded() {
        let rows = TranscriptGrouping.rows([message("m1", .user), tool("a"), tool("b"),
                                            message("m2"), tool("c"), tool("d"), tool("e")])
        XCTAssertEqual(rows.count, 4)
        guard case .entry = rows[0], case .toolRun(let first) = rows[1],
              case .entry = rows[2], case .toolRun(let second) = rows[3] else {
            return XCTFail("unexpected shape: \(rows)")
        }
        XCTAssertEqual(first.entries.map(\.id), ["a", "b"])
        XCTAssertEqual(second.entries.map(\.id), ["c", "d", "e"])
    }

    func testTheRunKeepsItsIdentityWhileItGrows() {
        // The disclosure stays open because the id is the first call, not the last.
        let short = TranscriptGrouping.rows([tool("a"), tool("b")])
        let longer = TranscriptGrouping.rows([tool("a"), tool("b"), tool("c")])
        XCTAssertEqual(short.first?.id, longer.first?.id)
        XCTAssertEqual(short.first?.id, "run-a")
    }

    func testARunSaysWhenItIsStillGoing() {
        let rows = TranscriptGrouping.rows([tool("a"), tool("b")], running: ["b"])
        guard case .toolRun(let run) = rows[0] else { return XCTFail("expected a run") }
        XCTAssertTrue(run.isRunning)

        let done = TranscriptGrouping.rows([tool("a"), tool("b")])
        guard case .toolRun(let finished) = done[0] else { return XCTFail("expected a run") }
        XCTAssertFalse(finished.isRunning)
    }

    func testAnEmptyTranscriptIsEmpty() {
        XCTAssertTrue(TranscriptGrouping.rows([]).isEmpty)
    }

    func testRowsKeepTheirOrderAndIdentity() {
        let entries = [message("m1", .user), message("m2"), tool("a"), tool("b"), message("m3")]
        XCTAssertEqual(TranscriptGrouping.rows(entries).map(\.id), ["m1", "m2", "run-a", "m3"])
    }
}
