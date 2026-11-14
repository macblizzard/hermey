import Foundation
import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The Mac's Settings window — `⌘,`, a real `Settings` scene, not another sheet.
///
/// Three tabs, in the order the contract fixes (`docs/ENDLESS-CHAT.md` §4): how the chat behaves,
/// which bots exist, and the connection this Mac holds. The phone's Settings screen is the same
/// list of facts at a different size; the copy about the threshold is deliberately identical in
/// meaning, because it is one setting shared by both apps through `AppModel`.
struct MacSettingsView: View {
    @ObservedObject var store: WorkspaceStore

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

            ConnectionSettingsTab(store: store,
                                  openDevices: { openWindow(id: "paired-devices") })
                .tabItem { Label("Connection", systemImage: "bolt.horizontal") }

            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }

            // Next to Appearance because both answer "how does this app behave on this Mac",
            // and separate from Chat because the *permission* is the system's, not the chat's.
            NotificationsSettingsTab(store: store)
                .tabItem { Label("Notifications", systemImage: "bell") }

            // Last: a version number is something a user goes looking for, and it reports the
            // build CI stamped rather than anything this file could guess.
            AboutSettingsTab(store: store)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Six tabs now (Chat, Bots, Connection, Appearance, Notifications, About): at 560 the bar
        // ran out of room and macOS pushed the last tab behind a chevron.
        .frame(width: 620, height: 500)
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
        }
    }
}

// MARK: - Chat

/// The three preferences `AppModel` persists, written straight back to it.
///
/// The threshold is edited as text and committed on Return or focus loss: writing every
/// keystroke to `autoCompactTokens` would compact the thread mid-typing and would make a
/// half-typed "20000" behave like "2".
private struct ChatSettingsTab: View {
    @ObservedObject var store: WorkspaceStore

    @FocusState private var thresholdFocused: Bool
    @State private var thresholdText: String = ""

    private var threshold: Int { store.model.autoCompactTokens }

    var body: some View {
        Form {
            Section {
                thresholdRow
            } header: {
                Text("Auto-compaction")
            } footer: {
                Text(threshold > 0
                     ? "After a turn leaves \(TokenCount.short(threshold)) tokens in the conversation, Hermes summarises it in place so the chat can continue. The full transcript on the host is rewritten; the conversation itself is kept."
                     : "Off. The conversation grows until the host refuses a turn. 200,000 tokens is the default — the point where a long conversation starts refusing turns, and early enough that the summary still fits behind the reply.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .onAppear { syncThreshold() }
        .onChange(of: store.model.autoCompactTokens) { _ in syncThreshold() }
        .onChange(of: thresholdFocused) { focused in
            if !focused { commitThreshold() }
        }
    }

    // MARK: Threshold

    private var thresholdRow: some View {
        HStack(spacing: 8) {
            Text("Compact after")
                .foregroundStyle(Tokens.textPrimary)

            Spacer(minLength: 8)

            TextField("Off", text: $thresholdText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(Tokens.mono)
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(Tokens.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                )
                .frame(width: 116)
                .focused($thresholdFocused)
                .onSubmit { commitThreshold() }
                .accessibilityLabel("Auto-compact threshold, in tokens")

            Text("tokens")
                .foregroundStyle(Tokens.textMuted)

            if threshold > 0 {
                TextButton("Turn off", tone: Tokens.accentText) { setThreshold(0) }
            } else {
                TextButton("Use \(TokenCount.short(AppModel.defaultAutoCompactTokens))",
                           tone: Tokens.accentText) {
                    setThreshold(AppModel.defaultAutoCompactTokens)
                }
            }
        }
        .font(TypeScale.font(Tokens.textMD))
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

    /// The field is the source of truth while focused, the model's value otherwise. Off is drawn
    /// as an empty field with the "Off" placeholder, not as a literal `0`: the number and the word
    /// mean the same thing, and the word is the one that reads as a state.
    private func syncThreshold() {
        let text = threshold > 0 ? Self.grouped(threshold) : ""
        if text != thresholdText { thresholdText = text }
    }

    /// Blank means off: a user who cleared the field is saying "stop doing this", not
    /// "compact at zero tokens".
    private func commitThreshold() {
        let digits = thresholdText.filter(\.isNumber)
        setThreshold(Int(digits) ?? 0)
    }

    private func setThreshold(_ value: Int) {
        let tokens = max(0, value)
        store.model.autoCompactTokens = tokens
        thresholdText = tokens > 0 ? Self.grouped(tokens) : ""
        thresholdFocused = false
    }

    // MARK: Formatting

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// `200 000` reads as "two hundred thousand"; `200k` fits in a sentence and in a chip.
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
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Tokens.canvas)
    }

    private var hiddenBots: [Bot] {
        model.bots.filter { model.isHidden(botID: $0.id) }
    }

    private func row(_ bot: Bot) -> some View {
        HStack(spacing: 10) {
            if let icon = store.botFaces[bot.id] {
                BotIconPortrait(icon, size: 24, isWorking: false)
            } else {
                Avatar(bot.displayName, size: .small, initials: bot.avatarInitials)
            }

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
        MacSettingsView(store: store)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Settings") {
    MacSettingsPreview()
}
#endif
