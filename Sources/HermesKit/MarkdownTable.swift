import Foundation

/// A GitHub-flavoured markdown table: a header row, a delimiter row that carries
/// the column alignments, and zero or more body rows.
///
/// This type is deliberately *pure data*: no SwiftUI, no attributed strings, no
/// knowledge of how wide a column should be drawn. `IncrementalMarkdown` emits it
/// as a `.table` block and each app shell decides what a grid looks like, which
/// means the iOS phone, the macOS window and the tests all parse pipes the same
/// way.
public struct MarkdownTable: Equatable, Sendable {

    /// Column alignment, taken from the `:` markers of the delimiter row
    /// (`---`, `:--`, `--:`, `:-:`).
    public enum Alignment: String, Equatable, Sendable {
        case none
        case leading
        case center
        case trailing
    }

    public let header: [String]
    public let rows: [[String]]
    public let alignments: [Alignment]

    /// Every row has exactly this many cells; ragged input is padded or
    /// truncated by the parser.
    public var columnCount: Int { header.count }

    public init(header: [String], rows: [[String]], alignments: [Alignment]) {
        precondition(!header.isEmpty, "a table needs at least one column")
        self.header = header
        self.rows = rows.map { MarkdownTable.normalize($0, to: header.count) }
        self.alignments = MarkdownTable.normalize(alignments, to: header.count, filler: .none)
    }

    /// Literal text, one row per line, for copy/paste and accessibility labels.
    public var plainText: String {
        ([header] + rows)
            .map { $0.joined(separator: " | ") }
            .joined(separator: "\n")
    }

    /// Pad with empty cells or drop the overflow, so a row always matches the
    /// header. GitHub renders a short row as blank cells rather than failing.
    static func normalize(_ cells: [String], to count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    static func normalize(_ values: [Alignment], to count: Int, filler: Alignment) -> [Alignment] {
        if values.count == count { return values }
        if values.count > count { return Array(values.prefix(count)) }
        return values + Array(repeating: filler, count: count - values.count)
    }
}

/// The table grammar, in one place.
///
/// Callers hand in the lines of a document and an index; `parse` answers either
/// "these lines are a table, and it consumed N of them" or `nil`, in which case
/// the line stays ordinary prose. Stopping at the first line that is not a table
/// row is what keeps the paragraph *after* a table a paragraph.
public enum MarkdownTableParser {

    /// Parse a table that starts at `index`, if one does.
    ///
    /// A table is a header row, a delimiter row with the same number of cells,
    /// then every following table row. The delimiter row is what distinguishes a
    /// table from a sentence that happens to contain a pipe.
    ///
    /// - Returns: the table and the number of lines it consumed (always ≥ 2).
    public static func parse(lines: [String], startingAt index: Int)
        -> (table: MarkdownTable, consumed: Int)? {

        guard index >= 0, index + 1 < lines.count else { return nil }

        let headerLine = lines[index]
        guard isRowLine(headerLine), let header = splitCells(headerLine), !header.isEmpty else {
            return nil
        }
        guard let alignments = delimiterAlignments(lines[index + 1]),
              alignments.count == header.count else {
            return nil
        }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count, isRowLine(lines[cursor]) {
            if let cells = splitCells(lines[cursor]) {
                rows.append(MarkdownTable.normalize(cells, to: header.count))
            }
            cursor += 1
        }

        return (MarkdownTable(header: header, rows: rows, alignments: alignments),
                cursor - index)
    }

    /// Alignments for a delimiter row such as `| --- | :--: | ---: |`, or `nil`
    /// when the line is not a delimiter row at all.
    public static func delimiterAlignments(_ line: String) -> [MarkdownTable.Alignment]? {
        guard indentationWidth(line) < 4 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let (raw, pipes) = rawCells(trimmed)
        guard pipes > 0 else { return nil }
        let cells = stripOuterPipes(raw, from: trimmed)
        guard !cells.isEmpty else { return nil }

        var result: [MarkdownTable.Alignment] = []
        result.reserveCapacity(cells.count)
        for cell in cells {
            let text = cell.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }

            var body = text
            let leading = body.hasPrefix(":")
            if leading { body.removeFirst() }
            let trailing = body.hasSuffix(":")
            if trailing { body.removeLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }

            switch (leading, trailing) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.leading)
            case (false, true): result.append(.trailing)
            case (false, false): result.append(.none)
            }
        }
        return result
    }

    /// Cell text of one row, or `nil` when the line is not a table row.
    ///
    /// Sources remain inline markdown (`**bold**`, `` `code` ``); only the cell
    /// boundaries and `\|` escapes are interpreted here.
    public static func splitCells(_ line: String) -> [String]? {
        guard indentationWidth(line) < 4 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let (raw, pipes) = rawCells(trimmed)
        guard pipes > 0 else { return nil }

        let cells = stripOuterPipes(raw, from: trimmed)
        // A lone pipe (or a row of nothing but empty cells) is not a table row.
        guard cells.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Whether this line can be part of a table. A lone `|`, an indented line
    /// (four spaces is a code block) and an ordinary sentence without a pipe all
    /// answer `false`.
    public static func isRowLine(_ line: String) -> Bool {
        guard indentationWidth(line) < 4 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix(">"),
              !trimmed.hasPrefix("```"),
              !trimmed.hasPrefix("- "),
              !trimmed.hasPrefix("* "),
              !trimmed.hasPrefix("+ ") else { return false }
        guard !trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) else { return false }
        return splitCells(line) != nil
    }

    /// Whether this line could still grow into a delimiter row.
    ///
    /// Used by the streaming parser: a line of dashes is a rule today and the
    /// delimiter of a table one keystroke later, so the block above it must stay
    /// re-parsable.
    public static func isDelimiterRowPrefix(_ line: String) -> Bool {
        guard indentationWidth(line) < 4 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.contains("|") || trimmed.contains("-") || trimmed.contains(":") else {
            return false
        }
        return trimmed.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " || $0 == "\t" }
    }

    // MARK: Scanning

    /// Split on pipes that are not escaped and not inside a backtick span.
    ///
    /// `pipes` counts the splits performed, which is how `splitCells` tells a
    /// row from a sentence containing one literal (escaped) pipe.
    static func rawCells(_ line: String) -> (cells: [String], pipes: Int) {
        var cells: [String] = []
        var current = ""
        var pipes = 0
        var codeTicks: Int?
        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            // `\|` is a literal pipe in the cell's text, never a boundary.
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                current.append("|")
                index += 2
                continue
            }

            if character == "`" {
                var run = 0
                while index + run < characters.count, characters[index + run] == "`" { run += 1 }
                if codeTicks == nil { codeTicks = run } else if codeTicks == run { codeTicks = nil }
                current += String(repeating: "`", count: run)
                index += run
                continue
            }

            if character == "|", codeTicks == nil {
                cells.append(current)
                current = ""
                pipes += 1
                index += 1
                continue
            }

            current.append(character)
            index += 1
        }

        cells.append(current)
        return (cells, pipes)
    }

    /// Drop the empty cells produced by one optional leading and one optional
    /// trailing pipe.
    static func stripOuterPipes(_ cells: [String], from trimmed: String) -> [String] {
        var cells = cells
        if trimmed.hasPrefix("|"), cells.count > 1 { cells.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|"), cells.count > 1 { cells.removeLast() }
        return cells
    }

    /// Columns of leading whitespace, with a tab counting as four, so an
    /// indented code block is never mistaken for a table.
    static func indentationWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 }
            else if character == "\t" { width += 4 }
            else { break }
            if width >= 4 { break }
        }
        return width
    }
}
