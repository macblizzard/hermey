import HermesAppKit
import HermesKit
import OpenBotUI
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
/// The header is one row of chrome: the bot filter (a field, not an icon that opens one), the
/// hidden-bots filter and Settings. There is no footer — the list takes the panel's last point.
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
    /// Where the keyboard is in the combined answer (findings first, then bots). Owned here because
    /// the keys arrive here; drawn by `SidebarBotList` because the rows live there.
    @State private var searchSelection = SidebarSearchSelection()
    /// The debounce in flight. Cancelled by the next keystroke, so a fast typist asks the host once.
    @State private var searchTask: Task<Void, Never>?


    @State private var pendingRoomDelete: RoomSummary?

    var body: some View {
        VStack(spacing: 0) {
            header
            // The list takes every point left under the header: on this screen the bots *are*
            // the panel, not a block above a session list and not a block above a footer chip.
            content
                .padding(.horizontal, Geometry.sidebarInset)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Rows dissolve at both ends instead of being cut off by the header and the floor:
                // 26 pt of gradient each way, fixed rather than a fraction, so a short list does
                // not fade away to nothing and a long one does not lose a row to the blur.
                .mask(listFade)
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

    /// The panel's chrome row: search, the panel's own toggle, then the verbs and Settings.
    ///
    /// Rakazo's arrangement, and the reason the search box is gone: a permanently open field costs
    /// the row its whole width for the one moment in ten it is used. The magnifier opens it, the ✕
    /// or Escape closes it, and the roster gets its width back in between.
    private var header: some View {
        VStack(spacing: 0) {
            // The row of verbs does not change when search opens: the field drops in **under** the
            // button that asked for it. Opened in place, the field took the row's own line — the
            // traffic lights' line — and blended into the window's chrome (reported 2026-11-14).
            HStack(spacing: 2) {
                // Every control in one cluster on the right, none on the left: the row is a row of
                // verbs for the list below it, and a verb split across both edges reads as two
                // groups when it is one.
                Spacer(minLength: 0)

                OpenBotIconButton("magnifyingglass",
                                  label: isSearching ? "Close search" : "Search bots and messages",
                                  size: .small) {
                    if isSearching { closeSearch() } else { isSearching = true }
                }
                .help(isSearching ? "Close search (esc)" : "Search bots and messages")

                // The panel's own toggle, where Rakazo keeps it. The chat header shows one only
                // while this panel is hidden, so the door is never gone.
                OpenBotIconButton("sidebar.left", label: "Hide the bot panel", size: .small) {
                    store.toggleSidebar()
                }
                .help("Hide the bot panel")

                addMenu

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.textMuted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, Geometry.sidebarInset)
            // The traffic-light strip: the panel's fill runs to the window's top edge and the row
            // sits on the lights' own line. 34 pt tall so its centre — 4 plus half — is 21, the
            // same line as the chat header's pill.
            .padding(.top, WorkspaceShell.titlebarStrip)
            .frame(height: WorkspaceShell.titlebarStrip + 34)

            if isSearching {
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

                    OpenBotIconButton("xmark", label: "Close search", size: .small) { closeSearch() }
                        .help("Close search (esc)")
                }
                .padding(.horizontal, Geometry.sidebarInset)
                .padding(.top, 2)
                .accessibilityIdentifier("sidebar.searchRow")
            }
        }
        .padding(.bottom, 6)
        .onExitCommand { if isSearching { closeSearch() } }
        .animation(.easeOut(duration: 0.12), value: isSearching)
        // The keyboard walks the same list the pointer sees. Recomputed whenever a finding or a bot
        // arrives; `SidebarSearchSelection` keeps the cursor on its row, or drops it if that row is
        // gone.
        .onChange(of: searchRows) { _, rows in searchSelection.update(rows: rows) }
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

    /// The plus, in the filled square Rakazo gives it: the one button in the row that is a verb
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

    /// The list's fade: transparent, solid, transparent, with the solid part taking whatever is
    /// left. Drawn as a mask so it costs no colour of its own and follows the theme.
    private var listFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 26)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 26)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !store.isPaired {
            unpairedState
        } else if model.bots.isEmpty {
            if model.botsLoading {
                discoveringBotsState
            } else if let error = model.botsError {
                botsErrorState(error)
            } else if model.connection.isLive {
                noBotsState
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
            OpenBotButton("Pair host…", systemImage: "link", kind: .secondary, size: .small) {
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
            OpenBotButton("Connect",
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
            OpenBotButton("Check again",
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
            OpenBotButton("Try again",
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

    private var discoveringBotsState: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("FINDING BOTS")
                .padding(.horizontal, 8)
            HStack(spacing: 8) {
                SpinningRing(color: Tokens.textDim, size: 10, lineWidth: 1.4)
                Text("Asking the host which bots it serves…")
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textMuted)
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
        // The panel at its 200 pt floor: search field, two buttons, rows.
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
