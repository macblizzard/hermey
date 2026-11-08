import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The message field.
///
/// It owns no state but its focus: the draft is the caller's binding, so a screen can
/// restore it per session and keep a failed send in place. `onSend` fires only when the
/// field has something to send; the screen clears the draft on success. While a turn is
/// running the send control becomes an interrupt, which is the contract `GatewayClient`
/// exposes (`submit` / `interrupt`, never both at once).
public struct Composer: View {
    @Binding private var text: String

    private let placeholder: String
    private let isSending: Bool
    private let isDisabled: Bool
    private let queuedCount: Int
    private let hasAttachments: Bool
    private let showsAttach: Bool
    private let showsMic: Bool
    private let hint: String?
    private let onSend: () -> Void
    private let onAttach: (() -> Void)?
    private let onMic: (() -> Void)?
    private let onInterrupt: (() -> Void)?
    /// Files and pictures pasted or dropped into the field. Nil where the caller has no attach
    /// path (the phone takes them through its own picker).
    private let onAttachItems: (([ComposerAttachment]) -> Void)?
    /// A popover the paperclip itself anchors, rather than one hung off the whole card.
    ///
    /// The Mac's attach menu is a two-item popover, and presenting it from the composer's outer
    /// frame put it under the *field* — nowhere near the clip that opened it. Both halves are
    /// optional so the phone, which pushes a sheet, passes neither.
    private let attachPopoverPresented: Binding<Bool>?
    private let attachPopoverContent: AnyView?

    /// The microphone's own presentation, supplied by the caller because only the recording
    /// controller knows whether it is idle, listening or transcribing. It is drawn immediately
    /// left of the send arrow — the phone's order — instead of on a separate line above the card.
    private let micSystemImage: String
    private let micTint: Color?
    private let micAccessibilityLabel: String
    private let isMicEnabled: Bool

    @FocusState private var focused: Bool

    #if os(macOS)
    /// The text view reports its own first-responder state: `@FocusState` cannot see an
    /// `NSViewRepresentable`, and the border colour is driven by focus.
    @State private var editorFocused = false
    /// The height the editor asks for, so the card grows a line at a time.
    @State private var editorHeight: CGFloat = 34
    #endif

    public init(text: Binding<String>,
                placeholder: String = "Ask Hermes anything",
                isSending: Bool = false,
                isDisabled: Bool = false,
                queuedCount: Int = 0,
                hasAttachments: Bool = false,
                showsAttach: Bool = true,
                showsMic: Bool = true,
                micSystemImage: String = "mic",
                micTint: Color? = nil,
                micAccessibilityLabel: String = "Record a voice message",
                isMicEnabled: Bool = true,
                hint: String? = Composer.defaultHint,
                onSend: @escaping () -> Void,
                onAttach: (() -> Void)? = nil,
                onMic: (() -> Void)? = nil,
                onInterrupt: (() -> Void)? = nil,
                onAttachItems: (([ComposerAttachment]) -> Void)? = nil,
                attachPopoverPresented: Binding<Bool>? = nil,
                attachPopoverContent: AnyView? = nil) {
        _text = text
        self.placeholder = placeholder
        self.isSending = isSending
        self.isDisabled = isDisabled
        self.queuedCount = queuedCount
        self.hasAttachments = hasAttachments
        self.showsAttach = showsAttach
        self.showsMic = showsMic
        self.micSystemImage = micSystemImage
        self.micTint = micTint
        self.micAccessibilityLabel = micAccessibilityLabel
        self.isMicEnabled = isMicEnabled
        self.hint = hint
        self.onSend = onSend
        self.onAttach = onAttach
        self.onMic = onMic
        self.onInterrupt = onInterrupt
        self.onAttachItems = onAttachItems
        self.attachPopoverPresented = attachPopoverPresented
        self.attachPopoverContent = attachPopoverContent
    }

    /// The desktop hint line, in OpenBot's own words. The phone has no hint line.
    #if os(macOS)
    public static let defaultHint: String? = "⏎ send · ⇧⏎ newline · ⌘K commands"
    #else
    public static let defaultHint: String? = nil
    #endif

    #if os(iOS)
    private var controlSide: CGFloat { 32 }
    private var glyphSize: CGFloat { 12 }
    #else
    private var controlSide: CGFloat { 26 }
    private var glyphSize: CGFloat { 11 }
    #endif

    /// The row the field and the controls share. The field is one line taller than a control so
    /// the text has breathing room; the controls are nudged down by half that difference so every
    /// glyph's centre sits on the same line as the first line of text.
    private var rowHeight: CGFloat { controlSide + 8 }
    private var controlInset: CGFloat { (rowHeight - controlSide) / 2 }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A pending attachment is sendable on its own: a file with no comment is a complete message,
    /// and disabling the arrow there made the attach feature look broken.
    private var canSend: Bool {
        // Sendable mid-turn on purpose: the host's busy policy steers, redirects or queues it, and
        // refusing here made "steer or queue" impossible while the bot was working.
        !isDisabled && (!trimmed.isEmpty || hasAttachments)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if queuedCount > 0 {
                StatusChip.queued(queuedCount)
                    .padding(.leading, 2)
            }

            // Top-aligned: a second line must grow the card downwards, not push the paperclip and
            // the send arrow around. Every control then shares the first line's centre.
            HStack(alignment: .top, spacing: 8) {
                if showsAttach {
                    attachControl
                        .padding(.top, controlInset)
                }

                field
                    .frame(minHeight: rowHeight)

                // One tap clears everything typed. Inside the card, right of the text and left of
                // the mic: it belongs to the field, not to the message's verbs. Dim on purpose —
                // it is an escape hatch, not a control in the row of actions.
                if !trimmed.isEmpty {
                    Button {
                        text = ""
                        // Put the caret back in the field: clearing is the start of a new message,
                        // not the end of typing.
                        #if os(macOS)
                        editorFocused = true
                        #else
                        focused = true
                        #endif
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: glyphSize + 3))
                            .foregroundStyle(Tokens.textDim.opacity(0.55))
                            .frame(width: controlSide, height: controlSide)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, controlInset)
                    .transition(.opacity)
                    .accessibilityLabel("Clear the message")
                }

                // The microphone belongs beside the send arrow: one row of controls, and the
                // control that ends a message next to the one that starts it.
                if showsMic {
                    micControl
                        .padding(.top, controlInset)
                }

                Group {
                    // Both controls while a turn runs: stop, and send-into-this-turn. One button
                    // that swaps meaning is exactly why there was no way to say anything else.
                    if isSending, let onInterrupt {
                        interruptButton(onInterrupt)
                        sendButton
                    } else {
                        sendButton
                    }
                }
                .padding(.top, controlInset)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, hint == nil ? 8 : 2)

            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
                    // Under the first character of the message, which is the card's own padding
                    // plus whatever the paperclip occupies.
                    .padding(.leading, showsAttach ? 8 + controlSide + 8 : 10)
                    .padding(.trailing, 10)
                    .padding(.bottom, 7)
                    .accessibilityHidden(true)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .fill(Tokens.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .strokeBorder(isFieldFocused ? Tokens.borderFocus : Tokens.borderStrong, lineWidth: 1)
        )
        .opacity(isDisabled ? 0.6 : 1)
    }

    /// The border's focus state. The Mac's editor is an `NSTextView` and reports its own first
    /// responder; the phone keeps `@FocusState`.
    private var isFieldFocused: Bool {
        #if os(macOS)
        editorFocused
        #else
        focused
        #endif
    }

    // MARK: Field

    private var baseField: some View {
        TextField("",
                  text: $text,
                  prompt: Text(placeholder).foregroundColor(Tokens.textPlaceholder),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(TypeScale.font(TypeScale.chatBody))
            .foregroundStyle(Tokens.textPrimary)
            .tint(Tokens.accent)
            .lineLimit(1...8)
            .focused($focused)
            .padding(.vertical, 6)
            .submitLabel(.send)
            .accessibilityLabel(placeholder)
            .disabled(isDisabled)
    }

    /// On the Mac the field is a real text view (see `ComposerTextView`), so Return sends and
    /// Shift+Return breaks the line *at the caret* — the platform's own insert, not an append.
    private var field: some View {
        #if os(macOS)
        // No SwiftUI placeholder: the text view draws its own, so the prompt and the caret share
        // one origin and one font. A `Text` on top positioned the string by its ascent while the
        // caret took a whole line fragment, which is why the caret sat above the first letter.
        ComposerTextView(text: $text,
                         isFocused: $editorFocused,
                         fontSize: TypeScale.chatBody,
                         minHeight: rowHeight,
                         // The design system's cap: past about eight lines the field scrolls
                         // inside itself instead of eating the conversation.
                         // Fourteen lines, then the field scrolls inside itself. Seven was about
                         // eleven lines of ordinary prose at this point size, and past that the
                         // caret could not be seen while typing.
                         maxHeight: rowHeight + TypeScale.chatLine * 14,
                         isEditable: !isDisabled,
                         onSend: { send() },
                         onHeightChange: { height in
                             if abs(height - editorHeight) > 0.5 { editorHeight = height }
                         },
                         onAttachItems: onAttachItems,
                         placeholder: placeholder,
                         placeholderColor: NSColor(Tokens.textPlaceholder))
            .frame(height: editorHeight)
            .frame(minHeight: rowHeight, alignment: .topLeading)
        #else
        baseField
            .onSubmit { send() }
        #endif
    }

    // MARK: Controls

    /// The paperclip. When a caller supplies a popover, it is anchored *here* — on the 26 pt
    /// button — so the menu drops from the clip instead of from the middle of the composer card.
    @ViewBuilder
    private var attachControl: some View {
        let button = OpenBotIconButton("paperclip",
                                       label: "Attach a file",
                                       size: .small,
                                       isDisabled: isDisabled) { onAttach?() }
        if let presented = attachPopoverPresented, let content = attachPopoverContent {
            button.popover(isPresented: presented, arrowEdge: .top) { content }
        } else {
            button
        }
    }

    /// The microphone. Drawn only when the caller supplied an action, so the phone's composer
    /// (which has its own voice affordances) is unchanged.
    @ViewBuilder
    private var micControl: some View {
        if let onMic {
            Button {
                Haptics.selection()
                onMic()
            } label: {
                Image(systemName: micSystemImage)
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(micTint ?? Tokens.textSecondary)
                    .frame(width: controlSide, height: controlSide)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isDisabled || !isMicEnabled)
            .opacity(isMicEnabled ? 1 : 0.5)
            #if os(macOS)
            .help(micAccessibilityLabel)
            #endif
            .accessibilityLabel(micAccessibilityLabel)
            .accessibilityIdentifier("composer.mic")
        }
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: glyphSize, weight: .bold))
                .foregroundStyle(canSend ? Tokens.textPrimary : Tokens.textDim)
                .frame(width: controlSide, height: controlSide)
                .background(
                    Circle().fill(canSend ? Tokens.accent : Tokens.controlActive)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!canSend)
        .accessibilityLabel(isSending ? "Send into the running turn" : "Send message")
    }

    private func interruptButton(_ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact()
            action()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: glyphSize - 0.5, weight: .semibold))
                .foregroundStyle(Tokens.danger)
                .frame(width: controlSide, height: controlSide)
                .background(Circle().fill(Tokens.dangerSoft))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Interrupt the turn")
    }

    private func send() {
        guard canSend else { return }
        Haptics.impact()
        onSend()
    }
}

// MARK: - Previews

private struct ComposerPreviewHost: View {
    @State private var empty = ""
    @State private var typing = "Check whether the gateway ticket is single-use, then fix the retry."
    @State private var running = "Add a test for the rewind contract"

    var body: some View {
        VStack(spacing: 18) {
            Composer(text: $empty, onSend: {})
            Composer(text: $typing, onSend: {})
            Composer(text: $running, isSending: true, onSend: {}, onInterrupt: {})
            Composer(text: $empty, isDisabled: true, onSend: {})
            Composer(text: $typing, queuedCount: 2, onSend: {})
        }
        .padding(20)
        .frame(width: 520)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#Preview("Composer · states") {
    ComposerPreviewHost()
}
#endif
#endif
#endif
#endif
#endif
#endif
#endif
#endif
