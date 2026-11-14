import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// Which model this bot thinks with — its own door, off the bot's pill panel.
///
/// It used to live at the bottom of Bot settings, under the icon, the soul and the description: a
/// catalogue of dozens of providers in a sheet you opened to change a description, so the delete
/// verb was a scroll away from a long list that had nothing to do with it (reported 2026-11-14).
/// A model is a fact about how the bot answers, not who it is, so it gets the panel row the other
/// facts get.
///
/// The confirmation gate is the host's, not this sheet's: a refusal comes back as
/// `.confirmationRequired(message)` and is only retried with `confirm: true` after the user reads
/// that sentence. A live conversation keeps the model it was created with — the host pins it per
/// session — so the footer says what changing the default does and does not do.
struct MacModelSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore
    let bot: Bot
    /// True when this bot's conversation is the one on screen (the copy differs, the write does not).
    let conversationIsOpen: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var catalog: ModelCatalog?
    @State private var error: String?
    @State private var busy = false
    @State private var pending: ModelOption?
    @State private var confirmation = ""
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Hairline()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let error {
                        Text(error)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let catalog {
                        currentSection(catalog)
                        modelsSection(catalog)
                    } else if error == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading the model catalogue…")
                                .font(TypeScale.font(TypeScale.caption))
                                .foregroundStyle(Tokens.textMuted)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 520)
        .frame(minHeight: 420, idealHeight: 520, maxHeight: 560)
        .background(Tokens.canvas)
        .task { await refresh() }
        .alert("Confirm model", isPresented: pendingBinding) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Confirm") {
                guard let option = pending else { return }
                pending = nil
                Task { await select(option, confirmed: true) }
            }
        } message: {
            Text(confirmation)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            SectionCaption("MODEL")
            Spacer(minLength: 8)
            OpenBotButton("Done", kind: .secondary, size: .small) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func currentSection(_ catalog: ModelCatalog) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionCaption("PROFILE DEFAULT")
            Text(catalog.current.map { "\($0.label) · \($0.provider)" } ?? "The host named no model.")
                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                .foregroundStyle(catalog.current == nil ? Tokens.textMuted : Tokens.textPrimary)
                .lineLimit(1)
        }
    }

    private func modelsSection(_ catalog: ModelCatalog) -> some View {
        let options = filteredOptions(catalog)

        return VStack(alignment: .leading, spacing: 6) {
            SectionCaption("MODELS")

            MacSidebarSearchField(text: $query, prompt: "Search models")

            if options.isEmpty {
                Text("No models match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(options, id: \.self) { option in
                        optionRow(option, current: catalog.current)
                    }
                }
            }

            Text(conversationIsOpen
                 ? "This becomes the bot's default. The conversation you have open keeps the model it started with — reset it to use the new one."
                 : "This becomes the bot's default for new conversations with this bot.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func optionRow(_ option: ModelOption, current: ModelOption?) -> some View {
        let isCurrent = option.id == current?.id && option.provider == current?.provider
        return Button {
            Task { await select(option, confirmed: false) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.label)
                        .font(TypeScale.font(Tokens.textSM, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)

                    Text(option.provider)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                        .foregroundStyle(Tokens.accentText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(rest: isCurrent ? Tokens.controlActive : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous))
        .disabled(busy)
    }

    /// The catalogue is long (dozens of entries across providers), so it is searchable by label,
    /// id and provider — the same three fields the phone searches.
    private func filteredOptions(_ catalog: ModelCatalog) -> [ModelOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return catalog.options }
        return catalog.options.filter {
            $0.label.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
                || $0.provider.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var pendingBinding: Binding<Bool> {
        Binding(get: { pending != nil },
                set: { presented in
                    if !presented { pending = nil }
                })
    }

    private func refresh() async {
        do {
            catalog = try await model.modelCatalog(for: bot.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Mirrors the phone: ask without consent first, show the host's sentence, and only repeat the
    /// write with `confirm: true` when the user says so.
    private func select(_ option: ModelOption, confirmed: Bool) async {
        busy = true
        defer { busy = false }
        do {
            switch try await model.configureModel(botID: bot.id,
                                                 model: option.id,
                                                 provider: option.provider,
                                                 confirm: confirmed) {
            case .applied:
                await refresh()
                if bot.id == model.selectedBotID {
                    await store.refreshOpenBotModelLabel()
                }
            case .confirmationRequired(let message):
                confirmation = message
                pending = option
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
