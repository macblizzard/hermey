import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// The app's main screen: every bot this host serves.
///
/// A Hermes host is not one assistant. One gateway serves every profile, and each profile
/// is a bot with exactly one endless conversation. So the list is the *bots*, not
/// sessions: avatar, name, and a neutral subtitle that names the profile — never a
/// fabricated preview or a status the phone cannot know.
///
/// Tapping a row selects that bot and pushes its conversation. There is no switcher to
/// open and no sheet: leaving a conversation is the way back to this list.
struct BotListScreen: View {
    @ObservedObject var model: AppModel
    /// Called when a row is chosen, so the tab can push that bot's conversation.
    var onOpenBot: (Bot) -> Void = { _ in }
    /// How a room is opened. The bots tab supplies this so a group chat pushes onto the same
    /// navigation stack a bot's conversation pushes onto, instead of covering the app.
    var onOpenRoom: ((RoomSummary) -> Void)? = nil
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    @State private var query = ""
    /// The search field is a button until it is wanted: a permanent field row spends about 52 pt of
    /// a phone's list on something most visits never touch, and the list is the app.
    @State private var searchOpen = false
    @FocusState private var searchFocused: Bool
    /// Hidden bots are a view preference; this reveals them so nothing becomes unreachable.
    @State private var showHidden = false
    @State private var iconBot: Bot?
    /// Long-press → Bot Settings. Presented from this screen so the settings flow needs no
    /// plumbing from the tab, and so a long-press can never accidentally open the chat.
    @State private var settingsBot: Bot?
    @State private var soulBot: Bot?
    @State private var showAddBot = false
    @State private var showManageBots = false
    @State private var showStartGroupChat = false
    @State private var showGroupChats = false
    @State private var openRoom: RoomSummary?
    @State private var pendingRoomDelete: RoomSummary?
    /// Used only by this screen's own room cover (`onOpenRoom == nil`); the app's pushed room has
    /// its own controller. Same host TTS either way.
    @StateObject private var roomVoice = VoiceController()
    @AppStorage("lastOpenedBotsByHost") private var lastOpenedBotsJSON = "{}"

    private var lastOpenedBots: [String: String] {
        guard let data = lastOpenedBotsJSON.data(using: .utf8),
              let bots = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return bots
    }

    private var hostKey: String? { app.store.host?.baseURL.absoluteString }

    private var lastOpenedID: String? {
        guard let hostKey else { return nil }
        return lastOpenedBots[hostKey]
    }

    private func recordOpened(_ bot: Bot) {
        guard let hostKey else { return }
        var bots = lastOpenedBots
        bots[hostKey] = bot.id
        guard let data = try? JSONEncoder().encode(bots),
              let json = String(data: data, encoding: .utf8) else { return }
        lastOpenedBotsJSON = json
    }

    private var hiddenBots: [Bot] {
        model.bots.filter { model.isHidden(botID: $0.id) }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filtered: [Bot] {
        // Pinned first, then by last message; hidden bots are excluded by the model's ordering.
        let ordered = model.orderedBots
        guard !trimmedQuery.isEmpty else { return ordered }
        return ordered.filter { bot in
            bot.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || bot.id.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    /// Bot settings, lifted out of the sheet chain: with rooms, headers and the rest, the chain had
    /// grown past what the type checker will type in one expression.
    private func settingsSheet(for bot: Bot) -> some View {

            BotModelSettingsScreen(
                bot: bot,
                icon: app.botFaces[bot.id],
                load: { botID in try await model.modelCatalog(for: botID) },
                conversationIsOpen: model.selectedBotID == bot.id,
                resetConversation: { model.resetEndlessSession(for: bot.id) },
                save: { botID, option, confirmed in
                    switch try await model.configureModel(botID: botID,
                                                          model: option.id,
                                                          provider: option.provider,
                                                          confirm: confirmed) {
                    case .applied:
                        return .saved
                    case .confirmationRequired(let message):
                        return .confirmationRequired(message)
                    }
                },
                saveDescription: { botID, text in
                    try await model.configureDescription(botID: botID, description: text)
                },
                editSoul: { soulBot = bot })
    }

    var body: some View {
        List {
            roomsSection
            if let error = app.botFacesError {
                Text("Could not refresh bot icons: \(error)").font(.caption).foregroundStyle(Tokens.danger)
            }
            if model.botsLoading && model.bots.isEmpty {
                loadingRow
            } else if filtered.isEmpty && !(showHidden && !hiddenBots.isEmpty) {
                emptySection
            } else {
                chatsSection
                if showHidden, !hiddenBots.isEmpty { hiddenSection }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        // No app name in the bar: the icon you tapped already said which app this is, and every
        // point it takes is a bot the list does not show. The bar keeps only its two verbs.
        .safeAreaInset(edge: .top, spacing: 0) {
            if searchOpen { searchField }
        }
        .refreshable {
            await app.loadBots()
            // A pull-to-refresh is a request for what is on the host *now*, so the cached preview
            // lines are dropped rather than trusted.
            await model.loadBotPreviews(force: true)
        }
        // First fill: one `session.list` per bot, bounded and cached, so the rows get their third
        // line without a pull.
        .task {
            roomVoice.transport = app.makeVoiceTransport()
            await model.refreshDisabledBots()
            await model.refreshRooms()
            await model.loadBotPreviews()
        }
        .confirmationDialog(deleteTitle,
                            isPresented: deleteIsPresented,
                            titleVisibility: .visible) {
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
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is the moment the other device's turn should show up here.
            if phase == .active {
                Task {
                    await model.loadBotPreviews()
                    // A room's badge is only as fresh as its refresh: coming back to the app is
                    // exactly when the other bots' replies landed.
                    await model.refreshRooms()
                }
            }
        }
        .toolbar { toolbarContent }
        .sheet(item: $settingsBot) { bot in
            settingsSheet(for: bot)
        }
        .sheet(isPresented: $showAddBot) {
            AddBotSheet { name, description, face in
                // No soul: who the bot is lives in its settings, where it can be edited later.
                let created = try await model.addBot(name: name, description: description, soul: "")
                if let face { try? await app.saveBotFace(botID: created, face: face) }
            }
        }
        .sheet(isPresented: $showStartGroupChat) {
            StartGroupChatSheet(
                bots: model.bots,
                icons: app.botFaces,
                onCreate: { name, members in
                    try await model.startGroupChat(name: name.isEmpty ? "Group chat" : name,
                                                   members: members)
                },
                onCreated: { room in open(room) })
        }
        .sheet(isPresented: $showGroupChats) {
            GroupChatsSheet(
                load: { try await model.groupChats() },
                onOpen: { room in open(room) },
                onNew: { showStartGroupChat = true })
        }
        .fullScreenCover(item: $openRoom) { room in
            RoomChatView(
                room: room,
                icons: app.botFaces,
                load: { roomID, since in try await model.roomPage(roomID, since: since) },
                send: { roomID, text, files in
                    try await model.sendRoomMessage(roomID, text: text, attachments: files)
                },
                onActivity: { Task { await model.refreshRooms() } },
                onLatestSeq: { model.markRoomRead(room.id, seq: $0) },
                onRename: { name in try await model.renameRoom(room.id, to: name) },
                renameSignal: $model.renameRequest,
                speak: { try await roomVoice.speakAndWait($0) },
                markdown: { markdownMessage($0) })
        }
        .sheet(isPresented: $showManageBots) {
            ManageBotsSheet(
                bots: model.bots,
                hidden: { model.isHidden(botID: $0) },
                disabled: model.disabledBots,
                onToggleHidden: { model.toggleHidden(botID: $0) },
                onToggleEnabled: { profile, enabled in
                    try await model.setBotEnabled(profile, enabled)
                },
                onDelete: { profile in try await model.deleteBot(profile) })
        }
        .sheet(item: $soulBot) { bot in
            SoulEditorSheet(
                botName: bot.displayName,
                load: { try await model.describeBot(bot.id).soul },
                save: { try await model.saveSoul($0, for: bot.id) })
        }
        .sheet(item: $iconBot) { bot in
            BotIconPicker(botName: bot.displayName, selected: app.botFaces[bot.id]) { face in
                try await app.saveBotFace(botID: bot.id, face: face)
            }
        }
        .mobileConnectionBanner(connection: app.visibleConnection,
                                turnRunning: model.isStreaming,
                                host: app.hostLabel,
                                retry: { Task { await app.reconnect() } })
    }

    // MARK: Rows

    private func row(for bot: Bot) -> some View {
        Button {
            Haptics.selection()
            recordOpened(bot)
            onOpenBot(bot)
        } label: {
            HStack(alignment: .center, spacing: Geometry.rosterRowGap) {
                // A bot always has a face: its own if the host has one, otherwise the portrait its
                // id picks. Initials are what made the first second of every launch look empty.
                BotIconPortrait(app.botFaces[bot.id] ?? BotFace.default(for: bot.id),
                                size: Geometry.rosterAvatar,
                                isWorking: model.isStreaming && model.selectedBotID == bot.id)

                // Rakazo's row is two lines, not three: the name and when it last spoke on the
                // first, what it said on the second. The count moved to the app badge — the row
                // only has to say "there is something here", which the dot does.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(bot.displayName)
                            .font(TypeScale.font(TypeScale.sessionTitle,
                                                 weight: model.hasUnread(bot.id) ? .semibold : .medium))
                            .foregroundStyle(Tokens.textPrimary)
                            .lineLimit(1)

                        if model.isPinned(botID: bot.id) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Tokens.textMuted)
                                .accessibilityHidden(true)
                        }

                        Spacer(minLength: 6)

                        if let at = model.botPreviewTimes[bot.id] {
                            Text(RelativeTime.stamp(at))
                                .font(TypeScale.font(Tokens.rosterMeta))
                                .foregroundStyle(Tokens.textDim)
                                .monospacedDigit()
                                .lineLimit(1)
                                .layoutPriority(1)
                                .accessibilityLabel("last message \(RelativeTime.detailed(at))")
                        }

                        if model.hasUnread(bot.id) {
                            Circle()
                                .fill(Tokens.accent)
                                .frame(width: 8, height: 8)
                                .accessibilityLabel("unread")
                        }
                    }

                    Text(model.botPreviews[bot.id] ?? subtitle(for: bot))
                        .font(TypeScale.font(TypeScale.sessionPreview,
                                             weight: model.hasUnread(bot.id) ? .medium : .regular))
                        .foregroundStyle(model.hasUnread(bot.id) ? Tokens.textSecondary : Tokens.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, Geometry.rosterRowPadding)
            .frame(minHeight: Geometry.rosterRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { iconBot = bot } label: { Label("Bot icon", systemImage: "person.crop.circle") }
            Button { settingsBot = bot } label: { Label("Bot Settings", systemImage: "gearshape") }
            Button { soulBot = bot } label: { Label("Edit SOUL.md", systemImage: "doc.text") }
            Button {
                model.togglePin(botID: bot.id)
            } label: {
                Label(model.isPinned(botID: bot.id) ? "Unpin" : "Pin to top",
                      systemImage: model.isPinned(botID: bot.id) ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                model.toggleHidden(botID: bot.id)
            } label: {
                Label("Hide bot", systemImage: "eye.slash")
            }
        }
        .listRowBackground(Tokens.canvas)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: Geometry.rosterListPadding, bottom: 0, trailing: Geometry.rosterListPadding))
        .accessibilityLabel(accessibilityLabel(for: bot))
        .accessibilityHint("Opens the conversation with this bot")
    }

    /// A description written on the host is the useful line; without one, name what the row is.
    /// A profile whose id is its own name has nothing worth printing twice, so it gets a label
    /// rather than a repeat of the title.
    private func subtitle(for bot: Bot) -> String {
        if let description = bot.description, !description.isEmpty { return description }
        return bot.id == bot.displayName ? "Hermes profile" : bot.id
    }

    private func accessibilityLabel(for bot: Bot) -> String {
        var parts = [bot.displayName, "bot"]
        if model.isPinned(botID: bot.id) { parts.append("pinned") }
        if bot.id == lastOpenedID { parts.append("last opened") }
        return parts.joined(separator: ", ")
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            SpinningRing(color: Tokens.textMuted, size: 12, lineWidth: 1.5)
            Text("Loading bots…")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
        }
        .listRowBackground(Tokens.canvas)
        .listRowSeparator(.hidden)
        .padding(.vertical, 8)
    }

    // MARK: Empty states

    /// The dialog's three arguments as properties: inline, they were enough to push this view's
    /// body past what the type checker will solve.
    private var deleteTitle: String {
        if let room = pendingRoomDelete { return "Delete \(room.name)?" }
        return "Delete this group chat?"
    }

    /// Open a room the one way the list opens rooms: pushed by the app, or covered by this screen
    /// when it is on its own.
    private func open(_ room: RoomSummary) {
        // Reading it counts as read: the badge clears now, not when the list next refreshes.
        model.markRoomRead(room)
        if let onOpenRoom { onOpenRoom(room) } else { openRoom = room }
    }

    private var deleteIsPresented: Binding<Bool> {
        Binding(get: { pendingRoomDelete != nil },
                set: { if !$0 { pendingRoomDelete = nil } })
    }

    /// The rooms, above the bots. Extracted rather than inlined: the list's own body had grown past
    /// what the type checker will accept in one expression.
    @ViewBuilder
    private var roomsSection: some View {
        if !model.rooms.isEmpty {
            Section {
                ForEach(model.rooms) { room in
                    roomRow(room)
                }
            } header: {
                listHeading("GROUP CHATS")
            }
        }
    }

    private func roomRow(_ room: RoomSummary) -> some View {
        Button {
            open(room)
        } label: {
            GroupChatRow(room: room,
                         icons: app.botFaces,
                         unread: model.roomUnreadCount(room.id))
                .padding(.vertical, Geometry.rosterRowPadding)
                .frame(minHeight: Geometry.rosterRow)
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Rename is here, on the row, and nowhere else: a button in the room's chrome is the
            // one place a name change does not look like it belongs.
            Button {
                open(room)
                model.requestRename(room.id)
            } label: {
                Label("Rename group chat…", systemImage: "pencil")
            }
            Button(role: .destructive) { pendingRoomDelete = room } label: {
                Label("Delete group chat", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingRoomDelete = room } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        // A row in a `.plain` List gets the cell's own background — black under a hidden scroll
        // background — and its own separators and insets. A room is a row in the same list as a
        // bot, so it wears the same three: the app's canvas, no separator, the same 16 pt gutter.
        // Without this the group chats read as a black band inside the themed list.
        .listRowBackground(Tokens.canvas)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: Geometry.rosterListPadding, bottom: 0, trailing: Geometry.rosterListPadding))
    }

    private var chatsSection: some View {
        Section {
            ForEach(filtered) { bot in
                row(for: bot)
            }
        } header: {
            listHeading("CHATS")
        }
    }

    private var hiddenSection: some View {
        Section("HIDDEN") {
            ForEach(hiddenBots) { bot in
                Button {
                    model.toggleHidden(botID: bot.id)
                } label: {
                    HStack {
                        Text(bot.displayName).foregroundStyle(Tokens.textPrimary)
                        Spacer()
                        Text("Show").foregroundStyle(Tokens.accentText)
                    }
                }
            }
        }
    }

    private func listHeading(_ title: String) -> some View {
        Text(title)
            .font(TypeScale.font(TypeScale.caption, weight: .semibold))
            .foregroundStyle(Tokens.textMuted)
    }

    private var emptySection: some View {
        Section {
            Group {
                if !trimmedQuery.isEmpty {
                    messageBlock(icon: "magnifyingglass",
                                 title: "No matches",
                                 body: "No bot on this host matches “\(trimmedQuery)”.")
                } else if !app.isPaired {
                    unpairedState
                } else if model.botsLoading {
                    loadingBlock
                } else if let error = model.botsError {
                    errorState(error)
                } else {
                    noBotsState
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        }
    }

    private var unpairedState: some View {
        VStack(spacing: 14) {
            Avatar("Hermes", size: .hero, presence: .idle)
            Text("Pair with your host")
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text("Scan the pairing code from `hermes-bridge pair`, or paste the code your host printed.")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            OpenBotButton("Pair a device",
                          systemImage: "qrcode",
                          kind: .primary,
                          corners: .capsule) {
                app.isPairingPresented = true
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 56)
    }

    private var loadingBlock: some View {
        VStack(spacing: 10) {
            SpinningRing(color: Tokens.textMuted, size: 14, lineWidth: 1.5)
            Text("Looking for bots…")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Tokens.textDim)
            Text("Could not list this host's bots")
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text(error)
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            OpenBotButton("Try again",
                          systemImage: "arrow.clockwise",
                          kind: .secondary,
                          corners: .capsule) {
                Task { await app.loadBots() }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 56)
    }

    private var noBotsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Tokens.textDim)
            Text("No bots found on this host")
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text("The gateway answered, but listed no profiles. Check that this host has a Hermes bot to talk to, then look again.")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            OpenBotButton("Check again",
                          systemImage: "arrow.clockwise",
                          kind: .secondary,
                          corners: .capsule) {
                Task { await app.loadBots() }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 56)
    }

    private func messageBlock(icon: String, title: String, body: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Tokens.textDim)
            Text(title)
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text(body)
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 56)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if app.isPaired {
            // Two verbs, one on each corner, and nothing between them: search on the leading side
            // (the corner iOS leaves free on a root screen) and the menu on the trailing one.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { searchOpen.toggle() }
                    // The field takes focus in its own `onAppear`: setting it here would race the
                    // state change that creates the field, and iOS would drop the focus request.
                    if !searchOpen { query = "" }
                } label: {
                    // A bar button is a glyph: `Tokens.control` is the fill for a control sitting
                    // *on* a card, so a disc of it on the canvas read as a pale blob with a dim
                    // glyph inside it — the "why does this look off" of the first screenshot.
                    Image(systemName: searchOpen ? "xmark" : "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Tokens.textPrimary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(searchOpen ? "Close search" : "Search bots")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showHidden.toggle()
                    } label: {
                        Label("Hidden bots", systemImage: showHidden ? "checkmark" : "circle")
                    }
                    .accessibilityValue(showHidden ? "On" : "Off")

                    Divider()

                    Button { showAddBot = true } label: {
                        Label("Add bot", systemImage: "plus.circle")
                    }
                    Button { showManageBots = true } label: {
                        Label("Manage bots", systemImage: "slider.horizontal.3")
                    }

                    Divider()

                    Button { showStartGroupChat = true } label: {
                        Label("New group chat", systemImage: "person.3")
                    }

                    Divider()

                    // Clears every badge on the list at once: a person who is done with the app
                    // should not have to open each chat to say so.
                    Button { model.markAllRead() } label: {
                        Label("Mark all as read", systemImage: "checkmark.circle")
                    }
                    .disabled(!model.hasAnyUnread)
                } label: {
                    // Three dots, because this is a menu and not a filter: the old funnel icon
                    // promised "narrow the list" and then offered to add a bot. A bare glyph: the
                    // bar already draws its own control chrome, and a second surface inside it read
                    // as a box in a circle.
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(showHidden ? Tokens.accentText : Tokens.textPrimary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Bot list menu")
            }
        }
        if !app.isPaired {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.isPairingPresented = true
                } label: {
                    Label("Pair", systemImage: "link.badge.plus")
                }
                .tint(Tokens.accentText)
            }
        }
    }

    /// The search field, only while it is wanted: a capsule under the bar, focused on open, that
    /// filters as it types and puts the list back the way it was when it closes.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.textDim)
            TextField("Search bots", text: $query)
                .focused($searchFocused)
                .font(TypeScale.font(TypeScale.chatBody))
                .foregroundStyle(Tokens.textPrimary)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Tokens.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Tokens.surface))
        .overlay(Capsule().strokeBorder(Tokens.border, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear { searchFocused = true }
        .accessibilityIdentifier("botsSearchField")
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Bots · paired") {
    let environment = AppEnvironment.preview()
    NavigationStack {
        BotListScreen(model: environment.model)
            .navigationDestination(for: Bot.self) { bot in
                ConversationScreen(model: environment.model, bot: bot)
            }
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}
#endif

#if DEBUG
#Preview("Bots · unpaired") {
    let environment = AppEnvironment.preview(paired: false)
    NavigationStack {
        BotListScreen(model: environment.model)
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
}
#endif
