import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// One name, asked for once: **New category…** and **Rename “Work”…**.
///
/// A sheet rather than an `alert` with a `TextField`, because the Mac's sheets all share the same
/// chrome (`hermesSheetChrome`) and because a refusal has to be shown where the name was typed —
/// a category is stored on the *host*, so "that name is taken" or "the host is not connected" comes
/// back as an error and the sheet stays open to say it.
struct BotCategorySheet: View {
    let title: String
    let confirmTitle: String
    let explanation: String
    private let commit: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false
    @State private var failure: String?

    /// - Parameter commit: given the trimmed name, returns the sentence to show on failure, or
    ///   `nil` when the host accepted it.
    init(title: String,
         confirmTitle: String,
         explanation: String,
         initialName: String = "",
         commit: @escaping (String) async -> String?) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.explanation = explanation
        self.commit = commit
        _name = State(initialValue: initialName)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption("CATEGORY")

            Text(title)
                .font(TypeScale.font(TypeScale.lg, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)

            Text(explanation)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Category name",
                      text: $name,
                      prompt: Text("Category name").foregroundColor(Tokens.textPlaceholder))
                .textFieldStyle(.plain)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(Tokens.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .strokeBorder(failure == nil ? Tokens.border : Tokens.danger, lineWidth: 1)
                )
                .onSubmit { Task { await save() } }
                .disabled(isSaving)

            if let failure {
                Text(failure)
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                OpenBotButton("Cancel", kind: .ghost, size: .small) { dismiss() }
                    .disabled(isSaving)

                OpenBotButton(isSaving ? "Saving…" : confirmTitle,
                              kind: .primary,
                              size: .small,
                              isDisabled: trimmed.isEmpty || isSaving,
                              isBusy: isSaving) {
                    Task { await save() }
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 400)
        .background(Tokens.canvas)
    }

    /// `@MainActor`: the sheet's own state is written after the host answers, and a task started
    /// here is not main-actor bound on its own.
    @MainActor
    private func save() async {
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        failure = nil
        let problem = await commit(trimmed)
        isSaving = false
        if let problem {
            failure = problem
        } else {
            dismiss()
        }
    }
}

#if DEBUG
#Preview("New category") {
    BotCategorySheet(title: "New category",
                     confirmTitle: "Create",
                     explanation: "Groups live on the host, so the phone and this Mac show the same ones.",
                     commit: { _ in nil })
        .preferredColorScheme(.dark)
}
#endif
