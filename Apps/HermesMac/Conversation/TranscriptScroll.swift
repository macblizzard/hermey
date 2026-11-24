import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// The scrolled transcript, with the live turn appended at the bottom.
///
/// Rows are laid out in a `LazyVStack` so a long conversation only builds the rows on
/// screen, and each row is capped at `Geometry.conversationMeasure` (640 pt) — the measure
/// Graphite draws chat at, which is what keeps a wide window readable.
struct TranscriptScroll: View {
    @ObservedObject var model: AppModel
    /// The other bot, when the pair sheet is open. A non-empty id is the sheet's whole state.
    @State private var pairPeer = ""

    /// Bumped by any of the three doors to find-in-conversation (`WorkspaceStore.openFindInChat`):
    /// ⌘F and the Conversation menu's "Find in Conversation…", the bot panel's "Search this
    /// conversation" row, and the ⌘K palette's verb. The search lives here, so this is a request,
    /// not shared state: the field, its query and its cursor are local to the reading surface
    /// (`TranscriptSearchState`), which is what keeps the sidebar's bot field and this one from
    /// ever being the same search.
    ///
    /// It **toggles**: every press flips the bar, so ⌘F is the way out as well as the way in. A bar
    /// you can only leave with the mouse reads as broken (reported 2026-11-16).
    var findToggleRequest: Int = 0

    /// Bumped by a *seeded* open only (a bot-list message hit): opens the bar pre-filled. Never a
    /// toggle — a finding clicked twice must land on the same phrase twice.
    var findRequest: Int = 0
    /// The phrase to open the bar with, when the request came from a finding in the bot panel's
    /// search rather than from ⌘F. Only honoured while `findSeedRequest` names *this* request, so a
    /// later plain ⌘F starts on an empty field instead of replaying the last finding.
    var findSeed: String = ""
    var findSeedRequest: Int = 0
    /// The seed request already applied. A seed is one shot: once the finding's phrase is in the
    /// field, a later ⌘F opens on an empty field instead of replaying it.
    @State private var appliedSeedRequest = -1
    /// The composer's measured height. The capsule floats over the transcript and grows upward, so
    /// the last rows have to clear it by exactly this much.
    var bottomInset: CGFloat = 0
    /// The bot's swatch: the user's own bubbles are drawn in it, so a window with three bots open
    /// never leaves you guessing whose conversation you are typing into.
    var userBubbleTint: Color = Tokens.control
    /// The roster's faces, so the thinking row can turn the same face the sidebar shows.
    var faces: [String: BotFaceChoice] = [:]

    /// Grouping is memoised: `TranscriptRowCache` walks the transcript only when it changes, and a
    /// body pass happens on every published token.
    @State private var rowCache = TranscriptRowCache()
    /// The bar, its field and its cursor: one value, so the three doors that open it (⌘F, the bot
    /// panel's "Search this conversation", the Conversation menu) cannot each hold their own idea of
    /// what is being searched. `TranscriptSearchState` owns the rules and is tested without a window.
    @State private var search = TranscriptSearchState()
    /// "Select Text" is one sheet for the whole transcript, not one per row: a row lives inside a
    /// `LazyVStack`, so a sheet owned by a row is destroyed the moment that row scrolls out.
    @State private var selectionText: String?
    /// The reading position, held across a prepend of older rows (see `TranscriptAnchorKeeper`).
    ///
    /// Armed from the two doors that *name* a prepend — the model's `earlierLoads` counter and the
    /// "load earlier" tap — before SwiftUI lays the merged rows out, and consumed by the AppKit half
    /// on the layout that follows. Without it a prepend inserts rows above the viewport and
    /// everything the reader is looking at slides down by the page's height.
    ///
    /// Not from `transcript.count`, which used to guess: a resume's merge grows the transcript and
    /// can change which row is first without prepending anything, and a guess that arms there moves
    /// a page the reader did not ask to move.
    @State private var anchorHold = TranscriptAnchorHold()
    @FocusState private var searchFocused: Bool
    private let streamingID = "conversation-streaming-search"

    /// The rows this conversation matches, in reading order, with the live turn last.
    ///
    /// `ConversationSearch` is the one matcher, shared with the phone: a substring of folded text,
    /// so it answers at one character exactly as it does at four and a longer query can only narrow
    /// the answer. The copy this replaces was the row's raw text through
    /// `localizedCaseInsensitiveContains` — locale- and diacritic-sensitive, and blind to a phrase
    /// the renderer wrapped across a line break.
    private var matches: [String] {
        // The live turn is searched as it is *drawn* (`visibleStreamingText`), not as it is stored:
        // the bar counts what the reader can see, and the bubble under it draws the visible form.
        ConversationSearch.ids(matching: search.query,
                               in: model.visibleTranscript,
                               id: \.id,
                               text: \.text,
                               extra: model.isStreaming && !model.visibleStreamingText.isEmpty
                                   ? (id: streamingID, text: model.visibleStreamingText)
                                   : nil)
    }

    private var selectedMatch: String? { search.selected(in: matches) }

    private func moveMatch(_ direction: Int) {
        // Wraps at both ends and is defined at every count, including none. The index is clamped
        // inside `step`, so one earned under a wider query cannot point past a narrower answer.
        search.step(by: direction, count: matches.count)
    }

    /// The tint a message row wears while the bar is open.
    ///
    /// The row the chevrons are on is the answer to "where am I"; the other rows that match are
    /// tinted faintly, so a search does not look like a single highlighted line in a transcript full
    /// of hits. Idle, every row is clear — the tint is chrome for the search, not for the message.
    ///
    /// `ids` are the ids this row answers for: its own for a message, a run's cards for a folded
    /// run. `matched` and `selected` are passed in rather than read from `matches` because `matches`
    /// walks the transcript: reading it per row would make drawing a search quadratic in the length
    /// of the conversation.
    private func fill(_ ids: [String], among matched: Set<String>, selected: String?) -> Color {
        guard search.isOpen else { return .clear }
        if let selected, ids.contains(selected) { return Tokens.accentSoft }
        return ids.contains(where: matched.contains) ? Tokens.accentSoft.opacity(0.45) : .clear
    }

    /// The ring a folded run wears.
    ///
    /// A run's cards are hidden until it is opened, and its own header is drawn on a card of its
    /// own, so a fill behind the group would sit under that card and never be seen. The match is
    /// drawn as a ring around the one line that *is* on screen — which is also where the chevrons
    /// land (`scrollTarget(for:)`).
    private func ring(_ ids: [String], among matched: Set<String>, selected: String?) -> Color {
        guard search.isOpen else { return .clear }
        if let selected, ids.contains(selected) { return Tokens.accent }
        return ids.contains(where: matched.contains) ? Tokens.accent.opacity(0.45) : .clear
    }

    private let bottomID = "transcript-bottom"

    /// True while new content may pull the transcript down. Reported by the scroll view itself, so
    /// the auto-scroll and the floating control can never disagree about whether the newest message
    /// is on screen.
    @State private var followsBottom = true

    /// Counts requests to go to the newest message. The scroll view's own position is what the
    /// jump is made from (see `ScrollViewportProbe`), because a proxy jump runs before the lazy
    /// transcript has laid out and lands short of the bottom — the reason a freshly opened
    /// conversation started mid-history.
    @State private var scrollRequest = 0

    /// Arrow/Page/Home keys, for the reader who has both hands on the keyboard. The scroll view is
    /// the only thing that knows how far a page is, so the keys go through it rather than through
    /// `ScrollViewProxy`, which can only scroll to an id.
    @State private var keyboardScroll = KeyboardScrollHandle()

    var body: some View {
        VStack(spacing: 0) {
            // No permanent search *row*: idle, the transcript gets that height back and search is
            // reached with ⌘F (the Conversation menu carries the same key), from the bot panel's
            // "Search this conversation" row, or from the palette. The field and its controls exist
            // only while the search is open — and they open here, over the transcript, not in the
            // sidebar, whose field searches every conversation at once and lists what it found.
            if search.isOpen {
                searchRow
                    .transition(.opacity)
            } else {
                searchShortcut
            }

            transcript
        }
        // Escape closes the bar and clears it. Both doors are wired: the hidden button owns the key
        // while the field has the keyboard (a focused `TextField` cancels its own editing and the
        // event never reaches `onExitCommand`), and `onExitCommand` covers the focus being
        // elsewhere, on a chevron or on Done.
        .background(escapeCloser)
        .onExitCommand { closeSearch() }
        .sheet(isPresented: selectionSheetPresented) {
            SelectTextSheet(text: selectionText ?? "") { selectionText = nil }
            .hermesSheetChrome()
        }
        // The exchange between two bots, opened from a bot-to-bot message's attribution line.
        .sheet(isPresented: Binding(get: { !pairPeer.isEmpty },
                                    set: { if !$0 { pairPeer = "" } })) {
            BotPairSheet(current: model.selectedBotID ?? "",
                         peer: pairPeer,
                         displayName: { profile in
                             model.bots.first { $0.id == profile }?.displayName
                                 ?? profile.capitalized
                         },
                         load: { await model.transfers(between: model.selectedBotID ?? "",
                                                       and: pairPeer) })
                .hermesSheetChrome()
        }
        // ⌘F and the magnifier land in the same place; a second press re-focuses a field that is
        // already open instead of doing nothing.
        .onChange(of: findToggleRequest) { _, _ in toggleSearch() }
        .onChange(of: findRequest) { _, _ in openSearch() }
        // A seeded request that arrived while this pane was being built — the counter changed
        // before the transcript existed, so the change above never fired. One shot, for this
        // request only: the seed is matched by number, not by being non-empty.
        .onAppear {
            if pendingSeed != nil, !search.isOpen {
                openSearch()
            }
        }
    }

    // MARK: - Transcript

    /// The reader, the scroll view, the two measurements and their handlers.
    ///
    /// Kept out of `body` on purpose: one expression this size is more than the type-checker will
    /// chew in reasonable time ("unable to type-check this expression"), which is the wall the
    /// phone's transcript hit with less on screen.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                // The lazy stack is the scroll view's *direct* child. It used to sit inside a plain
                // `VStack` (only to hold the sentinel below it), and a `LazyVStack` nested in a stack
                // that has to measure its children stops being lazy — every row gets built, and a
                // long conversation then scrolls with all of its text laid out at once. The sentinel
                // moved inside the stack, where it is also the last row rather than a sibling.
                rows
                // The measuring device: it reads the scroll view's own offset and height, and it
                // is what performs the jump when `scrollRequest` changes. Growth-following is
                // switched off while the search bar is up: a streaming token that lands mid-search
                // must not drag the transcript away from the row the chevrons just jumped to.
                .background(TranscriptAnchorKeeper(hold: anchorHold))
                .background(
                    ScrollViewportProbe(scrollSignal: scrollRequest,
                                        followsGrowth: !search.ownsScrollPosition) { atBottom in
                        if atBottom != followsBottom { followsBottom = atBottom }
                    }
                )
                .keyboardScrollProbe(keyboardScroll)
            }
            .keyboardScrolling(keyboardScroll)
            // Floating over the transcript's foot — the strip just above the composer, which is
            // where the eye goes looking for it.
            .overlay(alignment: .bottom) { foot.padding(.bottom, bottomInset) }
            .onAppear { scrollRequest += 1 }

            .onChange(of: model.transcript.count) { _, _ in
                // A count change is deliberately *not* a door to the hold. It is far too common a
                // shape: a turn landing at the bottom, a rewind, and — the one that used to arm and
                // should not — a resume's merge that grows the transcript without prepending
                // anything, because `TranscriptPaging.merge` replaces the whole thing when the two
                // pages do not overlap. Older rows arriving is named by the two doors below.
                follow(proxy)
            }
            // The model's own counter, which the one path that prepends today
            // (`loadEarlierHistory`) bumps itself — they are the same event, and this is the one
            // that arrives *after* the rows are already in the transcript.
            .onChange(of: model.earlierLoads) { _, loads in
                anchorHold.hold(pinnedToBottom: followsBottom, reason: "earlierLoads \(loads)")
            }
            .onChange(of: model.streamingText) { _, _ in follow(proxy) }
            .onChange(of: model.isStreaming) { _, _ in follow(proxy) }
            .onChange(of: model.selectedSessionID) { _, _ in openSession(proxy) }
            // A read replaced the rows in place: a foreground, a re-read after an event this app could
            // not place, or a turn the host said was finished. The scroll view keeps the offset it
            // had, so rows that arrived *below* the viewport stayed there — the reply was on screen in
            // the model and out of sight in the pane, which reads exactly like "the message only
            // appears when I switch away and back". The phone has landed at the newest message on this
            // signal since its own re-read; the Mac had no handler for it at all.
            .onChange(of: model.transcriptReloads) { _, _ in
                followsBottom = true
                anchorHold.release(because: "the transcript was re-read")
                scrollRequest += 1
            }
            .onChange(of: search.query) { _, _ in
                // The cursor has already been reset to the first result by the state's own
                // assignment rule; this is the jump that shows it.
                scrollToSelected(proxy)
            }
            .onChange(of: search.index) { _, _ in scrollToSelected(proxy) }
            .onChange(of: matches) { _, newMatches in
                guard search.isOpen else { return }
                // Clamped rather than min()'d against a count that may be zero: an index earned
                // under a wider query has to land on a row that still matches.
                search.reconcile(count: newMatches.count)
                scrollToSelected(proxy)
            }
        }
    }

    /// The rows as they are drawn, from the memoising cache — read here as well as in `rows` so the
    /// search jumps to the row that exists on screen rather than to an id that only exists inside a
    /// folded run.
    private var groupedRows: [TranscriptRow] {
        rowCache.rows(model.visibleTranscript + model.visibleLiveToolEntries,
                      running: Set(model.visibleLiveToolEntries.map(\.id)))
    }

    /// Where a match is actually drawn.
    ///
    /// A run of tool calls is one line: its individual cards are built only once the run is opened.
    /// Scrolling to a hidden inner row does nothing at all, so a match inside a folded run is
    /// anchored to the run — which is also the row that gets tinted, and the disclosure that shows
    /// the card when it is opened.
    private func scrollTarget(for id: String) -> String {
        for row in groupedRows {
            if row.id == id { return id }
            if case .toolRun(let run) = row, run.entries.contains(where: { $0.id == id }) {
                return run.id
            }
        }
        return id
    }

    private func scrollToSelected(_ proxy: ScrollViewProxy) {
        guard let id = selectedMatch else { return }
        proxy.scrollTo(scrollTarget(for: id), anchor: .center)
    }

    /// The messages, on the reading measure.
    private var rows: some View {
        // One pass for the highlight, not one per row: `matches` walks the whole conversation, and a
        // `LazyVStack` would otherwise pay for it once for every row it builds. Idle it is not
        // walked at all — `fill`/`ring` already draw nothing while the bar is closed, and a body
        // pass costs O(conversation) in case-folding otherwise, every streaming token long.
        let searching = search.isOpen
        let matchedIDs = searching ? matches : []
        let matched = searching ? Set(matchedIDs) : []
        let selected = searching ? search.selected(in: matchedIDs) : nil
        return LazyVStack(alignment: .leading, spacing: 18) {
            if model.hasEarlierHistory {
                EarlierHistoryRow(isLoading: model.loadingEarlier, total: model.historyTotal) {
                    // Armed here as well as on the model's counter: the request is a round trip, so
                    // this is the only moment strictly before the page can land, whatever order
                    // SwiftUI chooses for `onChange` and the layout that follows it.
                    anchorHold.hold(pinnedToBottom: followsBottom, reason: "load earlier tapped")
                    Task { await model.loadEarlierHistory() }
                }
            }

            // Consecutive tool calls fold into one line: a turn that makes thirty calls should not
            // push its answer off the screen. The run's cards are one click away, each still its own
            // card with its own disclosure.
            ForEach(groupedRows) { row in
                switch row {
                case .entry(let entry):
                    TranscriptRowView(entry: entry,
                                      host: model.hostName,
                                      bot: model.selectedBotID ?? "",
                                      session: model.selectedSessionID,
                                      userBubbleTint: userBubbleTint,
                                      onSelectText: { selectionText = $0 },
                                      onReply: { model.reply(to: $0) },
                                      onOpenPair: { peer in pairPeer = peer },
                                      fetchCard: { id, session, message in
                                          try await model.fetchCard(id: id, session: session, message: message)
                                      },
                                      openAttachmentFile: { [model] location in
                                          try await model.attachmentFile(for: location)
                                      },
                                      reaction: { model.reaction(for: $0) },
                                      onReact: { key, emoji in
                                          Task { await model.setReaction(emoji, for: key) }
                                      })
                        .id(entry.id)
                        .background(fill([entry.id], among: matched, selected: selected))
                case .toolRun(let run):
                    ToolRunGroup(run: run) { entry in
                        TranscriptRowView(entry: entry,
                                          host: model.hostName,
                                          bot: model.selectedBotID ?? "",
                                          session: model.selectedSessionID,
                                          userBubbleTint: userBubbleTint,
                                          onSelectText: { selectionText = $0 },
                                          onReply: { model.reply(to: $0) },
                                          onOpenPair: { peer in pairPeer = peer },
                                          fetchCard: { id, session, message in
                                              try await model.fetchCard(id: id, session: session, message: message)
                                          },
                                          openAttachmentFile: { [model] location in
                                              try await model.attachmentFile(for: location)
                                          },
                                          reaction: { model.reaction(for: $0) },
                                          onReact: { key, emoji in
                                              Task { await model.setReaction(emoji, for: key) }
                                          })
                            .background(fill([entry.id], among: matched, selected: selected))
                    }
                    .id(run.id)
                    // The run answers for its cards: a query that matches only a folded command has
                    // to say so on the one line that is drawn, and the chevrons land here.
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                            .strokeBorder(ring(run.entries.map(\.id), among: matched, selected: selected),
                                          lineWidth: 1.5)
                    )
                }
            }

            // The model's thinking, while it is thinking. The phone has drawn this since reasoning
            // landed; the Mac never did, so a reasoning model looked mute until the answer came.
            if model.showReasoning, !model.reasoningText.isEmpty {
                MacReasoningBlock(text: model.reasoningText,
                                  startsExpanded: model.reasoningExpandedByDefault)
                    .frame(maxWidth: Geometry.conversationMeasure, alignment: .leading)
            }

            if model.isStreaming {
                StreamingAssistantBubble(text: model.visibleStreamingText,
                                         bot: model.selectedBot?.id,
                                         color: model.selectedBot.flatMap { faces[$0.id]?.raw },
                                         activity: model.selectedBot.map { model.activity(forBot: $0.id) } ?? .working)
                    .id(streamingID)
                    .background(fill([streamingID], among: matched, selected: selected))
                    .transition(.opacity)
            }

            endSentinel
        }
        // Measured, *then* inset: the 640 pt measure is the text column, so the reading inset
        // sits outside it. Padding the measure instead (what the composer did) left the field
        // 592 pt wide and every column a different distance from the edge.
        .frame(maxWidth: Geometry.conversationMeasure, alignment: .leading)
        .padding(.horizontal, Geometry.readingInset)
        // Clears the floating pill: the transcript scrolls behind it, but its first row must not
        // start underneath it.
        .padding(.top, Geometry.chatHeaderPill + 20)
        // The composer's live height: the capsule grows upward, so the rows it would cover have to
        // move with it. Passed in by the pane, which measures it.
        .padding(.bottom, 10 + bottomInset)
        .frame(maxWidth: .infinity)
    }

    /// The end of the transcript as a marker of its own, not as the lazy stack's last row: a row
    /// is only built once it comes into view, and a sentinel a screenful away would report
    /// nothing until the user was already there.
    private var endSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id(bottomID)
    }

    /// The foot of the viewport: the control that returns to the newest message.
    private var foot: some View {
        ZStack(alignment: .bottom) {
            Group {
                // Hidden while the search row is up: the search owns the scroll position then,
                // and this would compete with the chevrons that step through matches.
                if !search.ownsScrollPosition, !followsBottom {
                    scrollToBottomButton
                }
            }
            .animation(.easeOut(duration: 0.18), value: followsBottom)
        }
    }

    // MARK: - Following the newest message

    /// Pull the transcript down only while it is already at the bottom.
    ///
    /// Off on purpose while the blank-out is chased: following a streaming reply means a scroll
    /// request per token, and a request that lands while the transcript is re-laying itself out is
    /// the most likely way for rows to vanish and the view to jump. With it off the transcript only
    /// moves when a person moves it, or when a *different* conversation opens.
    ///
    /// One line to put back — the call sites are all still wired.
    static let followsNewMessages = false

    /// A user who scrolled up keeps their place: a streaming reply must not yank the reading
    /// position back on every token, which is what the old unconditional scroll did. The
    /// floating control is the way back, and taking it re-arms the follow.
    private func follow(_ proxy: ScrollViewProxy) {
        guard Self.followsNewMessages else { return }
        // An open bar owns the scroll position: a match has been jumped to, and a token arriving
        // mid-search must not move it. `ownsScrollPosition` is the bar, not the query — the gap
        // between ⌘F and the first keystroke is when a streaming turn most often lands.
        guard !search.ownsScrollPosition, followsBottom else { return }
        // `proxy` is kept for the search jumps; the jump to the newest message is the probe's.
        _ = proxy
        scrollRequest += 1
    }

    /// A different conversation opens at its newest message, whatever the previous one's reading
    /// position was — the follow is re-armed with it. A search belongs to the conversation it was
    /// typed in, so it goes with the old one: leaving it up would answer the new bot's rows with
    /// the old bot's query.
    private func openSession(_ proxy: ScrollViewProxy) {
        _ = proxy
        search.resetForConversationChange()
        // The held position belongs to the rows that are leaving. A new conversation's first row
        // is not "earlier" than anything the reader was looking at.
        anchorHold.release(because: "a different conversation opened")
        followsBottom = true
        scrollRequest += 1
    }


    /// The way back down: a circle centred on the column, floating just above the composer, with
    /// the same quiet surface as the composer's own controls. Drawn only when the measurement
    /// says a message is out of sight.
    private var scrollToBottomButton: some View {
        Button {
            // No `followsBottom = true` here: the transcript is still above its end while the
            // jump happens, and the probe reports the verdict when it lands.
            scrollRequest += 1
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.textMuted)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Tokens.control))
                .overlay(Circle().strokeBorder(Tokens.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 7, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Scroll to latest message")
        .accessibilityLabel("Scroll to latest message")
        .accessibilityIdentifier("conversationScrollToBottom")
        .padding(.bottom, 14)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .hermeyFocusQuiet()
    }

    // MARK: - Search

    /// The open search: field, match count, the two chevrons and Done, on the same measure and
    /// reading inset as the transcript beneath it.
    ///
    /// It sits *over the transcript*, never in the bot panel. The panel's field searches too — it
    /// sends the phrase to the host, which scans every bot's conversation — but the answer there is
    /// snippets; the row has to be *findable in the text*, with its neighbours around it, which is
    /// what this bar does. A finding in the panel therefore opens this one, already filled.
    private var searchRow: some View {
        // One pass over the transcript per render: the count, the colour and the two chevrons all
        // read the same answer, so they cannot disagree mid-keystroke.
        let found = matches
        let label = search.status(matched: found.count)
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.textDim)

            // "Search this conversation", not "Search messages": the sidebar's field asks the host
            // about every conversation at once, and this one is the transcript you are looking at.
            // Two scopes, two prompts (reported 2026-11-15).
            TextField(ConversationSearch.prompt, text: $search.query)
                .textFieldStyle(.plain)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textPrimary)
                .focused($searchFocused)
                .onSubmit {
                    // Return walks the answer, the way ⌘G does in every Mac find bar.
                    if !found.isEmpty { moveMatch(1) }
                }
                .accessibilityIdentifier("conversationSearchField")

            Text(label)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(search.isActive && found.isEmpty
                                 ? Tokens.warning : Tokens.textMuted)
                .lineLimit(1)
                .accessibilityIdentifier("conversationSearchCount")

            HermeyIconButton("chevron.up",
                              label: "Previous search result",
                              size: .small,
                              isDisabled: found.isEmpty) {
                moveMatch(-1)
            }
            HermeyIconButton("chevron.down",
                              label: "Next search result",
                              size: .small,
                              isDisabled: found.isEmpty) {
                moveMatch(1)
            }

            TextButton("Done", tone: Tokens.textMuted) { closeSearch() }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        // The same quiet surface as the sidebar's filter field, so it reads as a control over the
        // transcript rather than as another line of it.
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .fill(Tokens.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .strokeBorder(Tokens.borderFocus, lineWidth: 1)
        )
        .padding(.horizontal, Geometry.readingInset)
        // The pill floats over this row too, so the field starts below it.
        .padding(.top, Geometry.chatHeaderPill + 10)
        .padding(.bottom, 4)
        .frame(maxWidth: Geometry.conversationMeasure + Geometry.readingInset * 2)
        .frame(maxWidth: .infinity)
        // The caret on arrival. `openSearch()` also asks on the already-open path (a second ⌘F);
        // this is the one that works when the row is being *inserted*, because focus assigned in the
        // same update as the insertion lands before the field exists and is silently dropped.
        .onAppear { searchFocused = true }
    }

    /// The keyboard door to search, kept while the row is hidden so ⌘F still works — and kept as a
    /// real `Button` with the same accessibility identifier, so the shortcut is discoverable to
    /// VoiceOver and to the UI tests. The key itself belongs to the Conversation menu's "Find in
    /// Conversation…", which is the copy a user can actually see.
    private var searchShortcut: some View {
        Button {
            openSearch()
        } label: {
            EmptyView()
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityIdentifier("conversationSearchToggle")
        .accessibilityLabel("Search conversation")
        .help("Search conversation")
        .hermeyFocusQuiet()
    }

    /// Escape, while the bar is up.
    ///
    /// A hidden button is the only way to own the key while the field holds it: a focused
    /// `TextField` handles Escape as "cancel editing" and the event never reaches `onExitCommand`.
    /// Absent while the bar is closed, so the bot panel's own Escape and the sidebar's search keep
    /// theirs.
    @ViewBuilder
    private var escapeCloser: some View {
        if search.isOpen {
            Button("") { closeSearch() }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
                .hermeyFocusQuiet()
        }
    }

    private var selectionSheetPresented: Binding<Bool> {
        Binding(get: { selectionText != nil },
                set: { if !$0 { selectionText = nil } })
    }

    /// Done, Escape, or a second ⌘F: the bar goes and the field goes with it, so the next open
    /// starts empty rather than on an answer the reader has already finished with. Closing also
    /// hands the scroll position back — `search.ownsScrollPosition` is what was holding
    /// `follow()` off, and leaving it armed after the bar is gone stops the transcript following
    /// the next turn for no visible reason.
    private func closeSearch() {
        search.close()
        searchFocused = false
        followsBottom = true
    }

    /// ⌘F, the menu, the palette, the panel row: open the bar if it is closed, close it if it is
    /// open. One verb, one key — the same press undoes itself.
    private func toggleSearch() {
        if search.isOpen {
            closeSearch()
        } else {
            openSearch()
        }
    }

    /// The phrase a finding asked for, if this request has not already used it.
    ///
    /// Matched by request number rather than by "is a seed set", and consumed when applied: the
    /// same phrase is never replayed by a later plain press, and a finding clicked twice still
    /// lands on its phrase twice (each click is a new request number).
    private var pendingSeed: String? {
        guard findSeedRequest == findRequest, findSeedRequest != appliedSeedRequest,
              !findSeed.isEmpty else { return nil }
        return findSeed
    }

    private func openSearch() {
        if let seed = pendingSeed, search.query != seed {
            search.query = seed
            appliedSeedRequest = findSeedRequest
        }
        search.open()
        searchFocused = true
    }
}


/// The model's reasoning, collapsed to one line until asked for.
///
/// It is not the answer and must not read like one: dim type, its own surface, a disclosure. Open by
/// default would put a paragraph of thinking above every reply.
struct MacReasoningBlock: View {
    let text: String
    /// The user's preference (Settings ▸ Chat): open on arrival rather than on a click.
    var startsExpanded = false

    @State private var expanded: Bool

    init(text: String, startsExpanded: Bool = false) {
        self.text = text
        self.startsExpanded = startsExpanded
        _expanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.textDim)
                    Text("Reasoning")
                        .font(TypeScale.font(TypeScale.label, weight: .semibold))
                        .foregroundStyle(Tokens.textMuted)
                    Spacer(minLength: 8)
                    DisclosureGlyph(expanded: expanded)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reasoning")
            .accessibilityHint(expanded ? "Collapse reasoning" : "Expand reasoning")
            .hermeyFocusQuiet()

            if expanded {
                Text(text)
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textMuted)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.bottom, 10)
            }
        }
        .background(Tokens.surface.opacity(0.7),
                    in: RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 1)
        )
    }
}

/// The assistant's turn while it is still arriving.
///
/// The first token can take a while, so an empty stream shows the spinner instead of an
/// empty bubble — but the moment there is text it is rendered through the same
/// `MarkdownTextView` a finished message uses, so nothing jumps when the turn completes.
struct StreamingAssistantBubble: View {
    let text: String
    /// The bot whose work this row is standing in for, and its stored face — the row that used to
    /// be a wheel with a phrase beside it.
    var bot: String?
    var color: String?
    /// What the bot is doing right now, so the row's face is the same activity the roster shows.
    var activity: BotAvatarActivity = .working

    var body: some View {
        Group {
            if text.isEmpty {
                WorkingStatus(bot: bot, activity: activity, color: color)
            } else {
                MarkdownTextView(text: text, isStreaming: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One message, whole, in a sheet of its own. Owned by `TranscriptScroll` rather than by the row
/// that opened it, so scrolling the row out of view while reading cannot take the sheet with it.
struct SelectTextSheet: View {
    let text: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Select Text")
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Spacer()
                TextButton("Done", tone: Tokens.textMuted, action: onDone)
            }

            ScrollView {
                Text(text)
                    .font(TypeScale.font(TypeScale.chatBody))
                    .lineSpacing(TypeScale.chatLineSpacing)
                    .foregroundStyle(Tokens.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 240)
        .background(Tokens.sheet)
    }
}

// MARK: - Previews

private struct TranscriptScrollPreview: View {
    @StateObject private var store = PreviewWorkspace.store(.streaming)

    var body: some View {
        TranscriptScroll(model: store.model)
            .frame(width: Geometry.conversationMeasure + 160, height: 620)
            .background(Tokens.canvas)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

private struct StreamingBubblePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StreamingAssistantBubble(text: "")
            StreamingAssistantBubble(text: "Snapshotting the vault first, then I'll diff the `docs/` tree.")
        }
        .padding(24)
        .frame(width: Geometry.conversationMeasure, alignment: .leading)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Transcript · streaming") {
    TranscriptScrollPreview()
}
#endif

#if DEBUG
#Preview("Streaming bubble") {
    StreamingBubblePreview()
}
#endif
