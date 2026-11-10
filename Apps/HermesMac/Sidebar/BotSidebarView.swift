import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The left panel: **bots, and nothing else**.
///
/// This is the phone's bot list on the desktop. One row per Hermes profile — name, description,
/// pin, hide, unread dot, context menu — and clicking a row opens that bot's single endless
/// conversation in the pane on the right. There is no session browser under it, no session
/// search, and no "new session" button: a bot has one conversation, and the app resumes it.
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

    /// The live bot filter. Matched case-insensitively against name and id by `SidebarBotList`.
    @State private var searchQuery = ""


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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.sidebar)
        .task {
            await model.refreshDisabledBots()
            await model.refreshRooms()
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
            AddBotSheet { name, description, soul, icon in
                let created = try await model.addBot(name: name, description: description, soul: soul)
                if let icon { try? await store.saveBotIcon(botID: created, icon: icon) }
            }
        }
        .sheet(isPresented: $store.isStartGroupChatPresented) {
            StartGroupChatSheet(
                bots: model.bots,
                icons: store.botIcons,
                onCreate: { name, members in
                    try await model.startGroupChat(name: name.isEmpty ? "Group chat" : name,
                                                   members: members)
                },
                onCreated: { room in model.openRoom(room) })
        }
        .sheet(isPresented: $store.isGroupChatsPresented) {
            GroupChatsSheet(
                load: { try await model.groupChats() },
                onOpen: { room in model.openRoom(room) },
                onNew: { store.isStartGroupChatPresented = true })
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
                onDelete: { profile in try await model.deleteBot(profile) })
        }
    }

    // MARK: Header

    /// The panel's only chrome row: search, list filters, Settings.
    ///
    /// The former magnifier was the command palette; the palette is still ⌘K and still in the
    /// Conversation menu, while the magnifier's understandable meaning — search — is now the
    /// field itself. The field leads the row and takes the remaining width, so at the 200 pt
    /// floor the two 24 pt buttons are the only fixed size in it.
    private var header: some View {
        HStack(spacing: 6) {
            MacSidebarSearchField(text: $searchQuery, prompt: "Search bots")
                .accessibilityIdentifier("sidebar.botSearch")
                .layoutPriority(1)

            Menu {
                // Same control as the phone's list filter: a switch, not a second list.
                Toggle("Show hidden bots", isOn: $showsHiddenBots)
                Divider()
                Button { store.isAddBotPresented = true } label: { Label("Add bot…", systemImage: "plus.circle") }
                Button { store.isManageBotsPresented = true } label: {
                    Label("Manage bots…", systemImage: "slider.horizontal.3")
                }
                Divider()
                Button { store.isStartGroupChatPresented = true } label: {
                    Label("Start group chat…", systemImage: "person.3")
                }
            } label: {
                // Three dots on the Mac too: the same menu, wearing the same control the phone
                // draws — one glyph, one surface, one theme across both apps — instead of a funnel
                // that promised filtering and then offered "Add bot".
                MenuDotsLabel(isActive: showsHiddenBots)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Bot list menu")
            .accessibilityLabel("Bot list menu")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textMuted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, Geometry.sidebarInset)
        // The traffic-light strip: the panel's fill runs to the window's top edge, the field
        // starts under the buttons.
        .padding(.top, WorkspaceShell.titlebarStrip)
        .padding(.bottom, 6)
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
                           })
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
            SectionCaption("NOT CONNECTED")
                .padding(.horizontal, 8)
            Text("Connect to \(store.pairing?.displayHost ?? model.hostName) to list its bots.")
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
