import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The window, edge to edge.
///
/// There is no frame and no surround: the sidebar's fill and the chat's canvas run out to the
/// window's own rounded corners, and the only thing over the top edge is the traffic lights. What
/// a frame would have said — "this is the app, that is the desktop" — the window's own shape says
/// already.
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
                // The plugin's boards: the shell resolves a card's URL from the pairing it already
                // holds, and a card's button comes back here as a notification.
                .environment(\.genUICards, genUICards)
                // Re-created, not merely re-drawn: `Tokens` is read at draw time by every view, and
                // a fresh subtree is what guarantees none of them kept the old palette. The model
                // lives outside this identity, so nothing about the conversation is lost.
                .id("\(themeID)-\(store.themeVersion)")
                // Edge to edge, on every side. Rakazo has no frame inside the window: the sidebar's
                // fill and the chat's canvas run out to the window's own rounded corners, and the
                // only thing drawn over the top edge is the traffic lights. The 8 pt surround and
                // the stroked border this used to wear read as a window inside a window.
                // The whole shell fades together: fading only the frame would leave an opaque
                // conversation floating in a translucent surround.
                .opacity(windowOpacity)

            // The title bar is hidden, so nothing owns the "drag me / double-click me" strip at the
            // top of the window. This transparent view does — across the **whole** width, because
            // the traffic lights are hit-tested by the window's own frame before this content, and
            // insetting past them by hand left the band above the sidebar's search field dead.
            WindowMovableByBackground()
                .frame(width: 0, height: 0)

            TitlebarDragArea()
                .frame(height: WorkspaceShell.dragStrip)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(true)

            paletteOverlay
        }
        .background(WindowBackdrop(opacity: windowOpacity))
        .onReceive(NotificationCenter.default.publisher(for: .genUICardSend)) { note in
            // A card's button sends its text as the user's next message, the same contract the
            // plugin's own composer actions have.
            guard let text = note.userInfo?["text"] as? String else { return }
            // Through the composer's own draft, so a card button takes the same path a typed
            // message does: the same guards, the same optimistic row, the same delivery.
            store.model.draft = text
            Task { await store.model.send() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .genUICardFill)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            store.model.draft = text
        }
        .onChange(of: scenePhase) { _, phase in
            // The other device's turn shows up here the moment the window comes back.
            if phase == .active {
                Task { await store.model.loadBotPreviews() }
                ReplyNotifier.shared.refreshAuthorization()
            }
        }
        // Banners: the decision is the model's, the delivery is the system's. Re-run when the
        // model is replaced (a re-pair builds a fresh one), because the sink lives on the model.
        .task(id: ObjectIdentifier(store.model)) {
            ReplyNotifier.shared.onOpenBot = { botID in store.selectBot(botID) }
            ReplyNotifier.shared.requestAuthorizationIfNeeded()
            ReplyNotifier.shared.updateBadge(store.model.badgeCount)
            store.model.replyNotificationSink = { note in
                ReplyNotifier.shared.post(note)
            }
        }
        // The Dock tile follows every change, not just new banners: opening a chat clears its
        // count without a reply arriving.
        .onChange(of: store.model.badgeCount) { _, count in
            ReplyNotifier.shared.updateBadge(count)
        }
        .onAppear {
            // A stored choice must be in place before the first frame is read.
            ThemeRuntime.restoreFromDefaults()
            TypeScale.restoreScale()
            auditLaunchSurfaces()
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
            case .workspace(let bot):
                MacWorkspaceSheet(bot: bot, client: store.workspace)
            case .skills(let bot):
                MacBotToolsSheet(bot: bot, kind: .skills, model: store.model)
            case .mcp(let bot):
                MacBotToolsSheet(bot: bot, kind: .mcp, model: store.model)
            case .model(let bot):
                MacModelSheet(model: store.model,
                              store: store,
                              bot: bot,
                              conversationIsOpen: store.model.selectedBotID == bot.id)
            case .routines(let bot):
                BotRoutinesSheet(
                    botName: bot.displayName,
                    load: { try await store.model.routines(for: bot.id) },
                    setPaused: { jobID, paused in
                        try await store.model.setRoutinePaused(jobID, paused: paused, for: bot.id)
                    })
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
        case workspace(Bot)
        case skills(Bot)
        case mcp(Bot)
        case routines(Bot)
        case model(Bot)
        case botSettings(Bot)

        var id: String {
            switch self {
            case .pair: return "pair"
            case .workspace(let bot): return "workspace:\(bot.id)"
            case .skills(let bot): return "skills:\(bot.id)"
            case .mcp(let bot): return "mcp:\(bot.id)"
            case .routines(let bot): return "routines:\(bot.id)"
            case .model(let bot): return "model:\(bot.id)"
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
                if let bot = store.workspaceBot { return .workspace(bot) }
                if let bot = store.skillsBot { return .skills(bot) }
                if let bot = store.mcpBot { return .mcp(bot) }
                if let bot = store.routinesBot { return .routines(bot) }
                if let bot = store.modelBot { return .model(bot) }
                if let bot = store.botSettingsBot { return .botSettings(bot) }
                return nil
            },
            set: { route in
                guard route == nil else { return }
                store.isPairSheetPresented = false
                store.workspaceBot = nil
                store.skillsBot = nil
                store.mcpBot = nil
                store.routinesBot = nil
                store.modelBot = nil
                store.botSettingsBot = nil
            }
        )
    }

    // MARK: - Launch audit

    /// Say, once, what is on screen a second after launch.
    ///
    /// A blank panel appeared over the sidebar on first run and closed with Esc, and nothing in the
    /// code presents one: every surface that can be up is either a flag the user has to raise or a
    /// fixed frame the panel was not. Rather than guess at a fix, the app now names what it actually
    /// has open — its windows with their frames, plus every flag that could raise an overlay — so the
    /// culprit is read out of Settings → View log instead of inferred from a photograph.
    private func auditLaunchSurfaces() {
        #if os(macOS)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let windows = NSApplication.shared.windows.map { window in
                let frame = window.frame
                return "\(window.className)|title=\(window.title)|id=\(window.identifier?.rawValue ?? "-")"
                    + "|visible=\(window.isVisible)|level=\(window.level.rawValue)"
                    + "|\(Int(frame.width))x\(Int(frame.height))@\(Int(frame.minX)),\(Int(frame.minY))"
            }
            ClientLog.note("launch audit: windows=\(windows.count) [\(windows.joined(separator: " ; "))]",
                           category: "launch")
            ClientLog.note("launch audit: flags palette=\(store.isPalettePresented)"
                           + " pairSheet=\(store.isPairSheetPresented)"
                           + " botSettings=\(store.botSettingsBot?.id ?? "-")"
                           + " computer=\(store.isComputerPanelPresented)"
                           + " reset=\(store.isResetConfirmationPresented)"
                           + " addBot=\(store.isAddBotPresented)"
                           + " manageBots=\(store.isManageBotsPresented)"
                           + " groupChat=\(store.isStartGroupChatPresented)"
                           + " groupChats=\(store.isGroupChatsPresented)"
                           + " paired=\(store.isPaired) bots=\(store.model.bots.count)",
                           category: "launch")
        }
        #endif
    }

    // MARK: - Command palette (⌘K)

    /// A floating palette, not a sheet.
    ///
    /// Sheets are window-modal on macOS: clicking the dimmed area behind one does nothing, and a
    /// verb picker that will not go away when you click outside it reads as a stuck window. So the
    /// palette is an overlay — a tappable backdrop plus the panel above it — rendered only while
    /// `isPalettePresented`, which means it covers nothing and captures nothing once closed.
    /// How a card finds its page. Built from the pairing the window already holds, so a card needs
    /// no new plumbing: the host's origin, the device, and the refresh token that mints a session.
    private var genUICards: GenUICardsResolver {
        let bot = store.model.selectedBotID ?? ""
        guard let pairing = store.pairing, !pairing.isTicketOnly,
              let origin = try? pairing.apiOrigin() else { return .unavailable }
        let cards = GenUICards(origin: origin, deviceID: pairing.deviceID, refreshToken: pairing.token)
        return GenUICardsResolver(bot: bot,
                                  url: { block in
                                      let palette = await MainActor.run { GenUIPalette.current }
                                      guard let session = await cards.session(for: bot) else { return nil }
                                      return cards.cardURL(bot: bot, block: block,
                                                           session: session, palette: palette)
                                  },
                                  palette: { GenUIPalette.current })
    }

    @ViewBuilder
    private var paletteOverlay: some View {
        // A palette with nothing to offer is a blank box; on a fresh launch the verb list is empty
        // until a bot arrives, and an empty panel is worse than no panel.
        if store.isPalettePresented && !store.commands.isEmpty {
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
    /// below it, so the buttons never land on the search field.
    ///
    /// 4 pt: Rakazo's first row (its search, its toggles, its plus) sits **on the traffic lights'
    /// line**, not under it. With a 34 pt row the centre lands at 21 — within a point of the lights'
    /// 20 pt centre — and the chat header's pill is on the same line.
    static let titlebarStrip: CGFloat = 4

    /// The band that behaves like a title bar. Six points, because the content now starts at 4 and
    /// the window is movable by its background as well — the strip is a shortcut for the gesture,
    /// not the only place it works.
    static let dragStrip: CGFloat = 6

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
                                 icons: store.botFaces,
                                 presentation: .pane,
                                 load: { roomID, since in try await model.roomPage(roomID, since: since) },
                                 send: { roomID, text, files in
                                     try await model.sendRoomMessage(roomID, text: text, attachments: files)
                                 },
                                 onActivity: { Task { await model.refreshRooms() } },
                                 onLatestSeq: { model.markRoomRead(room.id, seq: $0) },
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
                // With the computer beside it the reading pane hands back some width rather than
                // pushing the window's edges out of view.
                .frame(minWidth: store.isComputerPanelPresented
                              ? WindowLayout.conversationMinWithComputer
                              : WindowLayout.conversationMin,
                       maxWidth: .infinity,
                       maxHeight: .infinity)
                // A new bot is a new conversation: re-creating the pane drops the old scroll
                // position and any approval sheet that belonged to the last bot.
                .id(model.activeRoom.map { "room-\($0.id)" } ?? model.selectedBotID ?? "no-bot")

            // The bot's own panel, on the trailing edge: the phone's drawer as a pane. It is not
            // modal — the transcript keeps scrolling behind it, and a compaction keeps reporting
            // into it while you watch.
            //
            // The shared computer takes **this** slot, not the sidebar's and not a fourth pane: the
            // computer is a row on this panel, so it opens where the row is. `isBotPanelPresented`
            // is left alone, so closing the computer hands the panel back exactly as it was
            // (reported 2026-11-14, twice: first it was a third pane, then the wrong edge).
            if store.isComputerPanelPresented, !store.isComputerFullScreen {
                computerPane(fullScreen: false)
                    // The panel's own width, with a computer's floor: narrower than this and the
                    // screen inside stops being readable.
                    .frame(width: max(WindowLayout.botPanelWidth, WindowLayout.computerMin))
                    .transition(.move(edge: .trailing))
            } else if store.isBotPanelPresented {
                MacBotPanel(model: model, store: store)
                    .transition(.move(edge: .trailing))
            }

            // The shared computer, beside the conversation rather than over it: you read what the
            // bot says about the errand while watching it do the errand. Full screen is the
            // panel's own verb, so in that state this slot stays empty and the overlay below owns
            // the window — one pane instance alive either way.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panes start at the **window's** top edge, not at the bottom of the strip a title bar
        // would occupy. `.hiddenTitleBar` removed the bar but not the inset that stood where it
        // was, so both panes began 32 pt down and the transcript was clipped against that line,
        // cutting the first visible line through its glyphs. Rakazo has no such strip: its text
        // runs to the edge and dissolves under its own floating pill. The traffic lights need no
        // reservation — they live in the window's frame view and are hit-tested before this content
        // — and the 6 pt drag strip still owns the gesture at the top.
        .ignoresSafeArea(.container, edges: .top)
        // A third pane in a narrow window is grown, not clipped.
        .background(WindowWidthFitter(minimum: store.minimumWindowWidth).frame(width: 0, height: 0))
        .overlay {
            if store.isComputerPanelPresented, store.isComputerFullScreen {
                computerPane(fullScreen: true)
                    .background(Tokens.canvas)
                    .transition(.opacity)
            }
        }
        .background(Tokens.canvas)
        // Escape closes the topmost pane. The catcher sits under the shell, so it sees the key
        // before any view that might want it — except a text field, which keeps it.
        .background(EscapeKeyCatcher { store.closeTopmostOnEscape() }
                        .frame(width: 0, height: 0))
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
