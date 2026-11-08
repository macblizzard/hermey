import AppKit
import HermesRender
import OpenBotUI
import SwiftUI

/// Draws the `AttributedString` the block layer compiled, run by run.
///
/// `HermesRender` owns *semantics* (`BoldAttribute`, `InlineCodeAttribute`,
/// `CodeTokenAttribute`…), not colours; this is where a run's meaning becomes type. Two
/// choices worth stating:
///
/// - Runs are concatenated as `Text` values rather than converted into a second
///   `AttributedString` carrying SwiftUI attributes. `Text + Text` is the oldest, most
///   stable way to mix fonts inside one line on macOS and it cannot drift with an SDK's
///   attribute-scope rules.
/// - Nothing is hardcoded: sizes come from `ChatTextMetrics` / `TypeScale`, colours from
///   `Tokens`.
struct MacMarkdownText: View {
    let attributed: AttributedString
    var size: CGFloat = TypeScale.chatBody
    var weight: Font.Weight = .regular
    var color: Color = Tokens.textSecondary
    var codeSize: CGFloat = ChatTextMetrics.macOS.codeSize
    var isCodeBlock: Bool = false
    var lineSpacing: CGFloat = TypeScale.chatLineSpacing

    var body: some View {
        messageBody
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A link in a reply opens in the user's browser, not in whatever the app's own default
            // would be. Declared here so a run cannot fall through to an empty handler.
            .environment(\.openURL, OpenURLAction { url in
                // A reply may link to the web. It may not hand `file:` or a custom scheme to the
                // system: that is a click on a handler, chosen by whatever wrote the reply.
                guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                    return .discarded
                }
                NSWorkspace.shared.open(url)
                return .handled
            })
            .accessibilityLabel(String(attributed.characters))
    }

    /// Text with links, or text that can be selected — not both.
    ///
    /// `.textSelection(.enabled)` is the reason links were underlined and dead on the Mac: with a
    /// selection active, a click starts selecting and the link never fires. SwiftUI's `Text` gives
    /// no way to tell the two apart, so a message that carries a link gives up selection (it can
    /// still be copied from the app's own menu) and a plain message keeps it.
    @ViewBuilder
    private var messageBody: some View {
        if carriesLink {
            renderedText
        } else {
            renderedText.textSelection(.enabled)
        }
    }

    private var carriesLink: Bool {
        attributed.runs.contains { $0.link != nil }
    }

    /// One `AttributedString`, styled run by run from the run's hermes attributes.
    ///
    /// This used to concatenate `Text` values, which was the stable way to mix fonts in a line but
    /// silently dropped the one attribute that must survive: `.link`. Every URL in a reply rendered
    /// underlined and dead. SwiftUI's own attribute scope carries font, colour, underline and link
    /// on a single attributed string, and `Text` draws a `.link` run as a link.
    private var renderedText: Text {
        var result = AttributedString()
        for run in attributed.runs {
            let slice = attributed.characters[run.range]
            guard !slice.isEmpty else { continue }

            let attributes = run.attributes
            let isBold = attributes[BoldAttribute.self] == true
            let isItalic = attributes[ItalicAttribute.self] == true
            let isInlineCode = attributes[InlineCodeAttribute.self] == true
            let isStruck = attributes[StrikethroughAttribute.self] == true
            let blockLanguage = attributes[CodeBlockAttribute.self]
            let token = attributes[CodeTokenAttribute.self]
            let isLink = run.link != nil

            let isMonospaced = isCodeBlock || isInlineCode || blockLanguage != nil

            var font = Font.system(size: isMonospaced ? codeSize : size,
                                    weight: isBold ? .semibold : weight,
                                    design: isMonospaced ? .monospaced : .default)
            if isItalic {
                font = font.italic()
            }

            var segment = AttributedString(String(slice))
            segment.font = font

            if let url = run.link {
                segment.link = url
            }

            if isLink {
                segment.foregroundColor = Tokens.accentText
                segment.underlineStyle = .single
            } else if token != nil {
                segment.foregroundColor = MacCodePalette.color(for: token)
            } else if isMonospaced {
                segment.foregroundColor = isCodeBlock ? Tokens.textSecondary : Tokens.textPrimary
            } else {
                segment.foregroundColor = color
            }

            if isStruck {
                segment.strikethroughStyle = .single
            }

            result.append(segment)
        }
        return Text(result)
    }
}

// MARK: - Previews

private struct MacMarkdownTextPreview: View {
    private let sample = InlineMarkdown.attributedString(
        "Snapshotting the **vault** first, then I'll diff the `docs/` tree — ~~nothing deleted~~, see [the plan](https://example.com/plan)."
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MacMarkdownText(attributed: sample)
            MacMarkdownText(attributed: InlineMarkdown.attributedString("a single *quiet* line"),
                            size: TypeScale.label,
                            color: Tokens.textMuted)
        }
        .padding(20)
        .frame(width: Geometry.conversationMeasure)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Markdown text") {
    MacMarkdownTextPreview()
}
#endif
