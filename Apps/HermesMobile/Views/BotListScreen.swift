import SwiftUI
import HermesKit
import HermesAppKit
import HermeyUI

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
    var onGraphite: (Bot) -> Void = { _ in }
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
    /// Long-press → Bot Settings. Presented from this screen so the settings flow needs no
    /// plumbing from the tab, and so a long-press can never accidentally open the chat.
    @State private var settingsBot: Bot?

    /// The bot whose **All sessions…** sheet is open. Presented from this screen so a long-press
    /// can list every conversation the host keeps without leaving the list first.
    @State private var sessionsBot: Bot?
    @State private var showAddBot = false
    @State private var showManageBots = false
    @State private var showStartGroupChat = false
    /// The app's own settings: pairing, theme, notifications. It used to be the second half of the
    /// bottom tab pill, which went the way of the tab bar itself.
    @State private var showAppSettings = false
    /// Everything waiting, in a sheet — the same list the Mac's bell draws in a popover.
    @State private var showWaiting = false
    @State private var showGroupChats = false
    @State private var openRoom: RoomSummary?
    @State private var pendingRoomDelete: RoomSummary?
    /// Used only by this screen's own room cover (`onOpenRoom == nil`); the app's pushed room has
    /// its own controller. Same host TTS either way.
    @StateObject private var roomVoice = VoiceController()
    @AppStorage("lastOpenedBotsByHost") private var lastOpenedBotsJSON = "{}"
    /// Which headings are collapsed. One JSON map rather than an `@AppStorage` per category: the
    /// categories live on the host and come and go, and a property per key cannot follow that.
    @AppStorage("hermey.collapsedBotGroups") private var collapsedGroupsJSON = "{}"
    /// The list's size, dragged in Appearance. Default reproduces the shipped row exactly.
    @AppStorage(BotListMetrics.storageKey) private var listScale = BotListMetrics.defaultScale
    @State private var showAddCategory = false
    @State private var newCategoryName = ""
    /// The last category write the host refused or could not be reached for. A group kept on the
    /// phone alone is exactly the bug this surface exists to stop being silent.
    @State private var categoryError: String?

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

    /// One tap, one open.
    ///
    /// `beginOpen` is the gate and it is deliberately first: it paints the cached conversation
    /// synchronously (before the push, so the first frame of the next screen is already the right
    /// transcript), and it answers `false` for a bot that is already opening — which makes a second
    /// tap on the same row *nothing at all*, rather than a second `Task`, a second push and a second
    /// resume racing the first. A tap on a different row cancels the open in flight.
    ///
    /// The push itself stays with the tab that owns the navigation stack: `onGraphite` is called
    /// once per accepted tap, and the tab keeps one screen for one open.
    private func openBot(_ bot: Bot) {
        guard model.beginOpen(bot.id) else { return }
        recordOpened(bot)
        onGraphite(bot)
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

    /// The bell's list: the model's own unread state, the roster's names, the preview cache's lines
    /// and the face store's avatars — the same four inputs the Mac's popover reads, in the same
    /// order. No second counter: a row here and a badge on the list can never disagree.
    private var waitingBots: [WaitingBot] {
        WaitingBots.rows(unread: model.unreadBots,
                         counts: model.unreadCounts,
                         names: Dictionary(model.bots.map { ($0.id, $0.displayName) },
                                           uniquingKeysWith: { first, _ in first }),
                         previews: model.botPreviews,
                         faces: app.botFaces.mapValues { $0.raw },
                         times: model.botPreviewTimes)
    }

    /// Bot settings: the shared door, so this list and a conversation's Edit button cannot drift
    /// apart again. It used to be built here inline, and the conversation's copy was a second one.
    private func settingsSheet(for bot: Bot) -> some View {
        BotSettingsDoor(bot: bot, model: model)
    }

    var body: some View {
        List {
            roomsSection
            if let error = app.botFacesError {
                Text("Could not refresh bot icons: \(error)").font(.caption).foregroundStyle(Tokens.danger)
            }
            if let failure = categoryError {
                // A failed write, said out loud. Groups live on the host; one that only exists on
                // this phone would vanish at the next launch, so it is never pretended to be saved.
                Text(failure).font(.caption).foregroundStyle(Tokens.danger)
            }
            if model.bots.isEmpty && model.botsLoading {
                // Nothing of the list's own while the roster is still being asked for. The launch
                // screen is what the person is looking at during that window (see `BootScreen` and
                // `LaunchGateView`), and a second "Loading bots…" under it is a placeholder for a
                // placeholder. A host that never answers leaves through
                // `LaunchReadiness.Failure.deadline`, which uncovers the connection banner's own
                // words and its retry — not an empty list pretending to load.
                EmptyView()
            } else if filtered.isEmpty && trimmedQuery.isEmpty && !(showHidden && !hiddenBots.isEmpty) {
                // Only a genuinely empty list is an empty state. A query that matches no bot NAME
                // must still show its message findings — hiding them here is what made search look
                // broken at the third character.
                emptySection
            } else if !trimmedQuery.isEmpty {
                // Findings first: a phrase is the thing being looked for. The bot rows follow, so a
                // name search still works exactly as it did.
                findingsSection
                Section {
                    ForEach(filtered) { bot in row(for: bot) }
                }
            } else {
                chatsSection
                if showHidden, !hiddenBots.isEmpty { hiddenSection }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // The rows start under the bar's own buttons, not a section header below them.
        .contentMargins(.top, 2, for: .scrollContent)
        // Nothing masks the rows. A mask measured inside the scroll view inherits that view's own
        // safe-area inset, which reached two rows down and hid a bot completely; the dissolve
        // belongs to the bar and is drawn over it (see `topDissolve`), so the list below the
        // buttons is never dimmed at rest.
        .overlay(alignment: .top) {
            if hasRowsToFade { topDissolve }
        }
        // Behind the masked content, so a row fading out resolves to the canvas and not to whatever
        // the window happens to be showing.
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
            // And the groups are host state too: the other device may have made one a minute ago.
            await model.loadBotCategories()
        }
        .alert("New category", isPresented: $showAddCategory) {
            TextField("Name", text: $newCategoryName)
                .textInputAutocapitalization(.words)
            Button("Add") {
                let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                newCategoryName = ""
                // Straight to the host, not into a local list: the Mac reads the same file, which
                // is the only reason a group made here appears there.
                writeCategories { try await model.addBotCategory(name: name) }
            }
            .hermeyFocusQuiet()
            Button("Cancel", role: .cancel) { newCategoryName = "" }
            .hermeyFocusQuiet()
        } message: {
            Text("Groups live on the host, so the Mac shows the same ones. A bot with no group sits in Uncategorized.")
        }
        // First fill: one `session.list` per bot, bounded and cached, so the rows get their third
        // line without a pull.
        .task {
            roomVoice.transport = app.makeVoiceTransport()
            await model.refreshDisabledBots()
            await model.refreshRooms()
            await model.loadBotPreviews()
            // The headings come from the host, like the bots themselves.
            await model.loadBotCategories()
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
            .hermeyFocusQuiet()
            Button("Cancel", role: .cancel) { pendingRoomDelete = nil }
            .hermeyFocusQuiet()
        } message: {
            Text("The room is removed from every device. Its transcript stays on the host.")
        }
        // Typing is not a search per keystroke: a quarter second of quiet, then the host is asked.
        .onChange(of: query) { _, typed in
            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard typed == query else { return }
                await model.searchTranscripts(typed)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is the moment the other device's turn should show up here.
            if phase == .active {
                Task {
                    // Coming back to the app is the moment the other device's turn should show up
                    // here — and that needs the socket, not only the HTTP sweep: without this the
                    // transcript waited out the reconnect backoff the suspension caused.
                    await model.connectNow(reason: "foreground")
                    await model.loadBotPreviews()
                    // A room's badge is only as fresh as its refresh: coming back to the app is
                    // exactly when the other bots' replies landed.
                    await model.refreshRooms()
                }
            }
        }
        .toolbar { toolbarContent }
        .sheet(item: $sessionsBot) { bot in
            BotSessionsSheet(model: model, bot: bot) { session in
                open(session: session, for: bot)
            }
            .hermesSheetChrome()
        }
        .sheet(item: $settingsBot) { bot in
            settingsSheet(for: bot)
            .hermesSheetChrome()
        }
        .sheet(isPresented: $showAddBot) {
            AddBotSheet { name, description, face in
                // No soul: who the bot is lives in its settings, where it can be edited later.
                let created = try await model.addBot(name: name, description: description, soul: "")
                if let face { try? await app.saveBotFace(botID: created, face: face) }
            }
            .hermesSheetChrome()
        }
        .sheet(isPresented: $showAppSettings) {
            // `SettingsSheet`, not a bare `SettingsScreen`: a sheet does not inherit the stack it
            // was presented from, so its `NavigationLink` rows (Caching, Devices) had no
            // navigation container and SwiftUI drew them disabled.
            SettingsSheet(model: model)
            .hermesSheetChrome()
        }
        // The same list the Mac's bell shows, in a sheet: a row is read by opening it — the bot is
        // marked read through `markBotRead`, exactly as the pet and the row's own dot do, and then
        // the conversation it was waiting in is pushed. Nothing here is a second unread count.
        .sheet(isPresented: $showWaiting) {
            WaitingBotsInbox(bots: waitingBots,
                             hostUpdate: model.hostUpdate,
                             onOpen: { botID in
                                 showWaiting = false
                                 model.markBotRead(botID)
                                 if let bot = model.bots.first(where: { $0.id == botID }) {
                                     openBot(bot)
                                 }
                             },
                             onUpdateHost: {
                                 // The press is the whole permission: nothing here updates a host
                                 // on a schedule or on launch.
                                 Task { await model.beginHostUpdate() }
                             },
                             onDismissHostUpdate: { model.dismissHostUpdate() })
            .hermesSheetChrome()
            // The sheet is exactly as tall as what is waiting: the header, one row per bot and
            // the handle. A mid-height detent was a page of empty space above a single row; a long
            // list stops at the shared cap and scrolls instead. A host update is one fixed row
            // taller, and it is the shared row's own height rather than a second measurement.
            .presentationDetents([.height(WaitingBotsInbox.sheetHeight(for: waitingBots.count,
                                                                      hostUpdate: model.hostUpdate != nil))])
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
            .hermesSheetChrome()
        }
        .sheet(isPresented: $showGroupChats) {
            GroupChatsSheet(
                load: { try await model.groupChats() },
                onOpen: { room in open(room) },
                onNew: { showStartGroupChat = true })
            .hermesSheetChrome()
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
            .hermesSheetChrome()
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
                onDelete: { profile in try await model.deleteBot(profile) },
                categories: model.botCategories,
                categoryID: { model.categoryID(for: $0) },
                onSetCategory: { profile, category in
                    try await model.setBotCategory(profile, to: category)
                })
            .hermesSheetChrome()
        }
        .mobileConnectionBanner(connection: app.visibleConnection,
                                turnRunning: model.isStreaming,
                                host: app.hostLabel,
                                retry: { Task { await app.reconnect() } })
    }

    // MARK: Rows

    private var metrics: BotListMetrics { BotListMetrics(scale: listScale) }

    private func row(for bot: Bot) -> some View {
        // The row that is opening says so: the tap registered, and pressing it again is nothing.
        let opening = model.openingBotID == bot.id
        return Button {
            Haptics.selection()
            openBot(bot)
        } label: {
            HStack(alignment: .center, spacing: metrics.gap) {
                // A bot always has a face: the one stored for it, otherwise the body and colour its
                // id picks. Initials are what made the first second of every launch look empty.
                //
                // The pose is the tracker's answer, not a guess from `isStreaming`: the row you are
                // not reading still says `reading` or `computer` while that bot works.
                BotAvatarView(identity: bot.id,
                              color: app.botFaces[bot.id]?.raw,
                              activity: model.activity(forBot: bot.id),
                              size: metrics.avatar,
                              // Same rule as the Mac: idle rows must not animate.
                              animates: (model.isStreaming && model.selectedBotID == bot.id)
                                  || bot.id == model.selectedBotID)
                    // The count sits on the face, bottom-right, nudged out so it reads as a badge on
                    // the avatar rather than a chip inside it. It was dropped in the roster restyle
                    // (2026-11-13) on the theory that the app badge was enough — it is not: the app
                    // badge needs the app closed to be read, and the maintainer asked for both indicators
                    // by name. The beacon says *something* is waiting, this says *how much*.
                    .overlay(alignment: .bottomTrailing) {
                        UnreadBadge(count: model.unreadCount(bot.id), size: metrics.badge)
                            .offset(x: 5, y: 4)
                    }

                // the house row is two lines, not three: the name and when it last spoke on the
                // first, what it said on the second. The count moved to the app badge — the row
                // only has to say "there is something here", which the dot does.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(bot.displayName)
                            .font(TypeScale.font(metrics.nameSize,
                                                 weight: model.hasUnread(bot.id) ? .semibold : .medium))
                            .foregroundStyle(Tokens.textPrimary)
                            .lineLimit(1)

                        if model.isPinned(botID: bot.id) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Tokens.textMuted)
                                .accessibilityHidden(true)
                        }

                        // The same word the face wears, from the same table (see `BotStateBadge`).
                        BotStateBadge(activity: model.activity(forBot: bot.id),
                                      size: (metrics.metaSize * 0.92).rounded())

                        Spacer(minLength: 6)

                        if let at = model.botPreviewTimes[bot.id] {
                            Text(RelativeTime.stamp(at))
                                .font(TypeScale.font(metrics.metaSize))
                                .foregroundStyle(Tokens.textDim)
                                .monospacedDigit()
                                .lineLimit(1)
                                .layoutPriority(1)
                                .accessibilityLabel("last message \(RelativeTime.detailed(at))")
                        }

                    }

                    Text(opening ? "Opening…" : (model.botPreviews[bot.id] ?? subtitle(for: bot)))
                        .font(TypeScale.font(metrics.previewSize,
                                             weight: model.hasUnread(bot.id) ? .medium : .regular))
                        .foregroundStyle(model.hasUnread(bot.id) ? Tokens.textSecondary : Tokens.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                if model.hasUnread(bot.id) {
                    // The breathing beacon, at the row's trailing edge: a static dot read as a
                    // presence indicator sitting in the same place as the old one.
                    UnreadBeacon(diameter: 8)
                }
            }
            .padding(.vertical, metrics.rowPadding)
            .frame(minHeight: metrics.rowHeight)
            .contentShape(Rectangle())
            .opacity(opening ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            // The icon and the soul are not here any more: a long press is a gesture nobody
            // discovers, and both are things a person changes rarely and deliberately. They live in
            // Bot Settings, with the description and the memory (reported 2026-11-14).
            Button { settingsBot = bot } label: { Label("Bot Settings", systemImage: "gearshape") }
            // Filing a bot is the one thing about it that is a list-wide act, so it is here as well
            // as in Manage bots: a long press on the row is where a person looks first.
            Menu {
                Button {
                    assign(bot.id, to: nil)
                } label: {
                    Label("Uncategorized",
                          systemImage: model.categoryID(for: bot.id) == nil ? "checkmark" : "tray")
                }
                ForEach(model.botCategories) { category in
                    Button {
                        assign(bot.id, to: category.id)
                    } label: {
                        Label(category.name,
                              systemImage: model.categoryID(for: bot.id) == category.id
                              ? "checkmark" : "folder")
                    }
                }
            } label: {
                Label("Category", systemImage: "folder")
            }
            // Every conversation the host holds for this bot, not just the one tapping it opens:
            // a routine's run, another bot's DM and a terminal's `hermes -p <bot> chat` all sit
            // beside the Bot Chat, and the Mac has listed them since its sessions sheet landed.
            // The phone had no door to any of them (2026-11-16).
            Button {
                showSessions(for: bot)
            } label: {
                Label("All sessions…", systemImage: "clock.arrow.circlepath")
            }
            // The conversations the ceiling rolled out of the way, newest first, each with the
            // host's own count and its last-message date. Long-press is where the phone keeps the
            // per-bot verbs (All sessions is here too), and the same list the Mac's menu draws.
            Menu {
                previousItems(for: bot)
            } label: {
                Label("Previous conversations", systemImage: "archivebox")
            }
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
        // Swipe left (the trailing edge) pins, swipe right (the leading edge) marks unread. Icons
        // only, no words: a label under the glyph makes the reveal wider than the row it slides out
        // of, and the row already says what it is (asked for 2026-11-15).
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                model.togglePin(botID: bot.id)
            } label: {
                Image(systemName: model.isPinned(botID: bot.id) ? "pin.slash.fill" : "pin.fill")
            }
            .tint(model.isPinned(botID: bot.id) ? Tokens.textMuted : Tokens.accent)
            .accessibilityLabel(model.isPinned(botID: bot.id) ? "Unpin" : "Pin")
            .hermeyFocusQuiet()
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.markUnread(bot.id)
            } label: {
                Image(systemName: "circle.badge.exclamationmark.fill")
            }
            .tint(Tokens.warning)
            .accessibilityLabel("Mark unread")
            .hermeyFocusQuiet()
        }
        .accessibilityLabel(accessibilityLabel(for: bot))
        .accessibilityHint("Opens the conversation with this bot")
        .hermeyFocusQuiet()
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
        let unread = model.unreadCount(bot.id)
        if unread > 0 { parts.append(unread == 1 ? "1 unread" : "\(unread) unread") }
        if model.isPinned(botID: bot.id) { parts.append("pinned") }
        if bot.id == lastOpenedID { parts.append("last opened") }
        return parts.joined(separator: ", ")
    }

    /// The archived conversations for one bot, newest first — the rows of the
    /// **Previous conversations** submenu.
    ///
    /// Each row carries the host's own count and its last-message date, so the list says how big
    /// the chat the ceiling moved aside was. The closing line is the honest one: what opens is the
    /// real archived transcript, and a message sent there continues *that* conversation — it does
    /// not become the bot's chat again.
    @ViewBuilder
    private func previousItems(for bot: Bot) -> some View {
        let rows = model.previousConversations(for: bot.id)
        if rows.isEmpty {
            Text("None yet")
        }
        ForEach(rows) { row in
            Button {
                Haptics.selection()
                openPrevious(row, for: bot)
            } label: {
                Label(BotChatArchive.rowLabel(row), systemImage: "text.bubble")
            }
            .hermeyFocusQuiet()
        }
        if !rows.isEmpty {
            Divider()
            Text("Sending in one continues that old chat")
        }
    }

    /// Open an archived conversation. The bot's own chat is untouched: the next tap on its row
    /// resolves the live Bot Chat again, because the roll moved the name to the fresh one.
    private func openPrevious(_ row: BotChatArchive.Previous, for bot: Bot) {
        Task { @MainActor in
            await model.openPreviousConversation(row, for: bot.id)
            openBot(bot)
        }
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
                scrollingHeading { listHeading(BotGrouping.roomsName.uppercased()) }
                ForEach(model.rooms) { room in
                    roomRow(room)
                }
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
            .hermeyFocusQuiet()
        }
        // A row in a `.plain` List gets the cell's own background — black under a hidden scroll
        // background — and its own separators and insets. A room is a row in the same list as a
        // bot, so it wears the same three: the app's canvas, no separator, the same 16 pt gutter.
        // Without this the group chats read as a black band inside the themed list.
        .listRowBackground(Tokens.canvas)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: Geometry.rosterListPadding, bottom: 0, trailing: Geometry.rosterListPadding))
        .hermeyFocusQuiet()
    }

    /// What the search found *inside* the conversations — the reason the field exists.
    @ViewBuilder
    private var findingsSection: some View {
        if !model.searchPage.hits.isEmpty {
            Section {
                scrollingHeading {
                    listHeading(model.searchRunning ? "SEARCHING…"
                                : "MESSAGES · \(model.searchPage.total)")
                }
                ForEach(model.searchPage.hits) { hit in
                    Button {
                        Haptics.selection()
                        guard let bot = model.bots.first(where: { $0.id == hit.profile }) else { return }
                        recordOpened(bot)
                        onGraphite(bot)
                    } label: {
                        findingRow(hit)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Tokens.canvas)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: Geometry.rosterListPadding,
                                              bottom: 0, trailing: Geometry.rosterListPadding))
                    .accessibilityLabel("\(model.bots.first { $0.id == hit.profile }?.displayName ?? hit.profile): \(hit.snippet)")
                    .hermeyFocusQuiet()
                }
            }
        }
    }

    /// One finding: which bot, what was said around the match, and when.
    private func findingRow(_ hit: BotSearchHit) -> some View {
        HStack(alignment: .top, spacing: metrics.gap) {
            BotAvatarView(identity: hit.profile,
                          color: app.botFaces[hit.profile]?.raw,
                          activity: model.activity(forBot: hit.profile),
                          size: metrics.avatarCompact,
                          animates: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.bots.first { $0.id == hit.profile }?.displayName ?? hit.profile)
                        .font(TypeScale.font(metrics.previewSize, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)
                    Text(hit.isOwner ? "you" : "bot")
                        .font(TypeScale.font(Tokens.rosterMeta))
                        .foregroundStyle(Tokens.textDim)
                    Spacer(minLength: 6)
                    Text(RelativeTime.stamp(hit.at))
                        .font(TypeScale.font(metrics.metaSize))
                        .foregroundStyle(Tokens.textDim)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Text(highlighted(hit.snippet, match: hit.match))
                    .font(TypeScale.font(metrics.previewSize))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, metrics.rowPadding)
        .contentShape(Rectangle())
    }

    /// The matched words in the snippet, weighted — so the eye finds its place in a two-line row.
    private func highlighted(_ snippet: String, match: String) -> AttributedString {
        var text = AttributedString(snippet)
        guard !match.isEmpty,
              let range = text.range(of: match, options: .caseInsensitive) else { return text }
        text[range].font = .system(size: metrics.previewSize, weight: .semibold)
        text[range].foregroundColor = Tokens.textPrimary
        return text
    }

    /// The bots, folded into the owner's categories: Pinned above everything, then the categories
    /// by name, then Uncategorized. Each heading collapses, and what it collapsed stays collapsed
    /// on this device.
    private var chatsSection: some View {
        ForEach(model.botGroups) { group in
            Section {
                scrollingHeading { groupHeader(group) }
                if !isCollapsed(group) {
                    ForEach(group.bots) { bot in
                        row(for: bot)
                    }
                }
            }
        }
    }

    /// The category behind a heading, or `nil` for Pinned and Uncategorized.
    ///
    /// The model's own rule, written once more where the UI can see it: those two headings are the
    /// app's, not the owner's, so they are not part of the arrangement. Any control that moved one
    /// would send the host an id its document never holds — so the UI asks this, not the reverse.
    private func arrangeableCategory(_ group: BotGroup) -> BotCategory? {
        guard !group.isPinned, !group.isUncategorized else { return nil }
        return model.botCategories.first { $0.id == group.id }
    }

    /// Move a category one step. `AppModel.moveBotCategory` computes the arrangement from what is
    /// drawn, filters Pinned and Uncategorized itself, and sends the whole order; through
    /// `writeCategories` a refusal stays on screen instead of the group moving on this phone alone.
    private func move(_ category: BotCategory, by offset: Int) {
        writeCategories { try await model.moveBotCategory(id: category.id, by: offset) }
    }

    /// The two verbs, shared by the heading's long press and its ⋯. Ends are greyed out by the same
    /// predicate the Mac uses, so the two surfaces cannot disagree about where a group can go.
    @ViewBuilder
    private func categoryArrangeItems(_ group: BotGroup) -> some View {
        if let category = arrangeableCategory(group) {
            Button { move(category, by: -1) } label: {
                Label("Move “\(category.name)” Up", systemImage: "arrow.up")
            }
            .disabled(!model.canMoveBotCategory(id: category.id, by: -1))
            .hermeyFocusQuiet()

            Button { move(category, by: 1) } label: {
                Label("Move “\(category.name)” Down", systemImage: "arrow.down")
            }
            .disabled(!model.canMoveBotCategory(id: category.id, by: 1))
            .hermeyFocusQuiet()
        }
    }

    private func groupHeader(_ group: BotGroup) -> some View {
        HStack(spacing: 4) {
            Button {
                toggleCollapsed(group)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed(group) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.textDim)
                    Text(group.name.uppercased())
                        .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                        .foregroundStyle(Tokens.textMuted)
                    Text("\(group.bots.count)")
                        .font(TypeScale.font(metrics.metaSize))
                        .foregroundStyle(Tokens.textDim)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name), \(group.bots.count) bots")
            .accessibilityHint(isCollapsed(group) ? "Expand" : "Collapse")
            // A long press is where the phone keeps the verbs a row has; an empty builder for
            // Pinned and Uncategorized presents nothing rather than a menu with nothing in it.
            .contextMenu { categoryArrangeItems(group) }
            .hermeyFocusQuiet()

            // And the visible door, because a long press on a heading is not something a person
            // finds. Only categories get it: Pinned and Uncategorized cannot move (2026-11-21).
            if arrangeableCategory(group) != nil {
                Menu {
                    categoryArrangeItems(group)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.textDim)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("Arrange \(group.name)")
                .hermeyFocusQuiet()
            }
        }
        .textCase(nil)
    }

    private var collapsedGroups: [String: Bool] {
        guard let data = collapsedGroupsJSON.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return map
    }

    /// Categories are host data, so a group id is only unique per host: the map is keyed by both.
    private func collapseKey(for group: BotGroup) -> String { "\(hostKey ?? "")|\(group.id)" }

    private func isCollapsed(_ group: BotGroup) -> Bool { collapsedGroups[collapseKey(for: group)] == true }

    private func toggleCollapsed(_ group: BotGroup) {
        var map = collapsedGroups
        let key = collapseKey(for: group)
        map[key] = !(map[key] ?? false)
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8) else { return }
        collapsedGroupsJSON = json
    }

    // MARK: Categories

    /// One write through to the host, with its refusal kept on screen.
    ///
    /// Every category act is a host write — there is no local list to append to — so a failure is
    /// reported here instead of being swallowed by `try?`, which is how a group could look created
    /// on the phone and never reach the Mac.
    private func writeCategories(_ change: @escaping () async throws -> Void) {
        Task {
            do {
                try await change()
                categoryError = nil
            } catch {
                categoryError = "Category not saved: \(error.localizedDescription)"
                ClientLog.note("bots.categories write failed: \(error.localizedDescription)",
                               level: .warning, category: "bots")
            }
        }
    }

    /// File one bot, or put it back in Uncategorized with `nil`.
    private func assign(_ botID: String, to categoryID: String?) {
        writeCategories { try await model.setBotCategory(botID, to: categoryID) }
    }

    // MARK: Sessions

    /// **All sessions…** for one bot.
    ///
    /// `AppModel.sessions` is scoped to the bot on screen, so a bot that is not selected is opened
    /// first — the same act as tapping its row — and the sheet waits for that switch: `selectBot`
    /// is awaited here, and it does not return until that bot's `session.list` has landed. (The Mac
    /// polls `selectedBotID` because its store starts the switch in a detached task; iOS hands back
    /// a finished switch.) Listing another bot's history under this one's name is the bug that
    /// ordering exists to prevent, and the sheet checks the scope again before drawing a row.
    ///
    /// The presentation waits one run loop beat, deliberately: the context menu is still closing and
    /// iOS drops a sheet presented from inside that dismissal.
    private func showSessions(for bot: Bot) {
        Task { @MainActor in
            if model.selectedBotID != bot.id {
                await model.selectBot(bot.id)
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            sessionsBot = bot
        }
    }

    /// Open one of those sessions.
    ///
    /// The pick is recorded on the model as well as resumed: `endlessSession(for:)` resolves the
    /// host's canonical `Bot Chat` on every appear, and before `openSession` existed that opener
    /// replaced a hand-picked conversation a moment after it opened. The push is the tab's, so the
    /// list's own navigation stays the only way in.
    private func open(session: SessionSummary, for bot: Bot) {
        Task { @MainActor in
            recordOpened(bot)
            await model.openSession(session.id, for: bot.id)
            onGraphite(bot)
        }
    }

    private var hiddenSection: some View {
        Section {
            scrollingHeading { listHeading("HIDDEN") }
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
                .hermeyFocusQuiet()
            }
        }
    }

    /// Whether there is a row to dissolve. Over the empty state's hero face, or a search that
    /// matched nothing, the fade has nothing to do and a gradient would only dim the top of
    /// whatever is there.
    private var hasRowsToFade: Bool { !model.bots.isEmpty }

    /// The dissolve, sitting *behind* the bar's buttons.
    ///
    /// The rows are laid out from the top of the scroll area (`.contentMargins(..., .scrollContent)`),
    /// so y = 0 is where content begins and the bar occupies the space *above* it — a negative
    /// offset, measured from the list's own `safeAreaInsets.top` rather than a guessed constant.
    /// The gradient therefore ramps in the bar's own strip and ends exactly where the first row
    /// begins: rows sliding up vanish into the canvas, and nothing at rest — section labels, first
    /// bot — is ever veiled. (Two earlier attempts drew the ramp downward from y = 0, which put it
    /// over the labels; one reached two rows down and hid a bot entirely.)
    ///
    /// Hit testing is off, so the strip cannot swallow a tap on the first row.
    private var topDissolve: some View {
        GeometryReader { proxy in
            let bar = max(proxy.safeAreaInsets.top, 0)
            LinearGradient(stops: [
                .init(color: Tokens.canvas, location: 0),
                .init(color: Tokens.canvas.opacity(0.86), location: 0.72),
                .init(color: Tokens.canvas.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: bar)
            .offset(y: -bar)
        }
        .allowsHitTesting(false)
    }

    /// A heading that scrolls away with its rows.
    ///
    /// `Section(header:)` pins on iOS, so a category label stuck to the bar while the bots slid
    /// under it. The heading is a row now — same look, no pinning.
    private func scrollingHeading<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowBackground(Tokens.canvas)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: Geometry.rosterListPadding,
                                      bottom: 2, trailing: Geometry.rosterListPadding))
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
                } else if model.botsError == nil && !model.rosterAnswered {
                    // The deadline's path, not a loading state: the gateway has not listed its bots
                    // and never did. The banner over this list is what says so, with its own retry;
                    // the list will not answer for a host it has not heard from — "No bots found on
                    // this host" is a claim about a reply that never arrived.
                    EmptyView()
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

            HermeyButton("Pair a device",
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

            HermeyButton("Try again",
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

            HermeyButton("Check again",
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
                .hermeyFocusQuiet()
            }
            // One group, because the order inside it is the order on screen: the bell, Settings,
            // then the create menu. Two separate trailing items would leave the pairing to
            // SwiftUI's own preference, and the gear could land on either side of the plus.
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Everything waiting, immediately left of Settings: the owner's one mobile change,
                // and the same behaviour as the Mac's bell — the same rows, the same tap, the same
                // `markBotRead`. A dot, not a count: the sheet says how many.
                Button {
                    showWaiting = true
                } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Tokens.textPrimary)
                        .waitingDot(!waitingBots.isEmpty || model.hostUpdate?.wantsAttention == true, size: 6)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(waitingBots.isEmpty
                                    ? "Nothing waiting"
                                    : "Waiting: \(waitingBots.count) \(waitingBots.count == 1 ? "bot" : "bots")")
                .accessibilityIdentifier("botList.notifications")
                .hermeyFocusQuiet()

                // Settings used to be the last row of the menu, which is where an app-level
                // destination goes to be missed: a person looking for theme, pairing or update
                // checks opens the ⋯ and reads a list of things that add or change bots. It is a
                // control of its own now, in the corner the thumb already reaches.
                Button {
                    showAppSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Tokens.textPrimary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("botList.settings")
                .hermeyFocusQuiet()

                // A plus, because that is what the menu is for: everything in it creates or
                // maintains something. It wore ⋯ while it also carried navigation (Settings,
                // Hidden bots), and a glyph that means "more options" beside a gear that means
                // "settings" gave two buttons the same promise.
                Menu {
                    // Adding comes first: the menu opens from a +, and the first rows should be the
                    // things that + promises.
                    Button { showAddBot = true } label: {
                        Label("Add bot", systemImage: "plus.circle")
                    }
                    Button { showManageBots = true } label: {
                        Label("Manage bots", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        newCategoryName = ""
                        showAddCategory = true
                    } label: {
                        Label("Add category", systemImage: "folder.badge.plus")
                    }

                    Divider()

                    Button { showStartGroupChat = true } label: {
                        Label("New group chat", systemImage: "person.3")
                    }

                    Divider()

                    // The two list-wide switches sit at the foot together: what the list shows, and
                    // what the badges say. Hidden bots used to open the menu, above the actions that
                    // create things, which put a view toggle where the + pointed.
                    Button {
                        showHidden.toggle()
                    } label: {
                        Label("Hidden bots", systemImage: showHidden ? "checkmark" : "circle")
                    }
                    .accessibilityValue(showHidden ? "On" : "Off")

                    // Clears every badge on the list at once: a person who is done with the app
                    // should not have to open each chat to say so.
                    Button { model.markAllRead() } label: {
                        Label("Mark all as read", systemImage: "checkmark.circle")
                    }
                    .disabled(!model.hasAnyUnread)
                } label: {
                    // A bare glyph: the bar already draws its own control chrome, and a second
                    // surface inside it reads as a box in a circle. The accent tint stays as the
                    // one signal that a filter is on behind it.
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(showHidden ? Tokens.accentText : Tokens.textPrimary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add or manage")
                .accessibilityIdentifier("botList.add")
                .hermeyFocusQuiet()
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
                .hermeyFocusQuiet()
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
            TextField("Search bots and messages", text: $query)
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
                .hermeyFocusQuiet()
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
