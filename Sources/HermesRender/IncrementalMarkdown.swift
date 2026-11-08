import Foundation
import HermesKit

/// Incremental markdown for a streaming chat.
///
/// The rule that keeps 120 Hz smooth: never re-parse the whole message on every
/// token. We keep the last parsed prefix and only parse the unfinished tail.
public enum Block: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(String)
    case numbered(index: Int, text: String)
    case code(language: String?, body: String, closed: Bool)
    case quote(String)
    case rule
    /// A GitHub-style pipe table, already split into cells by `MarkdownTableParser`.
    case table(MarkdownTable)
}

public extension Block {
    /// Prose the reader may want to select: everything that is plain sentences and
    /// list items. Code, tables and rules are drawn as their own views, and a quote
    /// keeps its accent bar, so all three stay out of a selectable prose run.
    var isProse: Bool {
        switch self {
        case .paragraph, .heading, .bullet, .numbered: return true
        case .code, .table, .quote, .rule: return false
        }
    }
}

public struct IncrementalMarkdown: Sendable {
    public private(set) var source: String = ""
    public private(set) var blocks: [Block] = []

    /// Blocks that can never change again while streaming.
    private var stableBlocks: [Block] = []
    /// UTF-8 offset where the last block (the only re-parsable one) starts.
    private var tailOffset: Int?

    /// How many characters have been re-parsed so far. Diagnostics for the
    /// performance rule: appending one token should add the length of the last
    /// block, not the length of the transcript.
    public private(set) var reparsedCharacterCount: Int = 0

    public init() {}

    /// Append a streamed delta and return only the blocks that changed.
    /// Block identity is by index, so the UI can diff cheaply.
    ///
    /// Normally only the final block is re-parsed: a delta can extend the block it
    /// lands in, or start new ones after it. A table is the exception — the
    /// paragraph after it can still turn into one of its rows — so the live region
    /// is whatever `parseDetail` says it is, and everything before that is stable.
    @discardableResult
    public mutating func append(_ delta: String) -> [Int] {
        guard !delta.isEmpty else { return [] }
        source += delta

        let start = stringIndex(atUTF8: tailOffset ?? 0)
        let tail = source[start...]
        let parsed = IncrementalMarkdown.parseDetail(String(tail))
        reparsedCharacterCount += tail.count

        let newBlocks = stableBlocks + parsed.blocks
        var changed: [Int] = []
        changed.reserveCapacity(1)
        for index in newBlocks.indices where index >= blocks.count || blocks[index] != newBlocks[index] {
            changed.append(index)
        }
        blocks = newBlocks

        if parsed.blocks.isEmpty {
            stableBlocks = newBlocks
            tailOffset = nil
        } else {
            stableBlocks.append(contentsOf: parsed.blocks.prefix(parsed.stableBlockCount))
            tailOffset = (tailOffset ?? 0) + parsed.liveStart
        }
        return changed
    }

    public static func parse(_ text: String) -> [Block] {
        parseDetail(text).blocks
    }

    /// Parse a whole text and report the region `append` has to look at again:
    /// the UTF-8 offset where it starts and how many leading blocks are final.
    ///
    /// Everything after `stableBlockCount` is live. That is usually just the last
    /// block, but a paragraph directly under a table may still become a row of it,
    /// so the table is kept live too.
    static func parseDetail(_ text: String)
        -> (blocks: [Block], liveStart: Int, stableBlockCount: Int) {
        let lines = splitLines(text)
        let rawLines = lines.map { $0.text }
        var blocks: [Block] = []
        var blockStarts: [Int] = []
        var paragraph: [String] = []
        var paragraphStart = 0

        func append(_ block: Block, at offset: Int) {
            blocks.append(block)
            blockStarts.append(offset)
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            append(.paragraph(paragraph.joined(separator: "\n")), at: paragraphStart)
            paragraph.removeAll()
        }

        func beginParagraph(at lineOffset: Int) {
            if paragraph.isEmpty { paragraphStart = lineOffset }
        }

        var index = 0
        while index < lines.count {
            let lineOffset = lines[index].offset
            var line = lines[index].text
            index += 1

            // Fenced code: everything until the closing fence, or to the end while it
            // is still streaming (that is why `closed` exists).
            if line.hasPrefix("```") {
                flushParagraph()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body = ""
                var closed = false
                while index < lines.count {
                    let inner = lines[index].text
                    index += 1
                    if inner.hasPrefix("```") { closed = true; break }
                    body += (body.isEmpty ? "" : "\n") + inner
                }
                append(.code(language: language.isEmpty ? nil : language, body: body, closed: closed),
                       at: lineOffset)
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }

            // A table is decided by the delimiter row under the header, so the check
            // has to run before the line is folded into a paragraph.
            if let (table, consumed) = MarkdownTableParser.parse(lines: rawLines, startingAt: index - 1) {
                flushParagraph()
                append(.table(table), at: lineOffset)
                index += consumed - 1
                continue
            }

            if line.hasPrefix("#") {
                flushParagraph()
                let level = line.prefix(while: { $0 == "#" }).count
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                append(.heading(level: min(level, 6), text: title), at: lineOffset)
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                append(.quote(String(line.dropFirst(2))), at: lineOffset)
                continue
            }

            if line == "---" || line == "***" {
                flushParagraph()
                append(.rule, at: lineOffset)
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                append(.bullet(String(line.dropFirst(2))), at: lineOffset)
                continue
            }

            if let numbered = IncrementalMarkdown.numberedLine(line) {
                flushParagraph()
                append(.numbered(index: numbered.0, text: numbered.1), at: lineOffset)
                continue
            }

            line = line.trimmingCharacters(in: .whitespaces)
            beginParagraph(at: lineOffset)
            paragraph.append(line)
        }
        flushParagraph()

        var liveIndex = max(blocks.count - 1, 0)
        if blocks.count >= 2,
           case .table = blocks[blocks.count - 2],
           case .paragraph = blocks[blocks.count - 1] {
            // The line under a table is not prose yet: without outer pipes, the
            // next token can still turn it into a row of that table.
            liveIndex -= 1
        }
        if liveIndex > 0, let lastLine = rawLines.last,
           MarkdownTableParser.isDelimiterRowPrefix(lastLine) {
            // A line of dashes is a rule now and a table's delimiter row one
            // keystroke later; without the line above it, that can never re-parse.
            liveIndex -= 1
        }
        return (blocks,
                blockStarts.indices.contains(liveIndex) ? blockStarts[liveIndex] : 0,
                liveIndex)
    }

    /// Lines with the UTF-8 offset of each line's first byte, which is what
    /// `append` uses to restart parsing at a block boundary.
    static func splitLines(_ text: String) -> [(text: String, offset: Int)] {
        var lines: [(text: String, offset: Int)] = []
        var offset = 0
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[start..<end])
            lines.append((line, offset))
            offset += line.utf8.count + (end == text.endIndex ? 0 : 1)
            start = end == text.endIndex ? text.endIndex : text.index(after: end)
        }
        return lines
    }

    static func numberedLine(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    private func stringIndex(atUTF8 offset: Int) -> String.Index {
        let clamped = min(max(offset, 0), source.utf8.count)
        let utf8Index = source.utf8.index(source.utf8.startIndex, offsetBy: clamped)
        return String.Index(utf8Index, within: source) ?? source.endIndex
    }
}
