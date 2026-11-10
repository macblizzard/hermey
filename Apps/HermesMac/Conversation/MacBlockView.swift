import HermesKit
import HermesRender
import OpenBotUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One markdown block from `IncrementalMarkdown`, drawn the way the macOS transcript wants
/// it: prose at the chat measure, code in its own inset card, quotes on a rule.
///
/// The block has already been compiled to `AttributedString` by `TranscriptRenderer`; this
/// view never parses markdown itself, so a streamed paragraph costs one block compile, not
/// one per frame.
struct MacBlockView: View {
    let block: Block
    let attributed: AttributedString?
    var metrics: ChatTextMetrics = .macOSScaled

    @ViewBuilder
    var body: some View {
        switch block {
        case .paragraph:
            MacMarkdownText(attributed: text,
                            size: metrics.fontSize(for: block),
                            color: Tokens.textSecondary,
                            codeSize: metrics.codeSize,
                            lineSpacing: metrics.estimatedLineSpacing)
        case .heading:
            MacMarkdownText(attributed: text,
                            size: metrics.fontSize(for: block),
                            weight: .semibold,
                            color: Tokens.textPrimary,
                            codeSize: metrics.codeSize,
                            lineSpacing: metrics.estimatedLineSpacing)
                .padding(.top, 2)
        case .bullet, .numbered:
            MacMarkdownText(attributed: text,
                            size: metrics.fontSize(for: block),
                            color: Tokens.textSecondary,
                            codeSize: metrics.codeSize,
                            lineSpacing: metrics.estimatedLineSpacing)
                .padding(.leading, 13)
        case .quote:
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Tokens.borderFocus)
                    .frame(width: 2)
                MacMarkdownText(attributed: text,
                                size: metrics.fontSize(for: block),
                                color: Tokens.textMuted,
                                codeSize: metrics.codeSize,
                                lineSpacing: metrics.estimatedLineSpacing)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let body, let closed):
            codeBlock(language: language, body: body, closed: closed)
        case .table(let table):
            MacTableBlock(table: table, metrics: metrics)
        case .rule:
            Hairline(color: Tokens.borderStrong)
                .padding(.vertical, 4)
        }
    }

    private var text: AttributedString {
        attributed ?? BlockText.attributed(for: block)
    }

    private func codeBlock(language: String?, body: String, closed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(languageLabel(language))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if !closed {
                    Text("streaming")
                        .font(TypeScale.font(10))
                        .foregroundStyle(Tokens.textDim)
                }

                CodeCopyButton(code: body)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            MacMarkdownText(attributed: text,
                            size: metrics.codeSize,
                            color: Tokens.textSecondary,
                            codeSize: metrics.codeSize,
                            isCodeBlock: true,
                            lineSpacing: 3)
                .padding(10)
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

    private func languageLabel(_ language: String?) -> String {
        guard let language, !language.isEmpty else { return "code" }
        return language
    }

}

// MARK: - Tables

/// The same grid the phone draws, at the desktop's type size.
///
/// The cells come from `MarkdownTableParser` in `HermesKit`, so both shells read a
/// pipe table identically; only the metrics differ.
private struct MacTableBlock: View {
    let table: MarkdownTable
    var metrics: ChatTextMetrics

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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(table.plainText)
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                if column > 0 {
                    Hairline(.vertical, color: Tokens.borderGrouped)
                }
                MacMarkdownText(attributed: InlineMarkdown.attributedString(cell),
                                size: metrics.bodySize,
                                weight: isHeader ? .semibold : .regular,
                                color: isHeader ? Tokens.textPrimary : Tokens.textSecondary,
                                codeSize: metrics.codeSize,
                                lineSpacing: 2)
                    .multilineTextAlignment(textAlignment(for: column))
                    .frame(width: width(for: column), alignment: alignment(for: column))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHeader ? Tokens.surface : Color.clear)
    }

    private func width(for column: Int) -> CGFloat {
        var longest = column < table.header.count ? table.header[column].count : 0
        for cells in table.rows where column < cells.count {
            longest = max(longest, cells[column].count)
        }
        let estimate = CGFloat(longest) * (metrics.bodySize * 0.52) + 4
        return min(metrics.bodySize * 18, max(metrics.bodySize * 4.5, estimate))
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

// MARK: - Previews

private struct MacBlockViewPreview: View {
    private let metrics = ChatTextMetrics.macOS
    private let blocks: [Block] = IncrementalMarkdown.parse("""
    Snapshotting the **vault** first, then I'll diff the `docs/` tree.

    ## Plan

    1. `rsync` the vault to `~/backup/vault`
    2. Diff `docs/` against the backup

    > Nothing is deleted until the diff is reviewed.

    ```sh
    rsync -a --delete ~/vault/ ~/backup/vault/
    ```

    ---
    """)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.indices), id: \.self) { index in
                    MacBlockView(block: blocks[index],
                                 attributed: BlockText.attributed(for: blocks[index]),
                                 metrics: metrics)
                }
            }
            .padding(20)
            .frame(width: Geometry.conversationMeasure, alignment: .leading)
        }
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#if DEBUG
#if DEBUG
#Preview("Markdown blocks") {
    MacBlockViewPreview()
}
#endif
#endif
#endif
