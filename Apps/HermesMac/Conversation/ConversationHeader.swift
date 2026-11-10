import Foundation
import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The strip above the transcript: which bot, whether a turn is live, how full the context is,
/// and the menu of things that act on this conversation.
///
/// It names the **bot**, not a session: this app has one conversation per bot, so a title like
/// "Vault backup + docs audit" would describe a row the user never picked. The transcript beneath
/// is that bot's stored conversation, resumed wherever it was left.
struct ConversationHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    /// ⌘, — the real Settings scene, opened from the chat's own menu.
    @Environment(\.openSettings) private var openSettings

    private var title: String {
        model.selectedBot?.displayName ?? model.hostName
    }

    /// The line the panel shows under a bot's name: what this bot is, from the host.
    private var descriptionLine: String? {
        guard store.isPaired, model.connection.isLive else { return nil }
        guard let described = model.selectedBot?.description, !described.isEmpty else { return nil }
        return described
    }

    /// The third line: how much conversation there is and how much room it has left. Its own line,
    /// because three unrelated facts strung under a name read as a paragraph, not a header.
    private var statsLine: String {
        if !store.isPaired { return "no host paired" }
        if !model.connection.isLive { return "not connected" }
        guard model.selectedSessionID != nil else {
            return model.bots.isEmpty ? "no bots on this host" : "no conversation open"
        }
        var parts: [String] = []
        if !model.transcript.isEmpty {
            parts.append(model.transcript.count == 1 ? "1 entry" : "\(model.transcript.count) entries")
        }
        if let context = contextChipLabel { parts.append(context) }
        if let updated = model.selectedSession?.updatedAt {
            parts.append("updated \(RelativeTime.short(updated))")
        }
        return parts.isEmpty ? title : parts.joined(separator: " · ")
    }

    private var presence: Avatar.Presence {
        if model.hasPendingRequests { return .needsYou }
        if model.isStreaming { return .running }
        return .idle
    }

    /// `deepseek-v4.1-flash` fits; a provider-qualified id does not, and the chip is `fixedSize`,
    /// so it is shortened here rather than pushing the header's controls out of the strip.
    private var modelChipLabel: String? {
        guard let raw = store.openBotModelLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let words = raw.split(separator: " ")
        let short = words.prefix(2).joined(separator: " ")
        guard !short.isEmpty else { return nil }
        return short.count <= 22 ? short : String(short.prefix(21)) + "…"
    }

    /// How full the conversation is, as `used / window`. This is the one fact the removed
    /// inspector column used to carry, and it is the fact that explains a compaction.
    private var contextChipLabel: String? {
        guard let used = model.contextUsed else { return nil }
        if let max = model.contextMax, max > 0 {
            return "\(TokenCount.short(used)) / \(TokenCount.short(max))"
        }
        return TokenCount.short(used)
    }

    var body: some View {
        // The header's chips are fixed-size, so at `Geometry.conversationMin` (424 pt) the strip
        // used to push its own controls past the right edge. It now reads the pane width and drops
        // the optional chips first, keeping the title and the two controls.
        GeometryReader { proxy in
            header(width: proxy.size.width)
        }
        .frame(height: 60)
        .background(Tokens.canvas)
        // Owned by the store: the menu, the toolbar's own button and the palette's verb all raise
        // this one dialog, so "reset" cannot be two different confirmations.
        .confirmationDialog("Reset this conversation?",
                            isPresented: $store.isResetConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Reset conversation", role: .destructive) {
                Task { await model.resetConversation() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Hermey starts a fresh conversation with \(title). The current one stays on the host, but this app will not reopen it.")
        }
    }

    /// Widths at which each optional chip stops fitting next to a one-line title and the two
    /// controls. Context is the first to go: it is the fact a compacted conversation explains.
    private enum ChipBreakpoint {
        static let context: CGFloat = 520
        static let model: CGFloat = 600
        static let notice: CGFloat = 460
        /// Width below which compact/reset move to the ⋯ menu only.
        static let actions: CGFloat = 560
    }

    private func header(width: CGFloat) -> some View {
        HStack(spacing: 9) {
            // The panel's own control. A bot list that cannot be put away is the reason a narrow
            // window feels cramped; ⌘⌥S does the same thing without the mouse.
            OpenBotIconButton(store.isSidebarHidden ? "sidebar.leading" : "sidebar.left",
                              label: store.isSidebarHidden ? "Show the bot panel" : "Hide the bot panel",
                              size: .small) {
                store.toggleSidebar()
            }
            .help(store.isSidebarHidden ? "Show the bot panel (⌘S)" : "Hide the bot panel (⌘S)")

            // The bot's own portrait, the same one the sidebar row shows. The chat used to fall
            // back to a lettered circle, so the header and the row that opened it disagreed about
            // which bot this was.
            if let bot = model.selectedBot {
                BotIconPortrait(store.botIcons[bot.id] ?? BotIcon.default(for: bot.id),
                                size: 26,
                                isWorking: model.isStreaming)
            } else {
                Avatar(title, size: .small, presence: presence)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TypeScale.font(Tokens.textLG, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let descriptionLine {
                    Text(descriptionLine)
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(statsLine)
                    .font(TypeScale.font(TypeScale.micro))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // The title shrinks (and truncates) before anything to its right is displaced, and it
            // never takes more than its share of the strip.
            .frame(maxWidth: max(140, width * 0.42), alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 8)

            // A compaction is a real model turn on the host, so its outcome is a quiet note here
            // rather than a banner: nothing failed, the transcript was rewritten.
            if let notice = model.compactionNotice, width >= ChipBreakpoint.notice {
                StatusChip(notice, tone: .neutral, size: .small)
            }

            if width >= ChipBreakpoint.context, let context = contextChipLabel {
                StatusChip(context, tone: .neutral, size: .small)
            }

            // The open bot's own model, from the profile-scoped catalogue — never the gateway's
            // default, which is what a chip reading an unscoped call names.
            if width >= ChipBreakpoint.model, let label = modelChipLabel {
                StatusChip(label, tone: .neutral, size: .small)
            }

            if model.isStreaming {
                StatusChip("running", tone: .success, showsDot: true, size: .small)
            }

            if model.hasPendingRequests {
                StatusChip("needs you", tone: .warning, showsDot: true, size: .small)
            }

            // The two verbs a long conversation needs, at the place the conversation is read: they
            // used to live only in the ⋯ menu, where they were invisible until looked for.
            if width >= ChipBreakpoint.actions {
                OpenBotIconButton("rectangle.compress.vertical",
                                  label: "Compact the conversation now",
                                  size: .small,
                                  isDisabled: !model.canActOnConversation) {
                    Task { await model.compressNow() }
                }
                .help("Compact the conversation now")

                OpenBotIconButton("arrow.counterclockwise",
                                  label: "Reset this conversation",
                                  size: .small,
                                  isDisabled: !model.canActOnConversation) {
                    store.isResetConfirmationPresented = true
                }
                .help("Reset this conversation…")
            }

            // Find in this conversation, not the palette: a magnifier over a transcript means
            // "search what I am reading". ⌘K and the ⋯ menu keep the palette where it belongs.
            OpenBotIconButton("magnifyingglass",
                              label: "Search conversation (⌘F)",
                              size: .small) {
                store.openFindInChat()
            }

            // The shared desktop, one screen for every bot: a sidebar toggle (the panel lives on
            // the right of the transcript), not a modal — it has to sit beside the chat it is
            // working for.
            OpenBotIconButton("display",
                              label: store.isComputerPanelPresented ? "Hide the shared computer"
                                                                   : "Show the shared computer",
                              size: .small) {
                store.toggleComputerPanel()
            }
            .help(store.isComputerPanelPresented ? "Hide the shared computer" : "Shared computer")

            moreMenu
        }
        .padding(.horizontal, Geometry.readingInset)
        .frame(width: width, height: 48, alignment: .leading)
    }

    private var moreMenu: some View {
        Menu {
            Button("Bot computer…") { store.toggleComputerPanel() }
            Divider()
            if let bot = model.selectedBot {
                Button("Bot settings") { store.openBotSettings(bot) }
                Divider()
            }
            if !model.bots.isEmpty {
                Menu("Switch bot") {
                    ForEach(model.orderedBots) { bot in
                        Button(bot.id == model.selectedBotID ? "✓ \(bot.displayName)" : bot.displayName) {
                            store.selectBot(bot.id)
                        }
                    }
                }
                Divider()
            }
            // Two things a long conversation needs and only the phone had: compact it now
            // rather than waiting for the threshold, and start over from an empty conversation.
            Button("Compact Conversation") {
                Task { await model.compressNow() }
            }
            .disabled(!model.canActOnConversation)

            Button("Reset Conversation…") {
                store.isResetConfirmationPresented = true
            }
            .disabled(!model.canActOnConversation)

            Divider()
            Button("Mark all as read") { model.markAllRead() }
                .disabled(!model.hasAnyUnread)
            Divider()
            Button("Command palette…") { store.openPalette() }
            Button("Settings…") { openSettings() }
            Divider()
            Button("Pair host…") { store.isPairSheetPresented = true }
            Divider()
            if model.connection.isLive {
                Button("Disconnect") { Task { await store.disconnect() } }
            } else {
                Button("Connect") { Task { await store.connect() } }
                    .disabled(!store.isPaired)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
    }

    /// `200 000` reads as a number; `200k` fits in a chip next to the model name.
}

// MARK: - Previews

private struct ConversationHeaderPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(model: store.model, store: store)
            Hairline()
            Spacer()
        }
        .frame(width: Geometry.conversationMeasure + 200, height: 200)
        .background(Tokens.canvas)
        .task { await store.attachPreviewHost() }
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Conversation header") {
    ConversationHeaderPreview()
}
#endif
