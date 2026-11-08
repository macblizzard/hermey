import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

// TODO(design-system): a clarify/question card is not in OpenBotUI yet. It is built here
// from the same tokens and controls so the palette stays consistent; swap it for the
// design system's own card when that lands.

/// A question the agent asked, with the choices the host offered plus a free-form answer.
///
/// Clarify is the one request where the user's words are the payload, so the field is always
/// available even when the host supplied choices — a multiple-choice list that cannot be
/// argued with is worse than no choices at all.
struct MacClarifyCard: View {
    let request: ServerRequest
    let presentation: ServerRequestPresentation
    @ObservedObject var store: WorkspaceStore

    @State private var typed = ""
    @FocusState private var focused: Bool

    private var trimmed: String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.accentText)

                SectionCaption("HERMES ASKS", color: Tokens.accentText)

                Spacer(minLength: 8)

                Text(presentation.method)
                    .font(Tokens.mono)
                    .foregroundStyle(Tokens.textDim)
            }

            Text(presentation.command)
                .font(TypeScale.font(Tokens.textMD))
                .lineSpacing(2)
                .foregroundStyle(Tokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !presentation.choices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(presentation.choices, id: \.self) { choice in
                        OpenBotButton(choice, kind: .secondary, size: .small) {
                            Haptics.selection()
                            store.answer(request, choice: choice)
                        }
                    }
                }
                .padding(.top, 1)
            }

            HStack(spacing: 8) {
                TextField("",
                          text: $typed,
                          prompt: Text("Or answer in your own words").foregroundColor(Tokens.textPlaceholder))
                    .textFieldStyle(.plain)
                    .font(TypeScale.font(Tokens.textMD))
                    .foregroundStyle(Tokens.textPrimary)
                    .tint(Tokens.accent)
                    .focused($focused)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                            .fill(Tokens.sheetInset)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                            .strokeBorder(focused ? Tokens.borderFocus : Tokens.borderStrong, lineWidth: 1)
                    )
                    .onSubmit { submit() }
                    .accessibilityLabel("Your answer")

                OpenBotButton("Answer",
                              systemImage: "arrow.up",
                              kind: .primary,
                              size: .small,
                              isDisabled: trimmed.isEmpty) {
                    submit()
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .fill(Tokens.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .strokeBorder(Tokens.accentSoft, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        Haptics.selection()
        store.submitClarification(request, text: trimmed)
        typed = ""
    }
}

// MARK: - Previews

private struct MacClarifyCardPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    private var request: ServerRequest {
        ServerRequest(id: .string("srq-11"),
                      method: "clarify",
                      params: .object([
                        "question": .string("Which vault should I back up first? The work vault is 40 GB, the personal one 6 GB."),
                        "choices": .array([.string("personal"), .string("work"), .string("both, smallest first")]),
                      ]))
    }

    var body: some View {
        MacClarifyCard(request: request, presentation: ServerRequestPresentation(request), store: store)
            .frame(width: Geometry.conversationMeasure)
            .padding(20)
            .background(Tokens.canvas)
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Clarify card") {
    MacClarifyCardPreview()
}
#endif
