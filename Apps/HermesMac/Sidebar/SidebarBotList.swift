import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// The bots block at the top of the left pane.
///
/// The rail's avatars stay the fastest switch; this list is the phone's bot list brought to the
/// desktop: the profile's description under its name, a green dot for a reply that arrived while
/// the conversation was not on screen, pin/hide from the row's menu. The filter is the panel's
/// search field (`BotSidebarView`), applied here against name and id — and the same field's findings
/// are drawn above the rows, so the panel answers "where did anyone say this?" as well as "which bot
/// is this?".
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
    /// A finding was clicked. The panel owns what "open this hit" means (resume, then land on the
    /// message), so the list reports the click rather than deciding it — the keyboard's Return and
    /// this click must go through the same door.
    var onOpenHit: ((BotSearchHit) -> Void)? = nil

    /// The row the keyboard is on, drawn as the list's selection so the two agree about what Return
    /// would open. `nil` while the pointer is the only thing choosing.
    var highlighted: SidebarSearchRow? = nil

    private var icons: [String: BotFaceChoice] { store.botFaces }

    /// The row under the pointer, or whose overflow menu is open. One value for the whole list, so
    /// exactly one row can be lit — the panel's own convention (`MacBotPanel.hovered`).
    @State private var hoveredRow: String?

    /// The row the keyboard is actually on — tab focus, not the search list's highlight — so the
    /// ⋯ can be revealed for a keyboard user who has never touched the pointer. `nil` while no row
    /// holds focus, which is the resting case: a focused key is a per-row fact, so it cannot be read
    /// off a single `hoveredRow`.
    @FocusState private var focusedRow: String?

    /// The row whose ⋯ itself holds focus. Without it, tabbing from the row into the menu would take
    /// the focus off the row, hide the button under the focus ring, and leave a keyboard user with an
    /// invisible control.
    @FocusState private var focusedOverflow: String?

    /// Arrow/Page/Home keys for the roster. The list already scrolls to `highlighted`; this is the
    /// pointer-free way to move through what is on screen.
    @State private var keyboardScroll = KeyboardScrollHandle()

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
    /// The rule lives in `SidebarSearch` so the panel's keyboard list and this list cannot disagree
    /// about which bots the query matches.
    private func matches(_ bot: Bot) -> Bool {
        SidebarSearch.matches(bot, query: trimmedQuery)
    }

    /// The state the field is in, from the three facts this panel has: what was typed, what the host
    /// last answered, and whether a request is out. One value, so the header, the row and the empty
    /// state cannot tell three different stories about the same keystroke.
    private var phase: SidebarSearchPhase {
        SidebarSearch.phase(query: trimmedQuery,
                            answered: model.searchQuery,
                            running: model.searchRunning,
                            hits: model.searchPage.hits.count,
                            botMatches: visibleBots.count)
    }

    /// Findings belong to the phrase the host answered. While the next answer is in flight the old
    /// rows must not be drawn under a new query: they describe a search the user has moved past.
    private var activeHits: [BotSearchHit] {
        isSearching && phase == .results ? model.searchPage.hits : []
    }

    /// Nothing to draw: no matching visible bots, no matching hidden ones to reveal, and no findings
    /// above them. Findings count: a query that found messages has something to show even when no
    /// bot name matched it.
    private var isFilteredEmpty: Bool {
        visibleBots.isEmpty
            && activeHits.isEmpty
            && !(showsHiddenBots && !hiddenBots.isEmpty)
    }

    private var rowCount: Int {
        // A collapsed group contributes its heading and no rows: the block shrinks with it.
        let bots = isSearching ? visibleBots.count + activeHits.count + 1
                               : model.botGroups.reduce(0) { total, group in
                                   total + (isCollapsed(group) ? 0 : group.bots.count)
                               }
        return bots + (showsHiddenBots ? hiddenBots.count : 0)
    }

    /// One heading per group, drawn above its rows — plus the group chats' own caption, which is
    /// only drawn when there are rooms to head.
    private var captionCount: Int {
        isSearching ? 0 : model.botGroups.count + (roomRows.isEmpty ? 0 : 1)
    }

    /// Group chats sit above the bots and are searchable only by their own names' absence: the
    /// search box filters bots, so a search hides the rooms instead of pretending to match them.
    private var roomRows: [RoomSummary] { isSearching ? [] : model.rooms }

    /// The block sizes to its content and stops growing at about five rows, then scrolls.
    private var listHeight: CGFloat {
        let hiddenExtra = showsHiddenBots && !hiddenBots.isEmpty ? 24 : 0
        // Folded, the rooms contribute their heading and nothing else — the divider goes with the
        // rows, the way every category's does.
        let roomExtra = roomRows.isEmpty || roomsCollapsed
            ? 0 : CGFloat(roomRows.count) * 44 + 34
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
        let rows = ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !roomRows.isEmpty {
                        // The phone has always drawn a heading over its rooms; the Mac drew them
                        // bare, under a "no caption over either list" note that left the reader
                        // guessing what the rows above the divider were. It is now the same caption
                        // as every bot group — chevron, name, count, remembered fold — because a
                        // second kind of heading on one list is a second thing to learn.
                        roomsCaption

                        if !roomsCollapsed {
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
                    }

                    // What the search found inside the conversations, above the rows: a phrase is the
                    // thing being looked for, and a bot name is the fallback. The header counts what
                    // the host answered, not what is drawn — the page is capped at 50.
                    messagesSection

                    // The owner's groups, the same headings the phone draws: Pinned above everything,
                    // the categories by name, Uncategorized last (asked for 2026-11-15). While a search
                    // is running the answer is one flat list — a heading would split it up for nothing —
                    // so the row carries its category as a chip instead.
                    if isSearching {
                        ForEach(visibleBots) { bot in
                            HoverRow { hovered in
                                row(for: bot, isHovered: hovered,
                                    isKeyboardSelected: highlighted == .bot(bot.id))
                            }
                                // The identity the keyboard scrolls to: a row and a finding share the
                                // one namespace `SidebarSearchRow` defines.
                                .id(SidebarSearchRow.bot(bot.id))
                        }
                    } else {
                        ForEach(model.botGroups) { group in
                            groupCaption(group)
                            if !isCollapsed(group) {
                                ForEach(group.bots) { bot in
                                    HoverRow { hovered in row(for: bot, isHovered: hovered) }
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
                // looked half-faded before the list had scrolled at all — 6 pt was not enough, and
                // the row is 16 pt clear of the edge now (reported twice, 2026-11-14).
                .padding(.top, 16)
                .keyboardScrollProbe(keyboardScroll)
            }
            .keyboardScrolling(keyboardScroll)
            // Up/Down must be able to reach every row, not only the ones already on screen: the
            // keyboard's row is followed into view as soon as it moves.
            .onChange(of: highlighted) { _, row in
                guard let row else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(row, anchor: .center) }
            }
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
            BotAvatarView(identity: hit.profile,
                          color: store.botFaces[hit.profile]?.raw,
                          activity: store.activity(for: hit.profile),
                          size: Geometry.rosterAvatarCompact,
                          animates: false)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.bots.first { $0.id == hit.profile }?.displayName ?? hit.profile)
                        .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)
                    // Whose turn the message was: "leak" is answered differently depending on
                    // whether the bot said it or the user typed it.
                    Text(hit.isOwner ? "you" : "bot")
                        .font(TypeScale.font(Tokens.rosterMeta))
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(RelativeTime.stamp(hit.at))
                        .font(TypeScale.font(Tokens.rosterMeta))
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                }
                Text(emphasising(hit))
                    .font(TypeScale.font(Tokens.rosterMeta))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(hit.snippet)
    }

    /// The snippet with every occurrence of the match weighted.
    ///
    /// Built by *range*, from the plain string the host sent — never by parsing markup. A snippet is
    /// whatever was said in a conversation, so the one thing it must not be is a document: nothing
    /// here interprets `<`, `&` or anything else, which is why a message mentioning HTML cannot
    /// style the row or inject a control into it.
    private func emphasising(_ hit: BotSearchHit) -> AttributedString {
        var text = AttributedString(hit.snippet)
        let needle = hit.match.isEmpty ? trimmedQuery : hit.match
        guard !needle.isEmpty else { return text }

        var searchStart = text.startIndex
        // The host's snippet is a line or two; a cap keeps a pathological phrase ("a") from walking
        // the string once per character.
        var marks = 0
        while marks < 8, searchStart < text.endIndex,
              let found = text[searchStart..<text.endIndex].range(of: needle,
                                                                  options: .caseInsensitive) {
            text[found].font = .system(size: Tokens.rosterMeta, weight: .semibold)
            text[found].foregroundColor = Tokens.textPrimary
            searchStart = found.upperBound
            marks += 1
        }
        return text
    }

    // MARK: The messages block

    /// The panel's answer above the roster: what the host found inside the conversations, or the one
    /// sentence that says why there is nothing to draw yet.
    ///
    /// Every state the field can be in is drawn here, in the same place, so the panel never looks
    /// like a roster with a silent search running behind it.
    @ViewBuilder
    private var messagesSection: some View {
        switch phase {
        case .idle:
            EmptyView()

        case .tooShort:
            // The host will not search one character, so the panel says what it needs instead of
            // reporting an absence it never looked for.
            hintRow("Type at least 2 characters to search messages.")

        case .waiting:
            // Between a keystroke and the request: the field is ahead of the host. Claiming "no
            // matches" here is the bug this state exists to prevent.
            HStack(spacing: 6) {
                SpinningRing(color: Tokens.textDim, size: 9, lineWidth: 1.3)
                Text("Searching…")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

        case .searching:
            SectionCaption("MESSAGES")
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
            HStack(spacing: 6) {
                SpinningRing(color: Tokens.textDim, size: 9, lineWidth: 1.3)
                Text("Searching…")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

        case .results:
            SectionCaption("MESSAGES · \(model.searchPage.total)")
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(activeHits) { hit in
                Button { onOpenHit?(hit) } label: {
                    findingRow(hit)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                                .fill(hitFill(hit))
                        )
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hoveredRow = hitKey(hit.id) }
                    else if hoveredRow == hitKey(hit.id) { hoveredRow = nil }
                }
                .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous))
                .id(SidebarSearchRow.message(hit.id))
                .accessibilityLabel("\(model.bots.first { $0.id == hit.profile }?.displayName ?? hit.profile): \(hit.snippet)")
            }

        case .messagesEmpty:
            // The transcripts were searched and had nothing; the bots below did match. The count
            // says both things at once without a second sentence.
            SectionCaption("MESSAGES · 0")
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
            hintRow("No message mentions “\(trimmedQuery)”.")

        case .noMatches:
            // Both halves are empty, and the list's own empty state says so once.
            EmptyView()
        }
    }

    private func hitFill(_ hit: BotSearchHit) -> Color {
        if highlighted == .message(hit.id) { return Tokens.controlActive }
        return hoveredRow == hitKey(hit.id) ? Tokens.controlHover : .clear
    }

    private func hintRow(_ text: String) -> some View {
        Text(text)
            .font(TypeScale.font(TypeScale.caption))
            .foregroundStyle(Tokens.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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

    /// The group-chats heading folds and stays folded exactly like a category's: same map, same
    /// animation, its own reserved id. A room has no category on the host, so this heading is the
    /// app's own — and the Mac drew the rows with no caption at all, so a reader coming from the
    /// phone (which has always drawn one) could not tell what the rows above the divider were.
    private var roomsCollapsed: Bool { collapsedGroups[BotGrouping.roomsID] == true }

    private func toggleCollapsed(_ group: BotGroup) { setCollapsed(group.id) }

    private func toggleRoomsCollapsed() { setCollapsed(BotGrouping.roomsID) }

    private func setCollapsed(_ id: String) {
        var map = collapsedGroups
        map[id] = !(map[id] ?? false)
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8) else { return }
        collapsedGroupsJSON = json
    }

    /// The heading over the group chats: the phone's caption, with the Mac's own fold.
    ///
    /// Deliberately the same control the categories use — chevron, name, count, `help`, a remembered
    /// fold — rather than a label. Two kinds of heading in one list would be two things to learn, and
    /// this one has to be collapsible because rooms are now a group like any other.
    private var roomsCaption: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { toggleRoomsCollapsed() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: roomsCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Tokens.textDim)
                Text(BotGrouping.roomsName.uppercased())
                    .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Tokens.textMuted)
                Text("\(roomRows.count)")
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
        .help(roomsCollapsed ? "Expand \(BotGrouping.roomsName)" : "Collapse \(BotGrouping.roomsName)")
        .accessibilityLabel("\(BotGrouping.roomsName), \(roomRows.count) group chats")
        .accessibilityHint(roomsCollapsed ? "Expand" : "Collapse")
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
                Divider()
                // Moving a group is the one thing here that changes the list's shape, so it is
                // greyed out where there is nowhere to go rather than failing silently.
                Button { move(category, by: -1) } label: {
                    Label("Move “\(category.name)” Up", systemImage: "arrow.up")
                }
                .disabled(!model.canMoveBotCategory(id: category.id, by: -1))

                Button { move(category, by: 1) } label: {
                    Label("Move “\(category.name)” Down", systemImage: "arrow.down")
                }
                .disabled(!model.canMoveBotCategory(id: category.id, by: 1))
                Divider()

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


/// One row's hover, held by the row.
///
/// The list used to keep a single `hoveredRow` and every row read it, so one pointer crossing rows
/// invalidated the whole list — and a scroll with the cursor over the sidebar crosses rows for as
/// long as it lasts. The state belongs to the row that can be hovered.
private struct HoverRow<Content: View>: View {
    @ViewBuilder var content: (_ isHovered: Bool) -> Content
    @State private var inside = false

    var body: some View {
        content(inside)
            .onHover { inside = $0 }
    }
}

    private var metrics: BotListMetrics { BotListMetrics(scale: listScale) }

    private func row(for bot: Bot, isHovered: Bool = false,
                     isKeyboardSelected: Bool = false) -> some View {
        // A room on screen owns the selection: the bot underneath is not the conversation the
        // pane is showing, and highlighting both made the sidebar look like two things were open.
        let isSelected = bot.id == model.selectedBotID && model.activeRoom == nil
        // `isHovered` is the row's own now, handed down by `HoverRow`. It used to be
        // `hoveredRow == bot.id`, read from one @State on the whole list — so every hover change
        // rebuilt every visible row, and scrolling with the pointer over the list fires those
        // transitions continuously. That is the sticky feel the conversation pane no longer has.
        let isPinned = model.isPinned(botID: bot.id)

        // The ⋯ is not on every row all the time: it belongs to the row the person is on — under
        // the pointer, holding keyboard focus, or the one the list has selected or highlighted.
        // At rest the row is just the bot, and nothing is reserved for a control that is not there.
        let showsOverflow = isHovered
            || isSelected
            || isKeyboardSelected
            || focusedRow == bot.id
            || focusedOverflow == bot.id

        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            store.selectBot(bot.id)
        } label: {
            HStack(alignment: .center, spacing: metrics.gap) {
                // Same rule as the phone: the stored face if there is one, otherwise the body the
                // bot's id picks — never a bare initial. The working state is the reference's ring
                // around the face, which is where this app already puts it.
                //
                // The pose is the tracker's, so a row that is *not* the open conversation still says
                // `reading` or `computer` while that bot works. Only a moving bot animates: an idle
                // row is a legend, and a 20 fps timeline per row is pure heat.
                BotAvatarView(identity: bot.id,
                              color: store.botFaces[bot.id]?.raw,
                              activity: store.activity(for: bot.id),
                              size: metrics.avatar,
                              animates: store.activity(for: bot.id) != .idle,
                              // The pointer is on this row, so its face wakes: one greeting, then the
                              // reference's own idle float, for as long as the pointer stays. This is
                              // the same hover the ⋯ appears on — one state, two things that answer it.
                              // It lifts the resting `animates` rule for this row only, and the row's
                              // frame never changes size, so nothing re-lays while the face moves.
                              wakesOnHover: isHovered)
                    // Same two indicators as the phone, by the same instruction: the count on the
                    // face says *how much* is waiting, the beacon at the row's edge says *something*
                    // is. A single dot lost the number the user asked for twice.
                    .overlay(alignment: .bottomTrailing) {
                        UnreadBadge(count: model.unreadCount(bot.id), size: (17 * CGFloat(listScale)).rounded())
                            .offset(x: 5, y: 4)
                    }

                // Two lines, in the house order: the name and when it last spoke on the first, what
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

                        // One word for what this bot is doing, from the same table the face and the
                        // live activity read. Idle draws nothing.
                        BotStateBadge(activity: store.activity(for: bot.id),
                                      size: (Tokens.rosterMeta * 0.92).rounded())

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
                        // One trailing affordance at a time: while the ⋯ is on the row it owns that
                        // corner, or the two would be drawn on top of each other.
                        .opacity(showsOverflow ? 0 : 1)
                }
            }
            .padding(.horizontal, metrics.rowPadding)
            .padding(.vertical, metrics.rowPadding)
            .frame(height: metrics.rowHeight)
            // The hover fill is the row's own background, drawn at a fixed size: nothing here is
            // padded, scaled or re-laid-out by the pointer, so a row never moves under it.
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                    .fill(isSelected || isKeyboardSelected ? Tokens.controlActive
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
        // The keyboard's own row: tab focus is what reveals the ⋯ without a pointer, and the
        // binding is keyed by bot id so exactly one row can hold it.
        .focused($focusedRow, equals: bot.id)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous))
        // The ⋯ is a sibling of the row's button, not a button inside it: a control nested in a
        // button's label is a control macOS never delivers a click to.
        //
        // An *overlay*, so it reserves no gutter: the row's title and timestamp are laid out as if
        // the ⋯ were not there, and a long title simply truncates underneath it. A reserved trailing
        // slot instead would re-wrap names as the pointer moved and leave a permanent hole at rest.
        .overlay(alignment: .trailing) {
            overflowButton(for: bot, isVisible: showsOverflow)
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
    /// **Not on every row all the time.** It exists only while the row is the one being used —
    /// hovered, keyboard-focused, selected or highlighted — and at rest the row is the bot alone. It
    /// still occupies no layout: the button is an overlay, so nothing re-flows when it arrives, and
    /// `allowsHitTesting` follows visibility so a click over the invisible corner belongs to the row.
    /// It stays in the accessibility tree regardless, so VoiceOver and the accessibility "Show Menu"
    /// action reach it without a pointer, exactly as the right-click menu does.
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
        // Focus inside the menu is still "this row's ⋯": the row's own focus is gone the moment the
        // keyboard steps into the menu, and the button must not vanish under the focus ring.
        .focused($focusedOverflow, equals: bot.id)
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
            Button { store.openSettings(for: bot) } label: {
                Label("Bot Settings", systemImage: "gearshape")
            }
            Button { sheet = .newCategory(bot) } label: {
                Label("New category…", systemImage: "folder.badge.plus")
            }
        }
        .help("Show \(bot.displayName) in the bot list")
        .accessibilityLabel("Show \(bot.displayName)")
    }

    /// One row that says why the block is empty — and it is a statement about *both* halves of the
    /// answer, because the field searches both.
    ///
    /// The copy this replaces described the field as a bot filter and pointed at ⌘F for the
    /// conversation. That was true of the panel it was written for and is not true of this one: the
    /// field covers every bot's conversation itself. A phrase with no hits and no matching bot name
    /// therefore says so once, names the phrase, and says what was searched, so a mistyped query
    /// cannot be mistaken for a host with nothing to say.
    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            switch phase {
            case .tooShort:
                VStack(alignment: .leading, spacing: 3) {
                    // The host's floor, not ours: one character is a keystroke, not a search.
                    Text("Type at least 2 characters to search messages.")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Bot names still filter as you type.")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textDim.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            case .waiting, .searching:
                HStack(spacing: 8) {
                    SpinningRing(color: Tokens.textDim, size: 9, lineWidth: 1.3)
                    Text("Searching every bot's conversation…")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textDim)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)

            case .noMatches:
                VStack(alignment: .leading, spacing: 3) {
                    Text("No matches for “\(trimmedQuery)”")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Searched every bot's conversation and the bot names.")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textDim.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            default:
                // Findings are drawn above; a bot matched; or the field is empty. Nothing to add.
                EmptyView()
            }
        } else if model.botsLoading {
            // Nothing. A roster being re-read is not a host with no bots, and the pre-roster window
            // belongs to the launch screen (`BootScreen`), not to a spinner here — this list is only
            // drawn once the roster exists. Saying "no bots" mid-refresh would be the same lie in a
            // slower font, so the row simply says nothing until the answer lands.
            EmptyView()
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
                face: store.botFaces[bot.id],
                isPinned: model.isPinned(botID: bot.id),
                isHidden: model.isHidden(botID: bot.id),
                categories: model.botCategories,
                currentCategoryID: model.categoryID(for: bot.id),
                openSettings: { store.openSettings(for: bot) },
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

    /// One step up or down, from the heading's menu.
    ///
    /// The arrangement is the host's, so this is a write like any other and its refusal is kept on
    /// screen (`failure`, drawn by the alert above) — `try?` here would have moved a group on this
    /// Mac alone, which is the exact desync the category document exists to prevent. The ends are
    /// disabled by `canMoveBotCategory`, which applies the model's own Pinned/Uncategorized rule.
    private func move(_ category: BotCategory, by offset: Int) {
        Task { @MainActor in
            do {
                try await model.moveBotCategory(id: category.id, by: offset)
            } catch {
                failure = "The host did not move “\(category.name)”: \(sentence(for: error))"
            }
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
