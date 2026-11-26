import SwiftUI
import HermesKit
import HermeyUI

/// Who this bot **is**: its name, what it does, its prompt file, what it remembers, and the door
/// that deletes it.
///
/// The model, the effort level and the aux/vision model are not here — they moved to `BotModelSheet`,
/// reached from the drawer's Model row, which is where the desktop keeps them. A catalogue of hundreds of
/// providers inside a sheet you open to change a description is a list in the wrong room, and it put the
/// delete verb a long scroll away from the name you were about to delete (asked for 2026-11-17: "remove the
/// model selection from edit menu on mobile and make it just like the desktop in the bot menu sidebar").
struct BotModelSettingsScreen: View {
    let bot: Bot
    /// The portrait the host has for this bot, when it has one — the sheet shows the face the list
    /// shows, so it is recognisable before its title is read. It is only the fallback colour for a
    /// bot with no generated avatar; the avatar itself arrives through the environment.
    var icon: BotFaceChoice? = nil
    /// Writes the human-readable description on the host (`profiles.configure`, description
    /// section). `nil` hides the editor entirely — a client that cannot write it must not offer it.
    var saveDescription: ((String, String) async throws -> Void)? = nil
    /// Opens this bot's real SOUL.md. `nil` hides the row: a client that cannot write it must not
    /// offer it, the same rule the description follows.
    var editSoul: (() -> Void)? = nil
    /// The three calls the memory pane makes — list, open one, save one. `nil` hides the row: a
    /// client that cannot write memory must not offer an editor.
    var memory: BotMemoryAccess? = nil
    /// Deletes this bot on the host. `nil` hides the row — the rule every verb here follows: a
    /// client that cannot do it must not offer it.
    var deleteBot: (() async throws -> Void)? = nil
    /// The bot's own generated avatar, as the host stores it, and the door to save or clear it.
    /// `nil` for the closure hides the Avatar tab, the same rule as every other verb here.
    ///
    /// The closure takes a `BotAvatarSelection` — one family of face, with the other cleared — so a
    /// Classic pick and a drawn avatar cannot both be stored.
    var avatar: BotAvatarDocument? = nil
    var saveAvatar: ((BotAvatarSelection?) async throws -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var descriptionText: String
    @State private var savedDescription: String
    @State private var descriptionBusy = false
    @State private var descriptionError: String?
    @State private var descriptionSaved = false
    @State private var showingMemory = false
    @State private var showingDelete = false
    @State private var deleteError: String?
    @State private var deleting = false
    /// Which tab is showing: the bot's identity, or its generated avatar.
    @State private var tab: SettingsTab = .about
    /// The face the Avatar tab is showing right now — the editor's draft, reported by
    /// `onFaceChange`. Nil until that tab has appeared, when the header draws the stored face.
    @State private var liveFace: BotAvatarSelection?

    enum SettingsTab: String, CaseIterable, Identifiable {
        case about = "About"
        case avatar = "Avatar"
        var id: String { rawValue }
    }

    init(bot: Bot,
         icon: BotFaceChoice? = nil,
         saveDescription: ((String, String) async throws -> Void)? = nil,
         editSoul: (() -> Void)? = nil,
         memory: BotMemoryAccess? = nil,
         deleteBot: (() async throws -> Void)? = nil,
         avatar: BotAvatarDocument? = nil,
         saveAvatar: ((BotAvatarSelection?) async throws -> Void)? = nil) {
        self.bot = bot
        self.icon = icon
        self.saveDescription = saveDescription
        self.editSoul = editSoul
        self.memory = memory
        self.deleteBot = deleteBot
        self.avatar = avatar
        self.saveAvatar = saveAvatar
        _descriptionText = State(initialValue: bot.description ?? "")
        _savedDescription = State(initialValue: bot.description ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Two tabs, because editing a face is a different job from editing a description.
                // The Avatar tab only exists for a client that can write one.
                if saveAvatar != nil {
                    Picker("Section", selection: $tab) {
                        ForEach(SettingsTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .hermeyFocusQuiet()
                }
                List {
                    if tab == .avatar, let saveAvatar {
                        avatarSection(save: saveAvatar)
                    } else {
                        identitySection
                        descriptionSection
                        dangerSection
                    }
                }
            }
            .navigationTitle("\(bot.displayName) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The portrait it wears in the list, so this sheet is recognisable before the title
                // is read.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        // A settings screen is not a live surface: the face is drawn still, because
                        // nothing here is being asked to show a run. But it is the face being
                        // *edited* while the Avatar tab is open — the editor reports its draft — so
                        // picking a preset moves this head as well as the preview below it.
                        headerAvatar
                        Text(bot.displayName)
                            .font(TypeScale.font(TypeScale.md, weight: .semibold))
                            .foregroundStyle(Tokens.textPrimary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.hermeyFocusQuiet() }
            }
        }
    }

    /// The face the header draws: the tab's live draft when there is one, else what the host stores.
    ///
    /// Three cases, one per family, so the head says the same thing the preview does — a Classic pick
    /// draws the shape-and-palette face even for a bot that still has a drawing stored.
    @ViewBuilder
    private var headerAvatar: some View {
        // While the Avatar tab is open this is the draft; on any other tab it is what the host has.
        switch tab == .avatar ? liveFace : nil {
        case .custom(let document):
            BotAvatarView(identity: bot.id, size: BotAvatarSize.settingsHeader, animates: false,
                          document: document)
        case .classic(let choice):
            BotAvatarView(identity: bot.id, color: choice.raw, size: BotAvatarSize.settingsHeader,
                          animates: false, ignoresStoredAvatar: true)
        case nil:
            // Passed in, not read from the environment: this screen is presented, and a presented
            // surface is exactly where the injected library is not guaranteed to be.
            BotAvatarView(identity: bot.id, color: icon?.raw, size: BotAvatarSize.settingsHeader,
                          animates: false, document: avatar)
        }
    }

    // MARK: Identity

    /// What the bot *is*: its portrait, its prompt file, and the memory it carries. All three were
    /// reachable elsewhere before — the first two by long-pressing the bot's row, which is a gesture
    /// nobody discovers — so they live together here, beside the description that also belongs to the
    /// bot rather than to a conversation.
    ///
    /// A row that cannot be written is not offered at all: `nil` for each closure hides its row, the
    /// same rule the description and the soul have always followed.
    /// The one verb here that cannot be undone, so it is alone, last, and asks once.
    ///
    /// Deleting a bot was only possible from Manage bots, which is a list of switches — a place you
    /// go to hide a row, not to remove one. It belongs with the bot's other facts (2026-11-14).
    @ViewBuilder
    private var dangerSection: some View {
        if let deleteBot {
            Section {
                Button(role: .destructive) {
                    showingDelete = true
                } label: {
                    HStack {
                        Label("Delete this bot", systemImage: "trash")
                        if deleting {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(deleting)
                .hermeyFocusQuiet()
                if let deleteError {
                    Text(deleteError)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.danger)
                }
            } header: {
                Text("Delete")
            } footer: {
                Text("Removes \(bot.displayName) from the host and from every device. The host keeps "
                     + "an archive of its files; its conversation is not restored by adding it back.")
            }
            .confirmationDialog("Delete \(bot.displayName)?",
                                isPresented: $showingDelete,
                                titleVisibility: .visible) {
                Button("Delete bot", role: .destructive) {
                    deleting = true
                    deleteError = nil
                    Task {
                        do {
                            try await deleteBot()
                            dismiss()
                        } catch {
                            deleteError = error.localizedDescription
                        }
                        deleting = false
                    }
                }
                .hermeyFocusQuiet()
                Button("Cancel", role: .cancel) {}
                .hermeyFocusQuiet()
            } message: {
                Text("This cannot be undone from the app.")
            }
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        if editSoul != nil || memory != nil {
            Section {
                if let editSoul {
                    Button(action: editSoul) {
                        Label("Soul", systemImage: "doc.text")
                    }
                    .hermeyFocusQuiet()
                }
                if let memory {
                    Button {
                        showingMemory = true
                    } label: {
                        Label("Memory", systemImage: "brain")
                    }
                    .sheet(isPresented: $showingMemory) {
                        // Lists MEMORY.md and USER.md with their counts against the runtime's budget,
                        // and opens either as plain text that saves back to the host.
                        BotMemorySheet(botName: bot.displayName, access: memory)
                        .hermesSheetChrome()
                    }
                    .hermeyFocusQuiet()
                }
            } header: {
                Text("Identity")
            } footer: {
                Text("The prompt this bot is built on and the notes it carries into every turn. "
                     + "Both are stored on the host; a conversation already open keeps the soul it "
                     + "started with until it is reset.")
            }
        }
    }

    // MARK: Avatar

    /// The bot's face, from either family: the Classic row, the drawn presets, a JSON import,
    /// colour and eye placement, a live preview and Save/Reset. Nothing in it can reach the bot's
    /// config or its soul — the only closure it is given saves a face.
    @ViewBuilder
    private func avatarSection(save: @escaping (BotAvatarSelection?) async throws -> Void) -> some View {
        Section {
            OpenBotAvatarEditor(botID: bot.id,
                                botName: bot.displayName,
                                stored: avatar,
                                face: icon,
                                previewState: .idle,
                                // The head above draws this same face while the tab is open.
                                onFaceChange: { liveFace = $0 },
                                save: save)
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        } header: {
            Text("Avatar")
        } footer: {
            Text("A generated avatar replaces this bot's picture. It is drawn on every device from "
                 + "the definition, so it costs no storage and stays sharp at any size. A Classic face "
                 + "is one of the bodies this app already ships, in a palette colour. Saving either "
                 + "changes nothing about how the bot thinks.")
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
                .hermeyFocusQuiet()
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
}
