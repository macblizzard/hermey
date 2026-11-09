import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The window: a `Tokens.frame` surround with the workspace clipped inside it.
///
/// The surround is the app's one piece of theatre and it is exact — 8 pt on the sides and the
/// bottom only. The top is flush with the window edge: the hidden title bar's traffic lights sit
/// on the panels' own backgrounds (the sidebar's fill runs behind them) instead of on an empty
/// 28 pt band of frame colour above both panes.
///
/// Inside is the phone's information architecture, not a desktop three-pane one: **one panel on
/// the left listing bots, the chat on the right**. There is no session list to browse, no session
/// search and no third inspector column — picking a bot opens that bot's single endless
/// conversation, exactly as the iPhone does.
struct WorkspaceRoot: View {
    @ObservedObject var store: WorkspaceStore

    /// The window's transparency, set in Settings → Appearance. 1 is opaque.
    @AppStorage(WindowAppearance.opacityKey) private var windowOpacity: Double = 1

    /// The chosen theme. Watched here — not just in Settings — because the shell has to be
    /// re-created for a new palette to reach every view.
    @AppStorage(ThemeRuntime.defaultsKey) private var themeID: String = ThemeCatalog.defaultID

    /// Foreground is when another device's turn should appear in this list.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // At full opacity this is just the frame colour. Below it the fill fades with the
            // shell, and `WindowBackdrop` clears the window's own background so the desktop is
            // what shows through instead of a washed-out solid.
            Tokens.frame
                .opacity(windowOpacity)
                .ignoresSafeArea()

            WorkspaceShell(model: store.model, store: store)
                // Re-created, not merely re-drawn: `Tokens` is read at draw time by every view, and
                // a fresh subtree is what guarantees none of them kept the old palette. The model
                // lives outside this identity, so nothing about the conversation is lost.
                .id("\(themeID)-\(store.themeVersion)")
                .clipShape(RoundedRectangle(cornerRadius: Geometry.radiusWindow, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Geometry.radiusWindow, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                )
                .padding(.horizontal, 8)
                // No top inset: the shell reaches the window edge, so the sidebar's fill and the
                // conversation's canvas are what the traffic lights are drawn on. The window's own
                // rounded mask still shapes the top corners; the 13 pt clip below is what rounds
                // the bottom ones inside the frame.
                .padding(.bottom, 8)
                // The whole shell fades together: fading only the frame would leave an opaque
                // conversation floating in a translucent surround.
                .opacity(windowOpacity)

            // The title bar is hidden, so nothing owns the "drag me / double-click me" strip at the
            // top of the window. This transparent view does, and stays clear of the traffic lights.
            TitlebarDragArea()
                .frame(height: WorkspaceShell.titlebarStrip)
                .padding(.leading, 96)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(true)

            paletteOverlay
        }
        .background(WindowBackdrop(opacity: windowOpacity))
        .onChange(of: scenePhase) { _, phase in
            // The other device's turn shows up here the moment the window comes back.
            if phase == .active { Task { await store.model.loadBotPreviews() } }
        }
        .onAppear {
            // A stored choice must be in place before the first frame is read.
            ThemeRuntime.restoreFromDefaults()
            TypeScale.restoreScale()
        }
        // One animation owner for the palette's whole lifecycle: the backdrop fades, the panel
        // rises a few points, and closing is the same motion in reverse.
        .animation(.easeOut(duration: 0.14), value: store.isPalettePresented)
        // **One** sheet modifier, two routes.
        //
        // SwiftUI attaches a sheet per modifier: two `.sheet` modifiers on the same view means the
        // second is silently dropped while the first is up (and the last one wins on re-render).
        // So both doors — ⌘⇧P / "Pair host…", and the bot-settings door that the bot list's context
        // menu and the conversation's menu both open — are folded into one `.sheet(item:)` over a
        // small local route. The store stays the source of truth: the binding reads its two flags
        // and dismisses by clearing them.
        .sheet(item: presentation) { route in
            switch route {
            case .pair:
                PairHostSheet(store: store)
            case .botSettings(let bot):
                MacBotSettingsSheet(model: store.model,
                                    store: store,
                                    bot: bot,
                                    conversationIsOpen: store.model.selectedBotID == bot.id)
            }
        }
    }

    // MARK: - Sheets

    /// The one thing a modal can be in this window. `id` is stable per route so re-reading the
    /// store's flags does not re-present a sheet that is already on screen.
    private enum WorkspacePresentation: Identifiable {
        case pair
        case botSettings(Bot)

        var id: String {
            switch self {
            case .pair: return "pair"
            case .botSettings(let bot): return "bot-settings:\(bot.id)"
            }
        }
    }

    /// Pairing outranks bot settings: both are one-at-a-time, and pairing is the door that has to
    /// be reachable when nothing else works. Dismissing clears both flags, so a sheet can never be
    /// left queued behind the one that closed.
    private var presentation: Binding<WorkspacePresentation?> {
        Binding(
            get: {
                if store.isPairSheetPresented { return .pair }
                if let bot = store.botSettingsBot { return .botSettings(bot) }
                return nil
            },
            set: { route in
                guard route == nil else { return }
                store.isPairSheetPresented = false
                store.botSettingsBot = nil
            }
        )
    }

    // MARK: - Command palette (⌘K)

    /// A floating palette, not a sheet.
    ///
    /// Sheets are window-modal on macOS: clicking the dimmed area behind one does nothing, and a
    /// verb picker that will not go away when you click outside it reads as a stuck window. So the
    /// palette is an overlay — a tappable backdrop plus the panel above it — rendered only while
    /// `isPalettePresented`, which means it covers nothing and captures nothing once closed.
    @ViewBuilder
    private var paletteOverlay: some View {
        if store.isPalettePresented {
            ZStack(alignment: .top) {
                // The backdrop dismisses; the panel is a sibling drawn above it, so its own
                // clicks never reach the backdrop's gesture.
                Color.black.opacity(0.34)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { store.closePalette() }
                    .transition(.opacity)
                    .accessibilityLabel("Close the command palette")

                CommandPaletteView(store: store)
                    .clipShape(RoundedRectangle(cornerRadius: Geometry.radiusPalette, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Geometry.radiusPalette, style: .continuous)
                            .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.42), radius: 26, y: 14)
                    .padding(.top, 64)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            .onExitCommand { store.closePalette() }
        }
    }
}

/// Bot panel, conversation — in that order, at that geometry.
struct WorkspaceShell: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    /// Deleting a room from its own header, confirmed here: a room is host state and the verb is
    /// not undoable, so it asks once, from wherever it was raised.
    @State private var pendingRoomDelete: RoomSummary?

    /// The strip the hidden title bar's traffic lights occupy, measured from the window's top
    /// edge. The panels paint their backgrounds through it; only the sidebar's *content* starts
    /// below it, so the buttons never land on the search field. 26 pt clears the buttons' 20 pt
    /// baseline by 6 and is 2 pt under a standard 28 pt title bar's height.
    static let titlebarStrip: CGFloat = 26

    /// One definition of the pane: the panel and the full-screen overlay differ only in their
    /// frame and in which way the full-screen button points.
    @ViewBuilder
    private func computerPane(fullScreen: Bool) -> some View {
        BotComputerPane(profile: model.selectedBot?.id ?? "",
                        displayName: model.selectedBot?.displayName ?? "this bot",
                        client: store.computer,
                        isFullScreen: fullScreen,
                        onToggleFullScreen: { store.isComputerFullScreen = !fullScreen },
                        onClose: {
                            store.isComputerPanelPresented = false
                            store.isComputerFullScreen = false
                        })
    }

    private var sidebarBinding: Binding<CGFloat> {
        Binding(get: { store.sidebarWidth },
                set: { store.setSidebarWidth($0) })
    }

    var body: some View {
        HStack(spacing: 0) {
            // Collapsed, the panel, its drag strip and the hairline all go: a hidden panel that
            // still reserves 201 pt of chrome is not hidden.
            if !store.isSidebarHidden {
                BotSidebarView(model: model, store: store)
                    .frame(width: store.sidebarWidth)

                PaneDivider(width: sidebarBinding,
                            range: WorkspaceStore.sidebarFloor...Geometry.sidebarMax,
                            onCommit: { store.endSidebarDrag() })

                // The divider strip is `Geometry.paneDivider` of hit area; the boundary line itself
                // is this one hairline, so the shell adds paneDivider + 1 to the conversation's
                // minimum — the same sum `HermesMacApp`'s window minimum is built from.
                Hairline(.vertical)
            }

            // One pane, two kinds of conversation: a bot's endless chat, or a room. A room is not a
            // window on top of the app — it is the app, and closing it returns to the bot underneath.
            Group {
                if let room = model.activeRoom {
                    RoomChatView(room: room,
                                 icons: store.botIcons,
                                 presentation: .pane,
                                 load: { roomID, since in try await model.roomPage(roomID, since: since) },
                                 send: { roomID, text, files in
                                     try await model.sendRoomMessage(roomID, text: text, attachments: files)
                                 },
                                 onActivity: { Task { await model.refreshRooms() } },
                                 onClose: { model.closeRoom() },
                                 sidebarHidden: store.isSidebarHidden,
                                 onToggleSidebar: { store.toggleSidebar() },
                                 onDelete: { pendingRoomDelete = room },
                                 onRename: { name in try await model.renameRoom(room.id, to: name) },
                                 renameSignal: $model.renameRequest,
                                 markdown: { markdownMessage($0) },
                                 refreshSignal: model.refreshTick)
                } else {
                    ConversationPane(model: model, store: store)
                }
            }
                .frame(minWidth: Geometry.conversationMin, maxWidth: .infinity, maxHeight: .infinity)
                // A new bot is a new conversation: re-creating the pane drops the old scroll
                // position and any approval sheet that belonged to the last bot.
                .id(model.activeRoom.map { "room-\($0.id)" } ?? model.selectedBotID ?? "no-bot")

            // The shared computer, beside the conversation rather than over it: you read what the
            // bot says about the errand while watching it do the errand. Full screen is the
            // panel's own verb, so in that state this slot stays empty and the overlay below owns
            // the window — one pane instance alive either way.
            if store.isComputerPanelPresented, !store.isComputerFullScreen {
                Hairline(.vertical)
                computerPane(fullScreen: false)
                    .frame(width: 520)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if store.isComputerPanelPresented, store.isComputerFullScreen {
                computerPane(fullScreen: true)
                    .background(Tokens.canvas)
                    .transition(.opacity)
            }
        }
        .background(Tokens.canvas)
        .confirmationDialog(
            pendingRoomDelete.map { "Delete \($0.name)?" } ?? "Delete this group chat?",
            isPresented: Binding(get: { pendingRoomDelete != nil },
                                 set: { if !$0 { pendingRoomDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete group chat", role: .destructive) {
                guard let room = pendingRoomDelete else { return }
                pendingRoomDelete = nil
                Task {
                    try? await model.disbandRoom(room.id)
                    model.closeRoom()
                    await model.refreshRooms()
                }
            }
            Button("Cancel", role: .cancel) { pendingRoomDelete = nil }
        } message: {
            Text("The room is removed from every device. Its transcript stays on the host.")
        }
    }
}

// MARK: - Previews

private struct WorkspaceRootPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        WorkspaceRoot(store: store)
            .frame(width: 1280, height: 820)
            .preferredColorScheme(.dark)
            .task { await store.attachPreviewHost() }
    }
}

private struct WorkspaceRootApprovalPreview: View {
    @StateObject private var store = PreviewWorkspace.store(.approval)

    var body: some View {
        WorkspaceRoot(store: store)
            .frame(width: 1280, height: 820)
            .preferredColorScheme(.dark)
            .task { await store.attachPreviewHost() }
    }
}

private struct WorkspaceRootPalettePreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        WorkspaceRoot(store: store)
            .frame(width: 1280, height: 820)
            .preferredColorScheme(.dark)
            .task {
                await store.attachPreviewHost()
                store.openPalette()
            }
    }
}

#if DEBUG
#Preview("Workspace") {
    WorkspaceRootPreview()
}
#endif

#if DEBUG
#Preview("Workspace · approval waiting") {
    WorkspaceRootApprovalPreview()
}
#endif

#if DEBUG
#Preview("Workspace · palette open") {
    WorkspaceRootPalettePreview()
}
#endif
