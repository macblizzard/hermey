import OpenBotUI
import SwiftUI

// TODO(design-system): no inline error strip exists in OpenBotUI yet (the connection
// banner covers transport, not a failed send).

/// A send that failed, above the composer — with the draft still in the field.
///
/// Retry is offered only when there is something to retry: the model restores the text it
/// could not send, so pressing Retry re-sends exactly what the user wrote.
struct MacErrorStrip: View {
    let message: String
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Tokens.danger)

            Text(message)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let onRetry {
                TextButton("Retry", tone: Tokens.accentText, action: onRetry)
            }

            OpenBotIconButton("xmark", label: "Dismiss this error", size: .small) {
                onDismiss()
            }
        }
        .padding(.horizontal, Geometry.readingInset)
        .padding(.vertical, 7)
        .background(Tokens.dangerSoft)
        .overlay(alignment: .top) { Hairline(color: Tokens.borderStrong) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

private struct MacErrorStripPreview: View {
    var body: some View {
        VStack(spacing: 0) {
            MacErrorStrip(message: "session.submit timed out after 30s — the turn never reached the host.",
                          onRetry: {},
                          onDismiss: {})
            MacErrorStrip(message: "Not connected.",
                          onRetry: nil,
                          onDismiss: {})
            Spacer()
        }
        .frame(width: Geometry.conversationMeasure, height: 180, alignment: .top)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Error strip") {
    MacErrorStripPreview()
}
#endif
