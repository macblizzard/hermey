import Foundation
import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The pill above the transcript: which bot this is, and the way into its panel.
///
/// Rakazo's anatomy, and the reason there is no header bar: the name is the control. The pill
/// floats at the centre of the pane, the transcript scrolls beneath it, and clicking it opens the
/// bot's own panel on the right edge — computer, workspace, skills, settings, compact, reset. The
/// chips beside it are only the facts the transcript cannot say about itself, and only while they
/// are true.
///
/// It names the **bot**, not a session: this app has one conversation per bot, so a title like
/// "Vault backup + docs audit" would describe a row the user never picked. The transcript beneath
/// is that bot's stored conversation, resumed wherever it was left.
struct ConversationHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    private var title: String {
        model.selectedBot?.displayName ?? model.hostName
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

    var body: some View {
        // The header's chips are fixed-size, so at `Geometry.conversationMin` (424 pt) the strip
        // used to push its own controls past the right edge. It now reads the pane width and drops
        // the optional chips first, keeping the title and the two controls.
        GeometryReader { proxy in
            header(width: proxy.size.width)
        }
        .frame(height: Geometry.chatHeader)
        // No bar and no hairline: the pill is the header, and the pane's canvas is its background.
        .background(Color.clear)
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
        /// Width below which the model chip goes: the pill and the live chips come first.
        static let model: CGFloat = 640
    }

    private func header(width: CGFloat) -> some View {
        ZStack {
            // Rakazo's shape, and the reason the header has no bar: the **name is the control**.
            // One pill at the centre of the pane — portrait, name, and the ⋯ inside the same
            // capsule — and clicking it slides the bot's own panel in from the right edge, where
            // every verb about this bot lives. A menu that drops down from the corner has to be
            // re-opened for every verb; a panel stays open beside the thing it acts on.
            pill(width: width)

            HStack(spacing: 8) {
                // The bot list's own control. It stays in the header because a hidden panel with
                // its only door inside it is a panel that cannot be brought back.
                OpenBotIconButton(store.isSidebarHidden ? "sidebar.leading" : "sidebar.left",
                                  label: store.isSidebarHidden ? "Show the bot panel" : "Hide the bot panel",
                                  size: .small) {
                    store.toggleSidebar()
                }
                .help(store.isSidebarHidden ? "Show the bot panel (⌘S)" : "Hide the bot panel (⌘S)")

                Spacer(minLength: 12)

                // Only what the transcript cannot say about itself, and only while it is true:
                // a turn in flight, a request waiting, a compaction running. Everything fixed —
                // context, model, the verbs — lives in the panel now.
                if model.isCompressing {
                    StatusChip("compacting…", tone: .neutral, showsProgress: true, size: .small)
                } else if let notice = model.compactionNotice {
                    StatusChip(notice, tone: .neutral, size: .small)
                }
                if model.isStreaming {
                    StatusChip("running", tone: .success, showsDot: true, size: .small)
                }
                if model.hasPendingRequests {
                    StatusChip("needs you", tone: .warning, showsDot: true, size: .small)
                }
                if width >= ChipBreakpoint.model, let label = modelChipLabel {
                    StatusChip(label, tone: .neutral, size: .small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Geometry.readingInset)
        .frame(width: width, height: Geometry.chatHeader)
    }

    /// The pill: portrait, name, and the ⋯ that opens the bot's panel. The whole capsule is the
    /// target, so a click anywhere on the name does what the dots do.
    private func pill(width: CGFloat) -> some View {
        Button {
            store.toggleBotPanel()
        } label: {
            HStack(spacing: 7) {
                if let bot = model.selectedBot {
                    BotIconPortrait(store.botIcons[bot.id] ?? BotIcon.default(for: bot.id),
                                    size: Geometry.chatHeaderAvatar,
                                    isWorking: model.isStreaming)
                } else {
                    Avatar(title, size: .small, presence: presence)
                }

                Text(title)
                    .font(TypeScale.font(Tokens.chatHeaderTitle, weight: .medium))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(store.isBotPanelPresented ? Tokens.textPrimary : Tokens.textMuted)
                    .frame(width: 16)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .frame(height: Geometry.chatHeaderPill)
            .background(
                Capsule().fill(Tokens.surface.opacity(store.isBotPanelPresented ? 1 : 0.92))
            )
            .overlay(
                Capsule().strokeBorder(store.isBotPanelPresented ? Tokens.borderStrong : Tokens.border,
                                       lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: max(180, width * 0.46))
        .accessibilityLabel("\(title), bot actions")
        .accessibilityIdentifier("botPanelButton")
        .help(store.isBotPanelPresented ? "Close the bot panel" : "Bot panel — computer, workspace, skills, settings")
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
