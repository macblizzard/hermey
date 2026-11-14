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
        // Top-aligned: the pill's centre is set by the strip above it, not by the pane's height.
        .frame(height: Geometry.chatHeader, alignment: .top)
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
                // The toggle lives in the bot panel's own header now — Rakazo's arrangement. It
                // reappears here only while the panel is hidden, because a hidden panel with its
                // only door inside it is a panel that cannot be brought back.
                if store.isSidebarHidden {
                    OpenBotIconButton("sidebar.leading", label: "Show the bot panel", size: .small) {
                        store.toggleSidebar()
                    }
                    .help("Show the bot panel")
                }

                Spacer(minLength: 12)

                // No state chips: the bot's own face says it — an exclamation that flashes for a
                // request, an antenna that sparks for a turn, a zip that closes for a compaction.
                // A chip is a word you have to read; this is a thing you notice.
                //
                // The one exception is the compaction *notice*: "compacted 12 messages" is a result,
                // not a state, and it has no shape to take. It fades on its own.
                if let notice = model.compactionNotice {
                    StatusChip(notice, tone: .neutral, size: .small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Geometry.readingInset)
        // On the traffic lights' line: the capsule's centre is 21 pt down, the same line as the
        // sidebar's first row, and the rest of the header's height is the transcript's.
        .frame(width: width, height: Geometry.chatHeaderPill + 2)
    }

    /// What the face says. A request outranks a running turn, and both outrank a compaction: the
    /// one state that needs a person wins the face.
    private var portraitStatus: PortraitStatus? {
        if model.hasPendingRequests { return .needsYou }
        if model.isCompressing { return .compacting }
        if model.isStreaming { return .working }
        return nil
    }

    /// The pill: portrait, name, and the ⋯ that opens the bot's panel. The whole capsule is the
    /// target, so a click anywhere on the name does what the dots do.
    private func pill(width: CGFloat) -> some View {
        Button {
            store.toggleBotPanel()
        } label: {
            HStack(spacing: 7) {
                if let bot = model.selectedBot {
                    BotIconPortrait(store.botFaces[bot.id] ?? BotFace.default(for: bot.id),
                                    size: Geometry.chatHeaderAvatar,
                                    status: portraitStatus)
                } else {
                    Avatar(title, size: .small, presence: presence)
                }

                Text(title)
                    .font(TypeScale.font(Tokens.chatHeaderTitle, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // No ⋯ inside the pill: the whole capsule opens the panel, so the dots were a
                // second, smaller door drawn on the first one.
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(height: Geometry.chatHeaderPill)
            // Solid, not 92%: the transcript runs behind this capsule, and a translucent fill let
            // the text underneath show through the name. The shadow is what makes it read as
            // floating over the content rather than pasted onto it.
            .background(
                Capsule().fill(Tokens.surface)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
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
