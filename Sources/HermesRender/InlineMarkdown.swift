import Foundation

/// The inline emphasis a run carries.
public enum InlineStyle: String, CaseIterable, Hashable, Sendable {
    case strong
    case emphasis
    case code
    case strikethrough
}

/// One run of inline markdown after parsing: the literal text plus what applies
/// to it. Spans are merged, so adjacent text with identical styling is one span.
public struct InlineSpan: Equatable, Sendable {
    public var text: String
    public var styles: Set<InlineStyle>
    public var link: URL?

    public init(_ text: String, styles: Set<InlineStyle> = [], link: URL? = nil) {
        self.text = text
        self.styles = styles
        self.link = link
    }

}

/// Inline markdown for chat text: `**bold**`, `*italic*`, `` `code` ``,
/// `[label](url)`, `~~struck~~`, `<https://autolink>`.
///
/// Deliberately not a CommonMark implementation. It handles what a model actually
/// emits in a chat reply, never throws, and treats anything it cannot close as
/// literal text — a half-streamed `**` must render as `**` for a moment, not eat
/// the rest of the paragraph.
///
/// This is the *inline* layer only; blocks come from `IncrementalMarkdown`.
public enum InlineMarkdown {

    // MARK: Spans

    /// Parse inline markdown into styled spans. Concatenating `text` of the result
    /// gives back the input with delimiters and escapes removed.
    public static func spans(_ text: String) -> [InlineSpan] {
        guard !text.isEmpty else { return [] }
        var parser = InlineParser(Array(text))
        parser.parse(styles: [], link: nil, end: parser.characters.count)
        return parser.finish()
    }

    /// The literal text of an inline markdown string (delimiters removed).
    public static func plainText(_ text: String) -> String {
        spans(text).map(\.text).joined()
    }

    // MARK: AttributedString

    /// Compile inline markdown to an `AttributedString` carrying `BoldAttribute`,
    /// `ItalicAttribute`, `InlineCodeAttribute`, `StrikethroughAttribute` and the
    /// standard Foundation `link`.
    ///
    /// Called per block *after* the block layer has decided what changed; it never
    /// walks the whole message.
    public static func attributedString(_ text: String) -> AttributedString {
        var result = AttributedString()
        for span in linkified(spans(text)) {
            guard !span.text.isEmpty else { continue }
            var piece = AttributedString(span.text)
            var container = AttributeContainer.inlineTraits(span.styles)
            if let link = span.link { container.link = link }
            piece.mergeAttributes(container)
            result.append(piece)
        }
        return result
    }
}

// MARK: - Bare URLs

extension InlineMarkdown {
    /// A URL written as plain text is still a link.
    ///
    /// The download addresses the app hands out arrive as bare `https://…` in ordinary prose, and a
    /// markdown-only parser left them as characters — underlined on nobody's screen and clickable
    /// on nobody's click. Detection lives here so every renderer on every platform inherits it.
    /// Code is skipped: a URL inside a code span is text *about* a URL.
    static func linkified(_ spans: [InlineSpan]) -> [InlineSpan] {
        spans.flatMap { span -> [InlineSpan] in
            guard span.link == nil, !span.styles.contains(.code) else { return [span] }
            let text = span.text as NSString
            let matches = bareURLRegex.matches(in: text as String,
                                               range: NSRange(location: 0, length: text.length))
            guard !matches.isEmpty else { return [span] }
            var out: [InlineSpan] = []
            var cursor = 0
            for match in matches {
                let range = trimmed(range: match.range, in: text)
                guard range.length > 0 else { continue }
                if range.location > cursor {
                    out.append(InlineSpan(text.substring(with: NSRange(location: cursor,
                                                                      length: range.location - cursor)),
                                          styles: span.styles))
                }
                let literal = text.substring(with: range)
                out.append(InlineSpan(literal, styles: span.styles, link: URL(string: literal)))
                cursor = range.location + range.length
            }
            if cursor < text.length {
                out.append(InlineSpan(text.substring(from: cursor), styles: span.styles))
            }
            return out.isEmpty ? [span] : out
        }
    }

    /// `https?://` followed by everything that is not whitespace or a delimiter — deliberately
    /// permissive, because the host prints its own addresses and a stricter pattern would drop the
    /// port, the query or the trailing path.
    private static let bareURLRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s<>\"`\u201c\u201d]+"#, options: [.caseInsensitive])

    /// Give sentence punctuation that cannot belong to a URL back to the prose: a full stop, a
    /// comma, or a closing bracket whose opener is not inside the URL.
    private static func trimmed(range: NSRange, in text: NSString) -> NSRange {
        var result = range
        func lastCharacter() -> Character? {
            guard result.length > 0 else { return nil }
            let value = text.substring(with: NSRange(location: result.location + result.length - 1, length: 1))
            return value.first
        }
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\u{2026}"]
        while let character = lastCharacter() {
            if trailing.contains(character) {
                result.length -= 1
                continue
            }
            if character == ")" || character == "]" || character == "}" {
                let body = text.substring(with: result)
                let open: Character = character == ")" ? "(" : (character == "]" ? "[" : "{")
                if body.filter({ $0 == open }).count < body.filter({ $0 == character }).count {
                    result.length -= 1
                    continue
                }
            }
            break
        }
        return result
    }
}

// MARK: - Parser

private struct Delimiter: Equatable {
    var character: Character
    var length: Int
}

private struct InlineParser {
    let characters: [Character]
    var index = 0
    var spans: [InlineSpan] = []
    var buffer = ""

    init(_ characters: [Character]) {
        self.characters = characters
    }

    mutating func parse(styles: Set<InlineStyle>, link: URL?, end: Int) {
        while index < end {
            switch characters[index] {
            case "\\":
                if index + 1 < end, characters[index + 1].isASCIIPunctuation {
                    buffer.append(characters[index + 1])
                    index += 2
                } else {
                    buffer.append(characters[index])
                    index += 1
                }

            case "`":
                codeSpan(styles: styles, link: link, end: end)

            case "[":
                linkSpan(styles: styles, link: link, end: end)

            case "<":
                autolink(styles: styles, link: link, end: end)

            case "*", "_", "~":
                emphasis(styles: styles, link: link, end: end, character: characters[index])

            default:
                buffer.append(characters[index])
                index += 1
            }
        }
        flush(styles: styles, link: link)
    }

    mutating func finish() -> [InlineSpan] {
        flush(styles: [], link: nil)
        var merged: [InlineSpan] = []
        for span in spans where !span.text.isEmpty {
            if var last = merged.last, last.styles == span.styles, last.link == span.link {
                last.text += span.text
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private mutating func flush(styles: Set<InlineStyle>, link: URL?) {
        guard !buffer.isEmpty else { return }
        spans.append(InlineSpan(buffer, styles: styles, link: link))
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: Code

    private mutating func codeSpan(styles: Set<InlineStyle>, link: URL?, end: Int) {
        let open = index
        var run = 0
        while open + run < end, characters[open + run] == "`" { run += 1 }

        var cursor = open + run
        while cursor < end {
            guard characters[cursor] == "`" else {
                cursor += 1
                continue
            }
            var closeRun = 0
            while cursor + closeRun < end, characters[cursor + closeRun] == "`" { closeRun += 1 }
            if closeRun == run {
                var body = String(characters[(open + run)..<cursor])
                // CommonMark strips one space from each side when both are present.
                if body.count > 2, body.hasPrefix(" "), body.hasSuffix(" ") {
                    body = String(body.dropFirst().dropLast())
                }
                flush(styles: styles, link: link)
                if !body.isEmpty {
                    spans.append(InlineSpan(body, styles: styles.union([.code]), link: link))
                }
                index = cursor + closeRun
                return
            }
            cursor += closeRun
        }
        // Unclosed backtick: literal, so a streaming `` ` `` does not swallow text.
        buffer.append(contentsOf: String(characters[open..<(open + run)]))
        index = open + run
    }

    // MARK: Links

    private mutating func linkSpan(styles: Set<InlineStyle>, link: URL?, end: Int) {
        var depth = 0
        var cursor = index
        var labelEnd: Int?
        while cursor < end {
            if characters[cursor] == "[" { depth += 1 }
            if characters[cursor] == "]" {
                depth -= 1
                if depth == 0 { labelEnd = cursor; break }
            }
            cursor += 1
        }
        guard let labelEnd, labelEnd + 1 < end, characters[labelEnd + 1] == "(" else {
            buffer.append("[")
            index += 1
            return
        }

        // Balanced parentheses are legal in URLs (Wikipedia links); count them.
        var urlEnd: Int?
        var parenDepth = 0
        var scan = labelEnd + 2
        while scan < end {
            let character = characters[scan]
            if character == "(" { parenDepth += 1 }
            if character == ")" {
                if parenDepth == 0 { urlEnd = scan; break }
                parenDepth -= 1
            }
            scan += 1
        }
        guard let urlEnd else {
            buffer.append("[")
            index += 1
            return
        }

        let rawURL = String(characters[(labelEnd + 2)..<urlEnd])
            .trimmingCharacters(in: .whitespaces)
        guard !rawURL.isEmpty,
              !rawURL.contains(where: \.isWhitespace),
              let url = URL(string: rawURL) else {
            buffer.append("[")
            index += 1
            return
        }

        flush(styles: styles, link: link)
        let labelStart = index + 1
        index = labelStart
        parse(styles: styles, link: url, end: labelEnd)
        flush(styles: styles, link: url)
        index = urlEnd + 1
    }

    private mutating func autolink(styles: Set<InlineStyle>, link: URL?, end: Int) {
        var cursor = index + 1
        while cursor < end, characters[cursor] != ">" { cursor += 1 }
        guard cursor < end else {
            buffer.append("<")
            index += 1
            return
        }
        let inner = String(characters[(index + 1)..<cursor])
        guard let url = URL(string: inner),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            buffer.append("<")
            index += 1
            return
        }
        flush(styles: styles, link: link)
        spans.append(InlineSpan(inner, styles: styles, link: url))
        index = cursor + 1
    }

    // MARK: Emphasis

    private mutating func emphasis(styles: Set<InlineStyle>, link: URL?, end: Int, character: Character) {
        let open = index
        var run = 0
        while open + run < end, characters[open + run] == character { run += 1 }

        let isTilde = character == "~"
        let length = min(run, isTilde ? 2 : 3)

        guard length >= (isTilde ? 2 : 1) else {
            buffer.append(character)
            index += 1
            return
        }

        let bodyStart = open + length
        // A delimiter needs text on its inside: `* text*` is not emphasis.
        guard bodyStart < end, !characters[bodyStart].isWhitespace else {
            appendLiteral(count: run)
            return
        }
        if character == "_", open > 0 {
            let previous = characters[open - 1]
            // Intra-word underscores are snake_case, not emphasis.
            if previous.isLetter || previous.isNumber {
                appendLiteral(count: run)
                return
            }
        }

        guard let close = findClosing(
            character: character, length: length, from: bodyStart, end: end
        ) else {
            appendLiteral(count: run)
            return
        }

        flush(styles: styles, link: link)
        var inner = styles
        if isTilde {
            inner.insert(.strikethrough)
        } else if length == 3 {
            inner.insert(.strong)
            inner.insert(.emphasis)
        } else if length == 2 {
            inner.insert(.strong)
        } else {
            inner.insert(.emphasis)
        }

        index = bodyStart
        parse(styles: inner, link: link, end: close)
        flush(styles: inner, link: link)
        index = close + length
    }

    private func findClosing(character: Character, length: Int, from: Int, end: Int) -> Int? {
        var cursor = from
        while cursor < end {
            guard characters[cursor] == character else {
                cursor += 1
                continue
            }
            var run = 0
            while cursor + run < end, characters[cursor + run] == character { run += 1 }

            let precededBySpace = cursor == 0 || characters[cursor - 1].isWhitespace
            if run >= length, !precededBySpace {
                if character == "_", cursor + length < characters.count,
                   characters[cursor + length].isLetter || characters[cursor + length].isNumber {
                    cursor += run
                    continue
                }
                return cursor
            }
            cursor += run
        }
        return nil
    }

    private mutating func appendLiteral(count: Int) {
        buffer.append(contentsOf: String(characters[index..<(index + count)]))
        index += count
    }
}

// MARK: - Character helpers

private extension Character {
    static let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    var isASCIIPunctuation: Bool { Character.asciiPunctuation.contains(self) }
}
