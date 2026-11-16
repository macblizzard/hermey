import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The copy button a code block wears, on both platforms.
///
/// A copy that gives no answer is a copy the person repeats. The glyph becomes a tick where it
/// stands — not a toast, not a banner — so the confirmation appears in the corner of the eye that
/// pressed the button, and it goes back to the clipboard glyph on its own.
///
/// One component for both shells: the phone had no copy button at all, and the desktop's had no
/// answer, which is the same defect seen from two sides.
public struct CodeCopyButton: View {
    /// The exact text the block drew — copied verbatim, never re-wrapped and never re-indented.
    public let code: String
    /// How long the tick stays up. Long enough to be noticed, short enough not to lie.
    public var confirmation: TimeInterval = 1.5

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    public init(code: String, confirmation: TimeInterval = 1.5) {
        self.code = code
        self.confirmation = confirmation
    }

    public var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Tokens.success : Tokens.textDim)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: copied)
        #if os(macOS)
        .help(copied ? "Copied" : "Copy this code block")
        #endif
        .accessibilityLabel(copied ? "Copied" : "Copy this code block")
    }

    private func copy() {
        Haptics.selection()
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif

        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(confirmation * 1_000_000_000))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
