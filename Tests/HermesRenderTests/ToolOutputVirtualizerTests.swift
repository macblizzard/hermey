import XCTest
@testable import HermesRender

final class ToolOutputVirtualizerTests: XCTestCase {

    // MARK: Indexing

    func testLineCountingMatchesEditorSemantics() {
        XCTAssertEqual(ToolOutput("").lineCount, 0)
        XCTAssertEqual(ToolOutput("a").lineCount, 1)
        XCTAssertEqual(ToolOutput("a\n").lineCount, 1, "a trailing newline does not open an empty line")
        XCTAssertEqual(ToolOutput("a\nb").lineCount, 2)
        XCTAssertEqual(ToolOutput("a\n\n").lineCount, 2)
        XCTAssertEqual(ToolOutput("\n").lineCount, 1)
    }

    func testLinesDropTrailingNewlineAndCarriageReturn() {
        let output = ToolOutput("first\r\nsecond\nthird")
        XCTAssertEqual(output.lineText(at: 0), "first")
        XCTAssertEqual(output.lineText(at: 1), "second")
        XCTAssertEqual(output.lineText(at: 2), "third")
        XCTAssertNil(output.lineText(at: 3))
    }

    func testAppendKeepsLineIndexConsistent() {
        var output = ToolOutput("a\nb\n")
        XCTAssertEqual(output.lineCount, 2)
        output.append("c")
        XCTAssertEqual(output.lineCount, 3)
        XCTAssertEqual(output.lineText(at: 2), "c")

        output.append("\nd")
        XCTAssertEqual(output.lineCount, 4)
        XCTAssertEqual(output.lineText(at: 2), "c")
        XCTAssertEqual(output.lineText(at: 3), "d")

        var streamed = ToolOutput()
        for chunk in ["one\n", "two\n", "three"] {
            streamed.append(chunk)
        }
        XCTAssertEqual(ToolOutput("one\ntwo\nthree").lineCount, streamed.lineCount)
        XCTAssertEqual((0..<streamed.lineCount).compactMap { streamed.lineText(at: $0) },
                       ["one", "two", "three"])
    }

    // MARK: Windowing 100k lines

    func testHundredThousandLineWindowMaterialisesOnlyTheWindow() {
        let text = (1...100_000).map { "line \($0)" }.joined(separator: "\n")
        let virtualizer = ToolOutputVirtualizer(text: text, configuration: .init(visibleLines: 20, overscan: 5))

        let window = virtualizer.window(around: 50_000..<50_020)

        XCTAssertEqual(window.totalLines, 100_000)
        XCTAssertEqual(window.visibleLines, 50_000..<50_020)
        XCTAssertEqual(window.lines, 49_995..<50_025)
        XCTAssertEqual(window.rows.count, 32, "30 lines plus a head and a tail truncation marker")
        XCTAssertEqual(window.rows.first, .truncation(hiddenLines: 49_995))
        XCTAssertEqual(window.rows.last, .truncation(hiddenLines: 49_975))

        guard case .line(let number, let text, let truncated) = window.rows[1] else {
            return XCTFail("expected a line row")
        }
        XCTAssertEqual(number, 49_996)
        XCTAssertEqual(text, "line 49996")
        XCTAssertFalse(truncated)
        XCTAssertTrue(window.hasMoreAbove)
        XCTAssertTrue(window.hasMoreBelow)
    }

    func testHeadWindowHasNoHeadMarker() {
        let text = (1...100).map(String.init).joined(separator: "\n")
        let virtualizer = ToolOutputVirtualizer(text: text, configuration: .init(visibleLines: 10, overscan: 0))
        let window = virtualizer.window(around: 0..<10)

        XCTAssertFalse(window.hasMoreAbove)
        XCTAssertTrue(window.hasMoreBelow)
        XCTAssertEqual(window.rows.first, .line(number: 1, text: "1", truncated: false))
        XCTAssertEqual(window.rows.last, .truncation(hiddenLines: 90))
    }

    func testTailWindowFollowsStreamingOutput() {
        var virtualizer = ToolOutputVirtualizer(
            text: (1...100).map(String.init).joined(separator: "\n"),
            configuration: .init(visibleLines: 5, overscan: 0)
        )
        var window = virtualizer.tailWindow()
        XCTAssertEqual(window.lines, 95..<100)
        XCTAssertEqual(window.rows.last, .line(number: 100, text: "100", truncated: false))

        virtualizer.append("\n101\n102")
        window = virtualizer.tailWindow()
        XCTAssertEqual(window.totalLines, 102)
        XCTAssertEqual(window.lines, 97..<102)
        XCTAssertEqual(window.rows.last, .line(number: 102, text: "102", truncated: false))
        XCTAssertEqual(window.rows.first, .truncation(hiddenLines: 97))
    }

    func testClampingOutOfRangeRequests() {
        let virtualizer = ToolOutputVirtualizer(text: "a\nb\nc", configuration: .init(visibleLines: 10, overscan: 0))
        XCTAssertEqual(virtualizer.window(around: 99..<120).lines, 3..<3)
        XCTAssertEqual(virtualizer.window(around: -5..<2).visibleLines, 0..<2)
        XCTAssertEqual(virtualizer.window(around: 0..<0).lines, 0..<0)
        XCTAssertTrue(virtualizer.window(around: 0..<0).rows.isEmpty)
    }

    func testEmptyOutput() {
        let window = ToolOutputVirtualizer(text: "").window(around: 0..<10)
        XCTAssertEqual(window.totalLines, 0)
        XCTAssertTrue(window.rows.isEmpty)
    }

    // MARK: Long lines and limits

    func testOneEnormousLineIsTruncated() {
        let long = String(repeating: "x", count: 5_000)
        let virtualizer = ToolOutputVirtualizer(text: long, configuration: .init(maxLineLength: 100))
        let window = virtualizer.window(around: 0..<1)
        guard case .line(_, let text, let truncated) = window.rows.first else {
            return XCTFail("expected a line row")
        }
        XCTAssertTrue(truncated)
        XCTAssertEqual(text.count, 100)
    }

    func testMaxWindowRowsCapsRunawayRequests() {
        let text = (1...1_000).map(String.init).joined(separator: "\n")
        let virtualizer = ToolOutputVirtualizer(text: text, configuration: .init(visibleLines: 1_000, overscan: 0, maxWindowRows: 50))
        let window = virtualizer.window(around: 0..<1_000)
        XCTAssertEqual(window.lines.count, 50)
        XCTAssertEqual(window.rows.filter { row in
            if case .line = row { return true } else { return false }
        }.count, 50)
    }

    func testVeryLongOutputTimesOutQuickly() {
        // 100k lines, a window in the middle: the cost must be the window, not the
        // output. This is a smoke test for accidental whole-file scanning.
        let text = (1...100_000).map { "row \($0)\t\($0 * 7)" }.joined(separator: "\n")
        let virtualizer = ToolOutputVirtualizer(text: text)
        let start = Date()
        for _ in 0..<100 {
            _ = virtualizer.window(around: 40_000..<40_060)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
    }
}
