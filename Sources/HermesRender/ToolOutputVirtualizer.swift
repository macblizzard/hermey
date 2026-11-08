import Foundation

/// A tool result: one string, indexed by lines.
///
/// `100k+` lines is normal (`grep -R`, `cargo build`, a log tail), so this type
/// never turns the text into an array of strings. It keeps the original `String`
/// and an array of UTF-8 line offsets, and slices a line only when a view asks for
/// it. Appending a streaming chunk only scans the new bytes.
public struct ToolOutput: Sendable {
    public private(set) var text: String
    /// UTF-8 offset at which each line starts. Never includes the empty "line"
    /// after a trailing newline, matching editors and terminals.
    private var lineStarts: [Int] = []
    private var byteCount: Int = 0

    public init(_ text: String = "") {
        self.text = text
        rebuild()
    }

    public var lineCount: Int { lineStarts.count }
    public var isEmpty: Bool { text.isEmpty }
    public var utf8ByteCount: Int { byteCount }

    /// Append streamed output. Only the new bytes are scanned for newlines.
    public mutating func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        let previousCount = byteCount
        let startedEmpty = text.isEmpty
        let endedWithNewline = previousCount > 0 && text.utf8.last == 0x0A

        text += delta
        byteCount = previousCount + delta.utf8.count

        if startedEmpty {
            lineStarts = [0]
        } else if endedWithNewline {
            lineStarts.append(previousCount)
        }

        var offset = previousCount
        for byte in delta.utf8 {
            offset += 1
            if byte == 0x0A, offset < byteCount {
                lineStarts.append(offset)
            }
        }
    }

    /// The line at `index`, without its trailing newline (and without `\r` on
    /// CRLF output).
    public func line(at index: Int) -> Substring? {
        guard lineStarts.indices.contains(index) else { return nil }
        let startOffset = lineStarts[index]
        let nextOffset = index + 1 < lineStarts.count ? lineStarts[index + 1] : byteCount
        guard startOffset <= nextOffset else { return nil }
        // Take the whole span up to the next line start and trim the terminator
        // from the *character* side: `\r\n` is a single grapheme, so slicing at
        // `nextOffset - 1` would land inside a Character.
        var slice = text[stringIndex(atUTF8: startOffset)..<stringIndex(atUTF8: nextOffset)]
        while let last = slice.last, last == "\n" || last == "\r" || last == "\r\n" {
            slice = slice.dropLast()
        }
        return slice
    }

    public func lineText(at index: Int) -> String? {
        line(at: index).map(String.init)
    }

    private func stringIndex(atUTF8 offset: Int) -> String.Index {
        let clamped = min(max(offset, 0), byteCount)
        let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: clamped)
        return String.Index(utf8Index, within: text) ?? text.endIndex
    }

    private mutating func rebuild() {
        lineStarts = []
        guard !text.isEmpty else {
            byteCount = 0
            return
        }
        byteCount = text.utf8.count
        lineStarts.append(0)
        var offset = 0
        for byte in text.utf8 {
            offset += 1
            if byte == 0x0A, offset < byteCount {
                lineStarts.append(offset)
            }
        }
    }
}

/// One row the tool-output view draws.
public enum ToolOutputRow: Equatable, Sendable {
    /// A real line. `number` is 1-based; `truncated` means the line was longer
    /// than the configured cap and only a prefix is shown.
    case line(number: Int, text: String, truncated: Bool)
    /// "N lines hidden" between the visible window and the rest of the output.
    case truncation(hiddenLines: Int)
}

/// What the view should render right now.
public struct ToolOutputWindow: Equatable, Sendable {
    public var rows: [ToolOutputRow]
    /// The line range the rows cover, clamped to the output.
    public var lines: Range<Int>
    /// The range the caller asked for, clamped to the output.
    public var visibleLines: Range<Int>
    public var totalLines: Int

    public var hasMoreAbove: Bool { lines.lowerBound > 0 }
    public var hasMoreBelow: Bool { lines.upperBound < totalLines }

    public init(
        rows: [ToolOutputRow],
        lines: Range<Int>,
        visibleLines: Range<Int>,
        totalLines: Int
    ) {
        self.rows = rows
        self.lines = lines
        self.visibleLines = visibleLines
        self.totalLines = totalLines
    }
}

/// Windows a `ToolOutput` down to the lines a view is looking at.
///
/// A chat scroll view asks for the visible line range; this returns those lines
/// plus overscan and a truncation marker wherever lines were elided. Nothing else
/// is materialised, so opening a 100k-line build log costs what thirty lines cost.
public struct ToolOutputVirtualizer: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Lines a window shows by default when the caller does not pass a range.
        public var visibleLines: Int
        /// Lines rendered above and below the asked-for range.
        public var overscan: Int
        /// A single line longer than this (in characters) is cut, with `truncated`
        /// set, so one 2 MB minified JSON line cannot stall layout.
        public var maxLineLength: Int
        /// Hard ceiling on rows per window, whatever the caller asks for.
        public var maxWindowRows: Int

        public init(
            visibleLines: Int = 200,
            overscan: Int = 40,
            maxLineLength: Int = 2_000,
            maxWindowRows: Int = 4_000
        ) {
            self.visibleLines = max(1, visibleLines)
            self.overscan = max(0, overscan)
            self.maxLineLength = max(16, maxLineLength)
            self.maxWindowRows = max(1, maxWindowRows)
        }

        public static let `default` = Configuration()
    }

    public private(set) var output: ToolOutput
    public var configuration: Configuration

    public init(text: String = "", configuration: Configuration = .default) {
        self.output = ToolOutput(text)
        self.configuration = configuration
    }

    public var lineCount: Int { output.lineCount }

    public mutating func append(_ delta: String) {
        output.append(delta)
    }

    // MARK: Windows

    /// Rows for the visible range, widened by overscan and trimmed to the output.
    public func window(around visible: Range<Int>) -> ToolOutputWindow {
        let total = output.lineCount
        guard total > 0 else {
            return ToolOutputWindow(rows: [], lines: 0..<0, visibleLines: 0..<0, totalLines: 0)
        }

        let clampedVisible = clamp(visible, to: total)
        guard !clampedVisible.isEmpty else {
            return ToolOutputWindow(rows: [], lines: clampedVisible, visibleLines: clampedVisible, totalLines: total)
        }
        let lower = max(0, clampedVisible.lowerBound - configuration.overscan)
        var upper = min(total, clampedVisible.upperBound + configuration.overscan)
        if upper - lower > configuration.maxWindowRows {
            upper = lower + configuration.maxWindowRows
        }

        let rows = rows(in: lower..<upper)
        return ToolOutputWindow(
            rows: rows,
            lines: lower..<upper,
            visibleLines: clampedVisible,
            totalLines: total
        )
    }

    /// The window a streaming tool should show: the last `visibleLines` lines.
    public func tailWindow() -> ToolOutputWindow {
        let total = output.lineCount
        let count = min(configuration.visibleLines, total)
        return window(around: (total - count)..<total)
    }

    /// Rows for an explicit line range, markers included.
    public func rows(in range: Range<Int>) -> [ToolOutputRow] {
        let total = output.lineCount
        guard total > 0 else { return [] }
        let clamped = clamp(range, to: total)
        var rows: [ToolOutputRow] = []
        rows.reserveCapacity(clamped.count + 2)

        if clamped.lowerBound > 0 {
            rows.append(.truncation(hiddenLines: clamped.lowerBound))
        }
        for index in clamped {
            guard let text = output.lineText(at: index) else { continue }
            if text.count > configuration.maxLineLength {
                rows.append(.line(
                    number: index + 1,
                    text: String(text.prefix(configuration.maxLineLength)),
                    truncated: true
                ))
            } else {
                rows.append(.line(number: index + 1, text: text, truncated: false))
            }
        }
        if clamped.upperBound < total {
            rows.append(.truncation(hiddenLines: total - clamped.upperBound))
        }
        return rows
    }

    private func clamp(_ range: Range<Int>, to total: Int) -> Range<Int> {
        let lower = min(max(range.lowerBound, 0), total)
        let upper = min(max(range.upperBound, lower), total)
        return lower..<upper
    }
}
