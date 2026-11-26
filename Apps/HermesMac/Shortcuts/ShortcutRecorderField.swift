import AppKit
import HermesKit
import SwiftUI

/// The field that records a shortcut: click it, press a combination, and it reports what you pressed.
///
/// **Why AppKit.** A `keyDown` handler is the only way to see the *combination* rather than the
/// character it produced — SwiftUI's `.onKeyPress` reports a `KeyPress` with modifiers, but it never
/// sees a press the menu bar has already claimed, and the whole point of this field is that ⌘S and
/// ⌘E can be *reassigned*, which means the field has to intercept keys the menu currently owns. A
/// view in the responder chain that implements `performKeyEquivalent(with:)` is asked before the
/// main menu is (`NSWindow` walks its views first), so an armed field eats ⌘S and hands it to the
/// registry instead of hiding the bot panel.
///
/// **The rules, all in this file:**
/// * click (or Tab and Space) arms it — "Press a shortcut…";
/// * ⌘/⌥/⌃/⇧ show while held, so the press in progress is legible;
/// * Escape cancels and leaves the row exactly as it was;
/// * a bare ⌫ clears the row (the app then has no key for it — deliberately, not "back to default";
///   the row's own reset button is the way back to the default);
/// * anything else is reported to the registry, which is the only thing allowed to accept or refuse.
struct ShortcutRecorderField: NSViewRepresentable {

    /// Whether the row can be edited at all (a system-owned row cannot).
    let isEnabled: Bool
    /// Called with the combination the owner pressed. The caller validates it.
    let onCapture: (ShortcutCombo) -> Void
    /// Called for a bare ⌫.
    let onClear: () -> Void
    /// Called when Escape leaves the field.
    let onCancel: () -> Void
    /// Reporting whether the field is armed, so the label can say "Press a shortcut…".
    let onRecordingChanged: (Bool) -> Void
    /// The modifiers currently held, as glyphs, for the "⌘⇧" preview.
    let onPreviewChanged: (String?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: ShortcutRecorderView) {
        view.isEnabled = isEnabled
        view.onCapture = onCapture
        view.onClear = onClear
        view.onCancel = onCancel
        view.onRecordingChanged = onRecordingChanged
        view.onPreviewChanged = onPreviewChanged
    }
}

/// The NSView behind ``ShortcutRecorderField``. Draws nothing: the SwiftUI label above it is the
/// visible field, and this view is the key capture sitting invisibly on top of it.
final class ShortcutRecorderView: NSView {

    /// A system-owned row is drawn but not editable; a disabled recipe field must not arm itself.
    var isEnabled = true

    var onCapture: ((ShortcutCombo) -> Void)?
    var onClear: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onPreviewChanged: ((String?) -> Void)?

    /// Whether the next key press is being taken. Set by the view itself on a click and cleared the
    /// moment a combination, Escape or ⌫ is resolved.
    private(set) var isRecording = false

    // MARK: Being a responder

    override var acceptsFirstResponder: Bool { true }
    /// One click arms the field even when the Settings window is in the background — a recorder that
    /// needed two clicks would look broken.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !isRecording { begin() }
    }

    override func becomeFirstResponder() -> Bool { true }

    override func resignFirstResponder() -> Bool {
        // Clicking elsewhere is a cancel, not a capture: nothing is recorded by accident.
        if isRecording { end(cancelled: true) }
        return true
    }

    // MARK: Recording

    private func begin() {
        guard isEnabled, !isRecording else { return }
        isRecording = true
        onRecordingChanged?(true)
    }

    private func end(cancelled: Bool) {
        guard isRecording else { return }
        isRecording = false
        onRecordingChanged?(false)
        onPreviewChanged?(nil)
        if cancelled { onCancel?() }
        // The field lets go of the keyboard so the rest of the window goes back to normal. Guarded
        // against re-entry: this can be reached *from* `resignFirstResponder`.
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    /// The keys the menu bar would otherwise take. `NSWindow` asks its views before the main menu,
    /// which is what lets ⌘S be recorded here instead of toggling the bot panel.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        return handle(event)
    }

    /// Plain keys: letters, digits, function keys, arrows, Escape, ⌫.
    override func keyDown(with event: NSEvent) {
        guard isRecording, handle(event) else {
            super.keyDown(with: event)
            return
        }
    }

    /// One place both paths land.
    private func handle(_ event: NSEvent) -> Bool {
        // Escape: leave the row alone.
        if event.keyCode == 53 {
            end(cancelled: true)
            return true
        }
        // A bare ⌫ clears. With a modifier it is a combination like any other (⌘⌫ is a real
        // shortcut and is one of the registry's defaults).
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, (event.keyCode == 51 || event.keyCode == 117) {
            end(cancelled: false)
            onClear?()
            return true
        }
        guard let combo = ShortcutCombo(event: event) else {
            // A modifier pressed on its own: show it and keep waiting.
            onPreviewChanged?(Self.glyphs(for: modifiers))
            return true
        }
        end(cancelled: false)
        onCapture?(combo)
        return true
    }

    /// Live feedback while the owner holds modifiers: "⌘" then "⌘⇧".
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        onPreviewChanged?(Self.glyphs(for: modifiers))
    }

    private static func glyphs(for flags: NSEvent.ModifierFlags) -> String? {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text.isEmpty ? nil : text
    }
}

// MARK: - The visible field

/// The chip the pane draws: the current combination, or the invitation to press one.
///
/// The drawing is SwiftUI and the capture is AppKit (``ShortcutRecorderField``). Splitting them means
/// the chip is drawn in the app's own type and colours like every other control in Settings, while
/// the keyboard still goes through the one view that can see a menu-equivalent press.
struct ShortcutKeyChip: View {
    let combo: ShortcutCombo?
    let isEnabled: Bool
    let isRecording: Bool
    let preview: String?
    let message: String?
    let onCapture: (ShortcutCombo) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void
    let onRecordingChanged: (Bool) -> Void
    let onPreviewChanged: (String?) -> Void

    private var text: String {
        if isRecording {
            if let preview { return preview + "…" }
            return "Press a shortcut…"
        }
        return combo?.label ?? "Not set"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .fill(isRecording ? Tokens.accentSoft : Tokens.control)
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .strokeBorder(isRecording ? Tokens.accent : (message == nil ? Tokens.border : Tokens.danger),
                              lineWidth: 1)
            Text(text)
                .font(Tokens.mono)
                .foregroundStyle(isEnabled ? Tokens.textPrimary : Tokens.textMuted)
                .lineLimit(1)
                .padding(.horizontal, 8)
            // The invisible capture view: it sits on top, takes the click, and is the responder that
            // sees the key press before the menu bar does.
            ShortcutRecorderField(isEnabled: isEnabled,
                                  onCapture: onCapture,
                                  onClear: onClear,
                                  onCancel: onCancel,
                                  onRecordingChanged: onRecordingChanged,
                                  onPreviewChanged: onPreviewChanged)
                .accessibilityLabel(isRecording ? "Recording a shortcut" : "Shortcut \(text)")
        }
        .frame(width: 112, height: 24)
        .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        // A pointer press anywhere on the chip arms it — the NSView on top takes the click itself —
        // so the help text is the only thing left to say.
        .help(isEnabled ? "Click, then press a combination" : "macOS owns this one")
    }
}
