import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

// TODO(design-system): no "unsupported request" state exists in OpenBotUI yet.

/// A request this build cannot render.
///
/// It shows the method and the exact params (selectable, mono) and offers one honest verb:
/// Decline, which answers `-32601` so the agent fails in one round trip instead of hanging
/// until clarify's timeout. Pretending to handle it would be worse than saying so.
struct MacUnknownRequestCard: View {
    let request: ServerRequest
    let presentation: ServerRequestPresentation
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.warning)

                SectionCaption("REQUEST THIS BUILD CANNOT ANSWER", color: Tokens.warning)

                Spacer(minLength: 8)

                Text(presentation.method)
                    .font(Tokens.mono)
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
            }

            Text(presentation.rawJSON)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(Tokens.sheetInset)
                )

            HStack(spacing: 8) {
                Text("Declining lets the agent move on.")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textDim)

                Spacer(minLength: 8)

                OpenBotButton("Decline", kind: .danger, size: .small) {
                    Haptics.selection()
                    store.decline(request)
                }
            }
        }
        .padding(12)
        .cardSurface()
    }
}

// MARK: - Previews

private struct MacUnknownRequestCardPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    private var request: ServerRequest {
        ServerRequest(id: .string("srq-12"),
                      method: "theme.pick",
                      params: .object([
                        "palette": .string("dark"),
                        "options": .array([.string("dark"), .string("light")]),
                      ]))
    }

    var body: some View {
        MacUnknownRequestCard(request: request,
                              presentation: ServerRequestPresentation(request),
                              store: store)
            .frame(width: Geometry.conversationMeasure)
            .padding(20)
            .background(Tokens.canvas)
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Unsupported request") {
    MacUnknownRequestCardPreview()
}
#endif
