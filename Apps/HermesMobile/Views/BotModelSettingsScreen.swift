import SwiftUI
import HermesKit
import OpenBotUI

/// A profile default is distinct from any live session override. The caller supplies
/// profile-scoped gateway operations; this screen never creates or replaces a chat.
struct BotModelSettingsScreen: View {
    enum SaveResult {
        case saved
        case confirmationRequired(String)
    }

    let bot: Bot
    /// The portrait the host has for this bot, when it has one — the sheet shows the face the list
    /// shows, so it is recognisable before its title is read.
    var icon: BotFace? = nil
    let load: (String) async throws -> ModelCatalog
    /// True when this bot's conversation is the one currently open. A live conversation keeps the
    /// model it was created with — the gateway pins it per session and offers no way to change it —
    /// so the only way to apply a new default to it is to start it over.
    var conversationIsOpen: Bool = false
    var resetConversation: (() async -> Void)? = nil
    let save: (String, ModelOption, Bool) async throws -> SaveResult
    /// Writes the human-readable description on the host (`profiles.configure`, description
    /// section). `nil` hides the editor entirely — a client that cannot write it must not offer it.
    var saveDescription: ((String, String) async throws -> Void)? = nil
    /// Opens this bot's real SOUL.md. `nil` hides the row: a client that cannot write it must not
    /// offer it, the same rule the description follows.
    var editSoul: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var catalog: ModelCatalog?
    @State private var error: String?
    @State private var busy = false
    @State private var pending: ModelOption?
    @State private var confirmation = ""
    @State private var modelQuery = ""

    @State private var descriptionText: String
    @State private var savedDescription: String
    @State private var descriptionBusy = false
    @State private var descriptionError: String?
    @State private var descriptionSaved = false

    init(bot: Bot,
         icon: BotFace? = nil,
         load: @escaping (String) async throws -> ModelCatalog,
         conversationIsOpen: Bool = false,
         resetConversation: (() async -> Void)? = nil,
         save: @escaping (String, ModelOption, Bool) async throws -> SaveResult,
         saveDescription: ((String, String) async throws -> Void)? = nil,
         editSoul: (() -> Void)? = nil) {
        self.bot = bot
        self.icon = icon
        self.load = load
        self.conversationIsOpen = conversationIsOpen
        self.resetConversation = resetConversation
        self.save = save
        self.saveDescription = saveDescription
        self.editSoul = editSoul
        _descriptionText = State(initialValue: bot.description ?? "")
        _savedDescription = State(initialValue: bot.description ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(Tokens.danger)
                }
                soulSection
                descriptionSection
                if let catalog {
                    if let current = catalog.current {
                        Section("Profile default") {
                            Text("\(current.label) · \(current.provider)")
                        }
                    }
                    Section {
                        ForEach(filteredOptions(catalog), id: \.self) { option in
                            Button {
                                Task { await select(option, confirmed: false) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(option.label)
                                        Text(option.provider).font(.caption).foregroundStyle(Tokens.textSecondary)
                                    }
                                    Spacer()
                                    if option.id == catalog.current?.id && option.provider == catalog.current?.provider {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }.disabled(busy)
                        }
                    } header: {
                        Text("Models")
                    } footer: {
                        Text(conversationIsOpen
                             ? "This becomes the bot's default. The conversation you have open keeps the model it started with — reset it to use the new one."
                             : "This becomes the bot's default for new conversations with this bot.")
                    }
                    if conversationIsOpen, let resetConversation {
                        Section {
                            Button("Reset this conversation to use it") {
                                Task { await resetConversation(); dismiss() }
                            }
                        }
                    }
                } else if error == nil {
                    ProgressView("Loading models…")
                }
            }
            .searchable(text: $modelQuery, prompt: "Search models")
            .navigationTitle("\(bot.displayName) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The portrait it wears in the list, so this sheet is recognisable before the title
                // is read.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        BotIconPortrait(icon ?? BotFace.default(for: bot.id), size: 24)
                        Text(bot.displayName)
                            .font(TypeScale.font(TypeScale.md, weight: .semibold))
                            .foregroundStyle(Tokens.textPrimary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await refresh() }
            .alert("Confirm model", isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            )) {
                Button("Cancel", role: .cancel) { pending = nil }
                Button("Confirm") {
                    guard let option = pending else { return }
                    pending = nil
                    Task { await select(option, confirmed: true) }
                }
            } message: { Text(confirmation) }
        }
    }

    // MARK: Soul

    /// The bot's own text, the thing that makes it that bot rather than another one with a
    /// different name. It is a file on the host, edited as text, not a set of switches.
    @ViewBuilder
    private var soulSection: some View {
        if let editSoul {
            Section {
                Button(action: editSoul) {
                    Label("Edit SOUL.md", systemImage: "doc.text")
                }
            } header: {
                Text("Identity")
            } footer: {
                Text("The prompt this bot is built on. Saved to the host; a conversation already open keeps the soul it started with until it is reset.")
            }
        }
    }

    // MARK: Description

    @ViewBuilder
    private var descriptionSection: some View {
        if let saveDescription {
            Section {
                TextField("What this bot does", text: $descriptionText, axis: .vertical)
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.sentences)
                    .disabled(descriptionBusy)
                Button {
                    Task { await writeDescription(saveDescription) }
                } label: {
                    HStack {
                        if descriptionBusy { ProgressView().controlSize(.small) }
                        Text("Save description")
                    }
                }
                .disabled(descriptionBusy || trimmedDescription == savedDescription)
                if let descriptionError {
                    Text(descriptionError).font(.caption).foregroundStyle(Tokens.danger)
                } else if descriptionSaved {
                    Text("Saved").font(.caption).foregroundStyle(Tokens.textSecondary)
                }
            } header: {
                Text("Description")
            } footer: {
                Text("Shown under this bot's name in the list. Stored on the host, so it follows the bot to every device.")
            }
        }
    }

    private var trimmedDescription: String {
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeDescription(_ write: @escaping (String, String) async throws -> Void) async {
        descriptionBusy = true
        descriptionError = nil
        descriptionSaved = false
        defer { descriptionBusy = false }
        let text = trimmedDescription
        do {
            try await write(bot.id, text)
            descriptionText = text
            savedDescription = text
            descriptionSaved = true
        } catch {
            descriptionError = error.localizedDescription
        }
    }

    // MARK: Models

    /// The catalogue is long (dozens of entries across providers), so it is searchable.
    private func filteredOptions(_ catalog: ModelCatalog) -> [ModelOption] {
        let query = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog.options }
        return catalog.options.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.provider.localizedCaseInsensitiveContains(query)
        }
    }

    private func refresh() async {
        do { catalog = try await load(bot.id); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func select(_ option: ModelOption, confirmed: Bool) async {
        busy = true
        defer { busy = false }
        do {
            switch try await save(bot.id, option, confirmed) {
            case .saved: await refresh()
            case .confirmationRequired(let message):
                confirmation = message
                pending = option
            }
        } catch { self.error = error.localizedDescription }
    }
}
