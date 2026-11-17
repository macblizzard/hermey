import SwiftUI
import HermesKit
import HermeyUI

/// Who this bot **is**: its portrait, its name, what it does, its prompt file, what it remembers, and the
/// door that deletes it.
///
/// The model, the effort level and the aux/vision model are not here — they moved to `BotModelSheet`,
/// reached from the drawer's Model row, which is where the desktop keeps them. A catalogue of hundreds of
/// providers inside a sheet you open to change a description is a list in the wrong room, and it put the
/// delete verb a long scroll away from the name you were about to delete (asked for 2026-11-17: "remove the
/// model selection from edit menu on mobile and make it just like the desktop in the bot menu sidebar").
struct BotModelSettingsScreen: View {
    let bot: Bot
    /// The portrait the host has for this bot, when it has one — the sheet shows the face the list
    /// shows, so it is recognisable before its title is read.
    var icon: BotFaceChoice? = nil
    /// Writes the human-readable description on the host (`profiles.configure`, description
    /// section). `nil` hides the editor entirely — a client that cannot write it must not offer it.
    var saveDescription: ((String, String) async throws -> Void)? = nil
    /// Opens this bot's real SOUL.md. `nil` hides the row: a client that cannot write it must not
    /// offer it, the same rule the description follows.
    var editSoul: (() -> Void)? = nil
    /// Writes this bot's portrait. `nil` hides the row, the same rule as the soul: the picker moved
    /// here from a long press on the list, where nobody found it (reported 2026-11-14).
    var saveIcon: ((BotFaceChoice?) async throws -> Void)? = nil
    /// Reads the two documents this bot carries into every turn. `nil` hides the row.
    var loadMemory: (() async throws -> BotMemory)? = nil
    /// Deletes this bot on the host. `nil` hides the row — the rule every verb here follows: a
    /// client that cannot do it must not offer it.
    var deleteBot: (() async throws -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var descriptionText: String
    @State private var savedDescription: String
    @State private var descriptionBusy = false
    @State private var descriptionError: String?
    @State private var descriptionSaved = false
    @State private var showingIcon = false
    @State private var showingMemory = false
    @State private var showingDelete = false
    @State private var deleteError: String?
    @State private var deleting = false
    @State private var iconError: String?

    init(bot: Bot,
         icon: BotFaceChoice? = nil,
         saveDescription: ((String, String) async throws -> Void)? = nil,
         editSoul: (() -> Void)? = nil,
         saveIcon: ((BotFaceChoice?) async throws -> Void)? = nil,
         loadMemory: (() async throws -> BotMemory)? = nil,
         deleteBot: (() async throws -> Void)? = nil) {
        self.bot = bot
        self.icon = icon
        self.saveDescription = saveDescription
        self.editSoul = editSoul
        self.saveIcon = saveIcon
        self.loadMemory = loadMemory
        self.deleteBot = deleteBot
        _descriptionText = State(initialValue: bot.description ?? "")
        _savedDescription = State(initialValue: bot.description ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(Tokens.danger)
                }
                identitySection
                descriptionSection
                dangerSection
            }
            .navigationTitle("\(bot.displayName) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The portrait it wears in the list, so this sheet is recognisable before the title
                // is read.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        // A settings sheet is not a live surface: the face is the stored one,
                        // still, because nothing here is being asked to show a run.
                        BotAvatarView(identity: bot.id, color: icon?.raw, size: 24, animates: false)
                        Text(bot.displayName)
                            .font(TypeScale.font(TypeScale.md, weight: .semibold))
                            .foregroundStyle(Tokens.textPrimary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
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
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone from the app.")
            }
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        if editSoul != nil || saveIcon != nil || loadMemory != nil {
            Section {
                if let saveIcon {
                    Button {
                        showingIcon = true
                    } label: {
                        HStack {
                            Label("Bot icon", systemImage: "person.crop.circle")
                            Spacer()
                            BotAvatarView(identity: bot.id, color: icon?.raw, size: 22, animates: false)
                        }
                    }
                    .sheet(isPresented: $showingIcon) {
                        BotIconPicker(botID: bot.id, botName: bot.displayName, selected: icon) { face in
                            iconError = nil
                            do { try await saveIcon(face) }
                            catch { iconError = error.localizedDescription }
                        }
                        .hermesSheetChrome()
                    }
                }
                if let editSoul {
                    Button(action: editSoul) {
                        Label("Soul", systemImage: "doc.text")
                    }
                }
                if let loadMemory {
                    Button {
                        showingMemory = true
                    } label: {
                        Label("Memory", systemImage: "brain")
                    }
                    .sheet(isPresented: $showingMemory) {
                        BotMemorySheet(botName: bot.displayName, load: loadMemory)
                        .hermesSheetChrome()
                    }
                }
                if let iconError {
                    Text(iconError)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.danger)
                }
            } header: {
                Text("Identity")
            } footer: {
                Text("The portrait the list shows, the prompt this bot is built on, and the notes it "
                     + "carries into every turn. All three are stored on the host; a conversation "
                     + "already open keeps the soul it started with until it is reset.")
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
}
