import XCTest
@testable import HermesRender

final class SyntaxHighlighterTests: XCTestCase {

    private func tokens(_ code: String, _ language: CodeLanguage) -> [(text: String, kind: TokenKind)] {
        SyntaxHighlighter.highlight(code, language: language)
            .map { (String($0.text(in: code)), $0.kind) }
    }

    private func kind(of needle: String, in code: String, _ language: CodeLanguage) -> TokenKind? {
        tokens(code, language).first { $0.text == needle }?.kind
    }

    // MARK: Language detection

    func testLanguageHints() {
        XCTAssertEqual(CodeLanguage(hint: "swift"), .swift)
        XCTAssertEqual(CodeLanguage(hint: "py"), .python)
        XCTAssertEqual(CodeLanguage(hint: " Python3 "), .python)
        XCTAssertEqual(CodeLanguage(hint: "bash"), .shell)
        XCTAssertEqual(CodeLanguage(hint: "JSON"), .json)
        XCTAssertNil(CodeLanguage(hint: "rust"))
        XCTAssertNil(CodeLanguage(hint: nil))
    }

    func testUnknownLanguageIsOnePlainRun() {
        let runs = SyntaxHighlighter.highlight("anything at all", language: nil)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].kind, .plain)
        XCTAssertEqual(String(runs[0].text(in: "anything at all")), "anything at all")
    }

    // MARK: Swift

    func testSwiftKeywordsStringsNumbersComments() {
        let code = "let name = \"hermes\" // the client\nfunc f() { return 42 }"
        XCTAssertEqual(kind(of: "let", in: code, .swift), .keyword)
        XCTAssertEqual(kind(of: "func", in: code, .swift), .keyword)
        XCTAssertEqual(kind(of: "return", in: code, .swift), .keyword)
        XCTAssertEqual(kind(of: "\"hermes\"", in: code, .swift), .string)
        XCTAssertEqual(kind(of: "// the client", in: code, .swift), .comment)
        XCTAssertEqual(kind(of: "42", in: code, .swift), .number)
    }

    func testSwiftTypesAndProperties() {
        let code = "let view = SwiftUI.Text(foo.bar)"
        XCTAssertEqual(kind(of: "SwiftUI", in: code, .swift), .type)
        XCTAssertEqual(kind(of: "Text", in: code, .swift), .type)
        XCTAssertEqual(kind(of: "bar", in: code, .swift), .property)
    }

    func testSwiftBlockCommentSpansLines() {
        var state = HighlightState()
        let first = Substring("/* start")
        let firstRuns = SyntaxHighlighter.highlight(line: first, language: .swift, state: &state)
        XCTAssertEqual(firstRuns.map(\.kind), [.comment])
        XCTAssertEqual(state.continuation, .blockComment(depth: 1))

        let second = Substring("middle */ let x = 1")
        let secondRuns = SyntaxHighlighter.highlight(line: second, language: .swift, state: &state)
        XCTAssertEqual(secondRuns.first?.kind, .comment)
        XCTAssertEqual(secondRuns.first.map { String(second[$0.range]) }, "middle */")
        XCTAssertEqual(secondRuns.last?.kind, .number)
        XCTAssertNil(state.continuation)
    }

    // MARK: Python

    func testPythonKeywordsAndBuiltins() {
        let code = "def go(path):\n    print(len(path))\n    return None"
        XCTAssertEqual(kind(of: "def", in: code, .python), .keyword)
        XCTAssertEqual(kind(of: "print", in: code, .python), .builtin)
        XCTAssertEqual(kind(of: "len", in: code, .python), .builtin)
        XCTAssertEqual(kind(of: "None", in: code, .python), .keyword)
        XCTAssertEqual(kind(of: "#".isEmpty ? "" : "return", in: code, .python), .keyword)
    }

    func testPythonDocstringStateAcrossLines() {
        var state = HighlightState()
        let opener = Substring("doc = \"\"\"first")
        let runs = SyntaxHighlighter.highlight(line: opener, language: .python, state: &state)
        XCTAssertEqual(runs.last?.kind, .string)
        XCTAssertEqual(state.continuation, .string(opener: "\"\"\""))

        let middle = Substring("still inside the docstring")
        let middleRuns = SyntaxHighlighter.highlight(line: middle, language: .python, state: &state)
        XCTAssertEqual(middleRuns.map(\.kind), [.string])
        XCTAssertEqual(state.continuation, .string(opener: "\"\"\""))

        let closer = Substring("\"\"\"\nprint(1)")
        let closerRuns = SyntaxHighlighter.highlight(line: closer, language: .python, state: &state)
        XCTAssertEqual(closerRuns.first?.kind, .string)
        XCTAssertEqual(closerRuns.first.map { String(closer[$0.range]) }, "\"\"\"")
        XCTAssertNil(state.continuation)
        XCTAssertTrue(closerRuns.contains { $0.kind == .builtin })
    }

    func testPythonHashCommentAndStringHash() {
        let code = "x = \"#not a comment\"  # real"
        XCTAssertEqual(kind(of: "# real", in: code, .python), .comment)
        XCTAssertEqual(kind(of: "\"#not a comment\"", in: code, .python), .string)
    }

    // MARK: JSON

    func testJSONKeysValuesAndNumbers() {
        let code = "{\"name\": \"hermes\", \"count\": 3, \"ok\": true}"
        XCTAssertEqual(kind(of: "\"name\"", in: code, .json), .property)
        XCTAssertEqual(kind(of: "\"hermes\"", in: code, .json), .string)
        XCTAssertEqual(kind(of: "\"count\"", in: code, .json), .property)
        XCTAssertEqual(kind(of: "3", in: code, .json), .number)
        XCTAssertEqual(kind(of: "true", in: code, .json), .keyword)
    }

    func testJSONHasNoComments() {
        XCTAssertNil(kind(of: "// not a comment", in: "// not a comment", .json))
    }

    // MARK: Shell

    func testShellKeywordsBuiltinsVariablesAndComments() {
        let code = "#!/usr/bin/env bash\nif [ -f \"$HOME/x\" ]; then echo ok; fi"
        XCTAssertEqual(kind(of: "#!/usr/bin/env bash", in: code, .shell), .comment)
        XCTAssertEqual(kind(of: "if", in: code, .shell), .keyword)
        XCTAssertEqual(kind(of: "then", in: code, .shell), .keyword)
        XCTAssertEqual(kind(of: "echo", in: code, .shell), .builtin)

        let variable = "cp $HOME/${DEST} /tmp"
        XCTAssertEqual(kind(of: "$HOME", in: variable, .shell), .variable)
        XCTAssertEqual(kind(of: "${DEST}", in: variable, .shell), .variable)
        let cpToken = tokens(variable, .shell).first { $0.text.contains("cp") }
        XCTAssertEqual(cpToken?.kind, .plain, "an ordinary command stays untokenised plain text")
    }

    // MARK: Coverage and attributed output

    func testRunsCoverTheWholeLine() {
        let samples: [(String, CodeLanguage)] = [
            ("let x: Int = 0x1F // c", .swift),
            ("print(\"hi\", 1.5)", .python),
            ("{\"a\": [1, 2]}", .json),
            ("ls -la | grep x > out.txt", .shell),
        ]
        for (code, language) in samples {
            let joined = SyntaxHighlighter.highlight(code, language: language)
                .map { String($0.text(in: code)) }
                .joined()
            XCTAssertEqual(joined, code, "\(language) runs must tile the line")
        }
    }

    func testAttributedCodeCarriesTokenAttribute() {
        let code = "let x = 1"
        let attributed = SyntaxHighlighter.attributed(code, language: .swift)
        XCTAssertEqual(String(attributed.characters), code)
        let keyword = attributed.runs.first { $0.attributes[CodeTokenAttribute.self] == .keyword }
        XCTAssertEqual(keyword.map { String(attributed[$0.range].characters) }, "let")
    }

    func testAttributedUsesFenceHint() {
        let attributed = SyntaxHighlighter.attributed("def f(): pass", languageHint: "py")
        let kinds = attributed.runs.compactMap { $0.attributes[CodeTokenAttribute.self] }
        XCTAssertTrue(kinds.contains(.keyword))
    }

    func testStreamingLinesMatchWholeSourceHighlighting() {
        let code = "let x = 1\nlet y = 2\n/* a\n b */ let z = 3"
        var state = HighlightState()
        var streamed: [(String, TokenKind)] = []
        var start = code.startIndex
        while start < code.endIndex {
            let end = code[start...].firstIndex(of: "\n") ?? code.endIndex
            streamed += SyntaxHighlighter.highlight(line: code[start..<end], language: .swift, state: &state)
                .map { (String($0.text(in: code)), $0.kind) }
            start = end == code.endIndex ? code.endIndex : code.index(after: end)
        }
        let whole = tokens(code, .swift)
        XCTAssertEqual(streamed.map(\.0), whole.map(\.text))
        XCTAssertEqual(streamed.map(\.1), whole.map(\.kind))
    }
}
