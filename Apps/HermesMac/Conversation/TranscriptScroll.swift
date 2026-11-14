import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The scrolled transcript, with the live turn appended at the bottom.
///
/// Rows are laid out in a `LazyVStack` so a long conversation only builds the rows on
/// screen, and each row is capped at `Geometry.conversationMeasure` (640 pt) — the measure
/// OpenBot draws chat at, which is what keeps a wide window readable.
struct TranscriptScroll: View {
    @ObservedObject var model: AppModel

    /// Bumped by the header's magnifier (`WorkspaceStore.openFindInChat`). The search lives here,
    /// so this is a request to open the field and take the caret — not shared state: the field,
    /// its query and its match index are local to the reading surface.
    var findRequest: Int = 0
    /// The composer's measured height. The capsule floats over the transcript and grows upward, so
    /// the last rows have to clear it by exactly this much.
    var bottomInset: CGFloat = 0
    /// The bot's swatch: the user's own bubbles are drawn in it, so a window with three bots open
    /// never leaves you guessing whose conversation you are typing into.
    var userBubbleTint: Color = Tokens.control
    /// The roster's faces, so the thinking row can turn the same face the sidebar shows.
    var faces: [String: BotFace] = [:]

    /// Grouping is memoised: see `TranscriptRowCache` — a body pass per published token would
    /// otherwise walk the whole conversation.
    /// Grouping is memoised: `TranscriptRowCache` walks the transcript only when it changes, and a
    /// body pass happens on every published token.
    @State private var rowCache = TranscriptRowCache()
    @State private var searching = false
    @State private var query = ""
    @State private var matchIndex = 0
    /// "Select Text" is one sheet for the whole transcript, not one per row: a row lives inside a
    /// `LazyVStack`, so a sheet owned by a row is destroyed the moment that row scrolls out.
    @State private var selectionText: String?
    @FocusState private var searchFocused: Bool
    private let streamingID = "conversation-streaming-search"

    private var matches: [String] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var ids = model.visibleTranscript.filter { $0.text.localizedCaseInsensitiveContains(query) }.map(\.id)
        if model.isStreaming && model.streamingText.localizedCaseInsensitiveContains(query) { ids.append(streamingID) }
        return ids
    }

    private var selectedMatch: String? {
        guard searching, matches.indices.contains(matchIndex) else { return nil }
        return matches[matchIndex]
    }

    private func moveMatch(_ direction: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (min(matchIndex, matches.count - 1) + direction + matches.count) % matches.count
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

    var body: some View {
        VStack(spacing: 0) {
            // No permanent search *row*: idle, the transcript gets that height back and search is
            // reached with ⌘F (or the palette). The field and its controls exist only while the
            // search is open.
            if searching {
                searchRow
                    .transition(.opacity)
            } else {
                searchShortcut
            }

            transcript
        }
        .sheet(isPresented: selectionSheetPresented) {
            SelectTextSheet(text: selectionText ?? "") { selectionText = nil }
        }
        // ⌘F and the magnifier land in the same place; a second press re-focuses a field that is
        // already open instead of doing nothing.
        .onChange(of: findRequest) { _, _ in openSearch() }
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
                VStack(spacing: 0) {
                    rows
                    endSentinel
                }
                // The measuring device: it reads the scroll view's own offset and height, and it
                // is what performs the jump when `scrollRequest` changes.
                .background(
                    ScrollViewportProbe(scrollSignal: scrollRequest) { atBottom in
                        if atBottom != followsBottom { followsBottom = atBottom }
                    }
                )
            }
            // Floating over the transcript's foot — the strip just above the composer, which is
            // where the eye goes looking for it.
            .overlay(alignment: .bottom) { foot.padding(.bottom, bottomInset) }
            .onAppear { scrollRequest += 1 }

            .onChange(of: model.transcript.count) { _, _ in follow(proxy) }
            .onChange(of: model.streamingText) { _, _ in follow(proxy) }
            .onChange(of: model.isStreaming) { _, _ in follow(proxy) }
            .onChange(of: model.selectedSessionID) { _, _ in openSession(proxy) }
            .onChange(of: query) { _, _ in
                matchIndex = 0
                if let id = selectedMatch { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: matchIndex) { _, _ in
                if let id = selectedMatch { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: matches) { _, newMatches in
                guard searching else { return }
                matchIndex = min(matchIndex, max(0, newMatches.count - 1))
                if let id = selectedMatch { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// The messages, on the reading measure.
    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if model.hasEarlierHistory {
                EarlierHistoryRow(isLoading: model.loadingEarlier, total: model.historyTotal) {
                    Task { await model.loadEarlierHistory() }
                }
            }

            // Consecutive tool calls fold into one line: a turn that makes thirty calls should not
            // push its answer off the screen. The run's cards are one click away, each still its own
            // card with its own disclosure.
            ForEach(rowCache.rows(model.visibleTranscript + model.visibleLiveToolEntries,
                                  running: Set(model.visibleLiveToolEntries.map(\.id)))) { row in
                switch row {
                case .entry(let entry):
                    TranscriptRowView(entry: entry,
                                      host: model.hostName,
                                      bot: model.selectedBotID ?? "",
                                      session: model.selectedSessionID,
                                      userBubbleTint: userBubbleTint,
                                      onSelectText: { selectionText = $0 },
                                      onReply: { model.reply(to: $0) })
                        .id(entry.id)
                        .background(selectedMatch == entry.id ? Tokens.accentSoft : Color.clear)
                case .toolRun(let run):
                    ToolRunGroup(run: run) { entry in
                        TranscriptRowView(entry: entry,
                                          host: model.hostName,
                                          bot: model.selectedBotID ?? "",
                                          session: model.selectedSessionID,
                                          userBubbleTint: userBubbleTint,
                                          onSelectText: { selectionText = $0 },
                                          onReply: { model.reply(to: $0) })
                            .background(selectedMatch == entry.id ? Tokens.accentSoft : Color.clear)
                    }
                    .id(run.id)
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
                                         face: model.selectedBot.map {
                                             faces[$0.id] ?? BotFace.default(for: $0.id)
                                         })
                    .id(streamingID)
                    .background(selectedMatch == streamingID ? Tokens.accentSoft : Color.clear)
                    .transition(.opacity)
            }
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
                if !searching, !followsBottom {
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
        guard !searching, followsBottom else { return }
        // `proxy` is kept for the search jumps; the jump to the newest message is the probe's.
        _ = proxy
        scrollRequest += 1
    }

    /// A different conversation opens at its newest message, whatever the previous one's reading
    /// position was — the follow is re-armed with it.
    private func openSession(_ proxy: ScrollViewProxy) {
        _ = proxy
        query = ""
        matchIndex = 0
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
    }

    // MARK: - Search

    /// The open search: field, match count, the two chevrons and Done, on the same measure and
    /// reading inset as the transcript beneath it.
    private var searchRow: some View {
        HStack(spacing: 6) {
            TextField("Search messages", text: $query)
                .focused($searchFocused)
                .accessibilityIdentifier("conversationSearchField")

            Text(countLabel)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(isEmptySearch ? Tokens.warning : Tokens.textMuted)
                .lineLimit(1)
                .accessibilityIdentifier("conversationSearchCount")

            OpenBotIconButton("chevron.up",
                              label: "Previous search result",
                              size: .small,
                              isDisabled: matches.isEmpty) {
                moveMatch(-1)
            }
            OpenBotIconButton("chevron.down",
                              label: "Next search result",
                              size: .small,
                              isDisabled: matches.isEmpty) {
                moveMatch(1)
            }

            TextButton("Done", tone: Tokens.textMuted) { closeSearch() }
        }
        .padding(.horizontal, Geometry.readingInset)
        // The pill floats over this row too, so the field starts below it.
        .padding(.top, Geometry.chatHeaderPill + 10)
        .frame(maxWidth: Geometry.conversationMeasure + Geometry.readingInset * 2)
        .frame(maxWidth: .infinity)
    }

    /// The keyboard door to search, kept while the row is hidden so ⌘F still works — and kept as a
    /// real `Button` with the same accessibility identifier, so the shortcut is discoverable to
    /// VoiceOver and to the UI tests.
    private var searchShortcut: some View {
        Button {
            openSearch()
        } label: {
            EmptyView()
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityIdentifier("conversationSearchToggle")
        .accessibilityLabel("Search conversation")
        .help("Search conversation")
    }

    private var countLabel: String {
        guard !query.isEmpty else { return "" }
        return matches.isEmpty ? "No matches" : "\(min(matchIndex + 1, matches.count)) of \(matches.count)"
    }

    private var isEmptySearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && matches.isEmpty
    }

    private var selectionSheetPresented: Binding<Bool> {
        Binding(get: { selectionText != nil },
                set: { if !$0 { selectionText = nil } })
    }

    private func closeSearch() {
        searching = false
        query = ""
        matchIndex = 0
    }

    private func openSearch() {
        searching = true
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
    /// The bot's face while it works: the row that used to be a wheel with a phrase beside it.
    var face: BotFace?

    var body: some View {
        Group {
            if text.isEmpty {
                WorkingStatus(face: face)
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
