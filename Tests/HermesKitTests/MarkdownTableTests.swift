import XCTest
@testable import HermesKit

final class MarkdownTableTests: XCTestCase {

    // MARK: Helpers

    private func parse(_ text: String, from index: Int = 0)
        -> (table: MarkdownTable, consumed: Int)? {
        MarkdownTableParser.parse(lines: text.components(separatedBy: "\n"), startingAt: index)
    }

    private func parsed(_ text: String, from index: Int = 0,
                        file: StaticString = #filePath, line: UInt = #line) -> MarkdownTable? {
        guard let result = parse(text, from: index) else {
            XCTFail("expected a table in \(text.debugDescription)", file: file, line: line)
            return nil
        }
        return result.table
    }

    // MARK: Basics

    func testBasicTableWithOuterPipes() {
        let table = parsed("""
        | File | Status |
        | --- | --- |
        | a.md | new |
        | b.md | deleted |
        """)

        XCTAssertEqual(table?.header, ["File", "Status"])
        XCTAssertEqual(table?.rows, [["a.md", "new"], ["b.md", "deleted"]])
        XCTAssertEqual(table?.alignments, [.none, .none])
        XCTAssertEqual(table?.columnCount, 2)
    }

    func testMissingOuterPipes() {
        let table = parsed("""
        File | Status
        --- | ---
        a.md | new
        """)

        XCTAssertEqual(table?.header, ["File", "Status"])
        XCTAssertEqual(table?.rows, [["a.md", "new"]])
    }

    func testOneOuterPipeOnly() {
        let table = parsed("""
        | a | b
        | --- | ---
        | 1 | 2
        """)

        XCTAssertEqual(table?.header, ["a", "b"])
        XCTAssertEqual(table?.rows, [["1", "2"]])
    }

    func testSingleColumnTable() {
        let table = parsed("""
        | item |
        | --- |
        | one |
        """)

        XCTAssertEqual(table?.header, ["item"])
        XCTAssertEqual(table?.rows, [["one"]])
    }

    func testWhitespaceAroundCellsIsTrimmed() {
        let table = parsed("|   Name   |   Qty   |\n|  ---  |  ---  |\n|   a   |   2   |")
        XCTAssertEqual(table?.header, ["Name", "Qty"])
        XCTAssertEqual(table?.rows, [["a", "2"]])
    }

    func testHeaderOnlyTable() {
        let table = parsed("| a | b |\n| --- | --- |")
        XCTAssertEqual(table?.header, ["a", "b"])
        XCTAssertEqual(table?.rows, [])
    }

    // MARK: Alignment

    func testAlignmentMarkers() {
        let table = parsed("""
        | left | centre | right | plain |
        | :--- | :---: | ---: | --- |
        | a | b | c | d |
        """)

        XCTAssertEqual(table?.alignments, [.leading, .center, .trailing, .none])
        XCTAssertEqual(table?.rows, [["a", "b", "c", "d"]])
    }

    func testAlignmentWithoutOuterPipes() {
        let table = parsed("a | b\n:-- | --:\nc | d")
        XCTAssertEqual(table?.alignments, [.leading, .trailing])
    }

    func testDelimiterWithOneDashIsAccepted() {
        XCTAssertEqual(parsed("a | b\n-|-\n1 | 2")?.alignments, [.none, .none])
    }

    func testDelimiterCellMustBeOnlyDashesAndColons() {
        XCTAssertNil(parse("a | b\n--x | ---\n1 | 2"), "a delimiter cell with a letter is prose, not a table")
        XCTAssertNil(parse("a | b\n-: - | ---\n1 | 2"))
    }

    func testDelimiterCellCountMustMatchHeader() {
        XCTAssertNil(parse("| a | b |\n| --- |\n| 1 | 2 |"),
                     "a delimiter row with the wrong arity is not a table")
        XCTAssertNil(parse("| a |\n| --- | --- |"))
    }

    // MARK: Ragged rows

    func testRaggedRowsArePaddedAndTruncatedToTheHeader() {
        let table = parsed("""
        | a | b | c |
        | --- | --- | --- |
        | 1 |
        | 1 | 2 | 3 | 4 |
        """)

        XCTAssertEqual(table?.rows, [
            ["1", "", ""],
            ["1", "2", "3"],
        ])
        XCTAssertEqual(table?.rows.allSatisfy { $0.count == 3 }, true)
    }

    // MARK: Escapes and inline spans

    func testEscapedPipeStaysInTheCell() {
        let table = parsed("""
        | path | note |
        | --- | --- |
        | ~/vault \\| backup | one \\| two |
        """)

        XCTAssertEqual(table?.header, ["path", "note"])
        XCTAssertEqual(table?.rows, [["~/vault | backup", "one | two"]])
    }

    func testPipeInsideInlineCodeDoesNotSplitTheCell() {
        let table = parsed("""
        | expression | meaning |
        | --- | --- |
        | `a | b` | either |
        """)

        XCTAssertEqual(table?.rows, [["`a | b`", "either"]])
    }

    func testEscapedPipeInsideInlineCodeIsUnescaped() {
        let table = parsed("| shell |\n| --- |\n| `cat a \\| b` |")
        XCTAssertEqual(table?.rows, [["`cat a | b`"]])
    }

    func testInlineMarkdownIsLeftForTheRenderer() {
        let table = parsed("| what | why |\n| --- | --- |\n| **bold** `code` | a *quiet* note |")
        XCTAssertEqual(table?.rows, [["**bold** `code`", "a *quiet* note"]])
    }

    // MARK: What is not a table

    func testPipeContainingLineWithoutDelimiterIsProse() {
        XCTAssertNil(parse("Use `a | b` to mean either, so pass the flag."))
        XCTAssertNil(parse("a | b\nnot a delimiter\n1 | 2"))
    }

    func testLonePipeIsNotATable() {
        XCTAssertNil(parse("|"))
        XCTAssertNil(parse("|\n|---|"))
        XCTAssertFalse(MarkdownTableParser.isRowLine("|"))
    }

    func testIndentedCodeBlockIsNotATable() {
        XCTAssertNil(parse("    | a | b |\n    | --- | --- |\n    | 1 | 2 |"))
        XCTAssertNil(parse("\t| a | b |\n\t| --- | --- |"))
    }

    func testHeadingBulletAndQuoteLinesAreNotTableRows() {
        XCTAssertNil(parse("# a | b\n--- | ---"))
        XCTAssertNil(parse("> a | b\n--- | ---"))
        XCTAssertNil(parse("- a | b\n--- | ---"))
    }

    func testDelimiterAloneIsARuleNotATable() {
        // `---` is exactly the rule branch; it must never be read as a delimiter row.
        XCTAssertNil(MarkdownTableParser.splitCells("    ---"))
        XCTAssertNil(MarkdownTableParser.delimiterAlignments("---"))
    }

    // MARK: Where the table stops

    func testTableStopsAtTheFirstNonTableLine() {
        let text = """
        | a | b |
        | --- | --- |
        | 1 | 2 |
        That paragraph is prose.
        """
        guard let result = parse(text) else { return XCTFail("expected a table") }
        XCTAssertEqual(result.consumed, 3, "the trailing paragraph must not be eaten")
        XCTAssertEqual(result.table.rows, [["1", "2"]])
    }

    func testTableStopsAtABlankLine() {
        let text = "| a | b |\n| --- | --- |\n\nAfter"
        XCTAssertEqual(parse(text)?.consumed, 2)
        XCTAssertEqual(parse(text)?.table.rows, [])
    }

    func testTableStartingAfterProse() {
        let text = "Here is the plan:\n| a | b |\n| --- | --- |\n| 1 | 2 |"
        XCTAssertNil(parse(text, from: 0))
        XCTAssertEqual(parse(text, from: 1)?.table.rows, [["1", "2"]])
        XCTAssertEqual(parse(text, from: 1)?.consumed, 3)
    }

    func testParseWithoutRoomForADelimiterRow() {
        XCTAssertNil(parse("| a | b |"))
    }

    func testTableNeedsARowLineHeader() {
        XCTAssertNil(parse("Intro text\n--- | ---\n| 1 | 2 |"))
    }

    // MARK: Streaming helper

    func testDelimiterRowPrefixRecognisesAPartialDelimiter() {
        XCTAssertTrue(MarkdownTableParser.isDelimiterRowPrefix("---"))
        XCTAssertTrue(MarkdownTableParser.isDelimiterRowPrefix("--- | ---"))
        XCTAssertTrue(MarkdownTableParser.isDelimiterRowPrefix("| :-"))
        XCTAssertFalse(MarkdownTableParser.isDelimiterRowPrefix("Status"))
        XCTAssertFalse(MarkdownTableParser.isDelimiterRowPrefix("- item"))
        XCTAssertFalse(MarkdownTableParser.isDelimiterRowPrefix("    ---"))
    }

    // MARK: Plain text

    func testPlainTextKeepsEveryRow() {
        let table = parsed("| a | b |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertEqual(table?.plainText, "a | b\n1 | 2")
    }
}
