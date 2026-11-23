import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// The left panel: **bots, and the conversations behind them**.
///
/// This is the phone's bot list on the desktop. One row per Hermes profile — name, description,
/// pin, hide, unread dot, context menu — and clicking a row opens that bot's single endless
/// conversation in the pane on the right. There is no session browser under it and no "new session"
/// button: a bot has one conversation, and the app resumes it.
///
/// The search is one field with two halves: from two characters on, the phrase goes to the host,
/// which scans **every bot's conversation** and answers with snippets, drawn above the rows; below
/// that, and alongside it, the same phrase filters bot names. Both halves are one combined list to
/// the keyboard — findings first, then bots — so Up/Down and Return work without the user having to
/// know which half a row came from.
///
/// The panel has two rows of chrome, and the list scrolls between them: an **attention** row at the
/// top (the bell for everything waiting, then the ＋ that adds and manages), and a **floor** row at
/// the bottom (Settings on the left; search and the panel's own toggle on the right). The split is
/// on purpose: the top row is what the panel *is for* — the bots and what they have waiting — and
/// the bottom row is what the panel *sits in* — the app's settings, the way back to a narrower
/// list, and the finder. Neither row scrolls away with the list.
///
/// Connection, reconnect, latency, pairing and devices live in Settings ▸ Connection, which stays
/// reachable with no bot selected and no host paired.
struct BotSidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    /// Hidden bots are a view preference; this reveals them so nothing becomes unreachable.
    @State private var showsHiddenBots = false

    /// The live bot filter. Matched case-insensitively against name and id by `SidebarBotList`, and
    /// — when it is two characters or longer — sent to the host, which searches every bot's
    /// conversation and answers with findings. One field, two halves of one answer: the findings are
    /// drawn above the rows by the same list.
    @State private var searchQuery = ""
    /// Search is a button, not a box: the field only exists while it is being used, so the row
    /// holds four glyphs and the list gets the width back.
    @State private var isSearching = false
    /// The bell's popover: everything waiting, drawn from the same unread state the rows are.
    @State private var showsNotifications = false
    /// Where the keyboard is in the combined answer (findings first, then bots). Owned here because
    /// the keys arrive here; drawn by `SidebarBotList` because the rows live there.
    @State private var searchSelection = SidebarSearchSelection()
    /// The debounce in flight. Cancelled by the next keystroke, so a fast typist asks the host once.
    @State private var searchTask: Task<Void, Never>?


    @State private var pendingRoomDelete: RoomSummary?

    var body: some View {
        VStack(spacing: 0) {
            header
            // The list takes every point between the two rows of chrome: on this screen the bots
            // *are* the panel, and the two bars are its frame rather than blocks above and below it.
            ZStack(alignment: .bottom) {
                content
                    .padding(.horizontal, Geometry.sidebarInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // Rows dissolve at both ends instead of being cut off by the header and the
                    // floor: 26 pt of gradient each way, fixed rather than a fraction, so a short
                    // list does not fade away to nothing and a long one does not lose a row to the
                    // blur. The top half is a mask (there is nothing behind the rows but the panel
                    // itself); the bottom half is the floor's own scrim, drawn as a sibling so it
                    // can blend the bar's fill upward into the list.
                    .mask(listFade)
                bottomDissolve
                    .frame(height: Self.dissolveHeight)
                    .allowsHitTesting(false)
            }
            bottomChrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.sidebar)
        .task {
            await model.refreshDisabledBots()
            await model.refreshRooms()
            // Groups live on the host and the other device writes them too, so the list asks for
            // them whenever the panel appears rather than trusting what the last launch left.
            await model.loadBotCategories()
        }
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
                    await model.refreshRooms()
                }
            }
            Button("Cancel", role: .cancel) { pendingRoomDelete = nil }
        } message: {
            Text("The room is removed from every device. Its transcript stays on the host.")
        }
        .sheet(isPresented: $store.isAddBotPresented) {
            AddBotSheet { name, description, face in
                // No soul: who the bot is lives in its settings, where it can be edited later.
                let created = try await model.addBot(name: name, description: description, soul: "")
                if let face { try? await store.saveBotFace(botID: created, face: face) }
            }
            .hermesSheetChrome()
        }
        .sheet(isPresented: $store.isStartGroupChatPresented) {
            StartGroupChatSheet(
                bots: model.bots,
                icons: store.botFaces,
                onCreate: { name, members in
                    try await model.startGroupChat(name: name.isEmpty ? "Group chat" : name,
                                                   members: members)
                },
                onCreated: { room in model.openRoom(room) })
            .hermesSheetChrome()
        }
        .sheet(isPresented: $store.isGroupChatsPresented) {
            GroupChatsSheet(
                load: { try await model.groupChats() },
                onOpen: { room in model.openRoom(room) },
                onNew: { store.isStartGroupChatPresented = true })
            .hermesSheetChrome()
        }
        .sheet(isPresented: $store.isManageBotsPresented) {
            ManageBotsSheet(
                bots: model.bots,
                hidden: { model.isHidden(botID: $0) },
                disabled: model.disabledBots,
                onToggleHidden: { model.toggleHidden(botID: $0) },
                onToggleEnabled: { profile, enabled in
                    try await model.setBotEnabled(profile, enabled)
                },
                onDelete: { profile in try await model.deleteBot(profile) },
                categories: model.botCategories,
                categoryID: { model.categoryID(for: $0) },
                onSetCategory: { profile, category in
                    try await model.setBotCategory(profile, to: category)
                })
            .hermesSheetChrome()
        }
    }

    // MARK: Header

    /// The panel's chrome rows.
    ///
    /// 34 pt tall each — the same height as the chat header's pill — and the list scrolls between
    /// them. The top one holds two verbs and nothing else: the bell for what is waiting and the ＋
    /// that adds and manages. Search, the panel's own toggle and Settings are views *of the window*
    /// rather than of the list, so they live on the floor row, where a hand already is when it has
    /// reached the end of the roster.
    private var header: some View {
        // The row of verbs does not change when search opens: the field drops in **above the floor
        // bar**, under the list. Opened in place, the field took this row's own line — the traffic
        // lights' line — and blended into the window's chrome (reported 2026-11-14).
        HStack(spacing: 2) {
            // Every control in one cluster on the right, none on the left: the row is a row of
            // verbs for the list below it, and a verb split across both edges reads as two
            // groups when it is one.
            // The empty left half of this row is a title bar, not dead space: drag it to move the
            // window and double-click it to zoom/restore. The system 6 pt strip above the row works,
            // but that is a very small target — "I can't double click anywhere on the sidebar top"
            // (reported 2026-11-17). Buttons stay on top and keep their own clicks.
            TitlebarDragArea()
                .frame(maxWidth: .infinity)

            notificationsButton

            addMenu
        }
        .padding(.horizontal, Geometry.sidebarInset)
        // The traffic-light strip: the panel's fill runs to the window's top edge and the row
        // sits on the lights' own line. 34 pt tall so its centre — 4 plus half — is 21, the
        // same line as the chat header's pill.
        .padding(.top, WorkspaceShell.titlebarStrip)
        .frame(height: WorkspaceShell.titlebarStrip + 34)
        // Gaps between the buttons belong to the title bar too — one 38 pt band across the whole
        // sidebar top, with the controls still hit-tested above it.
        .background(alignment: .top) {
            TitlebarDragArea()
                .frame(height: WorkspaceShell.titlebarStrip + 34)
        }
        .padding(.bottom, 4)
    }

    /// Everything waiting, one tap away.
    ///
    /// The glyph wears a dot, not a number: "something is waiting" is what the row is for, and the
    /// list behind the bell says which bot and how many. The count is already on the rows and in the
    /// bots' own badges; a number here would be the third place to disagree.
    private var notificationsButton: some View {
        HermeyIconButton("bell", label: "Waiting for you", size: .small) {
            showsNotifications.toggle()
        }
        // ⇧⌘N: the ⌘N a Mac user reaches for was freed when "New Session" went away (a bot has one
        // conversation), and nothing in the window takes it. It exists only while this panel does —
        // the bell is the panel's own door.
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .waitingDot(!waitingBots.isEmpty)
        .help("Waiting for you (⇧⌘N)")
        .popover(isPresented: $showsNotifications, arrowEdge: .top) {
            WaitingBotsInbox(bots: waitingBots) { botID in
                self.showsNotifications = false
                // Opening the row *is* reading it: the badge goes through the same door the pet and
                // the row's dot use, so the count, the dot and the read mark move together.
                self.store.selectBot(botID)
                self.store.model.markBotRead(botID)
            }
            .frame(width: 300)
        }
        .accessibilityIdentifier("sidebar.notifications")
    }

    // MARK: Floor

    /// The panel's floor: the search field while it is open, then the bar. Both are chrome, and both
    /// stay put while the list scrolls between them. Escape and the keyboard's walk over the search
    /// rows live here, next to the field they belong to.
    ///
    /// The field **expands above the bar** rather than taking part of it: the bar's grouping —
    /// Settings left, search and the toggle right — is the panel's geometry, and a row that
    /// re-flowed when someone typed would move the toggle out from under the pointer mid-gesture.
    private var bottomChrome: some View {
        VStack(spacing: 0) {
            if isSearching {
                searchRow
            }
            bottomBar
        }
        .onExitCommand { if isSearching { closeSearch() } }
        .animation(.easeOut(duration: 0.12), value: isSearching)
        // The keyboard walks the same list the pointer sees. Recomputed whenever a finding or a bot
        // arrives; `SidebarSearchSelection` keeps the cursor on its row, or drops it if that row is
        // gone.
        .onChange(of: searchRows) { _, rows in searchSelection.update(rows: rows) }
    }

    /// The live field, opened by the magnifier on the bar below it.
    private var searchRow: some View {
        HStack(spacing: 6) {
            MacSidebarSearchField(text: $searchQuery,
                                  prompt: "Search bots and messages",
                                  onMoveUp: { moveHighlight(-1) },
                                  onMoveDown: { moveHighlight(1) },
                                  onSubmit: { openHighlighted() },
                                  onEscape: { closeSearch() },
                                  autofocuses: true)
                .onChange(of: searchQuery) { _, typed in searchTranscripts(for: typed) }
                .layoutPriority(1)
                .accessibilityIdentifier("sidebar.botSearch")

            HermeyIconButton("xmark", label: "Close search", size: .small) { closeSearch() }
                .help("Close search (esc)")
        }
        .padding(.horizontal, Geometry.sidebarInset)
        .padding(.bottom, 6)
        .accessibilityIdentifier("sidebar.searchRow")
    }

    /// Settings on the left; search and the panel's own toggle on the right.
    ///
    /// Two groups on two edges because they are two kinds of verb: a destination that leaves the
    /// panel, and two controls of the panel itself. The bar is the panel's own fill and carries no
    /// hairline — `bottomDissolve` above it is the separator, the same 26 pt the header draws at the
    /// other end, so the list dissolves into the bar rather than being cut by its top edge.
    private var bottomBar: some View {
        HStack(spacing: 2) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textMuted)
                    .frame(width: 24, height: 24)
                    .hoverFill(rest: .clear, hover: Tokens.controlHover, radius: Tokens.radiusControl)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")

            Spacer(minLength: 0)

            HermeyIconButton("magnifyingglass",
                             label: isSearching ? "Close search" : "Search bots and messages",
                             size: .small) {
                if isSearching { closeSearch() } else { isSearching = true }
            }
            .help(isSearching ? "Close search (esc)" : "Search bots and messages")

            // The panel's own toggle, where Midnight keeps it. The chat header shows one only
            // while this panel is hidden, so the door is never gone.
            HermeyIconButton("sidebar.left", label: "Hide the bot panel", size: .small) {
                store.toggleSidebar()
            }
            .help("Hide the bot panel")
        }
        .padding(.horizontal, Geometry.sidebarInset)
        .frame(height: Self.bottomBarHeight)
        .background(Tokens.sidebar)
        .accessibilityIdentifier("sidebar.bottomBar")
    }

    // MARK: Waiting

    /// The bell's list, built from the model's own unread state and nothing else.
    ///
    /// `unreadCounts` / `unreadBots` are the authority (the pets and the row dots read them too), the
    /// roster supplies the names, the preview cache supplies the line under each name, and the face
    /// store supplies the avatar. No second counter lives anywhere in this view.
    private var waitingBots: [WaitingBot] {
        WaitingBots.rows(unread: store.model.unreadBots,
                         counts: store.model.unreadCounts,
                         names: waitingNames,
                         previews: store.model.botPreviews,
                         faces: waitingFaces)
    }

    private var waitingNames: [String: String] {
        Dictionary(store.model.bots.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    private var waitingFaces: [String: String] {
        store.botFaces.mapValues { $0.raw }
    }

    /// The combined answer, in the order the keyboard walks it: findings first, then the bots whose
    /// names match. The list draws its own copy of this order from the same helpers; this one exists
    /// so Up/Down and Return know what "the next row" is without asking a view.
    private var searchRows: [SidebarSearchRow] {
        guard isSearching else { return [] }
        return SidebarSearch.rows(hits: activeHits, botIDs: matchingBotIDs)
    }

    /// The bots the query matches, in the order the list draws them: visible first, then the hidden
    /// ones when the panel is showing them.
    private var matchingBotIDs: [String] {
        guard isSearching else { return [] }
        var ids = model.orderedBots
            .filter { SidebarSearch.matches($0, query: searchQuery) }
            .map(\.id)
        if showsHiddenBots {
            ids += model.bots
                .filter { model.isHidden(botID: $0.id) && SidebarSearch.matches($0, query: searchQuery) }
                .map(\.id)
        }
        return ids
    }

    /// Findings only while they answer the phrase in the field: a late answer to an older query is
    /// not something Return should open.
    private var activeHits: [BotSearchHit] {
        guard isSearching else { return [] }
        let phase = SidebarSearch.phase(query: searchQuery,
                                        answered: model.searchQuery,
                                        running: model.searchRunning,
                                        hits: model.searchPage.hits.count,
                                        botMatches: matchingBotIDs.count)
        return phase == .results ? model.searchPage.hits : []
    }

    // MARK: - Search

    /// Typing is not a search per keystroke.
    ///
    /// Two layers, on purpose. Here: a 200 ms quiet period, with the previous wait cancelled, so a
    /// fast typist produces one request rather than one per character. In `AppModel`: a token that
    /// every answer is checked against, so an answer to an older phrase that is already on the wire
    /// cannot land on top of a newer one. The debounce keeps the wire quiet; the token keeps it
    /// correct.
    private func searchTranscripts(for typed: String) {
        searchTask?.cancel()
        let needle = SidebarSearch.trimmed(typed)
        guard needle.count >= SidebarSearch.minimumQuery else {
            // Below the host's floor nothing is asked, and the previous answer is dropped at once:
            // leaving it under a one-character field would describe a search nobody is running.
            searchTask = Task {
                // …unless a later keystroke overtook this one before it ran.
                guard SidebarSearch.trimmed(searchQuery).count < SidebarSearch.minimumQuery else { return }
                await store.model.searchTranscripts("")
            }
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            // A request that wakes up after the field moved on is not sent at all.
            guard SidebarSearch.trimmed(searchQuery) == needle else { return }
            await store.model.searchTranscripts(needle)
        }
    }

    private func moveHighlight(_ direction: Int) {
        // The rows may have arrived since the last keystroke; adopt them before moving.
        searchSelection.update(rows: searchRows)
        searchSelection.move(by: direction)
    }

    /// Return: open the row the keyboard is on, or the first row when it has not chosen one yet.
    private func openHighlighted() {
        searchSelection.update(rows: searchRows)
        guard let row = searchSelection.opening else { return }
        open(row)
    }

    private func open(_ row: SidebarSearchRow) {
        switch row {
        case .bot(let id):
            store.selectBot(id)
        case .message(let id):
            guard let hit = model.searchPage.hits.first(where: { $0.id == id }) else { return }
            openHit(hit)
        }
    }

    /// A finding, opened.
    ///
    /// The bot's conversation is resumed first — that is what `selectBot` means on this app — and
    /// then the reader is put at the message: see `WorkspaceStore.openSearchHit`. The phrase goes
    /// with it, because that is what the conversation's own find bar needs to land on the row.
    private func openHit(_ hit: BotSearchHit) {
        store.openSearchHit(hit, query: searchQuery)
    }

    private func closeSearch() {
        searchTask?.cancel()
        searchTask = nil
        withAnimation(.easeOut(duration: 0.12)) {
            isSearching = false
            searchQuery = ""
        }
        searchSelection.clear()
        Task { await store.model.searchTranscripts("") }
    }

    /// The plus, in the filled square Midnight gives it: the one button in the row that is a verb
    /// rather than a view control. The verbs are ours — add, group chat, manage, hidden, read.
    private var addMenu: some View {
        Menu {
            Button { store.isAddBotPresented = true } label: { Label("Add bot…", systemImage: "plus.circle") }
            Button { store.isStartGroupChatPresented = true } label: {
                Label("Start group chat…", systemImage: "person.3")
            }
            Button { store.isManageBotsPresented = true } label: {
                Label("Manage bots…", systemImage: "slider.horizontal.3")
            }
            Divider()
            // Groups are the owner's, stored on the host: they are made here rather than only from
            // the phone, and the list's own category headings carry rename and delete.
            Button { BotMenuRouter.shared.requestNewCategory() } label: {
                Label("New category…", systemImage: "folder.badge.plus")
            }
            Divider()
            // Same control as the phone's list filter: a switch, not a second list.
            Toggle("Show hidden bots", isOn: $showsHiddenBots)
            Divider()
            // One act for the whole list: opening nine chats to clear nine dots is not reading.
            Button { store.model.markAllRead() } label: {
                Label("Mark all as read", systemImage: "checkmark.circle")
            }
            .disabled(!store.model.hasAnyUnread)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Tokens.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Tokens.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // The first focusable control in a new window wears the system focus ring, and a ring on
        // the list's "+" at launch reads as "this is selected" when nothing is. The + is a verb,
        // not a tab stop that benefits from the ring; Tab still reaches everything after it.
        .focusEffectDisabled()
        .help("Add a bot, start a group chat, manage the list")
        .accessibilityLabel("Bot list menu")
    }

    /// The top of the list's dissolve: transparent at the header's edge, solid 26 pt down.
    ///
    /// Drawn as a mask so it costs no colour of its own and follows the theme. The other end of the
    /// list is `bottomDissolve` — the same 26 pt, mirrored, drawn in the panel's own fill above the
    /// floor bar.
    private var listFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.dissolveHeight)
            Color.black
        }
    }

    /// The bottom of the same dissolve, mirrored: the bar's fill rising into the list.
    ///
    /// Exactly the top fade's height, and its colours in the panel's own terms — `Tokens.sidebar` at
    /// the bar, fading to nothing upward — so rows approaching the floor dissolve into the bar
    /// instead of stopping dead at its edge. This is why the bar carries no hairline of its own: the
    /// gradient *is* the separation, and the two rows of chrome are framed the same way.
    private var bottomDissolve: some View {
        LinearGradient(colors: [Tokens.sidebar, Tokens.sidebar.opacity(0)],
                       startPoint: .bottom,
                       endPoint: .top)
            .frame(maxWidth: .infinity)
    }

    /// The height of one end of the dissolve — 26 pt, the same at the top and the bottom.
    private static let dissolveHeight: CGFloat = 26

    /// The floor bar's height: the top row's 34 pt, so the two rows of chrome read as one frame.
    private static let bottomBarHeight: CGFloat = 34

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !store.isPaired {
            unpairedState
        } else if model.bots.isEmpty {
            // No "finding bots" state of its own: while the roster is being asked for, the launch
            // screen is what covers this panel (`BootScreen` / `LaunchGateView`), and a spinner
            // behind a splash is a second, invisible loading state. The states below are the ones
            // that can still be true once the gate has opened — a host that failed, a host that is
            // not connected (the deadline's path, with its own Connect button), or a host that
            // answered with no bots at all.
            if let error = model.botsError {
                botsErrorState(error)
            } else if model.connection.isLive, model.rosterAnswered {
                noBotsState
            } else if model.connection.isLive {
                // The socket is up and the roster never arrived: the deadline's path. Saying "no
                // bots found" here would blame the host for a question it has not answered.
                awaitingRosterState
            } else {
                notConnectedState
            }
        } else {
            SidebarBotList(model: model,
                           store: store,
                           showsHiddenBots: $showsHiddenBots,
                           query: searchQuery,
                           fillsAvailableHeight: true,
                           onOpenRoom: { room in model.openRoom(room) },
                           onDeleteRoom: { pendingRoomDelete = $0 },
                           onRenameRoom: { room in
                               // Open it first: the field lives in the room, and a name is easier
                               // to edit with the conversation it belongs to on screen.
                               model.openRoom(room)
                               model.requestRename(room.id)
                           },
                           onOpenHit: openHit,
                           highlighted: searchSelection.highlighted)
        }
    }

    // MARK: Empty states

    private var unpairedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("NO HOST")
                .padding(.horizontal, 8)
            Text("Pair this Mac with your Hermes host to list its bots. Nothing is sent until you do.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            HermeyButton("Pair host…", systemImage: "link", kind: .secondary, size: .small) {
                store.isPairSheetPresented = true
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
    }

    /// Paired with a host that has not been dialled yet — say so instead of "no bots", which
    /// would blame the host for a socket that was never opened.
    private var notConnectedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A launch that is dialling is not a host that is down: the caption is the difference
            // between "wait a second" and "go and find your token".
            SectionCaption(model.connection == .connecting ? "CONNECTING" : "NOT CONNECTED")
                .padding(.horizontal, 8)
            Text(model.connection == .connecting
                 ? "Reaching \(store.pairing?.displayHost ?? model.hostName)…"
                 : "Connect to \(store.pairing?.displayHost ?? model.hostName) to list its bots.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            HermeyButton("Connect",
                          systemImage: "bolt.horizontal",
                          kind: .secondary,
                          size: .small,
                          isBusy: model.connection == .connecting) {
                Task { await store.connect() }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
    }

    /// The host answered `profiles.list` and named no bots. This is a state the user can
    /// act on, not a failure to retry forever, so it says what happened and offers one
    /// refresh rather than a spinner.
    private var noBotsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("NO BOTS")
                .padding(.horizontal, 8)
            Text("No bots found on this host.")
                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            Text("The gateway answered, but listed no profiles. Check that this host has a Hermes bot to talk to, then check again.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            HermeyButton("Check again",
                          systemImage: "arrow.clockwise",
                          kind: .secondary,
                          size: .small) {
                Task { await store.loadBots() }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
    }

    /// Connected, but the roster never came back — the launch gate's deadline path.
    ///
    /// This is not a loading state: the launch screen had the loading window and gave up on it, so
    /// what is left is a fact ("the host has not listed its bots") and the one action that re-asks.
    private var awaitingRosterState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("WAITING FOR THE HOST")
                .padding(.horizontal, 8)
            Text("The host's connection is up, but it has not listed its bots.")
                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            Text("Ask it again — a host that is still starting its gateway will answer on the second try.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            HermeyButton("Ask again",
                          systemImage: "arrow.clockwise",
                          kind: .secondary,
                          size: .small) {
                Task { await store.loadBots() }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
    }

    /// `profiles.list` failed. Say which call failed and what it said, plus one retry.
    private func botsErrorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("BOTS UNAVAILABLE")
                .padding(.horizontal, 8)
            Text("Could not list this host's bots.")
                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            Text(message)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            HermeyButton("Try again",
                          systemImage: "arrow.clockwise",
                          kind: .secondary,
                          size: .small,
                          isDisabled: !model.connection.isLive) {
                Task { await store.loadBots() }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
    }
}

// MARK: - Previews

private struct BotSidebarPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        BotSidebarView(model: store.model, store: store)
            .frame(width: Geometry.sidebarDefault, height: 640)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

private struct BotSidebarEmptyPreview: View {
    @StateObject private var store = PreviewWorkspace.store(.empty)

    var body: some View {
        BotSidebarView(model: store.model, store: store)
            .frame(width: Geometry.sidebarDefault, height: 640)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

private struct BotSidebarFloorPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        // The panel at its 200 pt floor: the bell and the ＋ above, the floor bar below, the rows
        // between them.
        BotSidebarView(model: store.model, store: store)
            .frame(width: WorkspaceStore.sidebarFloor, height: 640)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Bot panel") {
    BotSidebarPreview()
}
#endif

#if DEBUG
#Preview("Bot panel · no bots") {
    BotSidebarEmptyPreview()
}
#endif

#if DEBUG
#Preview("Bot panel · 200 pt floor") {
    BotSidebarFloorPreview()
}
#endif
