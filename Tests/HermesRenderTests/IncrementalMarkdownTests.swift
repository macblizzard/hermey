import XCTest
@testable import HermesRender

final class IncrementalMarkdownTests: XCTestCase {

    func testParagraphAndBullets() {
        let blocks = IncrementalMarkdown.parse("Backup is good.\n\n- a.md\n- b.md")
        XCTAssertEqual(blocks, [
            .paragraph("Backup is good."),
            .bullet("a.md"),
            .bullet("b.md"),
        ])
    }

    func testHeadingAndRule() {
        let blocks = IncrementalMarkdown.parse("## Files\n---\ntext")
        XCTAssertEqual(blocks.first, .heading(level: 2, text: "Files"))
        XCTAssertTrue(blocks.contains(.rule))
    }

    func testStreamingCodeFenceStaysOpen() {
        var md = IncrementalMarkdown()
        md.append("```swift\nlet x = 1\n")
        XCTAssertEqual(md.blocks.count, 1)
        guard case .code(let lang, let body, let closed) = md.blocks[0] else { return XCTFail() }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(body, "let x = 1")
        XCTAssertFalse(closed, "an unclosed fence while streaming must be marked unclosed")

        md.append("```\n")
        guard case .code(_, _, let nowClosed) = md.blocks[0] else { return XCTFail() }
        XCTAssertTrue(nowClosed)
    }

    func testAppendReportsOnlyChangedBlocks() {
        var md = IncrementalMarkdown()
        md.append("Hello")
        XCTAssertEqual(md.blocks, [.paragraph("Hello")])
        let changed = md.append(" world")
        XCTAssertEqual(changed, [0], "only the live paragraph is re-emitted, not the whole transcript")
        XCTAssertEqual(md.blocks, [.paragraph("Hello world")])
    }

    func testNumberedList() {
        XCTAssertEqual(IncrementalMarkdown.parse("1. one\n2. two"),
                       [.numbered(index: 1, text: "one"), .numbered(index: 2, text: "two")])
    }

    func testQuote() {
        XCTAssertEqual(IncrementalMarkdown.parse("> because it deletes"), [.quote("because it deletes")])
    }

    // MARK: Incremental contract

    func testIncrementalBlocksAlwaysMatchAFullParse() {
        var md = IncrementalMarkdown()
        let chunks = [
            "# Title\n\n",
            "Some **bold** text",
            " continues\n",
            "\n- one\n",
            "- two\n",
            "\n1. first\n",
            "\n```swift\n",
            "let x = 1\n",
            "```\n",
            "> quoted\n",
            "\n---\n",
            "Done",
        ]
        for chunk in chunks {
            md.append(chunk)
            XCTAssertEqual(md.blocks, IncrementalMarkdown.parse(md.source), "chunk \(chunk.debugDescription)")
        }
    }

    func testAppendOnlyReparsesTheLastBlock() {
        var md = IncrementalMarkdown()
        let paragraphs = (1...300).map { "paragraph \($0) with enough words to be a real block" }
            .joined(separator: "\n\n")
        md.append(paragraphs)
        XCTAssertEqual(md.blocks.count, 300)

        let before = md.reparsedCharacterCount
        md.append(" more")
        let cost = md.reparsedCharacterCount - before
        XCTAssertLessThan(cost, 100, "one token must re-parse the last block, not the 300-block transcript")
    }

    func testCodeFenceKeepsLaterOffsetsCorrect() {
        var md = IncrementalMarkdown()
        md.append("```\ncode\n```\n\nAfter the fence")
        XCTAssertEqual(md.blocks, [
            .code(language: nil, body: "code", closed: true),
            .paragraph("After the fence"),
        ])
        md.append(" grows")
        XCTAssertEqual(md.blocks.last, .paragraph("After the fence grows"))
        XCTAssertEqual(md.blocks, IncrementalMarkdown.parse(md.source))
    }

    // MARK: Tables

    func testTableBecomesOneBlockAndTheProseAfterItStaysProse() {
        let blocks = IncrementalMarkdown.parse("""
        | File | Status |
        | --- | --- |
        | a.md | new |
        After the table.
        """)

        guard blocks.count == 2, case .table(let table) = blocks[0] else {
            return XCTFail("expected a table block followed by a paragraph, got \(blocks)")
        }
        XCTAssertEqual(table.header, ["File", "Status"])
        XCTAssertEqual(table.rows, [["a.md", "new"]])
        XCTAssertEqual(blocks[1], .paragraph("After the table."))
    }

    func testTableOnlyFormsWhenTheDelimiterRowArrives() {
        var md = IncrementalMarkdown()
        md.append("| a | b |\n")
        XCTAssertEqual(md.blocks, [.paragraph("| a | b |")],
                       "a header alone is still just a sentence with pipes")

        md.append("| --- | --- |\n")
        guard md.blocks.count == 1, case .table(let table) = md.blocks[0] else {
            return XCTFail("expected the delimiter row to turn the line into a table, got \(md.blocks)")
        }
        XCTAssertEqual(table.header, ["a", "b"])
        XCTAssertEqual(table.rows, [])
    }

    func testStreamedTableMatchesAFullParse() {
        let document = """
        Before the table:

        | Name | Note |
        | :--- | ---: |
        | `a | b` | left \\| right |
        | short |

        After the table.
        """
        var md = IncrementalMarkdown()
        var index = document.startIndex
        while index < document.endIndex {
            let end = document.index(index, offsetBy: 3, limitedBy: document.endIndex) ?? document.endIndex
            md.append(String(document[index..<end]))
            XCTAssertEqual(md.blocks, IncrementalMarkdown.parse(md.source),
                           "split at \(document.distance(from: document.startIndex, to: end))")
            index = end
        }

        XCTAssertEqual(md.blocks.count, 3)
        guard case .table(let table) = md.blocks[1] else { return XCTFail() }
        XCTAssertEqual(table.alignments, [.leading, .trailing])
        XCTAssertEqual(table.rows, [["`a | b`", "left | right"], ["short", ""]])
    }

    func testStreamedTableWithoutOuterPipesMatchesAFullParse() {
        let document = """
        Status | Meaning
        --- | ---
        ok | fine
        fail | broken
        """
        var md = IncrementalMarkdown()
        // One character at a time: every partial row ("o", "ok", "ok |") must parse
        // the same as a full re-parse of what has arrived.
        for character in document {
            md.append(String(character))
            XCTAssertEqual(md.blocks, IncrementalMarkdown.parse(md.source),
                           "after \(md.source.debugDescription)")
        }
        guard md.blocks.count == 1, case .table(let table) = md.blocks[0] else {
            return XCTFail("expected one table block, got \(md.blocks)")
        }
        XCTAssertEqual(table.rows, [["ok", "fine"], ["fail", "broken"]])
    }

    func testTableFollowedByMoreBlocksKeepsOffsetsCorrect() {
        var md = IncrementalMarkdown()
        md.append("| a | b |\n| --- | --- |\n| 1 | 2 |\n\nAfter the table.")
        XCTAssertEqual(md.blocks.count, 2)
        md.append(" grows")
        XCTAssertEqual(md.blocks.last, .paragraph("After the table. grows"))
        XCTAssertEqual(md.blocks, IncrementalMarkdown.parse(md.source))
    }

    func testChunkedAppendsMatchAFullParseForArbitrarySplits() {
        let document = """
        # Deploy notes

        The **build** is green, see `ci.yml`.

        - first item
        - second item

        1. step one
        2. step two

        ```swift
        let x = 1
        // a comment

        let y = 2
        ```

        > quoted line

        | Step | State |
        | --- | --- |
        | build | green |
        | test | red |

        ---
        trailing paragraph
        """
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }

        var md = IncrementalMarkdown()
        var index = document.startIndex
        while index < document.endIndex {
            let remaining = document.distance(from: index, to: document.endIndex)
            let take = min(remaining, 1 + next() % 7)
            let end = document.index(index, offsetBy: take)
            md.append(String(document[index..<end]))
            XCTAssertEqual(md.blocks, IncrementalMarkdown.parse(md.source), "split at \(document.distance(from: document.startIndex, to: end))")
            index = end
        }
        XCTAssertEqual(md.blocks.count, 11)
    }
}
