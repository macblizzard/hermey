import SwiftUI
import UIKit
import HermesRender
import OpenBotUI

/// Prose you can actually select.
///
/// SwiftUI's `Text` + `.textSelection(.enabled)` gives a long-press "Copy" of the
/// whole run on iOS 17: no caret, no draggable handles, no way to take half a
/// sentence. A non-editable `UITextView` is the only supported way to get real
/// selection, so prose runs are rendered through `MobileSelectableText` while
/// everything shaped like a widget (code, tables, quotes, tool cards) stays in
/// SwiftUI.
///
/// The text view is not a scroll view: it is measured to its content so the
/// `LazyVStack` can lay it out like any other row.
struct MobileSelectableText: UIViewRepresentable {
    let attributed: NSAttributedString
    var allowsSelection = false

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1: `layoutManager.usedRect` is what makes the height exact, and
        // it is still the predictable path for non-scrolling text views.
        let view = MessageTextView(usingTextLayoutManager: false)
        view.allowsSelection = allowsSelection
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = false
        view.textContainer.maximumNumberOfLines = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.dataDetectorTypes = [.link]
        view.adjustsFontForContentSizeCategory = true
        view.tintColor = UIColor(Tokens.accent)
        view.linkTextAttributes = [
            .foregroundColor: UIColor(Tokens.accentText),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        // The row owns the height; the text view must never be squeezed or stretched.
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.attributedText = attributed
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        (view as? MessageTextView)?.allowsSelection = allowsSelection
        // Streaming re-renders this view several times a second; assigning an equal
        // string would collapse a selection the reader is dragging.
        guard !view.attributedText.isEqual(to: attributed) else { return }

        let selection = view.selectedRange
        view.attributedText = attributed
        if selection.location + selection.length <= view.attributedText.length {
            view.selectedRange = selection
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let fallbackWidth: CGFloat? = uiView.bounds.width > 0 ? uiView.bounds.width : nil
        guard let width = proposal.width ?? fallbackWidth, width.isFinite, width > 0 else {
            return nil
        }

        uiView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        uiView.layoutManager.ensureLayout(for: uiView.textContainer)
        let used = uiView.layoutManager.usedRect(for: uiView.textContainer)
        // A definite height from the first pass is what stops the row jumping once
        // the text view lays out.
        return CGSize(width: width, height: ceil(used.height))
    }
}

/// Keep taps on links, but let the row's context menu win long presses. The
/// dedicated selection sheet restores the native text-selection gestures.
private final class MessageTextView: UITextView {
    var allowsSelection = false

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if !allowsSelection && gestureRecognizer is UILongPressGestureRecognizer { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

// MARK: - Attributed prose

/// Builds the `NSAttributedString` a prose run is drawn from, using the same fonts,
/// colours and leading as the SwiftUI path (`TypeScale`, `Tokens`).
enum MobileProse {

    /// One attributed string for a run of consecutive prose blocks.
    ///
    /// Paragraphs are separated by a blank line's worth of `paragraphSpacing` rather
    /// than by separate views, so a drag started in one paragraph can run into the
    /// next — a single `UITextView` is one selection.
    static func attributed(for blocks: [Block]) -> NSAttributedString {
        let output = NSMutableAttributedString()

        for (offset, block) in blocks.enumerated() {
            let start = output.length
            append(block, to: output)
            let isLast = offset == blocks.count - 1
            if !isLast { output.append(NSAttributedString(string: "\n")) }

            let style = NSMutableParagraphStyle()
            style.lineSpacing = TypeScale.chatLineSpacing
            style.paragraphSpacing = isLast ? 0 : 10
            let indent = hangingIndent(for: block)
            style.headIndent = indent
            style.firstLineHeadIndent = 0
            output.addAttribute(.paragraphStyle,
                                value: style,
                                range: NSRange(location: start, length: output.length - start))
        }
        return output
    }

    /// A single user-authored message: no markdown, no list markers.
    static func plain(_ text: String,
                      color: Color = Tokens.textPrimary,
                      size: CGFloat = TypeScale.chatBody) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = TypeScale.chatLineSpacing
        return NSAttributedString(string: text, attributes: [
            .font: font(size: size),
            .foregroundColor: UIColor(color),
            .paragraphStyle: style,
        ])
    }

    // MARK: Blocks

    private static func append(_ block: Block, to output: NSMutableAttributedString) {
        switch block {
        case .paragraph(let text):
            appendInline(text, size: TypeScale.chatBody, color: Tokens.textSecondary, to: output)

        case .heading(let level, let text):
            appendInline(text,
                         size: TypeScale.chatBody + (level <= 1 ? 3 : 1),
                         weight: .semibold,
                         color: Tokens.textPrimary,
                         to: output)

        case .bullet(let text):
            output.append(NSAttributedString(string: "• ", attributes: [
                .font: font(size: TypeScale.chatBody),
                .foregroundColor: UIColor(Tokens.textDim),
            ]))
            appendInline(text, size: TypeScale.chatBody, color: Tokens.textSecondary, to: output)

        case .numbered(let index, let text):
            output.append(NSAttributedString(string: "\(index). ", attributes: [
                .font: font(size: TypeScale.chatBody),
                .foregroundColor: UIColor(Tokens.textDim),
            ]))
            appendInline(text, size: TypeScale.chatBody, color: Tokens.textSecondary, to: output)

        case .quote(let text):
            // Quotes keep their accent bar in SwiftUI, so this is only reached when a
            // caller hands the builder a block it does not draw.
            appendInline(text, size: TypeScale.chatBody, color: Tokens.textMuted, to: output)

        case .code(_, let body, _):
            output.append(NSAttributedString(string: body, attributes: [
                .font: monospacedFont(size: 13),
                .foregroundColor: UIColor(Tokens.textSecondary),
            ]))

        case .table(let table):
            output.append(NSAttributedString(string: table.plainText, attributes: [
                .font: font(size: TypeScale.chatBody),
                .foregroundColor: UIColor(Tokens.textSecondary),
            ]))

        case .rule:
            break
        }
    }

    private static func appendInline(_ source: String,
                                     size: CGFloat,
                                     weight: UIFont.Weight = .regular,
                                     color: Color = Tokens.textSecondary,
                                     to output: NSMutableAttributedString) {
        let base = UIColor(color)
        for span in InlineMarkdown.spans(source) where !span.text.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [:]
            let isCode = span.styles.contains(.code)
            let isBold = span.styles.contains(.strong)

            if isCode {
                attributes[.font] = monospacedFont(size: 15, weight: isBold ? .semibold : .regular)
                attributes[.foregroundColor] = UIColor(Tokens.accentText)
            } else {
                let effectiveWeight: UIFont.Weight = isBold ? .bold : weight
                attributes[.font] = font(size: size,
                                         weight: effectiveWeight,
                                         italic: span.styles.contains(.emphasis))
                attributes[.foregroundColor] = base
            }
            if span.styles.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = span.link {
                attributes[.link] = link
                attributes[.foregroundColor] = UIColor(Tokens.accentText)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            output.append(NSAttributedString(string: span.text, attributes: attributes))
        }
    }

    /// The width a wrapped list item hangs at, so the second line starts under the
    /// text rather than under the bullet.
    private static func hangingIndent(for block: Block) -> CGFloat {
        switch block {
        case .bullet: return 16
        case .numbered(let index, _): return index < 10 ? 20 : 27
        default: return 0
        }
    }

    // MARK: Fonts

    /// `TypeScale.font` is Inter-relative-to-body with the system face as its
    /// fallback; this mirrors it in UIKit. Dynamic Type is applied by the text view
    /// (`adjustsFontForContentSizeCategory`), so these are base sizes.
    static func font(size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        var base: UIFont
        if let inter = UIFont(name: "Inter", size: size) {
            base = inter.withWeight(weight)
        } else {
            base = UIFont.systemFont(ofSize: size, weight: weight)
        }
        if italic, let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) {
            base = UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    static func monospacedFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
