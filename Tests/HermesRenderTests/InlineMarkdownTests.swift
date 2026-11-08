import XCTest
@testable import HermesRender

final class InlineMarkdownTests: XCTestCase {

    // MARK: Spans

    func testPlainTextIsOneSpan() {
        XCTAssertEqual(InlineMarkdown.spans("just words"), [
            InlineSpan("just words"),
        ])
    }

    func testBoldItalicAndCode() {
        XCTAssertEqual(InlineMarkdown.spans("**b** *i* `c`"), [
            InlineSpan("b", styles: [.strong]),
            InlineSpan(" "),
            InlineSpan("i", styles: [.emphasis]),
            InlineSpan(" "),
            InlineSpan("c", styles: [.code]),
        ])
    }

    func testUnderscoreEmphasisAndStrikethrough() {
        XCTAssertEqual(InlineMarkdown.spans("_soft_ and ~~old~~"), [
            InlineSpan("soft", styles: [.emphasis]),
            InlineSpan(" and "),
            InlineSpan("old", styles: [.strikethrough]),
        ])
    }

    func testTripleDelimiterIsBoldAndItalic() {
        XCTAssertEqual(InlineMarkdown.spans("***loud***"), [
            InlineSpan("loud", styles: [.strong, .emphasis]),
        ])
    }

    func testNestedEmphasis() {
        let spans = InlineMarkdown.spans("**bold with *italic* inside**")
        XCTAssertEqual(spans, [
            InlineSpan("bold with ", styles: [.strong]),
            InlineSpan("italic", styles: [.strong, .emphasis]),
            InlineSpan(" inside", styles: [.strong]),
        ])
    }

    func testCodeSpanDoesNotNest() {
        XCTAssertEqual(InlineMarkdown.spans("`**not bold**`"), [
            InlineSpan("**not bold**", styles: [.code]),
        ])
    }

    func testLinkCarriesURL() {
        let spans = InlineMarkdown.spans("see [the docs](https://example.com/a?b=1) now")
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[1].text, "the docs")
        XCTAssertEqual(spans[1].link, URL(string: "https://example.com/a?b=1"))
        XCTAssertTrue(spans[1].styles.isEmpty)
        XCTAssertEqual(spans[0].text, "see ")
        XCTAssertEqual(spans[2].text, " now")
    }

    func testLinkLabelCanBeEmphasised() {
        XCTAssertEqual(InlineMarkdown.spans("[**hot** link](https://example.com)"), [
            InlineSpan("hot", styles: [.strong], link: URL(string: "https://example.com")),
            InlineSpan(" link", styles: [], link: URL(string: "https://example.com")),
        ])
    }

    func testLinkURLWithParentheses() {
        let spans = InlineMarkdown.spans("[wiki](https://en.wikipedia.org/wiki/Foo_(bar))!")
        XCTAssertEqual(spans.first?.link, URL(string: "https://en.wikipedia.org/wiki/Foo_(bar)"))
        XCTAssertEqual(spans.last?.text, "!")
    }

    func testAutolink() {
        XCTAssertEqual(InlineMarkdown.spans("go <https://example.com/x>"), [
            InlineSpan("go "),
            InlineSpan("https://example.com/x", styles: [], link: URL(string: "https://example.com/x")),
        ])
    }

    func testBareEmailInAngleBracketsStaysLiteral() {
        XCTAssertEqual(InlineMarkdown.spans("mail <a@b.c>"), [InlineSpan("mail <a@b.c>")])
    }

    // MARK: Robustness while streaming

    func testEscapedDelimitersAreLiteral() {
        XCTAssertEqual(InlineMarkdown.spans("\\*not italic\\*"), [InlineSpan("*not italic*")])
    }

    func testUnclosedEmphasisRendersLiterally() {
        XCTAssertEqual(InlineMarkdown.spans("**half a thought"), [InlineSpan("**half a thought")])
    }

    func testSnakeCaseIsNotEmphasis() {
        XCTAssertEqual(InlineMarkdown.spans("call my_function_name now"), [
            InlineSpan("call my_function_name now"),
        ])
    }

    func testUnmatchedBracketStaysLiteral() {
        XCTAssertEqual(InlineMarkdown.spans("[not a link"), [InlineSpan("[not a link")])
    }

    func testInvalidURLIsLiteral() {
        XCTAssertEqual(InlineMarkdown.spans("[x](not a url)"), [InlineSpan("[x](not a url)")])
    }

    func testPlainTextDropsDelimiters() {
        XCTAssertEqual(
            InlineMarkdown.plainText("**bold** and [link](https://example.com)"),
            "bold and link"
        )
    }

    // MARK: AttributedString

    func testAttributedStringCarriesInlineAttributes() {
        let attributed = InlineMarkdown.attributedString("**bold** *soft* `code` ~~gone~~ [l](https://e.co)")

        func runs(where predicate: (AttributeContainer) -> Bool) -> [String] {
            attributed.runs.compactMap { run in
                predicate(run.attributes) ? String(attributed[run.range].characters) : nil
            }
        }

        XCTAssertEqual(runs { $0[BoldAttribute.self] == true }, ["bold"])
        XCTAssertEqual(runs { $0[ItalicAttribute.self] == true }, ["soft"])
        XCTAssertEqual(runs { $0[InlineCodeAttribute.self] == true }, ["code"])
        XCTAssertEqual(runs { $0[StrikethroughAttribute.self] == true }, ["gone"])
        XCTAssertEqual(runs { $0.link != nil }, ["l"])
        XCTAssertEqual(String(attributed.characters), "bold soft code gone l")
    }

    /// A download address arrives as prose, not as markdown: it has to be a link anyway.
    func testBareURLInProseBecomesALink() {
        let attributed = InlineMarkdown.attributedString(
            "Mac build: https://hermes.example.ts.net:8444/Hermes-macOS-unsigned.zip")
        let links = attributed.runs.compactMap { run -> String? in
            guard let url = run.attributes.link else { return nil }
            return url.absoluteString
        }
        XCTAssertEqual(links, ["https://hermes.example.ts.net:8444/Hermes-macOS-unsigned.zip"])
    }

    func testASentenceFullStopIsNotPartOfTheLink() {
        let attributed = InlineMarkdown.attributedString("See https://example.com/download.zip.")
        let links = attributed.runs.compactMap { $0.attributes.link?.absoluteString }
        XCTAssertEqual(links, ["https://example.com/download.zip"])
        XCTAssertEqual(String(attributed.characters), "See https://example.com/download.zip.")
    }

    func testAURLInsideCodeStaysText() {
        let attributed = InlineMarkdown.attributedString("`curl https://example.com/x`")
        XCTAssertTrue(attributed.runs.allSatisfy { $0.attributes.link == nil })
    }

    func testAMarkdownLinkIsNotDoubleLinked() {
        let attributed = InlineMarkdown.attributedString("[docs](https://example.com/docs)")
        let links = attributed.runs.compactMap { $0.attributes.link?.absoluteString }
        XCTAssertEqual(links, ["https://example.com/docs"])
        XCTAssertEqual(String(attributed.characters), "docs")
    }

    func testEmptyString() {
        XCTAssertEqual(InlineMarkdown.spans(""), [])
        XCTAssertEqual(String(InlineMarkdown.attributedString("").characters), "")
    }

}
