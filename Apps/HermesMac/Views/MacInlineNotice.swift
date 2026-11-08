import OpenBotUI
import SwiftUI

// TODO(design-system): no inline notice row exists in OpenBotUI yet — the connection banner
// speaks transport states, not "the host refused your token".

/// One sentence and, optionally, the verb that fixes it.
///
/// Used for failures whose text matters and whose copy the banner cannot know: a refused
/// token, a malformed ticket response. The message is shown exactly as the host phrased it,
/// so the user can act on the real reason.
struct MacInlineNotice: View {
    let message: String
    var tone: Color = Tokens.warning
    var soft: Color = Tokens.warningSoft
    var actionTitle: String?
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone)

            Text(message)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                TextButton(actionTitle, tone: Tokens.accentText, action: action)
            }
        }
        .padding(.horizontal, Geometry.readingInset)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(soft)
        .overlay(alignment: .bottom) { Hairline(color: Tokens.borderStrong) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

private struct MacInlineNoticePreview: View {
    var body: some View {
        VStack(spacing: 0) {
            MacInlineNotice(message: "the host refused the device token (401): unknown device or bad refresh token",
                            actionTitle: "Pair host…",
                            action: {})
            MacInlineNotice(message: "the host's token response had no ws_ticket",
                            tone: Tokens.danger,
                            soft: Tokens.dangerSoft)
            Spacer()
        }
        .frame(width: Geometry.conversationMeasure, height: 200, alignment: .top)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Inline notice") {
    MacInlineNoticePreview()
}
#endif
