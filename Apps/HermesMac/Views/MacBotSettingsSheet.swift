import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// The Mac twin of the phone's `BotModelSettingsScreen`.
///
/// Same two jobs, same order and same rules: a description stored on the host, and the profile's
/// default model chosen from a searchable catalogue. The confirmation gate is the host's, not this
/// sheet's — a refusal comes back as `.confirmationRequired(message)` and is only retried with
/// `confirm: true` after the user reads that sentence.
///
/// A live conversation keeps the model it was created with; the host pins it per session, so the
/// footer says what changing the default does and does not do.
struct MacBotSettingsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore
    let bot: Bot
    /// True when this bot's conversation is the one on screen (the copy differs, the write does not).
    let conversationIsOpen: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var showingSoul = false
    @State private var showingMemory = false
    @State private var showingDelete = false
    @State private var deleteError: String?
    @State private var deleting = false
    @State private var error: String?

    @State private var descriptionText: String
    @State private var savedDescription: String
    @State private var descriptionBusy = false
    @State private var descriptionError: String?
    @State private var descriptionSaved = false

    /// The pet switch, mirrored from `PetSettings` so a pet closed from its own menu moves it.
    @State private var petEnabled: Bool
    /// Which tab of the sheet is showing. Two, not more: what the bot is, and what its avatar looks
    /// like. The avatar is its own tab because editing a face is a different job from editing a
    /// description, and mixing them put a paste box under the name field.
    @State private var tab: SettingsTab = .about

    enum SettingsTab: String, CaseIterable, Identifiable {
        case about = "About"
        case avatar = "Avatar"
        var id: String { rawValue }
    }

    init(model: AppModel, store: WorkspaceStore, bot: Bot, conversationIsOpen: Bool) {
        self.model = model
        self.store = store
        self.bot = bot
        self.conversationIsOpen = conversationIsOpen
        _descriptionText = State(initialValue: bot.description ?? "")
        _savedDescription = State(initialValue: bot.description ?? "")
        _petEnabled = State(initialValue: PetSettings.isEnabled(bot.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Hairline()
            Picker("Section", selection: $tab) {
                ForEach(SettingsTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .hermeyFocusQuiet()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == .avatar {
                        avatarTab
                    } else {
                        aboutContent
                    }
                }
                .padding(16)
            }
        }
        // A fixed height could not fit a short window; the inner ScrollView takes whatever
        // height the sheet is given between the floor and the ceiling.
        .frame(width: 520)
        .frame(minHeight: 420, idealHeight: 560, maxHeight: 560)
        .background(Tokens.canvas)
        .sheet(isPresented: $showingMemory) {
            // The bot's memory, edited here: both files listed with their counts, one opened as plain
            // text, saved back through the host's own route.
            BotMemorySheet(botName: bot.displayName,
                           access: BotMemoryAccess(
                               load: { try await model.memory(for: bot.id) },
                               read: { name in try await model.memoryDocument(named: name, for: bot.id) },
                               save: { name, text in
                                   try await model.saveMemoryDocument(text, named: name, for: bot.id)
                               }))
            .hermesSheetChrome()
        }
        .sheet(isPresented: $showingSoul) {
            SoulEditorSheet(
                botName: bot.displayName,
                load: { try await model.describeBot(bot.id).soul },
                save: { try await model.saveSoul($0, for: bot.id) })
            .hermesSheetChrome()
        }
    }

    /// What the bot is: its prompt file, its description and its pet.
    ///
    /// The face is *not* chosen here. It was — this tab carried a button of its own that opened the
    /// old shape-and-colour picker, a second chooser beside the Avatar tab's own editor, and the two
    /// could disagree about which face a bot wore. The Avatar tab is now the only door: choosing a
    /// body and a colour there is choosing the face, and this tab keeps the things that are not a
    /// face.
    @ViewBuilder
    private var aboutContent: some View {
        if let error {
            Text(error)
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.danger)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let iconError = store.botFacesError {
            Text("Could not refresh bot icons: \(iconError)")
                .font(TypeScale.font(TypeScale.caption)).foregroundStyle(Tokens.danger)
        }
        soulSection
        descriptionSection
        petSection

        dangerSection
    }

    /// The Avatar tab: the bot's face, from either family.
    ///
    /// Saving here writes one family and clears the other — a drawn avatar, or the one string
    /// `bots.color` holds — and nothing else: no config, no soul. A bot with neither keeps the face
    /// its id derives, which is what Reset returns it to.
    @ViewBuilder
    private var avatarTab: some View {
        OpenBotAvatarEditor(
            botID: bot.id,
            botName: bot.displayName,
            stored: store.botAvatars[bot.id],
            face: store.botFaces[bot.id],
            previewState: OpenBotAvatarState(activity: store.activity(for: bot.id)),
            save: { selection in
                try await store.saveBotAvatar(botID: bot.id, selection: selection)
            }
        )
    }

    // MARK: Chrome

    private var titleBar: some View {
        HStack(spacing: 10) {
            // The face this bot wears everywhere else, so the sheet is recognisable before its name
            // is read.
            BotAvatarView(identity: bot.id, color: store.botFaces[bot.id]?.raw, size: 26,
                          animates: false)

            VStack(alignment: .leading, spacing: 1) {
                Text(bot.displayName)
                    .font(TypeScale.font(Tokens.textLG, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)

                Text(bot.id == bot.displayName ? "Hermes profile" : bot.id)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HermeyButton("Done", kind: .secondary, size: .small) {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The one verb in this sheet that cannot be undone, so it is alone and last.
    ///
    /// Deleting a bot used to live only under Manage bots — a list of switches, which is where you
    /// go to hide a row, not to remove one (requested 2026-11-14 for both shells).
    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("DELETE")
            HermeyButton(deleting ? "Deleting…" : "Delete this bot…",
                          kind: .secondary,
                          size: .small,
                          isDisabled: deleting || store.pairing == nil || store.pairing?.isTicketOnly == true) {
                showingDelete = true
            }
            Text("Removes \(bot.displayName) from the host and from every device. The host keeps an "
                 + "archive of its files; adding it back does not restore this conversation.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let deleteError {
                Text(deleteError)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Delete \(bot.displayName)?", isPresented: $showingDelete) {
            Button("Cancel", role: .cancel) {}
            .hermeyFocusQuiet()
            Button("Delete bot", role: .destructive) {
                deleting = true
                deleteError = nil
                Task {
                    do {
                        try await model.deleteBot(bot.id)
                        dismiss()
                    } catch {
                        deleteError = error.localizedDescription
                    }
                    deleting = false
                }
            }
            .hermeyFocusQuiet()
        } message: {
            Text("This cannot be undone from the app.")
        }
    }

    /// The bot's own text — the file that makes it this bot, and the two documents it carries into
    /// every turn. Buttons, because the editors are real text surfaces and not fields that fit in a
    /// settings column.
    private var soulSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("IDENTITY AND MEMORY")
            HermeyButton("Edit SOUL.md…", kind: .secondary, size: .small) {
                showingSoul = true
            }
            // Read-only, and read fresh: the agent rewrites these two whenever it learns something.
            HermeyButton("Memory…", kind: .secondary, size: .small) {
                showingMemory = true
            }
            Text("The prompt this bot is built on. Saved to the host; a conversation already open keeps the soul it started with until it is reset.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Desktop pet

    /// The desktop pet: a small window for this bot, on this Mac only.
    ///
    /// The switch writes the key the controller reads (`PetSettings`), which is also the key the
    /// pet's own **Close pet** menu writes `false` to — so the two surfaces are one setting, not two
    /// that have to be kept in step.
    private var petSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("DESKTOP PET")

            Toggle(isOn: Binding(get: { petEnabled },
                                 set: { setPetEnabled($0) })) {
                Text("Show \(bot.displayName) on the desktop")
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textPrimary)
            }
            .hermeyFocusQuiet()

            HermeyButton("Bring it here", kind: .secondary, size: .small) {
                DesktopPetController.shared.bringHere(bot)
                petEnabled = PetSettings.isEnabled(bot.id)
            }

            Text("A small \(bot.displayName) that floats above your windows and answers a click. "
                 + "Which pets are out is this Mac's own choice — nothing about it is stored on the host.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Closed from the pet's own menu while this sheet is open: the toggle follows.
        .onReceive(NotificationCenter.default.publisher(for: PetSettings.changedNotification)) { note in
            guard (note.userInfo?[PetSettings.botKey] as? String) == bot.id else { return }
            petEnabled = PetSettings.isEnabled(bot.id)
        }
    }

    private func setPetEnabled(_ enabled: Bool) {
        petEnabled = enabled
        DesktopPetController.shared.setEnabled(enabled, for: bot)
    }

    // MARK: Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption("DESCRIPTION")

            TextField("What this bot does",
                      text: $descriptionText,
                      prompt: Text("What this bot does").foregroundColor(Tokens.textPlaceholder),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .lineLimit(1...3)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(Tokens.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                )
                .disabled(descriptionBusy)

            HStack(spacing: 8) {
                HermeyButton("Save description", kind: .secondary, size: .small,
                              isDisabled: descriptionBusy || trimmedDescription == savedDescription) {
                    Task { await writeDescription() }
                }

                if descriptionBusy {
                    SpinningRing(color: Tokens.textDim, size: 9, lineWidth: 1.3)
                } else if let descriptionError {
                    Text(descriptionError)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.danger)
                        .lineLimit(2)
                } else if descriptionSaved {
                    Text("Saved")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                }
            }

            Text("Shown under this bot's name in the list. Stored on the host, so it follows the bot to every device.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trimmedDescription: String {
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeDescription() async {
        descriptionBusy = true
        descriptionError = nil
        descriptionSaved = false
        defer { descriptionBusy = false }
        let text = trimmedDescription
        do {
            try await model.configureDescription(botID: bot.id, description: text)
            descriptionText = text
            savedDescription = text
            descriptionSaved = true
        } catch {
            descriptionError = error.localizedDescription
        }
    }

}

// MARK: - Previews

private struct MacBotSettingsSheetPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        MacBotSettingsSheet(model: store.model,
                            store: store,
                            bot: Bot(id: "assistant", displayName: "Assistant",
                                     description: "Personal assistant on this host"),
                            conversationIsOpen: true)
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Bot settings") {
    MacBotSettingsSheetPreview()
}
#endif
