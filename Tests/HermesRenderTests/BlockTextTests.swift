import XCTest
@testable import HermesRender

final class BlockTextTests: XCTestCase {

    func testParagraphCompilesInlineMarkdown() {
        let attributed = BlockText.attributed(for: .paragraph("use **sudo** and `rm`"))
        XCTAssertEqual(String(attributed.characters), "use sudo and rm")
        let bold = attributed.runs.compactMap { run -> String? in
            run.attributes[BoldAttribute.self] == true ? String(attributed[run.range].characters) : nil
        }
        XCTAssertEqual(bold, ["sudo"])
    }

    func testHeadingIsBoldWithoutDelimiters() {
        let attributed = BlockText.attributed(for: .heading(level: 2, text: "Files"))
        XCTAssertEqual(String(attributed.characters), "Files")
        XCTAssertEqual(attributed.runs.first?.attributes[BoldAttribute.self], true)
    }

    func testBulletAndNumberMarkersAreInTheText() {
        XCTAssertEqual(String(BlockText.attributed(for: .bullet("a.md")).characters), "• a.md")
        XCTAssertEqual(String(BlockText.attributed(for: .numbered(index: 3, text: "run it")).characters), "3. run it")
        XCTAssertEqual(BlockText.marker(for: .bullet("x")), "•")
        XCTAssertEqual(BlockText.marker(for: .numbered(index: 7, text: "x")), "7.")
        XCTAssertNil(BlockText.marker(for: .paragraph("x")))
    }

    func testCodeBlockIsHighlightedAndTagged() {
        let block = Block.code(language: "swift", body: "let x = 42 // answer", closed: true)
        let attributed = BlockText.attributed(for: block)

        XCTAssertEqual(String(attributed.characters), "let x = 42 // answer")
        XCTAssertEqual(attributed.runs.first?.attributes[CodeBlockAttribute.self], "swift")
        XCTAssertNil(attributed.runs.first?.attributes[InlineCodeAttribute.self])

        let keyword = attributed.runs.first { $0.attributes[CodeTokenAttribute.self] == .keyword }
        XCTAssertEqual(keyword.map { String(attributed[$0.range].characters) }, "let")
        let comment = attributed.runs.first { $0.attributes[CodeTokenAttribute.self] == .comment }
        XCTAssertEqual(comment.map { String(attributed[$0.range].characters) }, "// answer")
    }

    func testCodeBlockWithoutLanguageStillRenders() {
        let attributed = BlockText.attributed(for: .code(language: nil, body: "plain text", closed: false))
        XCTAssertEqual(String(attributed.characters), "plain text")
        XCTAssertEqual(attributed.runs.first?.attributes[CodeBlockAttribute.self], "")
    }

    func testRuleHasNoText() {
        XCTAssertEqual(String(BlockText.attributed(for: .rule).characters), "")
    }

    func testPlainTextIncludesMarkersAndDropsDelimiters() {
        XCTAssertEqual(BlockText.plainText(for: .bullet("**a.md**")), "• a.md")
        XCTAssertEqual(BlockText.plainText(for: .numbered(index: 2, text: "[x](https://e.co)")), "2. x")
        XCTAssertEqual(BlockText.plainText(for: .code(language: nil, body: "body", closed: true)), "body")
        XCTAssertEqual(BlockText.plainText(for: .rule), "")
    }
}
