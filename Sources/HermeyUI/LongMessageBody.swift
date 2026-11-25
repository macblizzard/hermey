import HermesKit
import SwiftUI

/// A body too long to draw whole, collapsed to its first fifty lines — one implementation for the
/// phone and the Mac.
///
/// The freeze this exists for was the same on both shells, so the answer is one view rather than two
/// that agree by hand. What differs between the shells is only the *expanded* body — each has its own
/// markdown renderer — and that is injected: the collapse, the wording, the count, the memory of
/// which rows were opened and the off-main hand-over are all here.
///
/// Three states, and the collapsed one draws **plain text**:
///
/// * collapsed — the first fifty lines, no markdown parse, no span styling, no table measurement.
///   A row whose every identifier is inline code used to cost one attributed run per identifier on
///   every body pass; this costs one `Text`.
/// * opening — the same preview, so the row does not change height under the finger that tapped it
///   while the blocks are parsed off the main actor.
/// * open — the shell's markdown, built from blocks it parsed in the background, and the button
///   says "Show less" with no count beside it.
///
/// The preview is selectable, and the message's own actions still copy the stored text: this is a
/// drawing clamp, never a truncation.
public struct LongMessageBody<Expanded: View>: View {
    private let preview: TranscriptClamp.Preview
    /// The message's identity: what the expansion is remembered by, and what the off-main parse is
    /// keyed to. Same id the transcript's `ForEach` draws the row by, so a rebuilt row agrees.
    private let messageID: String
    private let alignment: HorizontalAlignment
    private let font: Font
    private let color: Color
    private let lineSpacing: CGFloat
    /// Whether the shell's expanded body has been built yet. The preview stays on screen until it
    /// has — never a blank gap, never a collapsed row under an open button.
    private let expandedReady: Bool
    private let onOpen: () -> Void
    private let onCollapse: () -> Void
    private let expanded: () -> Expanded

    /// This row instance's own answer, for the case the shared store has not been consulted yet.
    @State private var openedHere = false

    /// Opened in this instance, or remembered from an earlier one. A row in a lazy stack is torn
    /// down when it leaves the viewport, so `@State` alone forgot the expansion two screens later —
    /// the reader tapped "Show full message", scrolled on, scrolled back and found it collapsed
    /// again. `ExpandedLongRows` is keyed by message id for exactly that reason.
    private var isOpen: Bool { openedHere || ExpandedLongRows.shared.contains(messageID) }

    /// - Parameters:
    ///   - font/color/lineSpacing: the shell's own body typography, so a clamped reply and an
    ///     ordinary one are set in the same type. A tool body passes `Tokens.mono`.
    ///   - onOpen: start the parse. Called once per draw of an open row, so it must be idempotent
    ///     (`guard full == nil`), and it must parse **off** the main actor. A body the shell draws as
    ///     plain text has nothing to parse: pass `expandedReady: true` and leave `onOpen` empty.
    public init(preview: TranscriptClamp.Preview,
                messageID: String,
                alignment: HorizontalAlignment = .leading,
                font: Font = TypeScale.font(TypeScale.chatBody),
                color: Color = Tokens.textPrimary,
                lineSpacing: CGFloat = TypeScale.chatLineSpacing,
                expandedReady: Bool,
                onOpen: @escaping () -> Void = {},
                onCollapse: @escaping () -> Void = {},
                expanded: @escaping () -> Expanded) {
        self.preview = preview
        self.messageID = messageID
        self.alignment = alignment
        self.font = font
        self.color = color
        self.lineSpacing = lineSpacing
        self.expandedReady = expandedReady
        self.onOpen = onOpen
        self.onCollapse = onCollapse
        self.expanded = expanded
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            if isOpen && expandedReady {
                expanded()
            } else {
                // The preview. Fifty whole lines of one `Text`: nothing here parses, styles or
                // measures more than the lines that are actually shown.
                Text(preview.text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineSpacing(lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
            }

            button
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        // A remembered row is parsed when it is drawn again, so scrolling back to a message the
        // reader opened does not leave an open button over a collapsed body. Keyed to this message,
        // so a row rebuilt for a different message never reuses this one's answer.
        .task(id: messageID) {
            guard isOpen, !expandedReady else { return }
            onOpen()
        }
    }

    /// "Show full message · 312 more lines", and then "Show less". The count is the body's own,
    /// recomputed from the text, and it disappears the moment nothing is hidden.
    private var button: some View {
        Button(action: isOpen ? collapse : open) {
            Label(isOpen ? TranscriptClamp.showLessTitle
                         : TranscriptClamp.showFullTitle(hiddenLines: preview.hiddenLines),
                  systemImage: isOpen ? "arrow.up.right.and.arrow.down.left"
                                      : "arrow.down.right.and.arrow.up.left")
                .font(TypeScale.font(TypeScale.sm, weight: .semibold))
                .foregroundStyle(Tokens.accentText)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("longMessageToggle")
        .hermeyFocusQuiet()
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .trailing: return .trailing
        case .center: return .center
        default: return .leading
        }
    }

    private func open() {
        ExpandedLongRows.shared.insert(messageID)
        openedHere = true
        onOpen()
    }

    private func collapse() {
        ExpandedLongRows.shared.remove(messageID)
        openedHere = false
        onCollapse()
    }
}

/// The clamp's one decision for a body a row draws: this body whole, or collapsed to a preview.
///
/// Both shells hand every body they draw through this, so "is this row long" has exactly one answer
/// in the app and neither shell can invent an exemption. The two views are closures on purpose: the
/// *whole* branch is where the shell's markdown parse lives, and building it eagerly — as a view
/// value passed in — would put the parse back on the collapsed path this type exists to keep it off.
///
/// So the collapsed row costs what `LongMessageBody` costs, which is one `Text`; and the shell's
/// renderer is only ever built for a body that is short, or for one the reader opened.
public struct ClampedBody<Whole: View, Expanded: View>: View {
    private let body: TranscriptClamp.Body
    private let messageID: String
    private let alignment: HorizontalAlignment
    private let font: Font
    private let color: Color
    private let lineSpacing: CGFloat
    private let expandedReady: Bool
    private let onOpen: () -> Void
    private let onCollapse: () -> Void
    private let whole: () -> Whole
    private let expanded: () -> Expanded

    public init(_ body: TranscriptClamp.Body,
                messageID: String,
                alignment: HorizontalAlignment = .leading,
                font: Font = TypeScale.font(TypeScale.chatBody),
                color: Color = Tokens.textPrimary,
                lineSpacing: CGFloat = TypeScale.chatLineSpacing,
                expandedReady: Bool = true,
                onOpen: @escaping () -> Void = {},
                onCollapse: @escaping () -> Void = {},
                whole: @escaping () -> Whole,
                expanded: @escaping () -> Expanded) {
        self.body = body
        self.messageID = messageID
        self.alignment = alignment
        self.font = font
        self.color = color
        self.lineSpacing = lineSpacing
        self.expandedReady = expandedReady
        self.onOpen = onOpen
        self.onCollapse = onCollapse
        self.whole = whole
        self.expanded = expanded
    }

    public var body: some View {
        switch TranscriptClamp.plan(body) {
        case .whole:
            whole()
        case .preview(let preview):
            LongMessageBody(preview: preview,
                            messageID: messageID,
                            alignment: alignment,
                            font: font,
                            color: color,
                            lineSpacing: lineSpacing,
                            expandedReady: expandedReady,
                            onOpen: onOpen,
                            onCollapse: onCollapse,
                            expanded: expanded)
        }
    }
}
