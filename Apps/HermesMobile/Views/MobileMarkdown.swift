import SwiftUI
import HermesKit
import HermesRender
import OpenBotUI

/// Markdown, drawn the way OpenBot draws a message: 16 pt on a 22 pt line, code in
/// the mono face on the inset surface, tables as a real grid.
///
/// The block list comes from `HermesRender` (the block layer decides what is a
/// paragraph, a fence, a table or a rule); this file is only the mapping from a
/// `Block` to pixels. Prose runs are drawn by `MobileSelectableText` — a
/// `UITextView` — because only UIKit gives a draggable selection on iOS; code,
/// tables, quotes and rules stay SwiftUI views.
/// A raw message body drawn as markdown: for screens that hold a string rather than a
/// `TranscriptEntry` — a room's transcript, where the message came from the host's room log.
func markdownMessage(_ text: String) -> AnyView {
    AnyView(MobileMarkdownText(blocks: IncrementalMarkdown.parse(text)))
}

struct MobileMarkdownText: View {
    let blocks: [Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.runs(of: blocks).enumerated()), id: \.offset) { _, run in
                switch run {
                case .prose(let prose):
                    // One text view per run of consecutive prose: selection can cross
                    // paragraph and list boundaries inside it, which is what a reader
                    // dragging over a reply expects.
                    MobileSelectableText(attributed: MobileProse.attributed(for: prose))
                case .block(let block):
                    MobileMarkdownBlock(block: block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A message is drawn as alternating runs: prose (one selectable text view) and
    /// the blocks that are widgets (code, tables, quotes, rules).
    enum MarkdownRun: Equatable {
        case prose([Block])
        case block(Block)
    }

    static func runs(of blocks: [Block]) -> [MarkdownRun] {
        var runs: [MarkdownRun] = []
        var prose: [Block] = []

        func flushProse() {
            guard !prose.isEmpty else { return }
            runs.append(.prose(prose))
            prose.removeAll()
        }

        for block in blocks {
            if block.isProse {
                prose.append(block)
            } else {
                flushProse()
                runs.append(.block(block))
            }
        }
        flushProse()
        return runs
    }
}

/// The fallback for a single block: used for code, tables, quotes and rules, and by
/// callers that hand over one block directly. Prose normally arrives through a
/// `MobileSelectableText` run instead (see `MobileMarkdownText`).
private struct MobileMarkdownBlock: View {
    let block: Block

    private var bodySize: CGFloat { TypeScale.chatBody }

    var body: some View {
        switch block {
        case .paragraph(let text):
            inline(text)
                .lineSpacing(TypeScale.chatLineSpacing)

        case .heading(let level, let text):
            inline(text,
                   weight: .semibold,
                   size: bodySize + (level <= 1 ? 3 : 1),
                   color: Tokens.textPrimary)
                .lineSpacing(TypeScale.chatLineSpacing)
                .padding(.top, 2)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(TypeScale.font(bodySize))
                    .foregroundColor(Tokens.textDim)
                inline(text)
                    .lineSpacing(TypeScale.chatLineSpacing)
            }

        case .numbered(let index, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index).")
                    .font(TypeScale.font(bodySize))
                    .foregroundColor(Tokens.textDim)
                inline(text)
                    .lineSpacing(TypeScale.chatLineSpacing)
            }

        case .code(let language, let body, _):
            codeBlock(language: language, body: body)

        case .table(let table):
            MobileMarkdownTable(table: table)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Tokens.borderFocus)
                    .frame(width: 2)
                inline(text, color: Tokens.textMuted)
                    .italic()
                    .lineSpacing(TypeScale.chatLineSpacing)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Hairline(color: Tokens.borderGrouped)
                .padding(.vertical, 2)
        }
    }

    // MARK: Inline

    private func inline(_ source: String,
                        weight: Font.Weight = .regular,
                        size: CGFloat? = nil,
                        color: Color = Tokens.textSecondary) -> Text {
        mobileInlineText(source, size: size ?? bodySize, weight: weight, color: color)
    }

    // MARK: Code

    /// A code block wears its own copy button, the way the desktop's does.
    ///
    /// The phone used to draw the floating card and nothing else, so the only way to take a command
    /// off the screen was to select it with a long press and drag the handles. The header row is the
    /// desktop's: the language on the left, the verb on the right.
    private func codeBlock(language: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "code")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)

                Spacer(minLength: 4)

                CodeCopyButton(code: body)
                    // A glyph in a card corner is a small target on a phone; the button's own 24 × 22
                    // sits inside this, and the padding is what makes it reachable with a thumb.
                    .padding(.vertical, 4)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(body.isEmpty ? " " : body)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .fill(Tokens.sheetInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 1)
        )
    }
}

// MARK: - Inline runs

/// Inline markdown as concatenated `Text` runs, the one builder the message body
/// and its tables share so a cell is styled exactly like a sentence.
private func mobileInlineText(_ source: String,
                              size: CGFloat,
                              weight: Font.Weight = .regular,
                              color: Color = Tokens.textSecondary) -> Text {
    var output = AttributedString()
    for span in InlineMarkdown.spans(source) {
        var piece = AttributedString(span.text)
        var font: Font = span.styles.contains(.code)
            ? .system(.subheadline, design: .monospaced)
            : TypeScale.font(size, weight: weight)
        if span.styles.contains(.strong) { font = font.bold() }
        if span.styles.contains(.emphasis) { font = font.italic() }
        piece.font = font
        piece.foregroundColor = span.styles.contains(.code) ? Tokens.accentText : color
        if span.styles.contains(.strikethrough) { piece.strikethroughStyle = .single }
        if let link = span.link {
            piece.link = link
            piece.foregroundColor = Tokens.accentText
            piece.underlineStyle = .single
        }
        output.append(piece)
    }
    return Text(output)
}

// MARK: - Tables

/// A GitHub-style pipe table drawn as a real grid.
///
/// The parser (`MarkdownTableParser`) has already decided the cells; this view is
/// only geometry: header in semibold on the surface colour, one-pixel separators,
/// cells that wrap instead of truncating, and a horizontal scroll when the
/// columns are wider than the bubble.
private struct MobileMarkdownTable: View {
    let table: MarkdownTable

    private var bodySize: CGFloat { TypeScale.chatBody }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.header, isHeader: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    Hairline(color: Tokens.borderGrouped)
                    row(cells, isHeader: false)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                    .strokeBorder(Tokens.borderGrouped, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(table.plainText)
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                if column > 0 {
                    Hairline(.vertical, color: Tokens.borderGrouped)
                }
                mobileInlineText(cell,
                                 size: bodySize,
                                 weight: isHeader ? .semibold : .regular,
                                 color: isHeader ? Tokens.textPrimary : Tokens.textSecondary)
                    .lineSpacing(2)
                    .multilineTextAlignment(textAlignment(for: column))
                    .frame(width: width(for: column), alignment: alignment(for: column))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHeader ? Tokens.surface : Color.clear)
    }

    // MARK: Column metrics

    /// A width estimated from the longest cell in the column, clamped so a short
    /// column is not cramped and a long one wraps at a readable measure. Exact
    /// measurement would need a `GeometryReader` per cell and would not change the
    /// result the eye reads.
    private func width(for column: Int) -> CGFloat {
        var longest = column < table.header.count ? table.header[column].count : 0
        for cells in table.rows where column < cells.count {
            longest = max(longest, cells[column].count)
        }
        let estimate = CGFloat(longest) * 8.2 + 4
        return min(240, max(64, estimate))
    }

    private func alignment(for column: Int) -> Alignment {
        switch alignmentValue(for: column) {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    private func textAlignment(for column: Int) -> TextAlignment {
        switch alignmentValue(for: column) {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    private func alignmentValue(for column: Int) -> MarkdownTable.Alignment {
        guard column < table.alignments.count else { return .none }
        return table.alignments[column]
    }
}

// MARK: - Streaming

/// The live assistant bubble.
///
/// The text arrives a token at a time; `IncrementalMarkdown` keeps the parsed prefix and
/// only re-parses the open tail, so a long answer does not re-parse itself on every frame.
/// The caret is the only motion, and it stops under Reduce Motion.
struct MobileStreamingBubble: View {
    let text: String
    /// The bot's face while it works, in place of the wheel.
    var face: BotFace?

    @State private var markdown = IncrementalMarkdown()
    @State private var caretOn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if markdown.blocks.isEmpty {
                WorkingStatus(face: face)
            } else {
                MobileMarkdownText(blocks: markdown.blocks)
                    .textSelection(.enabled)
                caret
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { sync(text) }
        .onChange(of: text) { newValue in sync(newValue) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hermes is responding")
    }

    private var caret: some View {
        Capsule()
            .fill(Tokens.accent)
            .frame(width: 7, height: 16)
            .opacity(caretOn ? 0.2 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                    caretOn = true
                }
            }
            .accessibilityHidden(true)
    }

    /// Append only the delta when the stream is a prefix extension (the normal case);
    /// start over if the host rewound or the session changed.
    private func sync(_ value: String) {
        if value.hasPrefix(markdown.source) {
            let delta = String(value.dropFirst(markdown.source.count))
            if !delta.isEmpty { markdown.append(delta) }
        } else {
            markdown = IncrementalMarkdown()
            markdown.append(value)
        }
    }
}

/// Kept for the previews below and for a caller that wants the bare mark: the working row itself
/// is `WorkingStatus(face:)`, which every shell already draws.
struct MobileTypingIndicator: View {
    var face: BotFace?

    var body: some View {
        WorkingStatus(face: face)
            .accessibilityLabel("Hermes is thinking")
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Markdown · assistant reply") {
    ScrollView {
        MobileMarkdownText(blocks: IncrementalMarkdown.parse("""
        Here is the **plan**, in order:

        1. Snapshot the vault with `restic`.
        2. Diff the docs tree against the last run.
        3. Only then touch anything.

        > Backups first, edits second.

        ```swift
        let snapshot = try await restic.snapshot(path: "~/vault")
        print(snapshot.id)
        ```

        - `--dry-run` is always safe
        - so is *reading* the log
        """))
        .padding(16)
    }
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif

#if DEBUG
#Preview("Streaming") {
    VStack(alignment: .leading, spacing: 20) {
        MobileStreamingBubble(text: "Snapshotting the vault first")
        MobileStreamingBubble(text: "")
        MobileTypingIndicator()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif
