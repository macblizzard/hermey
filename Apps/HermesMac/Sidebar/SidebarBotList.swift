import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The bots block at the top of the left pane.
///
/// The rail's avatars stay the fastest switch; this list is the phone's bot list brought to the
/// desktop: the profile's description under its name, a green dot for a reply that arrived while
/// the conversation was not on screen, pin/hide from the row's menu. The filter is the panel's
/// search field (`BotSidebarView`), applied here against name and id, so the list needs no caption
/// row of its own: the field says what the block is.
///
/// Ordering is `AppModel.orderedBots` — pinned first, then last activity — folded into the owner's
/// categories by `AppModel.botGroups`, so both surfaces agree. The headings are the categories,
/// drawn by `groupCaption`; a category with no bots still gets one, because a heading that appears
/// only once it has a member is a heading nobody can find to fill.
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

    private var icons: [String: BotFace] { store.botFaces }

    /// The row under the pointer, or whose overflow menu is open. One value for the whole list, so
    /// exactly one row can be lit — the panel's own convention (`MacBotPanel.hovered`).
    @State private var hoveredRow: String?

    /// The header's **+** menu asks for the category prompt through here; the row's own menu needs
    /// no router — it is the native `Menu` its ⋯ opens. See `BotMenuRouter`.
    @ObservedObject private var menuRouter = BotMenuRouter.shared

    /// One sheet at a time: sessions for a bot, or the category prompt. Two `.sheet` modifiers on
    /// one view fight each other, so they share one item.
    @State private var sheet: BotListSheet?
    /// The category whose deletion is waiting on a confirmation.
    @State private var pendingCategoryDelete: BotCategory?
    /// A write that failed, said where the list can see it.
    @State private var failure: String?

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
        // A collapsed group contributes its heading and no rows: the block shrinks with it.
        let bots = isSearching ? visibleBots.count
                               : model.botGroups.reduce(0) { total, group in
                                   total + (isCollapsed(group) ? 0 : group.bots.count)
                               }
        return bots + (showsHiddenBots ? hiddenBots.count : 0)
    }

    /// One heading per group, drawn above its rows.
    private var captionCount: Int { isSearching ? 0 : model.botGroups.count }

    /// Group chats sit above the bots and are searchable only by their own names' absence: the
    /// search box filters bots, so a search hides the rooms instead of pretending to match them.
    private var roomRows: [RoomSummary] { isSearching ? [] : model.rooms }

    /// The block sizes to its content and stops growing at about five rows, then scrolls.
    private var listHeight: CGFloat {
        let hiddenExtra = showsHiddenBots && !hiddenBots.isEmpty ? 24 : 0
        let roomExtra = roomRows.isEmpty ? 0 : CGFloat(roomRows.count) * 44 + 34
        let rowHeight = SidebarBotList.rowHeight * listScale
        return min(CGFloat(max(rowCount, 1)) * rowHeight
                   + CGFloat(captionCount) * SidebarBotList.captionHeight
                   + CGFloat(hiddenExtra) + roomExtra + 2,
                   rowHeight * 5 + 2)
    }

    /// A heading row: caption type, its chevron and a 12 pt rhythm above and below.
    static let captionHeight: CGFloat = 26

    /// Name, description, last message: three lines at caption sizes, plus the row's own padding.
    /// One number, used by both the row and the block's height cap, so they cannot drift apart.
    static let rowHeight: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if isFilteredEmpty {
                    emptyState
                } else {
                    rows
                }
            }
            // The failure alert lives on the inner block so it cannot collide with the deletion
            // confirmation on the outer one: two alerts on one node is one alert.
            .alert("Category not changed",
                   isPresented: Binding(get: { failure != nil },
                                        set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .sessions(let bot):
                BotSessionsSheet(model: model, bot: bot) { session in
                    open(session: session, for: bot)
                }
                .hermesSheetChrome()
            case .newCategory(let bot):
                BotCategorySheet(
                    title: "New category",
                    confirmTitle: "Create",
                    explanation: bot.map {
                        "“\($0.displayName)” moves into it. Groups are stored on the host, so the phone and this Mac show the same ones."
                    } ?? "Groups are stored on the host, so the phone and this Mac show the same ones.",
                    commit: { name in await createCategory(named: name, assignTo: bot) })
                .hermesSheetChrome()
            case .renameCategory(let category):
                BotCategorySheet(
                    title: "Rename “\(category.name)”",
                    confirmTitle: "Rename",
                    explanation: "Every device that shows this group shows the new name.",
                    initialName: category.name,
                    commit: { name in await rename(category, to: name) })
                .hermesSheetChrome()
            }
        }
        .alert(pendingCategoryDelete.map { "Delete “\($0.name)”?" } ?? "Delete this category?",
               isPresented: Binding(get: { pendingCategoryDelete != nil },
                                    set: { if !$0 { pendingCategoryDelete = nil } }),
               presenting: pendingCategoryDelete) { category in
            Button("Delete category", role: .destructive) { delete(category) }
            Button("Cancel", role: .cancel) { pendingCategoryDelete = nil }
        } message: { category in
            Text("The bots in it move to Uncategorized. Nothing is deleted but the group.")
        }
        // The header's **+** menu cannot present this list's sheet, so it asks through the router.
        .onChange(of: menuRouter.wantsNewCategory) { _, wants in
            guard wants else { return }
            menuRouter.acknowledgeNewCategory()
            sheet = .newCategory(nil)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var rows: some View {
        let rows = ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !roomRows.isEmpty {
                    // No caption over either list. "CHATS" over a list of chats told the reader
                    // what they were already looking at, and it cost a line above the first row.
                    // The divider below the group chats is the whole separation.
                    ForEach(roomRows) { room in
                        Button { onOpenRoom?(room) } label: {
                            GroupChatRow(room: room,
                                         icons: icons,
                                         unread: model.roomUnreadCount(room.id))
                                .padding(.horizontal, Geometry.rosterRowPadding)
                                .padding(.vertical, Geometry.rosterRowPadding)
                                .frame(height: Geometry.rosterRow)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                                        .fill(roomFill(room))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // The same fill a selected bot uses, so "which conversation is open" reads
                        // the same whether it is a bot or a room.
                        .onHover { inside in
                            if inside { hoveredRow = roomKey(room.id) }
                            else if hoveredRow == roomKey(room.id) { hoveredRow = nil }
                        }
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

                // What the search found inside the conversations, above the rows: a phrase is the
                // thing being looked for, and a bot name is the fallback.
                if isSearching, !model.searchPage.hits.isEmpty {
                    SectionCaption("MESSAGES · \(model.searchPage.total)")
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    ForEach(model.searchPage.hits) { hit in
                        Button {
                            if let bot = model.bots.first(where: { $0.id == hit.profile }) {
                                store.selectBot(bot.id)
                            }
                        } label: {
                            findingRow(hit)
                                .background(
                                    RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                                        .fill(hoveredRow == hitKey(hit.id) ? Tokens.controlHover : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            if inside { hoveredRow = hitKey(hit.id) }
                            else if hoveredRow == hitKey(hit.id) { hoveredRow = nil }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous))
                    }
                }

                // The owner's groups, the same headings the phone draws: Pinned above everything,
                // the categories by name, Uncategorized last (asked for 2026-11-15). While a search
                // is running the answer is one flat list — a heading would split it up for nothing —
                // so the row carries its category as a chip instead.
                if isSearching {
                    ForEach(visibleBots) { bot in
                        row(for: bot)
                    }
                } else {
                    ForEach(model.botGroups) { group in
                        groupCaption(group)
                        if !isCollapsed(group) {
                            ForEach(group.bots) { bot in
                                row(for: bot)
                            }
                        }
                    }
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
            // The first row's rounded corner kept landing in the top fade, so the selected row
            // looked half-faded before the list had scrolled at all — 6 pt was not enough, and the
            // row is 16 pt clear of the edge now (reported twice, 2026-11-14).
            .padding(.top, 16)
        }

        if fillsAvailableHeight {
            rows.frame(maxHeight: .infinity)
        } else {
            rows.frame(height: listHeight)
        }
    }

    /// One search finding on the Mac: which bot, the snippet, when.
    private func findingRow(_ hit: BotSearchHit) -> some View {
        HStack(alignment: .top, spacing: 8) {
            BotIconPortrait(store.botFaces[hit.profile] ?? BotFace.default(for: hit.profile),
                            size: Geometry.rosterAvatarCompact)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.bots.first { $0.id == hit.profile }?.displayName ?? hit.profile)
                        .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(RelativeTime.stamp(hit.at))
                        .font(TypeScale.font(Tokens.rosterMeta))
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                }
                Text(hit.snippet)
                    .font(TypeScale.font(Tokens.rosterMeta))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(hit.snippet)
    }

    // MARK: Category headings

    /// Which headings are collapsed, remembered on this device. One JSON map, because the
    /// categories themselves live on the host and come and go.
    @AppStorage("hermey.collapsedBotGroups.mac") private var collapsedGroupsJSON = "{}"

    private var collapsedGroups: [String: Bool] {
        guard let data = collapsedGroupsJSON.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return map
    }

    private func isCollapsed(_ group: BotGroup) -> Bool { collapsedGroups[group.id] == true }

    private func toggleCollapsed(_ group: BotGroup) {
        var map = collapsedGroups
        map[group.id] = !(map[group.id] ?? false)
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8) else { return }
        collapsedGroupsJSON = json
    }

    /// A heading is a control, not a label: clicking it folds the group away, and right-clicking
    /// it is where a group is renamed, emptied or added — the same three verbs the phone offers on
    /// its category headers.
    @ViewBuilder
    private func groupCaption(_ group: BotGroup) -> some View {
        let category = model.botCategories.first { $0.id == group.id }

        Button {
            withAnimation(.easeOut(duration: 0.12)) { toggleCollapsed(group) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isCollapsed(group) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Tokens.textDim)
                Text(group.name.uppercased())
                    .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Tokens.textMuted)
                Text("\(group.bots.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Tokens.textDim)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .help(isCollapsed(group) ? "Expand \(group.name)" : "Collapse \(group.name)")
        .contextMenu {
            Button { sheet = .newCategory(nil) } label: {
                Label("New category…", systemImage: "folder.badge.plus")
            }

            if let category {
                Button { sheet = .renameCategory(category) } label: {
                    Label("Rename “\(category.name)”…", systemImage: "pencil")
                }
                Button(role: .destructive) { pendingCategoryDelete = category } label: {
                    Label("Delete “\(category.name)”", systemImage: "trash")
                }
            }
        }
    }

    /// The list's size, dragged in Appearance. Same key as the phone: one choice per person.
    @AppStorage(BotListMetrics.storageKey) private var listScale = BotListMetrics.defaultScale

    private var metrics: BotListMetrics { BotListMetrics(scale: listScale) }

    private func row(for bot: Bot) -> some View {
        // A room on screen owns the selection: the bot underneath is not the conversation the
        // pane is showing, and highlighting both made the sidebar look like two things were open.
        let isSelected = bot.id == model.selectedBotID && model.activeRoom == nil
        let isHovered = hoveredRow == bot.id
        let isPinned = model.isPinned(botID: bot.id)

        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            store.selectBot(bot.id)
        } label: {
            HStack(alignment: .center, spacing: metrics.gap) {
                // Same rule as the phone: the host's icon if there is one, otherwise the portrait
                // the bot's id picks — never a bare initial. Rakazo draws the working state as a
                // ring around the face, which is where this app already puts it.
                //
                // Live state is passed only for the bot whose turn is actually moving. An idle row
                // hands the portrait no status at all, so nothing on this screen is being asked to
                // animate on its behalf (see `BotIconPortrait` for the movement that remains).
                BotIconPortrait(store.botFaces[bot.id] ?? BotFace.default(for: bot.id),
                                size: metrics.avatar,
                                status: portraitStatus(for: bot),
                                // Only a moving bot animates. Everything else in the roster is a
                                // legend, and a 20 fps timeline per idle row is pure heat.
                                animates: portraitStatus(for: bot) != nil)
                    // Same two indicators as the phone, by the same instruction: the count on the
                    // face says *how much* is waiting, the beacon at the row's edge says *something*
                    // is. A single dot lost the number the user asked for twice.
                    .overlay(alignment: .bottomTrailing) {
                        UnreadBadge(count: model.unreadCount(bot.id), size: (17 * CGFloat(listScale)).rounded())
                            .offset(x: 5, y: 4)
                    }

                // Two lines, in Rakazo's order: the name and when it last spoke on the first, what
                // it said on the second. A bot with no preview yet falls back to its description so
                // the second line is never empty.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(bot.displayName)
                            .font(TypeScale.font((Tokens.rosterName * CGFloat(listScale)).rounded(),
                                                 weight: model.hasUnread(bot.id) ? .semibold : .medium))
                            .foregroundStyle(Tokens.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(TypeScale.font(TypeScale.micro, weight: .semibold))
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

                    }

                    // A flat search list has no headings, so the row says which group it is in;
                    // with the headings on screen the heading already said it.
                    HStack(spacing: 4) {
                        if isSearching, let category = categoryName(for: bot) {
                            Text(category.uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(Tokens.textDim)
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }

                        Text(model.botPreviews[bot.id] ?? subtitle(for: bot))
                            .font(TypeScale.font(Tokens.rosterMeta,
                                                 weight: model.hasUnread(bot.id) ? .medium : .regular))
                            .foregroundStyle(model.hasUnread(bot.id) ? Tokens.textSecondary : Tokens.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 0)

                if model.hasUnread(bot.id) {
                    UnreadBeacon(diameter: 7)
                        .opacity(isHovered ? 0 : 1)
                }
            }
            .padding(.horizontal, metrics.rowPadding)
            .padding(.vertical, metrics.rowPadding)
            .frame(height: metrics.rowHeight)
            // The hover fill is the row's own background, drawn at a fixed size: nothing here is
            // padded, scaled or re-laid-out by the pointer, so a row never moves under it.
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                    .fill(isSelected ? Tokens.controlActive
                          : (isHovered ? Tokens.controlHover : .clear))
            )
            // One hairline on hover, the chat header pill's own signal (a scale would move the hit
            // box, which is what made that pill feel like it ignored clicks).
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                    .strokeBorder(Tokens.borderStrong,
                                  lineWidth: isHovered && !isSelected ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous))
        .onHover { inside in
            if inside { hoveredRow = bot.id }
            else if hoveredRow == bot.id { hoveredRow = nil }
        }
        // The ⋯ is a sibling of the row's button, not a button inside it: a control nested in a
        // button's label is a control macOS never delivers a click to.
        .overlay(alignment: .trailing) {
            overflowButton(for: bot, isVisible: isHovered)
                .padding(.trailing, metrics.rowPadding + 2)
        }
        .contextMenu {
            BotRowMenu(menu: rowMenu(for: bot))
        }
        .help(bot.displayName)
        .accessibilityLabel(accessibilityLabel(for: bot))
    }

    /// The row's ⋯: the same entries the right-click opens, as a native menu. It used to be a
    /// popover the row drew itself, because ⌘E could not raise a `Menu` from the menu bar — ⌘E opens
    /// the bot's panel now, so the pointer's menu went back to being a menu.
    ///
    /// Hidden until the pointer is on the row (or a menu is open), in a fixed slot so revealing it
    /// moves nothing.
    @ViewBuilder
    private func overflowButton(for bot: Bot, isVisible: Bool) -> some View {
        Menu {
            BotRowMenu(menu: rowMenu(for: bot))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Tokens.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Tokens.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .help("Bot menu")
        .accessibilityLabel("Bot menu")
    }

    /// A hidden bot is not gone: the filter reveals it here, and one click puts it back.
    private func hiddenRow(for bot: Bot) -> some View {
        let isHovered = hoveredRow == hiddenKey(bot.id)

        return Button {
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
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                    .fill(isHovered ? Tokens.controlHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredRow = hiddenKey(bot.id) }
            else if hoveredRow == hiddenKey(bot.id) { hoveredRow = nil }
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        .contextMenu {
            Button { model.toggleHidden(botID: bot.id) } label: {
                Label("Show bot", systemImage: "eye")
            }
            Button { store.openBotSettings(bot) } label: {
                Label("Bot Settings", systemImage: "gearshape")
            }
            Button { sheet = .newCategory(bot) } label: {
                Label("New category…", systemImage: "folder.badge.plus")
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

    // MARK: The row's menu

    /// One description of the menu, read by the native context menu and by the popover ⌘E opens.
    private func rowMenu(for bot: Bot) -> BotMenu {
        BotMenu(bot: bot,
                face: store.botFaces[bot.id] ?? BotFace.default(for: bot.id),
                isPinned: model.isPinned(botID: bot.id),
                isHidden: model.isHidden(botID: bot.id),
                categories: model.botCategories,
                currentCategoryID: model.categoryID(for: bot.id),
                openSettings: { store.openBotSettings(bot) },
                togglePin: { model.togglePin(botID: bot.id) },
                toggleHidden: { model.toggleHidden(botID: bot.id) },
                showSessions: { showSessions(for: bot) },
                assignCategory: { categoryID in assign(category: categoryID, to: bot) },
                newCategory: { sheet = .newCategory(bot) },
                renameCategory: { category in sheet = .renameCategory(category) },
                deleteCategory: { category in pendingCategoryDelete = category })
    }

    // MARK: Category writes

    /// Every group is a document on the host; each call answers with the whole of it, so the list
    /// redraws from the host's own answer rather than from a local guess.
    private func assign(category categoryID: String?, to bot: Bot) {
        // @MainActor: `@State` is written from this task, and a plain `Task {}` started from a
        // view helper is not main-actor bound.
        Task { @MainActor in
            do {
                try await model.setBotCategory(bot.id, to: categoryID)
            } catch {
                failure = "The host did not accept the move: \(sentence(for: error))"
            }
        }
    }

    private func createCategory(named name: String, assignTo bot: Bot?) async -> String? {
        let before = Set(model.botCategories.map(\.id))
        do {
            try await model.addBotCategory(name: name)
        } catch {
            return "The host did not create “\(name)”: \(sentence(for: error))"
        }

        guard let bot else { return nil }
        guard let created = model.botCategories.first(where: { !before.contains($0.id) }) else {
            return nil
        }
        do {
            try await model.setBotCategory(bot.id, to: created.id)
        } catch {
            return "“\(created.name)” was created, but \(bot.displayName) could not be moved into it: \(sentence(for: error))"
        }
        return nil
    }

    private func rename(_ category: BotCategory, to name: String) async -> String? {
        do {
            try await model.renameBotCategory(id: category.id, to: name)
            return nil
        } catch {
            return "The host did not rename it: \(sentence(for: error))"
        }
    }

    private func delete(_ category: BotCategory) {
        pendingCategoryDelete = nil
        Task { @MainActor in
            do {
                try await model.deleteBotCategory(id: category.id)
            } catch {
                failure = "The host did not delete “\(category.name)”: \(sentence(for: error))"
            }
        }
    }

    /// The host writes the useful sentence; an NSError's is a sentence about a socket.
    private func sentence(for error: Error) -> String {
        if case let GatewayError.rpc(rpc) = error, !rpc.message.isEmpty { return rpc.message }
        if let gateway = error as? GatewayError { return gateway.message }
        return error.localizedDescription
    }

    // MARK: Sessions

    /// **All sessions…** for one bot.
    ///
    /// `AppModel.sessions` is scoped to the bot on screen, so a bot that is not selected is opened
    /// first — the same act as clicking its row — and the sheet waits for that switch to land.
    /// Handing the sheet another bot's history under this one's name is the bug worth avoiding.
    private func showSessions(for bot: Bot) {

        Task { @MainActor in
            if model.selectedBotID != bot.id {
                store.selectBot(bot.id)
                var waited = 0
                while model.selectedBotID != bot.id, waited < 60 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    waited += 1
                }
            }
            // The switch is a resume, and the popover this menu lives in is still dismissing:
            // one beat between closing a popover and presenting a sheet over the same row.
            try? await Task.sleep(nanoseconds: 80_000_000)
            sheet = .sessions(bot)
        }
    }

    private func open(session: SessionSummary, for bot: Bot) {
        Task {
            // The sheet is dismissed by the caller; resuming paints the pane behind it.
            await model.select(session.id)
        }
    }

    // MARK: Facts

    /// The face's state, and only for the bot whose turn is live. Everything else is `nil`, the
    /// portrait's own idle case: no sparks, no pulse, nothing asked of the renderer by a row that
    /// is not doing anything.
    private func portraitStatus(for bot: Bot) -> PortraitStatus? {
        guard bot.id == model.selectedBotID else { return nil }
        if model.hasPendingRequests { return .needsYou }
        if model.isCompressing { return .compacting }
        if model.isStreaming { return .working }
        return nil
    }

    private func categoryName(for bot: Bot) -> String? {
        guard let id = model.categoryID(for: bot.id) else { return nil }
        return model.botCategories.first { $0.id == id }?.name
    }

    private func roomFill(_ room: RoomSummary) -> Color {
        if model.activeRoom?.id == room.id { return Tokens.controlActive }
        return hoveredRow == roomKey(room.id) ? Tokens.controlHover : .clear
    }

    private func roomKey(_ id: RoomSummary.ID) -> String { "room-\(id)" }
    private func hitKey(_ id: BotSearchHit.ID) -> String { "hit-\(id)" }
    private func hiddenKey(_ id: String) -> String { "hidden-\(id)" }

    /// A description written on the host is the useful line; without one, name what the row is.
    private func subtitle(for bot: Bot) -> String {
        if let description = bot.description, !description.isEmpty { return description }
        return bot.id == bot.displayName ? "Hermes profile" : bot.id
    }

    private func accessibilityLabel(for bot: Bot) -> String {
        var parts = [bot.displayName, "bot"]
        if model.isPinned(botID: bot.id) { parts.append("pinned") }
        if let category = categoryName(for: bot) { parts.append("in \(category)") }
        let unread = model.unreadCount(bot.id)
        if unread > 0 { parts.append(unread == 1 ? "1 unread" : "\(unread) unread") }
        else if model.hasUnread(bot.id) { parts.append("unread") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Sheets

/// One presentation at a time on this list: a bot's sessions, a new group, or a group's new name.
private enum BotListSheet: Identifiable {
    case sessions(Bot)
    case newCategory(Bot?)
    case renameCategory(BotCategory)

    var id: String {
        switch self {
        case .sessions(let bot): return "sessions-\(bot.id)"
        case .newCategory(let bot): return "new-\(bot?.id ?? "any")"
        case .renameCategory(let category): return "rename-\(category.id)"
        }
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
