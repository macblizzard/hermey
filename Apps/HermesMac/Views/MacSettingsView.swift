import Foundation
import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// The Mac's Settings window — `⌘,`, a real `Settings` scene, not another sheet.
///
/// Three tabs, in the order the contract fixes (`docs/ENDLESS-CHAT.md` §4): how the chat behaves,
/// which bots exist, and the connection this Mac holds. The phone's Settings screen is the same
/// list of facts at a different size.
struct MacSettingsView: View {
    @ObservedObject var store: WorkspaceStore

    /// The updater action from `HermesMacApp`, forwarded to the About tab. Explicit rather than a
    /// default so a new caller has to decide what pressing "Check for Updates" does.
    let checkForUpdates: () -> Void

    @Environment(\.openWindow) private var openWindow

    /// The bot whose settings sheet is open *from this window*. Kept local rather than reusing
    /// `store.botSettingsBot`, so a sheet opened from the panel and one opened here can never
    /// fight over the same presentation slot.
    @State private var botForSettings: Bot?

    var body: some View {
        TabView {
            ChatSettingsTab(store: store)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

            BotsSettingsTab(store: store, botForSettings: $botForSettings)
                .tabItem { Label("Bots", systemImage: "person.2") }

            // One switch for every bot's approval policy. Next to Bots because it is about what the
            // bots may *do*, not about who they are.
            ApprovalSettingsTab(store: store)
                .tabItem { Label("Approvals", systemImage: "checkmark.shield") }

            // The Mac as a local computer. Same pattern as the other native clients: a toggle in
            // settings, no inbound port and no SSH.
            LocalComputerSettingsView(store: store)
                .tabItem { Label("Computer", systemImage: "desktopcomputer") }

            ConnectionSettingsTab(store: store,
                                  openDevices: { openWindow(id: "paired-devices") })
                .tabItem { Label("Connection", systemImage: "bolt.horizontal") }

            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }

            // Next to Appearance because both answer "how does this app behave on this Mac",
            // and separate from Chat because the *permission* is the system's, not the chat's.
            NotificationsSettingsTab(store: store)
                .tabItem { Label("Notifications", systemImage: "bell") }

            // What this Mac keeps, with real byte counts and the switches that govern them. Last
            // before About, because storage is something a user looks for rather than tunes daily.
            CachingSettingsTab(store: store)
                .tabItem { Label("Caching", systemImage: "internaldrive") }

            // Last: a version number is something a user goes looking for, and it reports the
            // build CI stamped rather than anything this file could guess.
            AboutSettingsTab(store: store, checkForUpdates: checkForUpdates)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Nine tabs now (Chat, Bots, Approvals, Computer, Connection, Appearance, Notifications,
        // Caching, About): the bar pushes the last tab behind a chevron when the window is too narrow.
        .frame(width: 820, height: 500)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
        // Escape and a click outside both close this window, the way every other surface in the
        // app closes. Before this, Escape here did nothing to the window and closed the sidebar
        // behind it instead (reported 2026-11-14).
        .onExitCommand {
            NSApp.keyWindow?.performClose(nil)
        }
        .background(ClosesOnResignKey().frame(width: 0, height: 0))
        .sheet(item: $botForSettings) { bot in
            MacBotSettingsSheet(model: store.model,
                                store: store,
                                bot: bot,
                                conversationIsOpen: store.model.selectedBotID == bot.id)
            .hermesSheetChrome()
        }
    }
}

// MARK: - Chat

/// The three preferences `AppModel` persists, written straight back to it.
private struct ChatSettingsTab: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Form {
            Section {
                Toggle("Show reasoning", isOn: reasoningBinding)
                    .tint(Tokens.success)
                Text("The model's thinking, above each answer.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)

                Toggle("Expand reasoning automatically", isOn: reasoningExpandedBinding)
                    .tint(Tokens.success)
                Text("Open the model's thinking on arrival instead of a click.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)

                Toggle("Show tool calls", isOn: toolCallsBinding)
                    .tint(Tokens.success)
                Text("A card for every command, with its result. Off hides them from the chat.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            } header: {
                Text("What the chat draws")
            } footer: {
                // Compaction is the host's job, at its own `compression.threshold`: it compacts at
                // the start of a turn when the context crosses it. A second threshold here was an
                // opinion the app is not entitled to — and it could compact a thread the host was
                // about to.
                Text("The host compacts a conversation on its own when it nears the model's window. The header still shows how full the context is.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
    }

    private var reasoningBinding: Binding<Bool> {
        Binding(get: { store.model.showReasoning },
                set: { store.model.showReasoning = $0 })
    }

    private var reasoningExpandedBinding: Binding<Bool> {
        Binding(get: { store.model.reasoningExpandedByDefault },
                set: { store.model.reasoningExpandedByDefault = $0 })
    }

    private var toolCallsBinding: Binding<Bool> {
        Binding(get: { store.model.showToolCalls },
                set: { store.model.showToolCalls = $0 })
    }

}

// MARK: - Bots

/// The bot settings entry point.
///
/// The panel's context menu already opens a bot's sheet; this tab is the same door with the list
/// in front of you, plus the pin/hide switches that shape the panel's order.
private struct BotsSettingsTab: View {
    @ObservedObject var store: WorkspaceStore
    @Binding var botForSettings: Bot?

    private var model: AppModel { store.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.bots.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.orderedBots) { bot in
                        row(bot)
                    }
                    if !hiddenBots.isEmpty {
                        Section("Hidden") {
                            ForEach(hiddenBots) { bot in
                                row(bot)
                            }
                        }
                    }
                    // The roster as a whole, below the bots themselves: what a new bot starts from,
                    // and a file that can rebuild all of this on another host (asked for 2026-11-15).
                    Section("New bots start from") {
                        DefaultSoulPane(current: model.botDefaults.soul.text,
                                        builtIn: model.botDefaults.builtIn,
                                        present: model.botDefaults.soul.present,
                                        isBusy: model.rosterBusy,
                                        save: { await model.saveDefaultSoul($0) },
                                        onChange: { await model.loadBotDefaults() })
                    }
                    Section("Backup") {
                        BackupPane(botCount: model.bots.count,
                                   export: { await model.backupDocument() },
                                   restore: { await model.restoreBackup($0) })
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Tokens.canvas)
        .task { await model.loadBotDefaults() }
    }

    private var hiddenBots: [Bot] {
        model.bots.filter { model.isHidden(botID: $0.id) }
    }

    private func row(_ bot: Bot) -> some View {
        HStack(spacing: 10) {
            // A bot always has a face — the one stored for it, or the body its id draws — so this
            // row never falls back to initials.
            BotAvatarView(identity: bot.id, color: store.botFaces[bot.id]?.raw, size: 24, animates: false)

            VStack(alignment: .leading, spacing: 1) {
                Text(bot.displayName)
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                Text(subtitle(for: bot))
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if model.isHidden(botID: bot.id) {
                TextButton("Show", tone: Tokens.accentText) { model.toggleHidden(botID: bot.id) }
            } else {
                Toggle("Pinned", isOn: Binding(
                    get: { model.isPinned(botID: bot.id) },
                    set: { _ in model.togglePin(botID: bot.id) }))
                    .toggleStyle(.checkbox)
            }

            Button("Settings…") { botForSettings = bot }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for bot: Bot) -> String {
        if let description = bot.description, !description.isEmpty { return description }
        return bot.id == bot.displayName ? "Hermes profile" : bot.id
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.isPaired ? "No bots listed yet." : "No host paired.")
                .font(TypeScale.font(Tokens.textMD, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
            Text(store.isPaired
                 ? "Connect to the host, or check again if it answered with no profiles."
                 : "Pair a host first; its bots are what this app talks to.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Connection

/// Host, state, latency — the facts that explain whether a message gets through — then the four
/// ways to change them. Device management is one button: the list is reference material on its
/// own window, and it has to be readable while the socket is down.
private struct ConnectionSettingsTab: View {
    @ObservedObject var store: WorkspaceStore
    let openDevices: () -> Void

    @State private var confirmingUnpair = false

    private var host: String { store.pairing?.displayHost ?? store.model.hostName }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Avatar(host, size: .small, presence: presence)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(host).foregroundStyle(Tokens.textPrimary)
                        Text(store.model.connection.label)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textMuted)
                    }
                    Spacer(minLength: 8)
                    Text(latencyText)
                        .font(Tokens.mono)
                        .foregroundStyle(Tokens.textMuted)
                }
            } header: {
                Text("Host")
            } footer: {
                // Where it is kept matters on an unsigned build: the Keychain can refuse, and then the
                // pairing lives in a user-only file. Saying which one is why a relaunch is predictable.
                Text(store.isPaired
                     ? "Disconnecting closes the socket but keeps this Mac paired. \(store.pairingStorageDescription ?? "")"
                     : "Nothing is paired yet. Pair with the bridge running on your Hermes host.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if store.isPaired, store.model.connection.isLive {
                    Button("Disconnect") { Task { await store.disconnect() } }
                } else if store.isPaired {
                    Button("Connect") { Task { await store.connect() } }
                        .disabled(store.model.connection == .connecting)
                }
                Button(store.isPaired ? "Pair another host…" : "Pair a host…") {
                    store.isPairSheetPresented = true
                }
                Button("Manage Paired Devices…", action: openDevices)
                    .disabled(!store.isPaired)
                if store.isPaired {
                    Button("Unpair this Mac…", role: .destructive) { confirmingUnpair = true }
                }
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .confirmationDialog("Unpair this Mac?",
                            isPresented: $confirmingUnpair,
                            titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { Task { await store.unpair() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The refresh token is deleted from this Mac. The device stays in the host's list until you revoke it there.")
        }
    }

    private var presence: Avatar.Presence {
        if store.model.hasPendingRequests { return .needsYou }
        if store.model.connection.isLive { return .running }
        return .idle
    }

    private var latencyText: String {
        guard let ms = store.model.latencyMS else { return "rtt —" }
        return "rtt \(ms) ms"
    }
}

// MARK: - Previews

private struct MacSettingsPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        // A preview must never start a real check against the live feed: the button is drawn, the
        // press is a no-op.
        MacSettingsView(store: store, checkForUpdates: {})
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Settings") {
    MacSettingsPreview()
}
#endif
