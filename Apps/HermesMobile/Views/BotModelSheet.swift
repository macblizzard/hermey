import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// A bot's model, effort level and aux/vision model — the phone's half of the desktop's three columns.
///
/// Asked for 2026-11-17: "on mobile there is no model sheet on the bot menu sidebar, its still inside the
/// edit menu only. pls remove the model selection from edit menu on mobile and make it just like the
/// desktop in the bot menu sidebar with all the same options like the desktop version".
///
/// A phone has one column, not three, so the same three answers are three rows that each open their own
/// list: Provider → Model → Effort, with the aux/vision model underneath as its own row. The order is the
/// desktop's, the vocabulary is the desktop's, and the two reads are the desktop's too — the catalogue
/// from `model.options`, the effort level and aux model from the bot's own config, so a host that cannot
/// answer the second read leaves those rows inert instead of claiming "provider default".
struct BotModelSheet: View {
    let bot: Bot
    @ObservedObject var model: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var catalog: ModelCatalog?
    @State private var settings: BotModelSettings?
    @State private var error: String?
    @State private var busy = false
    @State private var pending: ModelOption?
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.danger)
                }

                currentSection
                if let catalog {
                    providerSection(catalog)
                    modelSection(catalog)
                }
                effortSection
                auxSection(catalog)

                if model.selectedBotID == bot.id {
                    Section {
                        Text("The conversation you have open keeps the model it started with — reset it to use a new one. The effort level applies from the next turn.")
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textMuted)
                    }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                    .hermeyFocusQuiet()
                }
            }
            .task { await refresh() }
            .alert("Confirm model", isPresented: pendingBinding) {
                Button("Cancel", role: .cancel) { pending = nil }
                .hermeyFocusQuiet()
                Button("Confirm") {
                    guard let option = pending else { return }
                    pending = nil
                    Task { await select(option, confirmed: true) }
                }
                .hermeyFocusQuiet()
            } message: {
                Text(confirmation)
            }
        }
    }

    // MARK: - Current

    @ViewBuilder
    private var currentSection: some View {
        Section("Current") {
            if let current = catalog?.current {
                row(title: current.label, detail: "\(current.provider) · \(current.id)")
            } else if error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the model catalogue…")
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textMuted)
                }
            }
        }
    }

    // MARK: - Provider → model → effort

    private func providerSection(_ catalog: ModelCatalog) -> some View {
        Section("Provider") {
            NavigationLink {
                providerList(catalog)
            } label: {
                row(title: catalog.current?.provider ?? "Choose a provider",
                    detail: "\(providers(catalog).count) available")
            }
            .hermeyFocusQuiet()
        }
    }

    private func providerList(_ catalog: ModelCatalog) -> some View {
        List(providers(catalog), id: \.self) { name in
            Button {
                model_pick(catalog, provider: name)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).foregroundStyle(Tokens.textPrimary)
                        Text("\(catalog.options.filter { $0.provider == name }.count) models")
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textMuted)
                    }
                    Spacer()
                    if catalog.current?.provider == name {
                        Image(systemName: "checkmark").foregroundStyle(Tokens.accentText)
                    }
                }
            }
            .hermeyFocusQuiet()
        }
        .navigationTitle("Provider")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modelSection(_ catalog: ModelCatalog) -> some View {
        Section("Model") {
            NavigationLink {
                modelList(catalog)
            } label: {
                row(title: catalog.current?.label ?? "Choose a model",
                    detail: catalog.current.map { $0.provider } ?? "—")
            }
            .hermeyFocusQuiet()
        }
    }

    /// Every model the host offers, grouped by provider — the desktop's middle column, one level down.
    private func modelList(_ catalog: ModelCatalog) -> some View {
        List {
            ForEach(providers(catalog), id: \.self) { name in
                Section(name) {
                    ForEach(catalog.options.filter { $0.provider == name }, id: \.self) { option in
                        Button {
                            Task { await select(option, confirmed: false) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label).foregroundStyle(Tokens.textPrimary)
                                    Text(option.id)
                                        .font(TypeScale.font(TypeScale.caption))
                                        .foregroundStyle(Tokens.textMuted)
                                }
                                Spacer()
                                if option.id == catalog.current?.id
                                    && option.provider == catalog.current?.provider {
                                    Image(systemName: "checkmark").foregroundStyle(Tokens.accentText)
                                }
                            }
                        }
                        .disabled(busy)
                        .hermeyFocusQuiet()
                    }
                }
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var effortSection: some View {
        Section {
            if let settings {
                NavigationLink {
                    effortList(settings)
                } label: {
                    row(title: settings.label(for: settings.effort), detail: "How hard it thinks")
                }
                .hermeyFocusQuiet()
            } else {
                // The level lives in the bot's config: unread is unread, not "provider default".
                row(title: "Reading the bot's config…", detail: "")
                    .foregroundStyle(Tokens.textMuted)
            }
        } header: {
            Text("Effort")
        } footer: {
            Text("Set per bot, on the host. \"Provider default\" leaves it to whatever the model does on its own; \"Off\" disables thinking.")
        }
    }

    private func effortList(_ settings: BotModelSettings) -> some View {
        List(settings.efforts) { level in
            Button {
                Task { await setEffort(level.id) }
            } label: {
                HStack {
                    Text(level.label).foregroundStyle(Tokens.textPrimary)
                    Spacer()
                    if settings.effort == level.id {
                        Image(systemName: "checkmark").foregroundStyle(Tokens.accentText)
                    }
                }
            }
            .disabled(busy)
            .hermeyFocusQuiet()
        }
        .navigationTitle("Effort")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Aux / vision

    @ViewBuilder
    private func auxSection(_ catalog: ModelCatalog?) -> some View {
        Section {
            if let catalog, let settings {
                NavigationLink {
                    visionList(catalog, settings: settings)
                } label: {
                    row(title: settings.visionInherits
                        ? "Inherit the bot's model"
                        : settings.visionModel,
                        detail: settings.visionInherits
                            ? (catalog.current?.label ?? "the main model")
                            : settings.visionProvider)
                }
                .hermeyFocusQuiet()
            } else {
                row(title: "Reading the bot's config…", detail: "")
                    .foregroundStyle(Tokens.textMuted)
            }
        } header: {
            Text("Aux · Vision model")
        } footer: {
            Text("The model that looks at pictures. Inheriting sends them to whatever answers the bot's turns; a separate one is cheaper when the main model is expensive.")
        }
    }

    private func visionList(_ catalog: ModelCatalog, settings: BotModelSettings) -> some View {
        List {
            Section {
                Button {
                    Task { await setVision(provider: "auto", visionModel: "") }
                } label: {
                    HStack {
                        Text("Inherit the bot's model").foregroundStyle(Tokens.textPrimary)
                        Spacer()
                        if settings.visionInherits {
                            Image(systemName: "checkmark").foregroundStyle(Tokens.accentText)
                        }
                    }
                }
                .hermeyFocusQuiet()
            }
            ForEach(providers(catalog), id: \.self) { name in
                Section(name) {
                    ForEach(catalog.options.filter { $0.provider == name }, id: \.self) { option in
                        Button {
                            Task { await setVision(provider: option.provider,
                                                   visionModel: option.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label).foregroundStyle(Tokens.textPrimary)
                                    Text(option.id)
                                        .font(TypeScale.font(TypeScale.caption))
                                        .foregroundStyle(Tokens.textMuted)
                                }
                                Spacer()
                                if !settings.visionInherits,
                                   settings.visionProvider == option.provider,
                                   settings.visionModel == option.id {
                                    Image(systemName: "checkmark").foregroundStyle(Tokens.accentText)
                                }
                            }
                        }
                        .disabled(busy)
                        .hermeyFocusQuiet()
                    }
                }
            }
        }
        .navigationTitle("Vision model")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Plumbing

    private func providers(_ catalog: ModelCatalog) -> [String] {
        var seen: [String] = []
        for option in catalog.options where !seen.contains(option.provider) {
            seen.append(option.provider)
        }
        return seen
    }

    private func row(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(TypeScale.font(TypeScale.sm, weight: .medium))
                .foregroundStyle(Tokens.textPrimary)
            if !detail.isEmpty {
                Text(detail)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            }
        }
    }

    /// Naming a provider is only a filter on the way to a model, so it sets the picker that the model list
    /// reads — the phone keeps the desktop's order without three live columns.
    private func model_pick(_ catalog: ModelCatalog, provider: String) {
        // The chosen provider's current model, or its first: a provider row that changes nothing when
        // tapped would be a dead control.
        guard let option = catalog.options.first(where: { $0.provider == provider }) else { return }
        Task { await select(option, confirmed: false) }
    }

    private var pendingBinding: Binding<Bool> {
        Binding(get: { pending != nil },
                set: { presented in if !presented { pending = nil } })
    }

    private func refresh() async {
        do {
            catalog = try await model.modelCatalog(for: bot.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        settings = try? await model.modelSettings(for: bot.id)
    }

    private func select(_ option: ModelOption, confirmed: Bool) async {
        busy = true
        defer { busy = false }
        do {
            switch try await model.configureModel(botID: bot.id, model: option.id,
                                                  provider: option.provider, confirm: confirmed) {
            case .applied:
                await refresh()
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

    private func setVision(provider: String, visionModel: String) async {
        busy = true
        defer { busy = false }
        do {
            settings = try await model.setModelSettings(for: bot.id, visionProvider: provider,
                                                        visionModel: visionModel)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
