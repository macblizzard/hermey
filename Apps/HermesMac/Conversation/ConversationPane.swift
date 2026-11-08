import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The conversation column: header, optional wire banner, the transcript, the blocking
/// requests, the composer.
///
/// One conversation, forever: this pane has no picker and no "new" button. The transcript on
/// screen is whatever `AppModel.selectedSessionID` holds — the bot's stored endless conversation,
/// resumed by `WorkspaceStore` — and it stays put across reconnects.
///
/// Vertical order is the priority order. A banner sits directly under the header so a
/// reconnecting wire is the first thing read; approvals sit directly above the composer
/// because that is where the user's next action is.
struct ConversationPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    /// The bot this pane last announced as visible, so a teardown cannot clear the dot of the bot
    /// that replaced it (the shell re-creates the pane per bot).
    @State private var shownBotID: String?

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader(model: model, store: store)
            Hairline()

            if let banner = bannerKind {
                ConnectionBanner(banner,
                                 host: model.hostName,
                                 turnRunning: model.isStreaming,
                                 onRetry: { Task { await store.reconnect() } })
            }

            // The banner's copy is per transport state; a refused token or a malformed
            // ticket response needs the host's own sentence, and the way to fix it.
            if case .failed(let why) = model.connection, store.isPaired {
                MacInlineNotice(message: why, actionTitle: "Pair host…") {
                    store.isPairSheetPresented = true
                }
            }

            if model.selectedSessionID == nil {
                ConversationEmptyState(model: model, store: store)
            } else {
                TranscriptScroll(model: model, findRequest: store.findRequest)
            }

            ApprovalInbox(model: model, store: store)
            MacComposerBar(model: model, store: store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.canvas)
        // Mirrors the phone: the conversation that is on screen is the one whose replies count as
        // read; leaving it (or switching bots) hands the unread dot back to the panel.
        .onAppear {
            shownBotID = model.selectedBotID
            model.setVisibleBot(model.selectedBotID)
        }
        .onChange(of: model.selectedBotID) { _, botID in
            shownBotID = botID
            model.setVisibleBot(botID)
        }
        .onDisappear {
            // Only if this pane's bot is still the visible one: a teardown that lands after the
            // next bot's appearance must not erase the dot state for the bot now on screen.
            if model.visibleBotID == shownBotID {
                model.setVisibleBot(nil)
            }
        }
        // Bot change and appearance both land here, so the chip is never a bot behind.
        .task(id: model.selectedBotID) {
            await store.refreshOpenBotModelLabel()
        }
        .onChange(of: model.connection) { _ in
            // The chip is a host fact: re-ask when the wire comes back.
            Task { await store.refreshOpenBotModelLabel() }
        }
    }

    private var bannerKind: ConnectionBanner.Kind? {
        guard store.isPaired || store.connectAttempted else { return nil }
        // `.failed` has a real message of its own, which the inline notice below shows
        // verbatim; the banner would only repeat it in vaguer words.
        if case .failed = model.connection { return nil }
        return ConnectionBanner.kind(for: model.connection.transportState)
    }
}

/// Nothing open yet: the three doors (pair, connect, open the bot's conversation) plus the
/// shortcuts worth learning. No "new session": a bot has one conversation and this is where it
/// opens.
private struct ConversationEmptyState: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    private var title: String {
        if !store.isPaired { return "No host paired" }
        if !model.connection.isLive { return "Not connected" }
        if model.bots.isEmpty { return "No bots found on this host" }
        if model.selectedBotID == nil { return "Pick a bot" }
        return "Start the conversation with \(store.botTitle)"
    }

    private var subtitle: String {
        if !store.isPaired {
            return "Paste your host's wss:// URL and device token. Nothing leaves this Mac until you do."
        }
        if !model.connection.isLive {
            return "Connect to \(store.pairing?.displayHost ?? model.hostName) to load its bots."
        }
        if model.bots.isEmpty {
            return "The gateway answered, but listed no profiles. Check that this host has a Hermes bot to talk to, then check again."
        }
        if model.selectedBotID == nil {
            return "Choose a bot in the panel on the left; its conversation opens beside it."
        }
        return "Each bot has a single conversation that picks up where it left off. Opening it resumes that history — nothing is thrown away."
    }

    private var icon: String {
        if !store.isPaired { return "link.badge.plus" }
        if model.connection.isLive && model.bots.isEmpty { return "person.2.slash" }
        return "bubble.left.and.bubble.right"
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Tokens.textDim)

            Text(title)
                .font(TypeScale.font(Tokens.textLG, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)

            Text(subtitle)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)

            if !store.isPaired {
                OpenBotButton("Pair host…", systemImage: "link", kind: .primary, size: .small) {
                    store.isPairSheetPresented = true
                }
            } else if !model.connection.isLive {
                OpenBotButton("Connect",
                              systemImage: "bolt.horizontal",
                              kind: .primary,
                              size: .small,
                              isBusy: model.connection == .connecting) {
                    Task { await store.connect() }
                }
            } else if model.bots.isEmpty {
                OpenBotButton("Check again", systemImage: "arrow.clockwise", kind: .secondary, size: .small) {
                    Task { await store.loadBots() }
                }
            } else if model.selectedBotID != nil {
                OpenBotButton("Open conversation",
                              systemImage: "bubble.left",
                              kind: .secondary,
                              size: .small) {
                    store.startConversation()
                }
            }

            Text("⌘K commands · ⌘↩ send · ⌘. interrupt")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.canvas)
    }
}

// MARK: - Previews

private struct ConversationPanePreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        ConversationPane(model: store.model, store: store)
            .frame(width: Geometry.conversationMeasure + 240, height: 720)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

private struct ConversationPaneEmptyPreview: View {
    @StateObject private var store = PreviewWorkspace.store(.empty)

    var body: some View {
        ConversationPane(model: store.model, store: store)
            .frame(width: Geometry.conversationMeasure + 240, height: 600)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Conversation") {
    ConversationPanePreview()
}
#endif

#if DEBUG
#Preview("Conversation · nothing open") {
    ConversationPaneEmptyPreview()
}
#endif
