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

    /// True when the field is a capsule floating over content rather than a bar sitting under it:
    /// no stroke, a translucent fill and a shadow, so the text behind it reads as passing
    /// underneath instead of the field reading as a box drawn on top.
    public var floats: Bool

    public init(text: Binding<String>,
                floats: Bool = false,
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
        self.floats = floats
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

    /// No hint line by default, on either platform.
    ///
    /// The composer said `⏎ send · ⇧⏎ newline · ⌘K commands` under every conversation, forever —
    /// a keyboard reference that costs a line of the reading column and teaches nothing after the
    /// first day. What is left is state, not instruction: a caller passes a hint only while
    /// something is actually happening (recording, transcribing).
    public static let defaultHint: String? = nil

    #if os(iOS)
    private var controlSide: CGFloat { 32 }
    private var glyphSize: CGFloat { 12 }
    #else
    private var controlSide: CGFloat { 26 }
    private var glyphSize: CGFloat { 11 }
    #endif

    /// The gap above the field's first line. The text, both control columns and the card's padding
    /// are all laid out from this one number.
    private var lineInset: CGFloat { 6 }

    /// One line of the field, at the transcript's own rhythm — which `.lineSpacing` below makes
    /// true, and which every `chatLine` number in this file already assumes.
    private var lineBox: CGFloat { lineInset * 2 + TypeScale.chatLine }

    /// A line, not `controlSide + 8`.
    ///
    /// 40 was 7.7 pt taller than the field's own single line, and `minHeight` absorbed that slack by
    /// centring the field — then dropped it the moment a second line made the field taller, which
    /// moved the first line 3.9 pt up while the glyphs beside it stayed put. On one line the text
    /// looked aligned and on two it did not, which is the "geometry goes wrong when the text is
    /// longer" report.
    private var rowHeight: CGFloat { max(lineBox, controlSide) }

    /// How far a control sits above the card's foot so that its centre is the centre of the *last*
    /// line — the line the caret is on.
    ///
    /// Controls anchored to the top put the paperclip beside line one and left it there while the
    /// text grew away from it, which reads as the box filling up underneath a row of buttons that
    /// belong to a different control. They ride the bottom now, the way a keyboard's own controls do.
    private var controlInset: CGFloat { max(0, (lineBox - controlSide) / 2) }

    private func rowCentred<V: View>(_ view: V) -> some View {
        // Nothing that can grow: an unbounded frame inside the row made each control column
        // claim all the vertical space the card could offer, and the card — which is an overlay with
        // no ceiling — offered the whole screen. The row's bottom alignment is what anchors them.
        view.padding(.bottom, controlInset)
    }

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

            // A second line grows the card downwards and the controls stay at the foot of it, so a
            // long message keeps its paperclip and its arrow where the thumb left them.
            HStack(alignment: .bottom, spacing: 8) {
                if showsAttach {
                    rowCentred(attachControl)
                }

                field
                    .frame(minHeight: rowHeight)

                // One tap clears everything typed. Inside the card, right of the text and left of
                // the mic: it belongs to the field, not to the message's verbs. Dim on purpose —
                // it is an escape hatch, not a control in the row of actions.
                // Reserved, never inserted: a 40 pt control appearing in the row took 40 pt off the
                // field the instant the first character landed, and a long line re-wrapped onto
                // another line because of it — while the reader watched the text move.
                Group {
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
                    .padding(.bottom, controlInset)
                    .opacity(trimmed.isEmpty ? 0 : 1)
                    .allowsHitTesting(!trimmed.isEmpty)
                    .accessibilityHidden(trimmed.isEmpty)
                    .accessibilityLabel("Clear the message")
                }

                // The microphone belongs beside the send arrow: one row of controls, and the
                // control that ends a message next to the one that starts it.
                if showsMic {
                    rowCentred(micControl)
                }

                // The closure is spelled as a `Group` argument, not a trailing one: a bare
                // `rowCentred { … }` infers the closure itself as the view.
                rowCentred(Group {
                    // Both controls while a turn runs: stop, and send-into-this-turn. One button
                    // that swaps meaning is exactly why there was no way to say anything else.
                    if isSending, let onInterrupt {
                        interruptButton(onInterrupt)
                        sendButton
                    } else {
                        sendButton
                    }
                })
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
        .background {
            // A floating field draws its own surface; a bar keeps its control fill, which is part of
            // the bar rather than something hovering over the text.
            if floats {
                // The platform's glass, in the composer's own shape. Nothing painted over it: no
                // wash, no rim, no shadow — each of those is a drawing of glass rather than glass,
                // and next to the system's own surfaces they read as frosting.
                Color.clear.hermeyGlass(Self.floatingShape, interactive: true)
            } else {
                RoundedRectangle(cornerRadius: Tokens.radiusComposer, style: .continuous)
                    .fill(Tokens.control)
            }
        }
        .overlay {
            // Floating: nothing at all. The glass carries its own edge, and every line drawn on top
            // of it is a line Apple's glass does not have. A bar still gets its rule, because a bar
            // is a piece of chrome rather than a lens.
            if !floats {
                RoundedRectangle(cornerRadius: Tokens.radiusComposer, style: .continuous)
                    .strokeBorder(isFieldFocused ? Tokens.borderFocus : Tokens.borderStrong,
                                  lineWidth: 1)
            }
        }
        .opacity(isDisabled ? 0.6 : 1)
        // The empty parts of the card are the field too — the padding above the first line, the
        // margins beside the paperclip. A *background* tap-catcher rather than a gesture on the whole
        // card: a simultaneous tap here fired in the same event as the field's own focus handling and
        // mutated `@FocusState` underneath it, which is what crashed the app on some taps. A shape
        // behind the field cannot compete with the field's own hit test, and it cannot take a tap
        // from a button drawn on top of it.
        .background {
            if !isDisabled {
                RoundedRectangle(cornerRadius: Tokens.radiusComposer, style: .continuous)
                    .fill(Color.clear)
                    .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusComposer,
                                                style: .continuous))
                    .onTapGesture { requestFocus() }
            }
        }
    }

    /// Ask for the caret from a tap on the card's padding.
    ///
    /// Off the gesture's own stack on purpose: setting `@FocusState` while SwiftUI is still handling
    /// that touch is what made the app fall over. One runloop turn later is the same thing to the
    /// reader and a different thing to the framework.
    private func requestFocus() {
        guard !isDisabled, !isFieldFocused else { return }
        Task { @MainActor in focusField() }
    }

    /// Put the caret in the field, wherever the tap landed.
    private func focusField() {
        guard !isDisabled else { return }
        #if os(macOS)
        editorFocused = true
        #else
        focused = true
        #endif
    }

    /// One line is a capsule; a paragraph is not.
    ///
    /// `Capsule()` makes the radius half the height, so a field that has grown to eight lines turns
    /// into a lozenge with semicircular ends — a shape that says "button", not "text field". The
    /// radius is capped at the single-line half-height instead, which is the same circle on one line
    /// and a sane rounded rectangle on eight.
    static let floatingRadius: CGFloat = 26

    static var floatingShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: floatingRadius, style: .continuous)
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
            // The transcript's rhythm, so a message is the same shape in the field as on the page.
            .lineSpacing(TypeScale.chatLineSpacing)
            .padding(.vertical, lineInset)
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

    /// The attach button. A **plus**, not a paperclip: it opens a menu of things to add, and a
    /// plus says "add" without promising that everything behind it is a file.
    ///
    /// It wears a ring, the way Rakazo's does: an unstroked glyph in a floating capsule read as
    /// loose punctuation rather than a button, and the ring is what says "this is pressable" before
    /// the cursor arrives. Hover fills it brighter; the ring stays.
    @ViewBuilder
    private var attachControl: some View {
        let button = ComposerRingButton(glyph: "plus",
                                        label: "Attach a file",
                                        side: controlSide,
                                        glyphSize: glyphSize,
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

/// A circular composer control with a ring, and a fill that brightens under the pointer.
///
/// The glyph is framed by the circle rather than by a square, so the optical centre is the box's
/// centre at every side length the composer uses (26 on the phone, 32 on the Mac).
private struct ComposerRingButton: View {
    let glyph: String
    let label: String
    let side: CGFloat
    let glyphSize: CGFloat
    var isDisabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: glyphSize, weight: .medium))
                .foregroundStyle(isHovering ? Tokens.textPrimary : Tokens.textSecondary)
                .frame(width: side, height: side)
                .background(
                    Circle().fill(isHovering ? Tokens.controlHover : Tokens.control.opacity(0.55))
                )
                .overlay(
                    Circle().strokeBorder(isHovering ? Tokens.borderFocus : Tokens.borderStrong,
                                          lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
        .accessibilityIdentifier("composer.attach")
    }
}
