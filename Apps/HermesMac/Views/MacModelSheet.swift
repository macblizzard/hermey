import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// Which model this bot thinks with — its own door, off the bot's pill panel.
///
/// It used to live at the bottom of Bot settings, under the icon, the soul and the description: a
/// catalogue of dozens of providers in a sheet you opened to change a description, so the delete
/// verb was a scroll away from a long list that had nothing to do with it (reported 2026-11-14).
/// A model is a fact about how the bot answers, not who it is, so it gets the panel row the other
/// facts get.
///
/// ## Three answers, three columns
///
/// Asked for 2026-11-17: "update model selection sheet to include provider, then model, then effort
/// level. also add option to select aux/vision model". The catalogue is a list of providers *of* lists
/// of models, and one flat list of a thousand names hides which account a pick bills; the effort level
/// is a fact about the pick rather than about the bot, so it sits beside the model it modifies. Provider
/// → model → effort, left to right, with the aux/vision model underneath because it is a second,
/// smaller question of the same shape.
///
/// The two halves come from different places on the host and are read separately: the catalogue from
/// `model.options`, the effort level and the aux model from the bot's own config. A host without the
/// config route still draws the catalogue, with the effort column disabled rather than wrong.
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
    @State private var settings: BotModelSettings?
    @State private var error: String?
    @State private var busy = false
    @State private var pending: ModelOption?
    @State private var confirmation = ""
    @State private var provider: String?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Hairline()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if let error {
                        Text(error)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let catalog {
                        currentSection(catalog)
                        columns(catalog)
                        auxSection(catalog)
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
        .frame(width: 720)
        .frame(minHeight: 460, idealHeight: 580, maxHeight: 660)
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
            HermeyButton("Done", kind: .secondary, size: .small) { dismiss() }
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

            if let settings {
                Text("Effort: \(settings.label(for: settings.effort))")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            }
        }
    }

    // MARK: - Provider → model → effort

    private func columns(_ catalog: ModelCatalog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption("PROVIDER · MODEL · EFFORT")

            HStack(alignment: .top, spacing: 10) {
                providerColumn(catalog)
                modelColumn(catalog)
                effortColumn
            }

            Text(conversationIsOpen
                 ? "The model becomes this bot's default. The conversation you have open keeps the model it started with — reset it to use the new one. The effort level applies from the next turn."
                 : "This becomes the bot's default for new conversations with this bot.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providers: [String] {
        guard let catalog else { return [] }
        var seen: [String] = []
        for option in catalog.options where !seen.contains(option.provider) {
            seen.append(option.provider)
        }
        return seen
    }

    /// One row per provider, with its model count. Choosing a provider narrows the middle column instead
    /// of picking a model the person has not seen yet.
    private func providerColumn(_ catalog: ModelCatalog) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(providers, id: \.self) { name in
                    let count = catalog.options.filter { $0.provider == name }.count
                    let isCurrentProvider = catalog.current?.provider == name
                    let isChosen = (provider ?? catalog.current?.provider) == name

                    Button {
                        provider = name
                        query = ""
                    } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(name)
                                    .font(TypeScale.font(Tokens.textSM,
                                                         weight: isChosen ? .semibold : .regular))
                                    .foregroundStyle(Tokens.textPrimary)
                                    .lineLimit(1)
                                Text("\(count) model\(count == 1 ? "" : "s")")
                                    .font(TypeScale.font(TypeScale.caption))
                                    .foregroundStyle(Tokens.textMuted)
                            }
                            Spacer(minLength: 4)
                            if isCurrentProvider {
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
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                            .fill(isChosen ? Tokens.controlActive : .clear))
                    .disabled(busy)
                }
            }
        }
        .frame(width: 190)
        .frame(height: 214)
    }

    private func modelColumn(_ catalog: ModelCatalog) -> some View {
        let chosen = provider ?? catalog.current?.provider
        let options = filteredOptions(catalog, provider: chosen)

        return VStack(alignment: .leading, spacing: 4) {
            MacSidebarSearchField(text: $query, prompt: "Search models")

            if options.isEmpty {
                Text("No models match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(options, id: \.self) { option in
                            optionRow(option, current: catalog.current)
                        }
                    }
                }
                .frame(height: 178)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The level this bot is pinned to, not the model's default: it lives in the profile's config, which is
    /// why it is written through the model-settings route rather than the catalogue's.
    private var effortColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            let levels = settings?.efforts ?? BotModelSettings.standardEfforts
            ForEach(levels) { level in
                let isChosen = (settings?.effort ?? "") == level.id
                Button {
                    Task { await setEffort(level.id) }
                } label: {
                    HStack(spacing: 6) {
                        Text(level.label)
                            .font(TypeScale.font(Tokens.textSM, weight: isChosen ? .semibold : .regular))
                            .foregroundStyle(Tokens.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if isChosen {
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
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                        .fill(isChosen ? Tokens.controlActive : .clear))
                .disabled(busy || settings == nil)
            }

            if settings == nil {
                // A host that cannot answer the config route leaves this column inert rather than
                // pretending every bot is on the provider default.
                Text("The bot's config could not be read.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .frame(width: 150, alignment: .leading)
    }

    // MARK: - Aux / vision

    /// The model that looks at pictures: a second provider → model pair, smaller, because it answers a
    /// narrower question and inheriting the bot's own model is the sensible default.
    private func auxSection(_ catalog: ModelCatalog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption("AUX · VISION MODEL")

            Text(settings.map { settings in
                settings.visionInherits
                    ? "Inheriting the bot's own model — \(catalog.current?.label ?? "the main model")."
                    : "\(settings.visionModel) · \(settings.visionProvider)"
            } ?? "Reading the bot's config…")
                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                .foregroundStyle(Tokens.textPrimary)
                .lineLimit(1)

            HStack(alignment: .top, spacing: 10) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        auxChoice(label: "Inherit the bot's model", provider: "auto", model: "",
                                  chosen: settings?.visionInherits == true)
                        ForEach(providers, id: \.self) { name in
                            auxChoice(label: name, provider: name,
                                      model: firstModel(catalog, provider: name) ?? "",
                                      chosen: settings?.visionProvider == name
                                          && settings?.visionInherits == false)
                        }
                    }
                }
                .frame(width: 190)
                .frame(height: 132)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Model for pictures")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)

                    let auxProviderName = settings?.visionInherits == false
                        ? (settings?.visionProvider ?? "")
                        : auxDefaultProvider
                    let options = filteredOptions(catalog, provider: auxProviderName)
                    if options.isEmpty {
                        Text("No models for this provider.")
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.textMuted)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(options, id: \.self) { option in
                                    auxModelRow(option)
                                }
                            }
                        }
                        .frame(height: 112)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Left on inherit, pictures go to whatever model answers this bot's turns. A separate vision model is cheaper when the main one is expensive — it is the model `vision_analyze` and the host's own image handling call.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var auxDefaultProvider: String {
        catalog?.current?.provider ?? providers.first ?? ""
    }

    private func auxChoice(label: String, provider: String, model: String, chosen: Bool) -> some View {
        Button {
            Task { await setVision(provider: provider, visionModel: model) }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(TypeScale.font(Tokens.textSM, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if chosen {
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
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                .fill(chosen ? Tokens.controlActive : .clear))
        .disabled(busy || settings == nil)
    }

    private func auxModelRow(_ option: ModelOption) -> some View {
        let chosen = settings?.visionProvider == option.provider
            && settings?.visionModel == option.id
            && settings?.visionInherits == false
        return Button {
            Task { await setVision(provider: option.provider, visionModel: option.id) }
        } label: {
            HStack(spacing: 6) {
                Text(option.label)
                    .font(TypeScale.font(Tokens.textSM, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if chosen {
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
        .disabled(busy)
    }

    private func firstModel(_ catalog: ModelCatalog, provider: String) -> String? {
        catalog.options.first { $0.provider == provider }?.id
    }

    // MARK: - Rows

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

                    // The id, not the provider: the provider is the column this row lives in, and the id
                    // is what two same-named models on different providers differ by.
                    Text(option.id)
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

    /// Search narrows whichever provider column is selected; no provider shows everything, which is how a
    /// model whose provider the person cannot name is still reachable.
    private func filteredOptions(_ catalog: ModelCatalog, provider: String?) -> [ModelOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.options.filter { option in
            (provider == nil || provider == "" || option.provider == provider)
                && (trimmed.isEmpty
                    || option.label.localizedCaseInsensitiveContains(trimmed)
                    || option.id.localizedCaseInsensitiveContains(trimmed)
                    || option.provider.localizedCaseInsensitiveContains(trimmed))
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
        // The effort level and the aux model live in the bot's config, which is a second, independent
        // read: a host without that route leaves the effort column inert rather than wrong.
        settings = try? await model.modelSettings(for: bot.id)
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
                    await store.refreshHermeyModelLabel()
                }
            case .confirmationRequired(let message):
                confirmation = message
                pending = option
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setEffort(_ level: String) async {
        busy = true
        defer { busy = false }
        do {
            settings = try await model.setModelSettings(for: bot.id, effort: level)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// `visionModel`, not `model`: the property of that name is the app model this sheet writes through,
    /// and a parameter called `model` shadows it into a String (which has no setModelSettings, and the
    /// compiler says so in a way that reads like a library bug).
    private func setVision(provider: String, visionModel: String) async {
        busy = true
        defer { busy = false }
        do {
            settings = try await model.setModelSettings(for: bot.id,
                                                       visionProvider: provider,
                                                       visionModel: visionModel)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
