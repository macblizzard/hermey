import Foundation

/// Code languages the chat renderer knows about. Anything else renders as plain
/// text — there are no dependencies and no grammar files.
public enum CodeLanguage: String, CaseIterable, Sendable {
    case swift
    case python
    case json
    case shell

    /// Accept the fence hints models actually write (`py`, `sh`, `bash`, `zsh`, …).
    public init?(hint: String?) {
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "swift", "swiftui": self = .swift
        case "python", "py", "python3": self = .python
        case "json", "jsonc", "json5": self = .json
        case "shell", "sh", "bash", "zsh", "console", "terminal": self = .shell
        default: return nil
        }
    }

    /// Parse a fence hint; nil when the language is unknown or absent.
    public static func detect(_ hint: String?) -> CodeLanguage? {
        CodeLanguage(hint: hint)
    }
}

/// A lexical class. The block layer tags runs with this; the apps map each case to
/// a colour from their own palette.
public enum TokenKind: String, CaseIterable, Hashable, Sendable {
    case plain
    case keyword
    case type
    case string
    case comment
    case number
    case punctuation
    case builtin
    case property
    case variable
    case attribute
}

/// A highlighted slice of a line (or of a whole source string). The range indexes
/// the string the run was produced from, so it stays valid for a `Substring`.
public struct HighlightedRun: Equatable, Sendable {
    public var kind: TokenKind
    public var range: Range<String.Index>

    public init(kind: TokenKind, range: Range<String.Index>) {
        self.kind = kind
        self.range = range
    }

    public func text(in source: String) -> Substring { source[range] }
}

/// What a multi-line construct leaves behind for the next line.
///
/// This is what makes highlighting a streamed code block cheap: each line is
/// lexed against the previous line's state, so a growing fence is never
/// re-tokenised from the top.
public struct HighlightState: Equatable, Sendable {
    public enum Continuation: Equatable, Sendable {
        case blockComment(depth: Int)
        case string(opener: String)
    }

    public var continuation: Continuation?

    public init(continuation: Continuation? = nil) {
        self.continuation = continuation
    }

    public var isInMultilineConstruct: Bool { continuation != nil }
}

/// A small, dependency-free highlighter for swift, python, json and shell.
///
/// It is intentionally lexical: enough to make a tool's code output readable while
/// a reply streams, not a parser. Unknown languages return one plain run.
public enum SyntaxHighlighter {

    // MARK: Entry points

    /// Highlight a whole source string, line by line, carrying multi-line state.
    public static func highlight(_ source: String, language: CodeLanguage?) -> [HighlightedRun] {
        guard let language else {
            guard !source.isEmpty else { return [] }
            return [HighlightedRun(kind: .plain, range: source.startIndex..<source.endIndex)]
        }
        var state = HighlightState()
        var runs: [HighlightedRun] = []
        var lineStart = source.startIndex

        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            runs.append(contentsOf: highlight(line: source[lineStart..<lineEnd], language: language, state: &state))
            lineStart = lineEnd == source.endIndex ? source.endIndex : source.index(after: lineEnd)
        }
        return runs
    }

    /// Highlight a whole source string using the fence's language hint.
    public static func highlight(_ source: String, languageHint: String?) -> [HighlightedRun] {
        highlight(source, language: CodeLanguage(hint: languageHint))
    }

    /// Highlight one line against carried state — the streaming path.
    ///
    /// `line` may be a `Substring` of the source being built; ranges in the result
    /// point into that same storage, so the caller can slice the original text.
    public static func highlight(
        line: Substring,
        language: CodeLanguage,
        state: inout HighlightState
    ) -> [HighlightedRun] {
        var lexer = Lexer(line: line, language: language, state: state)
        let runs = lexer.run()
        state = lexer.state
        return runs
    }

    /// Compile code to an `AttributedString` whose non-plain runs carry
    /// `CodeTokenAttribute`.
    public static func attributed(_ source: String, language: CodeLanguage?) -> AttributedString {
        var attributed = AttributedString(source)
        for run in highlight(source, language: language) where run.kind != .plain {
            guard let range = Range<AttributedString.Index>(run.range, in: attributed) else { continue }
            var container = AttributeContainer()
            container[CodeTokenAttribute.self] = run.kind
            attributed[range].mergeAttributes(container)
        }
        return attributed
    }

    /// As above, resolving the language from a fence hint (` ```swift `).
    public static func attributed(_ source: String, languageHint: String?) -> AttributedString {
        attributed(source, language: CodeLanguage(hint: languageHint))
    }
}

// MARK: - Lexer

private struct Lexer {
    let line: Substring
    let language: CodeLanguage
    var state: HighlightState
    var index: Substring.Index
    var lastEnd: Substring.Index
    var runs: [HighlightedRun] = []
    var previousSignificant: Character?

    init(line: Substring, language: CodeLanguage, state: HighlightState) {
        self.line = line
        self.language = language
        self.state = state
        self.index = line.startIndex
        self.lastEnd = line.startIndex
    }

    mutating func run() -> [HighlightedRun] {
        if let continuation = state.continuation {
            resume(continuation)
        }

        while index < line.endIndex {
            let character = line[index]

            if let commentStart = commentStart(at: index, character: character) {
                emit(commentStart.kind, from: index, to: commentStart.end)
                index = commentStart.end
                previousSignificant = nil
                continue
            }

            switch character {
            case "\"", "'", "`":
                if let token = scanString(quote: character) {
                    emit(token.kind, from: token.start, to: token.end)
                    index = token.end
                    previousSignificant = character
                    continue
                }
                advance()

            case "@" where language == .swift || language == .python:
                let end = scanAttribute(from: index)
                emit(.attribute, from: index, to: end)
                index = end
                previousSignificant = nil

            case "$" where language == .shell:
                let end = scanVariable(from: index)
                emit(.variable, from: index, to: end)
                index = end
                previousSignificant = nil

            default:
                if character.isNumber, isNumberStart(index) {
                    let end = scanNumber(from: index)
                    emit(.number, from: index, to: end)
                    index = end
                    previousSignificant = nil
                } else if isIdentifierStart(character) {
                    let end = scanIdentifier(from: index)
                    let kind = classify(identifier: String(line[index..<end]))
                    emit(kind, from: index, to: end)
                    index = end
                } else if isPunctuation(character) {
                    emit(.punctuation, from: index, to: line.index(after: index))
                    index = line.index(after: index)
                    previousSignificant = character
                } else {
                    advance()
                }
            }
        }

        if lastEnd < line.endIndex {
            append(.plain, from: lastEnd, to: line.endIndex)
        }
        return runs
    }

    // MARK: Multi-line continuation

    private mutating func resume(_ continuation: HighlightState.Continuation) {
        switch continuation {
        case .blockComment(let depth):
            let scan = scanBlockComment(from: index, depth: depth)
            emit(.comment, from: index, to: scan.end)
            index = scan.end
            state.continuation = scan.closed ? nil : .blockComment(depth: scan.depth)

        case .string(let opener):
            let scan = scanMultilineString(from: index, opener: opener)
            emit(.string, from: index, to: scan.end)
            index = scan.end
            state.continuation = scan.closed ? nil : .string(opener: opener)
        }
    }

    // MARK: Comments

    private mutating func commentStart(
        at start: Substring.Index,
        character: Character
    ) -> (end: Substring.Index, kind: TokenKind)? {
        switch language {
        case .swift:
            if line[start...].hasPrefix("//") {
                return (line.endIndex, .comment)
            }
            if line[start...].hasPrefix("/*") {
                let bodyStart = line.index(start, offsetBy: 2)
                let scan = scanBlockComment(from: bodyStart, depth: 1)
                state.continuation = scan.closed ? nil : .blockComment(depth: scan.depth)
                return (scan.end, .comment)
            }
            return nil

        case .python, .shell:
            guard character == "#" else { return nil }
            let atLineStart = start == line.startIndex
            let precededBySpace = start > line.startIndex && line[line.index(before: start)].isWhitespace
            guard atLineStart || precededBySpace else { return nil }
            return (line.endIndex, .comment)

        case .json:
            return nil
        }
    }

    private func scanBlockComment(from start: Substring.Index, depth initial: Int) -> (end: Substring.Index, closed: Bool, depth: Int) {
        var depth = initial
        var cursor = start
        while cursor < line.endIndex {
            if line[cursor...].hasPrefix("/*") {
                depth += 1
                cursor = line.index(cursor, offsetBy: 2)
            } else if line[cursor...].hasPrefix("*/") {
                depth -= 1
                cursor = line.index(cursor, offsetBy: 2)
                if depth == 0 { return (cursor, true, 0) }
            } else {
                cursor = line.index(after: cursor)
            }
        }
        return (line.endIndex, false, depth)
    }

    // MARK: Strings

    private mutating func scanString(quote: Character) -> (start: Substring.Index, end: Substring.Index, kind: TokenKind)? {
        let start = index

        // Triple-quoted strings (Swift multiline, Python docstrings).
        if language == .swift || language == .python {
            let triple = String(repeating: quote, count: 3)
            if line[start...].hasPrefix(triple) {
                if language == .swift, quote == "'" { return nil }   // Swift has no ''' strings
                let bodyStart = line.index(start, offsetBy: 3)
                let scan = scanMultilineString(from: bodyStart, opener: triple)
                if !scan.closed {
                    state.continuation = .string(opener: triple)
                }
                return (start, scan.end, .string)
            }
        }

        // Shell backticks are command substitution, not strings.
        if language == .shell, quote == "`" { return nil }

        let escapes = !(language == .shell && quote == "'")
        var cursor = line.index(after: start)
        while cursor < line.endIndex {
            let character = line[cursor]
            if escapes, character == "\\" {
                cursor = line.index(cursor, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                continue
            }
            if character == quote {
                cursor = line.index(after: cursor)
                return (start, cursor, kindForString())
            }
            cursor = line.index(after: cursor)
        }
        // Unterminated: the rest of the line is still a string token.
        return (start, line.endIndex, kindForString())
    }

    private func kindForString() -> TokenKind {
        guard language == .json else { return .string }
        // A JSON string immediately followed by a colon is a key.
        var cursor = index
        if line[cursor...].hasPrefix("\"") {
            var scan = line.index(after: cursor)
            while scan < line.endIndex {
                if line[scan] == "\\" {
                    scan = line.index(scan, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                    continue
                }
                if line[scan] == "\"" { break }
                scan = line.index(after: scan)
            }
            cursor = scan < line.endIndex ? line.index(after: scan) : line.endIndex
        }
        var probe = cursor
        while probe < line.endIndex, line[probe].isWhitespace { probe = line.index(after: probe) }
        return probe < line.endIndex && line[probe] == ":" ? .property : .string
    }

    private func scanMultilineString(from start: Substring.Index, opener: String) -> (end: Substring.Index, closed: Bool) {
        var cursor = start
        while cursor < line.endIndex {
            if line[cursor...].hasPrefix("\\") {
                cursor = line.index(cursor, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                continue
            }
            if line[cursor...].hasPrefix(opener) {
                return (line.index(cursor, offsetBy: opener.count), true)
            }
            cursor = line.index(after: cursor)
        }
        return (line.endIndex, false)
    }

    // MARK: Numbers and identifiers

    private func isNumberStart(_ start: Substring.Index) -> Bool {
        guard start > line.startIndex else { return true }
        let previous = line[line.index(before: start)]
        return !isIdentifierPart(previous)
    }

    private func scanNumber(from start: Substring.Index) -> Substring.Index {
        var cursor = start
        var sawHex = false
        if line[cursor...].hasPrefix("0x") || line[cursor...].hasPrefix("0X") {
            sawHex = true
            cursor = line.index(cursor, offsetBy: 2)
        }
        var sawDot = false
        var sawExponent = false
        while cursor < line.endIndex {
            let character = line[cursor]
            if character.isNumber || character == "_" {
                cursor = line.index(after: cursor)
            } else if sawHex, character.isHexDigit {
                cursor = line.index(after: cursor)
            } else if character == ".", !sawDot, !sawExponent, cursor > start {
                sawDot = true
                cursor = line.index(after: cursor)
            } else if character == "e" || character == "E" {
                guard !sawHex, !sawExponent else { break }
                sawExponent = true
                cursor = line.index(after: cursor)
                if cursor < line.endIndex, line[cursor] == "+" || line[cursor] == "-" {
                    cursor = line.index(after: cursor)
                }
            } else {
                break
            }
        }
        return cursor
    }

    private func scanIdentifier(from start: Substring.Index) -> Substring.Index {
        var cursor = start
        while cursor < line.endIndex, isIdentifierPart(line[cursor]) {
            cursor = line.index(after: cursor)
        }
        return cursor
    }

    private func scanAttribute(from start: Substring.Index) -> Substring.Index {
        var cursor = line.index(after: start)
        while cursor < line.endIndex, isIdentifierPart(line[cursor]) || line[cursor] == "." {
            cursor = line.index(after: cursor)
        }
        return cursor
    }

    private func scanVariable(from start: Substring.Index) -> Substring.Index {
        var cursor = line.index(after: start)
        guard cursor < line.endIndex else { return cursor }
        if line[cursor] == "{" {
            while cursor < line.endIndex, line[cursor] != "}" { cursor = line.index(after: cursor) }
            if cursor < line.endIndex { cursor = line.index(after: cursor) }
            return cursor
        }
        if isIdentifierPart(line[cursor]) {
            while cursor < line.endIndex, isIdentifierPart(line[cursor]) { cursor = line.index(after: cursor) }
            return cursor
        }
        return line.index(after: cursor)      // $?, $1, $$ …
    }

    private func classify(identifier: String) -> TokenKind {
        let followedDot = previousSignificant == "."
        let startsUppercase = identifier.first?.isUppercase == true

        switch language {
        case .swift:
            if Vocabulary.swiftKeywords.contains(identifier) { return .keyword }
            // `SwiftUI.Text` is a type after a dot, `foo.bar` is a property.
            if startsUppercase { return .type }
            if followedDot { return .property }
            return .plain

        case .python:
            if Vocabulary.pythonKeywords.contains(identifier) { return .keyword }
            if Vocabulary.pythonBuiltins.contains(identifier) { return .builtin }
            if followedDot { return .property }
            return .plain

        case .json:
            if identifier == "true" || identifier == "false" || identifier == "null" { return .keyword }
            return .plain

        case .shell:
            if Vocabulary.shellKeywords.contains(identifier) { return .keyword }
            if Vocabulary.shellBuiltins.contains(identifier) { return .builtin }
            if followedDot { return .property }
            return .plain
        }
    }

    // MARK: Emission

    private func isPunctuation(_ character: Character) -> Bool {
        switch character {
        case "(", ")", "{", "}", "[", "]", ",", ";", ":", ".", "+", "-", "*", "/", "%",
             "=", "<", ">", "!", "&", "|", "^", "~", "?", "\\":
            return true
        default:
            return false
        }
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isIdentifierPart(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private mutating func advance() {
        previousSignificant = line[index]
        index = line.index(after: index)
    }

    private mutating func emit(_ kind: TokenKind, from start: Substring.Index, to end: Substring.Index) {
        guard start < end else { return }
        if lastEnd < start {
            append(.plain, from: lastEnd, to: start)
        }
        append(kind, from: start, to: end)
        lastEnd = end
    }

    private mutating func append(_ kind: TokenKind, from start: Substring.Index, to end: Substring.Index) {
        guard start < end else { return }
        if var last = runs.last, last.kind == kind, last.range.upperBound == start {
            last.range = last.range.lowerBound..<end
            runs[runs.count - 1] = last
        } else {
            runs.append(HighlightedRun(kind: kind, range: start..<end))
        }
    }
}

// MARK: - Vocabulary

private enum Vocabulary {
    static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case",
        "catch", "class", "continue", "convenience", "default", "defer", "deinit",
        "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
        "final", "for", "func", "guard", "if", "import", "in", "indirect", "init",
        "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated",
        "open", "operator", "optional", "override", "private", "protocol", "public",
        "repeat", "required", "rethrows", "return", "self", "Self", "some", "static",
        "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
        "typealias", "unowned", "var", "weak", "where", "while",
    ]

    static let pythonKeywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break",
        "class", "continue", "def", "del", "elif", "else", "except", "finally",
        "for", "from", "global", "if", "import", "in", "is", "lambda", "match",
        "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with",
        "yield", "self",
    ]

    static let pythonBuiltins: Set<String> = [
        "abs", "all", "any", "bool", "bytes", "callable", "dict", "dir", "enumerate",
        "Exception", "float", "format", "frozenset", "getattr", "hasattr", "id",
        "input", "int", "isinstance", "issubclass", "iter", "len", "list", "map",
        "max", "min", "next", "object", "open", "ord", "print", "range", "repr",
        "reversed", "round", "set", "setattr", "sorted", "str", "sum", "super",
        "tuple", "type", "ValueError", "TypeError", "KeyError", "zip",
    ]

    static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
        "until", "case", "esac", "function", "select", "time", "coproc",
    ]

    static let shellBuiltins: Set<String> = [
        "alias", "bg", "break", "cd", "command", "continue", "echo", "eval", "exec",
        "exit", "export", "false", "fg", "getopts", "hash", "jobs", "kill", "local",
        "printf", "pwd", "read", "readonly", "return", "set", "shift", "source",
        "sudo", "test", "trap", "true", "type", "umask", "unalias", "unset", "wait",
        "which", "xargs",
    ]
}
