import Foundation

/// Turns a parsed `Block` into the text the chat actually draws.
///
/// One call per block, on the block layer: the bullet, the number, the inline
/// emphasis and — for fenced code — the syntax highlighting all come out of here,
/// so a paragraph looks the same on macOS and iOS and neither app re-implements
/// markdown.
public enum BlockText {

    /// Attributed text for a whole block, markers included.
    ///
    /// - Paragraph, heading, quote, bullet, numbered: inline markdown compiled to
    ///   `AttributedString` (bold/italic/code/strikethrough/link).
    /// - Code: the body, every run tagged `CodeBlockAttribute` (with the fence
    ///   language) and `CodeTokenAttribute` from `SyntaxHighlighter`. Inline-code
    ///   styling is deliberately *not* applied to a whole block.
    /// - Rule: empty (the view draws a hairline; there is no text).
    public static func attributed(for block: Block) -> AttributedString {
        switch block {
        case .paragraph(let text):
            return InlineMarkdown.attributedString(text)

        case .heading(_, let text):
            var heading = InlineMarkdown.attributedString(text)
            // Headings are bold even without `**`, as in OpenBot.
            heading.setAll(BoldAttribute.self, to: true)
            return heading

        case .bullet(let text):
            return prefixed(marker: "• ", text: text)

        case .numbered(let index, let text):
            return prefixed(marker: "\(index). ", text: text)

        case .quote(let text):
            return InlineMarkdown.attributedString(text)

        case .code(let language, let body, _):
            var code = SyntaxHighlighter.attributed(body, languageHint: language)
            // Code blocks are marked as blocks, not as inline spans: the app draws
            // a fence around them, not an inline chip per line.
            code.setAll(CodeBlockAttribute.self, to: language ?? "")
            return code

        case .table(let table):
            // The apps draw a real grid; this is the flat fallback used for
            // accessibility, copying and any caller that only wants text.
            var result = AttributedString()
            for (rowIndex, cells) in ([table.header] + table.rows).enumerated() {
                if rowIndex > 0 { result.append(AttributedString("\n")) }
                for (column, cell) in cells.enumerated() {
                    if column > 0 { result.append(AttributedString("   ")) }
                    var piece = InlineMarkdown.attributedString(cell)
                    if rowIndex == 0 { piece.setAll(BoldAttribute.self, to: true) }
                    result.append(piece)
                }
            }
            return result

        case .rule:
            return AttributedString()
        }
    }

    /// Literal text of a block including its marker, for copy/paste and for
    /// accessibility labels.
    public static func plainText(for block: Block) -> String {
        switch block {
        case .paragraph(let text):
            return InlineMarkdown.plainText(text)
        case .heading(_, let text):
            return InlineMarkdown.plainText(text)
        case .bullet(let text):
            return "• " + InlineMarkdown.plainText(text)
        case .numbered(let index, let text):
            return "\(index). " + InlineMarkdown.plainText(text)
        case .quote(let text):
            return InlineMarkdown.plainText(text)
        case .code(_, let body, _):
            return body
        case .table(let table):
            return table.plainText
        case .rule:
            return ""
        }
    }

    /// The bullet/number prefix the view should draw before the text, if the
    /// marker is laid out separately rather than inline.
    public static func marker(for block: Block) -> String? {
        switch block {
        case .bullet: return "•"
        case .numbered(let index, _): return "\(index)."
        default: return nil
        }
    }

    private static func prefixed(marker: String, text: String) -> AttributedString {
        var result = AttributedString(marker)
        result.append(InlineMarkdown.attributedString(text))
        return result
    }
}
