import SwiftUI

/// The body of a tool card: the text the tool produced, laid out so it can be read.
///
/// A `read_file` result arrives as `12|text` lines. Rendered inline that prefix sits in the middle
/// of the prose, and every wrapped continuation line starts flush with the number — so a long
/// comment looks like it belongs to the line above it. Recognising the shape lets the number move
/// into a gutter of its own, right-aligned, where it stops competing with the text.
public struct ToolBodyView: View {
    public var text: String
    public var font: Font
    public var color: Color
    public var gutterColor: Color

    public init(text: String, font: Font, color: Color, gutterColor: Color) {
        self.text = text
        self.font = font
        self.color = color
        self.gutterColor = gutterColor
    }

    /// The cap exists because a 20 000-line file in one card is worse than the same file scrolled in
    /// a sheet: past this the plain text renderer takes over and the card stays usable.
    private static let maxNumberedLines = 400

    public var body: some View {
        if let numbered {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(numbered, id: \.line) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.line == 0 ? "" : "\(entry.line)")
                            .font(font)
                            .monospacedDigit()
                            .foregroundStyle(gutterColor)
                            .frame(minWidth: 26, alignment: .trailing)
                        Text(entry.text.isEmpty ? " " : entry.text)
                            .font(font)
                            .foregroundStyle(color)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `["1|import AppKit", "2|", …]` → numbered pairs. Every line has to carry the prefix, otherwise
    /// this is ordinary text that happens to contain a pipe.
    private var numbered: [(line: Int, text: String)]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1, lines.count <= Self.maxNumberedLines else { return nil }
        var entries: [(line: Int, text: String)] = []
        entries.reserveCapacity(lines.count)
        for raw in lines {
            guard let bar = raw.firstIndex(of: "|"), bar != raw.startIndex else { return nil }
            guard let number = Int(raw[raw.startIndex..<bar]), number > 0 else { return nil }
            entries.append((number, String(raw[raw.index(after: bar)...])))
        }
        return entries
    }
}
