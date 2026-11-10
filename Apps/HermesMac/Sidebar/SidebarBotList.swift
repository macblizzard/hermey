import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The bots block at the top of the left pane.
///
/// The rail's avatars stay the fastest switch; this list is the phone's bot list brought to the
/// desktop: the profile's description under its name, a green dot for a reply that arrived while
/// the conversation was not on screen, pin/hide from the row's context menu. The filter is the
/// panel's search field (`BotSidebarView`), applied here against name and id, so the list needs no
/// caption row of its own: the field says what the block is.
///
/// Ordering is `AppModel.orderedBots` — pinned first, then last activity — so both surfaces agree.
struct SidebarBotList: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore
    /// View preference, not a stored one: hidden bots stay hidden across launches via the model.
    @Binding var showsHiddenBots: Bool
    /// The live search text. Empty means "every bot"; otherwise name and id are matched
    /// case-insensitively, and hidden bots are matched by the same rule.
    var query: String = ""
    /// True when this block *is* the left panel rather than a strip above a session list: the
    /// rows then take every point the window offers instead of stopping after about five.
    var fillsAvailableHeight: Bool = false
    /// Group chats open and delete through the sidebar's own sheets, so this view stays a list.
    var onOpenRoom: ((RoomSummary) -> Void)? = nil
    var onDeleteRoom: ((RoomSummary) -> Void)? = nil
    /// Rename lives on the row's context menu, like every other file-like name on the Mac.
    var onRenameRoom: ((RoomSummary) -> Void)? = nil

    private var icons: [String: BotIcon] { store.botIcons }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// Hidden bots are excluded by the model's ordering, so this is the visible list.
    private var visibleBots: [Bot] { model.orderedBots.filter(matches) }

    private var hiddenBots: [Bot] {
        model.bots.filter { model.isHidden(botID: $0.id) && matches($0) }
    }

    /// Name first, then id: a bot called "Assistant" whose profile id is `assistant` answers to either.
    private func matches(_ bot: Bot) -> Bool {
        guard isSearching else { return true }
        return bot.displayName.localizedCaseInsensitiveContains(trimmedQuery)
            || bot.id.localizedCaseInsensitiveContains(trimmedQuery)
    }

    /// Nothing to draw: no matching visible bots and no matching hidden ones to reveal.
    private var isFilteredEmpty: Bool {
        visibleBots.isEmpty && !(showsHiddenBots && !hiddenBots.isEmpty)
    }

    private var rowCount: Int {
        visibleBots.count + (showsHiddenBots ? hiddenBots.count : 0)
    }

    /// Group chats sit above the bots and are searchable only by their own names' absence: the
    /// search box filters bots, so a search hides the rooms instead of pretending to match them.
    private var roomRows: [RoomSummary] { isSearching ? [] : model.rooms }

    /// The block sizes to its content and stops growing at about five rows, then scrolls.
    private var listHeight: CGFloat {
        let hiddenExtra = showsHiddenBots && !hiddenBots.isEmpty ? 24 : 0
        let roomExtra = roomRows.isEmpty ? 0 : CGFloat(roomRows.count) * 44 + 34
        return min(CGFloat(max(rowCount, 1)) * SidebarBotList.rowHeight + CGFloat(hiddenExtra) + roomExtra + 2,
                   SidebarBotList.rowHeight * 5 + 2)
    }

    /// Name, description, last message: three lines at caption sizes, plus the row's own padding.
    /// One number, used by both the row and the block's height cap, so they cannot drift apart.
    static let rowHeight: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isFilteredEmpty {
                emptyState
            } else {
                rows
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var rows: some View {
        let rows = ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !roomRows.isEmpty {
                    SectionCaption("GROUP CHATS")
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                        .padding(.bottom, 2)

                    ForEach(roomRows) { room in
                        Button { onOpenRoom?(room) } label: {
                            GroupChatRow(room: room,
                                         icons: icons,
                                         unread: model.roomUnreadCount(room.id))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // The same fill a selected bot uses, so "which conversation is open" reads
                        // the same whether it is a bot or a room.
                        .hoverFill(rest: model.activeRoom?.id == room.id ? Tokens.controlActive : .clear,
                                   hover: model.activeRoom?.id == room.id ? Tokens.controlActive : Tokens.controlHover)
                        .contextMenu {
                            Button { onRenameRoom?(room) } label: {
                                Label("Rename group chat…", systemImage: "pencil")
                            }
                            Button(role: .destructive) { onDeleteRoom?(room) } label: {
                                Label("Delete group chat", systemImage: "trash")
                            }
                        }
                    }

                    Divider().padding(.horizontal, 8).padding(.vertical, 4)
                }

                SectionCaption("CHATS")
                    .padding(.horizontal, 8)
                    .padding(.top, roomRows.isEmpty ? 2 : 0)
                    .padding(.bottom, 2)

                ForEach(visibleBots) { bot in
                    row(for: bot)
                }

                if showsHiddenBots, !hiddenBots.isEmpty {
                    SectionCaption("HIDDEN")
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    ForEach(hiddenBots) { bot in
                        hiddenRow(for: bot)
                    }
                }
            }
        }

        if fillsAvailableHeight {
            rows.frame(maxHeight: .infinity)
        } else {
            rows.frame(height: listHeight)
        }
    }

    private func row(for bot: Bot) -> some View {
        // A room on screen owns the selection: the bot underneath is not the conversation the
        // pane is showing, and highlighting both made the sidebar look like two things were open.
        let isSelected = bot.id == model.selectedBotID && model.activeRoom == nil
        let isPinned = model.isPinned(botID: bot.id)

        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            store.selectBot(bot.id)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                // Same rule as the phone: the host's icon if there is one, otherwise the portrait
                // the bot's id picks — never a bare initial.
                BotIconPortrait(store.botIcons[bot.id] ?? BotIcon.default(for: bot.id),
                                size: 26,
                                isWorking: bot.id == model.selectedBotID && model.isStreaming)
                    // Same badge as the phone, scaled to a 26 pt face in a 28 pt row: it overhangs
                    // the portrait by nothing, because the sidebar clips its rows.
                    .overlay(alignment: .bottomTrailing) {
                        UnreadBadge(count: model.unreadCount(bot.id), size: 14)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(bot.displayName)
                            .font(TypeScale.font(Tokens.textSM, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(Tokens.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(TypeScale.font(TypeScale.micro, weight: .semibold))
                                .foregroundStyle(Tokens.textMuted)
                                .accessibilityHidden(true)
                        }
                    }

                    Text(subtitle(for: bot))
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // The third line every chat app has: what was said last. Absent until the host
                    // answers for that bot, and then it is the host's own newest message, never a
                    // line borrowed from another bot.
                    if let preview = model.botPreviews[bot.id] {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(preview)
                                .font(TypeScale.font(TypeScale.caption))
                                .foregroundStyle(Tokens.textDim)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            // When it arrived, by the host's clock: the row already says what was
                            // said, and "what was said without when" is what made a stale row look
                            // like a fresh one.
                            if let at = model.botPreviewTimes[bot.id] {
                                Text(RelativeTime.stamp(at))
                                    .font(TypeScale.font(TypeScale.micro))
                                    .foregroundStyle(Tokens.textMuted)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                    .accessibilityLabel("last message \(RelativeTime.detailed(at))")
                            }
                        }
                    }
                }

                Spacer(minLength: 4)

                if model.hasUnread(bot.id) {
                    // A message that arrived while this bot was not the one on screen. It breathes
                    // rather than sitting still: unread is an invitation, presence is a fact.
                    UnreadBeacon()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(height: SidebarBotList.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(rest: isSelected ? Tokens.controlActive : .clear,
                   hover: isSelected ? Tokens.controlActive : Tokens.controlHover)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        .contextMenu {
            Button { store.openBotSettings(bot) } label: {
                Label("Bot Settings", systemImage: "gearshape")
            }

            Button {
                model.togglePin(botID: bot.id)
            } label: {
                Label(isPinned ? "Unpin" : "Pin to top",
                      systemImage: isPinned ? "pin.slash" : "pin")
            }

            Button(role: .destructive) {
                model.toggleHidden(botID: bot.id)
            } label: {
                Label("Hide bot", systemImage: "eye.slash")
            }
        }
        .help(bot.displayName)
        .accessibilityLabel(accessibilityLabel(for: bot))
    }

    /// A hidden bot is not gone: the filter reveals it here, and one click puts it back.
    private func hiddenRow(for bot: Bot) -> some View {
        Button {
            model.toggleHidden(botID: bot.id)
        } label: {
            HStack(spacing: 8) {
                Text(bot.displayName)
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("Show")
                    .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Tokens.accentText)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill()
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        .contextMenu {
            Button {
                model.toggleHidden(botID: bot.id)
            } label: {
                Label("Show bot", systemImage: "eye")
            }
            Button { store.openBotSettings(bot) } label: {
                Label("Bot Settings", systemImage: "gearshape")
            }
        }
        .help("Show \(bot.displayName) in the bot list")
        .accessibilityLabel("Show \(bot.displayName)")
    }

    /// One row that says why the block is empty. A query with no hits names the query, so a
    /// mistyped search cannot be mistaken for a host that has no bots.
    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            Text("No bots match \"\(trimmedQuery)\"")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        } else if model.botsLoading {
            HStack(spacing: 8) {
                SpinningRing(color: Tokens.textDim, size: 9, lineWidth: 1.3)
                Text("Asking the host which bots it serves…")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        } else {
            Text(hiddenBots.isEmpty ? "No bots found on this host." : "All bots are hidden. Use the filter to show them.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        }
    }

    // MARK: Facts

    /// A description written on the host is the useful line; without one, name what the row is.
    private func subtitle(for bot: Bot) -> String {
        if let description = bot.description, !description.isEmpty { return description }
        return bot.id == bot.displayName ? "Hermes profile" : bot.id
    }

    /// Live state is only known for the bot whose sessions are loaded; the rest stay idle rather
    /// than borrowing the selected bot's ring.
    private func presence(for bot: Bot) -> Avatar.Presence {
        guard bot.id == model.selectedBotID else { return .idle }
        if model.hasPendingRequests { return .needsYou }
        if model.isStreaming { return .running }
        return .idle
    }

    private func accessibilityLabel(for bot: Bot) -> String {
        var parts = [bot.displayName, "bot"]
        if model.isPinned(botID: bot.id) { parts.append("pinned") }
        if model.hasUnread(bot.id) { parts.append("unread") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews

private struct SidebarBotListPreview: View {
    @StateObject private var store = PreviewWorkspace.store()
    @State private var showsHidden = false

    var body: some View {
        SidebarBotList(model: store.model, store: store, showsHiddenBots: $showsHidden)
            .padding(.horizontal, 6)
            .frame(width: Geometry.sidebarDefault)
            .background(Tokens.sidebar)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

private struct SidebarBotListFilteredPreview: View {
    @StateObject private var store = PreviewWorkspace.store()
    @State private var showsHidden = false

    var body: some View {
        SidebarBotList(model: store.model,
                       store: store,
                       showsHiddenBots: $showsHidden,
                       query: "cod")
            .padding(.horizontal, 6)
            // The panel's floor, where the rows and the empty state both have to hold.
            .frame(width: WorkspaceStore.sidebarFloor)
            .background(Tokens.sidebar)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Sidebar bots") {
    SidebarBotListPreview()
}
#endif

#if DEBUG
#Preview("Sidebar bots · filtered at the 200 pt floor") {
    SidebarBotListFilteredPreview()
}
#endif
