import SwiftUI
import UIKit
import UniformTypeIdentifiers
import HermesKit
import HermesAppKit
import OpenBotUI

/// The conversation with one bot — one endless thread, always.
///
/// There is no session browser here and none anywhere else: opening a bot asks the model
/// for that bot's stored (or freshly created) session and attaches to it. The header is
/// the bot, the model the host named, the wire latency and how full the context window is;
/// the only two things you can do to the thread — compact it or reset it — sit behind the
/// overflow menu, and resetting asks first.
struct ConversationScreen: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var app: AppEnvironment
    /// The custom back button below is the only way out, so this view needs the dismissal itself.
    @Environment(\.dismiss) private var dismiss

    let bot: Bot

    @State private var sessionID: SessionID?
    @State private var isOpening = true
    @State private var showApprovalSheet = false
    @State private var showResetConfirm = false
    @State private var showComputer = false
    @State private var notice: String?
    @State private var lastSeenRequestCount = 0
    /// The prepend counter this screen has already reacted to (see the transcript's onChange).
    @State private var lastSeenEarlierLoads = 0
    @State private var hasLoaded = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardScreenSize: CGSize = .zero
    @State private var keyboardScrollTask: Task<Void, Never>?
    @State private var isDraggingTranscript = false

    /// Whether the transcript's own end is on screen. Fed by the bottom sentinel appearing and
    /// disappearing, so it is a fact about the scroll position rather than a guess — it decides
    /// both whether new tokens may pull the view down and whether the way back is offered.
    @State private var isAtBottom = true

    /// Bumped when a conversation finishes opening. The jump runs a few times because a lazy
    /// transcript lays its rows out over several frames, and a single scroll taken on the first
    /// frame lands near the top of the history instead of its end.
    @State private var openScrollSignal = 0
    @State private var showAttachmentMenu = false
    @State private var attachmentSource: AttachmentSource?

    /// One voice controller per conversation screen: recording, transcription and
    /// playback share an audio session, so they must not race each other.
    @StateObject private var voice = VoiceController()
    /// Opt-in and never persisted: speaking replies is a per-visit choice.
    @State private var speakReplies = false
    @State private var lastSpokenEntryID: String?
    @State private var showBotSettings = false
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchIndex = 0
    @FocusState private var searchFocused: Bool

    private static let bottomID = "conversation-bottom"
    private static let streamingSearchID = "conversation-streaming-search"

    /// A pick can now carry a whole selection: the pickers return everything that was chosen, in
    /// the order it was chosen, and each one queues itself. A batch where some items failed still
    /// lands the ones that did not.
    private func accept(_ result: Result<[AttachmentPayload], Error>) {
        attachmentSource = nil
        switch result {
        case .success(let payloads):
            let before = model.pendingAttachments.count
            for payload in payloads {
                model.addPendingAttachment(name: payload.name, data: payload.data, isImage: payload.isImage)
            }
            // Some of the batch was refused (the cap, or a size the sender will not take): say so
            // instead of letting the missing files look like a picker that ignored them.
            if model.pendingAttachments.count < before + payloads.count {
                notice = model.lastSendError ?? "Some attachments could not be added."
            }
        case .failure(let error):
            notice = error.localizedDescription
        }
    }

    /// The menu closes before the picker opens: they are separate presentations and the
    /// overlay must not sit on top of a system sheet.
    private func pick(_ source: AttachmentSource) {
        closeAttachmentMenu()
        switch source {
        case .camera:
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                notice = AttachmentPickerError.cameraUnavailable.localizedDescription
                return
            }
            attachmentSource = .camera
        case .photos:
            attachmentSource = .photos
        case .files:
            attachmentSource = .files
        }
    }

    private func closeAttachmentMenu() {
        showAttachmentMenu = false
    }

    private var title: String { bot.displayName }

    /// What is waiting in chats that are not this one.
    ///
    /// The count cannot live on the back button: iOS draws a custom bar button inside its own glass
    /// capsule, which pushed the title off centre and cost the edge-swipe (hiding the system back
    /// button disables it). It sits in the header strip instead, next to the model, and a tap goes
    /// back to the list where every row carries its own badge.
    private var unreadElsewhere: Int { model.unreadElsewhere(excludingBot: bot.id) }

    var body: some View {
        transcriptScroll
        // Tapping the thread closes the paperclip's menu, the way any transient menu behaves.
        .overlay {
            if showAttachmentMenu {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { closeAttachmentMenu() }
                    .accessibilityHidden(true)
            }
        }
        .background(Tokens.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) { composerArea }
        .mobileConnectionBanner(connection: app.visibleConnection,
                                turnRunning: model.isStreaming,
                                host: app.hostLabel,
                                retry: { Task { await app.reconnect() } })
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The bot's own face in the title bar, sparks and all: the list taught the eye which
            // portrait means which bot, and a header that showed only a name made the two places
            // disagree. `isWorking` is the same flag the list uses, so the antenna arcs while this
            // bot is the one answering — and not while another one is.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    BotIconPortrait(app.botIcons[bot.id] ?? BotIcon.default(for: bot.id),
                                    size: 26,
                                    isWorking: model.isStreaming && model.selectedBotID == bot.id)
                    Text(title)
                        .font(TypeScale.font(TypeScale.sessionTitle, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            toolbarContent
        }
        .safeAreaInset(edge: .top, spacing: 0) { headerStrip }
        .onAppear { model.setVisibleBot(bot.id) }
        .onDisappear { model.setVisibleBot(nil) }
        .task(id: bot.id) {
            voice.transport = app.makeVoiceTransport()
            await openConversation()
        }
        // Another chat's unread is this screen's badge, so the counts are swept while the
        // conversation is open instead of waiting for the list to reappear. Both calls are one
        // request each and only answer rooms that moved, so an idle chat costs two pings.
        .task {
            while !Task.isCancelled {
                await model.loadBotPreviews()
                await model.refreshRooms()
                try? await Task.sleep(nanoseconds: 25_000_000_000)
            }
        }
        .onChange(of: app.store.host) { _, _ in
            // A re-pair or host switch changes the endpoint the controller may talk to.
            voice.cancel()
            voice.transport = app.makeVoiceTransport()
        }
        .onChange(of: model.transcript.count) { _, _ in
            speakNewReplyIfNeeded()
        }
        .onChange(of: model.pendingRequests.count) { count in
            let arrived = hasLoaded && count > lastSeenRequestCount
            lastSeenRequestCount = count
            guard arrived, model.pendingRequests.first != nil else { return }
            Haptics.approvalArrived()
            showApprovalSheet = true
        }
        // The screen gets the whole sheet: a 1440x900 desktop in a half-height cover is a
        // thumbnail with buttons, which is what the pane already offers before you open it.
        // A page, not a sheet: the desktop is dragged, tapped and pinched inside this view, and a
        // sheet's own drag gesture took those touches and dismissed the window mid-task.
        .fullScreenCover(isPresented: $showComputer) {
            BotComputerPane(profile: bot.id,
                            displayName: bot.displayName,
                            client: app.computer,
                            resources: BotComputerResources(),
                            onClose: { showComputer = false })
        }
        .sheet(isPresented: $showBotSettings) {
            BotModelSettingsScreen(
                bot: bot,
                icon: app.botIcons[bot.id],
                load: { botID in try await model.modelCatalog(for: botID) },
                conversationIsOpen: true,
                resetConversation: { model.resetEndlessSession(for: bot.id) },
                save: { botID, option, confirmed in
                    switch try await model.configureModel(botID: botID, model: option.id,
                                                          provider: option.provider,
                                                          confirm: confirmed) {
                    case .applied: return .saved
                    case .confirmationRequired(let message): return .confirmationRequired(message)
                    }
                },
                // Memberwise order matters: `save` precedes `saveDescription` in the declaration.
                saveDescription: { botID, text in
                    try await model.configureDescription(botID: botID, description: text)
                })
        }
        // The choices live in the composer, anchored to the paperclip (`AttachmentMenu`); this
        // is only the system picker for the one the user chose.
        .sheet(item: $attachmentSource) { source in
            switch source {
            case .camera:
                AttachmentCamera(completion: { accept($0) },
                                 cancel: { attachmentSource = nil }).ignoresSafeArea()
            case .photos:
                AttachmentPhotos(completion: { accept($0) },
                                 cancel: { attachmentSource = nil }).ignoresSafeArea()
            case .files:
                AttachmentFiles(completion: { accept($0) },
                                cancel: { attachmentSource = nil })
            }
        }
        .sheet(isPresented: $showApprovalSheet) {
            MobileApprovalSheet(model: model, request: model.pendingRequests.first)
        }
        .confirmationDialog("Reset this conversation?",
                            isPresented: $showResetConfirm,
                            titleVisibility: .visible) {
            Button("Reset conversation", role: .destructive) {
                Task { await resetConversation() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This phone forgets its thread with \(title) and starts a new one on the next message. The old conversation stays on the host, and you can still open it there.")
        }
        .alert("Couldn’t add attachment", isPresented: noticeBinding) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: Header

    /// The header's second line, directly under the bot name: what is answering, over what
    /// wire, and how much of the window the thread has used. All three are facts the host
    /// reported — a missing fact is omitted, never guessed.
    private var headerStrip: some View {
        VStack(spacing: 0) {
            // The same line the bot list shows under the name.
            if let described = bot.description, !described.isEmpty {
                Text(described)
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 5)
            }

            HStack(spacing: 6) {
                // Other chats, while this one is on screen. Zero draws nothing.
                if unreadElsewhere > 0 {
                    Button {
                        dismiss()
                    } label: {
                        StatusChip("\(unreadElsewhere) unread", tone: .success, showsDot: true, size: .small)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(unreadElsewhere) unread chats elsewhere — back to the bot list")
                }

                if let label = modelChipLabel {
                    StatusChip(label, tone: .neutral, size: .small)
                }

                // One count in this row, never two: a phone-width strip fits the model chip, a
                // count, the context gauge and the latency pill — and "3 unread" is the only one of
                // those that is asking to be acted on, so it takes the entries label's place while
                // it is showing.
                if unreadElsewhere == 0, let entries = entryCountLabel {
                    Text(entries)
                        .font(TypeScale.font(TypeScale.micro))
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                }

                if let usage = contextUsage {
                    Text(usage)
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(contextTint)
                        .lineLimit(1)
                        .accessibilityLabel("Context used, \(usage) tokens")
                }

                Spacer(minLength: 6)

                MobileConnectionPill(connection: model.connection, rttMS: app.effectiveRTT)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(minHeight: 30)

            Hairline(color: Tokens.border)
            if isSearching {
                searchBar
                Hairline(color: Tokens.border)
            }
        }
        .background(Tokens.canvas)
    }

    /// `deepseek-v4.1-flash` fits; a provider-qualified id does not, and the chip is
    /// `fixedSize`, so it is shortened here rather than pushing the latency chip off.
    private var modelChipLabel: String? {
        guard let raw = model.modelLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let words = raw.split(separator: " ")
        let short = words.prefix(2).joined(separator: " ")
        guard !short.isEmpty else { return nil }
        return short.count <= 22 ? short : String(short.prefix(21)) + "…"
    }

    /// `12k / 1M` — only when the host has reported both halves of the window.
    /// "43k / 200k" when the host reports a window, "43k" when it does not — the desktop shows
    /// both facts and the phone showed neither.
    private var contextUsage: String? {
        guard let used = model.contextUsed else { return nil }
        if let limit = model.contextMax, limit > 0 {
            return "\(MobileTokens.short(used)) / \(MobileTokens.short(limit))"
        }
        return MobileTokens.short(used)
    }

    /// How much conversation is on screen, the same count the desktop's subtitle carries.
    private var entryCountLabel: String? {
        let count = model.transcript.count
        guard count > 0 else { return nil }
        return count == 1 ? "1 entry" : "\(count) entries"
    }

    private var contextTint: Color {
        guard let fraction = model.contextFraction else { return Tokens.textDim }
        if fraction >= 0.85 { return Tokens.danger }
        if fraction >= 0.70 { return Tokens.warning }
        return Tokens.textDim
    }

    // MARK: Transcript

    /// Search visible transcript text, including the summaries of tool and reasoning rows.
    private var searchMatches: [String] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var ids = model.visibleTranscript.filter { entry in
            entry.text.localizedCaseInsensitiveContains(searchText)
        }.map(\.id)
        if !model.streamingText.isEmpty,
           model.streamingText.localizedCaseInsensitiveContains(searchText) {
            ids.append(Self.streamingSearchID)
        }
        return ids
    }

    private var selectedSearchID: String? {
        let matches = searchMatches
        guard isSearching, matches.indices.contains(searchIndex) else { return nil }
        return matches[searchIndex]
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Tokens.textMuted)
            TextField("Search messages", text: $searchText)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("conversationSearchField")
            Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "" : searchMatches.isEmpty ? "No matches" : "\(min(searchIndex + 1, searchMatches.count)) of \(searchMatches.count)")
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize()
                .accessibilityIdentifier("conversationSearchCount")
            Button { moveSearch(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(searchMatches.isEmpty)
                .accessibilityLabel("Previous search result")
            Button { moveSearch(1) } label: { Image(systemName: "chevron.down") }
                .disabled(searchMatches.isEmpty)
                .accessibilityLabel("Next search result")
            Button("Done") {
                searchFocused = false
                isSearching = false
                searchText = ""
                searchIndex = 0
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear { searchFocused = true }
    }

    private func moveSearch(_ direction: Int) {
        let count = searchMatches.count
        guard count > 0 else { return }
        searchIndex = (min(searchIndex, count - 1) + direction + count) % count
    }

    private func scrollToSearchResult(_ proxy: ScrollViewProxy) {
        guard let id = selectedSearchID else { return }
        withAnimation(Motion.messageIn) { proxy.scrollTo(id, anchor: .center) }
    }

    /// Split out of `body` on purpose: a ScrollViewReader + ScrollView + LazyVStack + six
    /// conditionals in one expression exceeded the type-checker's budget
    /// ("unable to type-check this expression in reasonable time").
    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcriptList
                    // The one gutter a conversation uses, shared with the composer and with a
                    // group chat: `Geometry.chatGutter`, never a number typed here.
                    .padding(.horizontal, Geometry.chatGutter)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            // The way back to the newest message, on the same rule as the desktop's: it appears
            // only while the transcript's end is off screen.
            .overlay(alignment: .bottomTrailing) { scrollToBottomControl(proxy) }
            .animation(.easeOut(duration: 0.18), value: isAtBottom)
            .simultaneousGesture(DragGesture(minimumDistance: 5)
                .onChanged { _ in
                    isDraggingTranscript = true
                    keyboardScrollTask?.cancel()
                }
                .onEnded { _ in isDraggingTranscript = false })
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                keyboardFrameChanged(notification, proxy: proxy)
            }
            .onDisappear {
                keyboardScrollTask?.cancel()
                keyboardHeight = 0
                isDraggingTranscript = false
            }
            .onChange(of: openScrollSignal) {
                // Open lands at the newest message, however tall the transcript turns out to be.
                settleAtBottom(proxy)
            }
            .onChange(of: model.transcript.count) {
                // Older rows arriving is the one change that is *above* the reading position:
                // follow to the bottom and the user loses the page they just asked for.
                if model.earlierLoads != lastSeenEarlierLoads {
                    lastSeenEarlierLoads = model.earlierLoads
                    if let anchor = model.earlierAnchor { proxy.scrollTo(anchor, anchor: .top) }
                    return
                }
                // A message the user just sent is a reason to go down even from mid-history;
                // anything else follows only when the view was already at the end.
                if model.transcript.last?.role == .user {
                    scroll(proxy, animated: true)
                } else {
                    follow(proxy, animated: true)
                }
            }
            .onChange(of: model.streamingText) {
                follow(proxy, animated: false)
            }
            .onChange(of: model.liveTools.count) {
                follow(proxy, animated: false)
            }
            .onChange(of: model.reasoningText) {
                follow(proxy, animated: false)
            }
            .onChange(of: searchText) {
                searchIndex = 0
                scrollToSearchResult(proxy)
            }
            .onChange(of: searchIndex) {
                scrollToSearchResult(proxy)
            }
            .onChange(of: searchMatches) {
                guard isSearching else { return }
                searchIndex = min(searchIndex, max(0, searchMatches.count - 1))
                scrollToSearchResult(proxy)
            }
        }
    }

    private var transcriptList: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if isBlank {
                if isOpening {
                    openingState
                } else {
                    MobileTranscriptEmpty(title: title)
                }
            }

            if model.hasEarlierHistory {
                EarlierHistoryRow(isLoading: model.loadingEarlier, total: model.historyTotal) {
                    Task { await model.loadEarlierHistory() }
                }
            }

            ForEach(model.visibleTranscript) { entry in
                MobileTranscriptRow(entry: entry)
                    .overlay {
                        if selectedSearchID == entry.id {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Tokens.accentText, lineWidth: 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .id(entry.id)
            }

            if !model.pendingRequests.isEmpty {
                pendingSection
            }

            if let notice = model.compactionNotice {
                // Auto-compaction rewrites the stored transcript; without a line the conversation
                // would just get shorter with no explanation.
                Label(notice, systemImage: "arrow.triangle.2.circlepath")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
                    .accessibilityIdentifier("compactionNotice")
            }

            if model.showReasoning, !model.reasoningText.isEmpty {
                MobileReasoningBlock(text: model.reasoningText,
                                     startsExpanded: model.reasoningExpandedByDefault)
            }

            if model.showToolCalls, !model.liveTools.isEmpty {
                liveToolsSection
            }

            if model.isStreaming || !model.visibleStreamingText.isEmpty {
                MobileStreamingBubble(text: model.visibleStreamingText)
                    .overlay {
                        if selectedSearchID == Self.streamingSearchID {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Tokens.accentText, lineWidth: 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .id(Self.streamingSearchID)
            }

            Color.clear
                .frame(height: 1)
                .id(ConversationScreen.bottomID)
                // On screen only when the newest message is. A lazy row's appearance is the one
                // scroll fact a SwiftUI ScrollView gives without a preference dance.
                .onAppear { isAtBottom = true }
                .onDisappear { isAtBottom = false }
        }
    }

    private var isBlank: Bool {
        model.visibleTranscript.isEmpty
            && !model.isStreaming
            && model.pendingRequests.isEmpty
            && !(model.showToolCalls && !model.liveTools.isEmpty)
            && model.reasoningText.isEmpty
    }

    private var openingState: some View {
        HStack(spacing: 10) {
            SpinningRing(color: Tokens.textMuted, size: 12, lineWidth: 1.5)
            Text("Opening \(title)…")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// Live tool calls for the turn in flight.
    ///
    /// `input`/`output` are copied out as `String?` first: the card takes optional text, and
    /// the model is free to hand back either shape. The output is only passed when the user
    /// asked to see tool output in Settings *and* the tool actually produced some — an empty
    /// result is not a result.
    private var liveToolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.liveTools) { tool in
                let input: String? = tool.input
                let output: String? = tool.output
                MobileToolRow(name: tool.name,
                              summary: toolSummary(input),
                              output: output,
                              isRunning: tool.isRunning,
                              durationMS: tool.durationMS)
            }
        }
    }

    /// The first line of a tool's arguments, short enough for a card header.
    ///
    /// `tool.start` sends the arguments as JSON, so the first line is `{"command":"…` — unwrapping
    /// first means the header names the command rather than the envelope it came in.
    private func toolSummary(_ input: String?) -> String? {
        guard let input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let headline = ToolPayload.headline(raw: input) { return headline }
        let firstLine = input.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? input
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(90))
    }

    // MARK: Header controls

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 14) {
                // No stop control here: the composer's send button already turns into stop while a
                // turn runs, and a second one in the header was two buttons for one action.
                Menu {
                    // The shared desktop, where a bot's own verbs live: one screen for every bot,
                    // opened from the chat it is doing the errand for.
                    Button {
                        showComputer = true
                    } label: {
                        Label("Computer", systemImage: "display")
                    }

                    Divider()

                    Button {
                        isSearching = true
                        searchFocused = true
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }

                    Button {
                        showBotSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }

                    Button {
                        Task { await model.compressNow() }
                    } label: {
                        Label("Compact", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .disabled(sessionID == nil)

                    Divider()

                    // Reading aloud, where a switch with a name belongs — not as a bare glyph
                    // above the composer.
                    Toggle(isOn: Binding(get: { speakReplies },
                                         set: { enabled in
                                             speakReplies = enabled
                                             if !enabled { voice.stopSpeaking() }
                                             // History is not replayed: mark what exists now.
                                             if enabled { lastSpokenEntryID = lastAssistantReply?.id }
                                         })) {
                        Label("Speak replies", systemImage: "speaker.wave.2")
                    }
                    .disabled(lastAssistantReply == nil)

                    Divider()

                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("Reset chat", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Tokens.textSecondary)
                }
                .accessibilityLabel("Conversation actions")
            }
        }
    }

    // MARK: Pending requests

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let request = model.pendingRequests.first {
                MobilePendingRequestCard(model: model,
                                         request: request,
                                         onExpand: { showApprovalSheet = true })
            }

            if model.pendingRequests.count > 1 {
                Text("\(model.pendingRequests.count - 1) more waiting behind this one")
                    .font(TypeScale.font(TypeScale.sm, weight: .semibold))
                    .foregroundStyle(Tokens.warning)
                    .padding(.leading, 2)
            }
        }
    }

    // MARK: Composer

    private var composerArea: some View {
        VStack(spacing: 0) {
            if let error = model.lastSendError {
                sendErrorBar(error)
            }

            if !model.pendingAttachments.isEmpty {
                pendingAttachmentsBar
            }

            // Nothing sits above the field: the record button is in the composer beside send, and
            // "speak replies" moved into the ⋯ menu. What was left of the old row was a lone
            // muted-speaker glyph floating above the field with nothing to explain it.
            Hairline(color: Tokens.border)

            if let reply = model.replyTarget {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Replying to \(reply.author): \(reply.snippet.replacingOccurrences(of: "\n", with: " "))")
                        .font(TypeScale.font(TypeScale.caption))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button { model.clearReply() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel reply")
                }
                .foregroundStyle(Tokens.textMuted)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // What the host did with a message sent while the turn was running.
            if let notice = model.deliveryNotice {
                Text(notice)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.accentText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .transition(.opacity)
            }

            Composer(text: $model.draft,
                     placeholder: "Message \(title)",
                     isSending: model.isBusy,
                     isDisabled: sessionID == nil,
                     hasAttachments: !model.pendingAttachments.isEmpty,
                     micSystemImage: micGlyph,
                     micTint: voice.state == .recording ? Tokens.danger : nil,
                     micAccessibilityLabel: micLabel,
                     isMicEnabled: sessionID != nil,
                     onSend: { Task { await model.send() } },
                     onAttach: {
                         withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                             showAttachmentMenu.toggle()
                         }
                     },
                     onMic: { toggleRecording() },
                     onInterrupt: { Task { await model.interrupt() } })
                // The same gutter the bubbles stop at: a composer 4 pt wider on each side is what
                // made a chat look tilted against its own text.
                .padding(.horizontal, Geometry.chatGutter)
                .padding(.top, 8)
                .padding(.bottom, 8)
                // Anchored to the paperclip, above it: the card is an overlay, not a
                // presentation, so nothing here can be dismissed out from under it.
                .overlay(alignment: .topLeading) {
                    if showAttachmentMenu {
                        AttachmentMenu(onPick: pick)
                            .padding(.leading, 4)
                            .offset(y: -(AttachmentMenu.height + 10))
                            .transition(.scale(scale: 0.9, anchor: .bottomLeading)
                                .combined(with: .opacity))
                    }
                }
        }
        .background(Tokens.canvas)
    }

    /// Picked attachments wait here until the user sends, so cancelling the composer uploads nothing.
    private var pendingAttachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        if attachment.isImage {
                            AttachmentThumbnail(data: attachment.data, size: 26)
                        } else {
                            Image(systemName: "doc")
                                .font(.system(size: 11))
                        }
                        Text(attachment.name)
                            .font(TypeScale.font(TypeScale.sm))
                            .lineLimit(1)
                        Button {
                            model.removePendingAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Tokens.surface, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private func sendErrorBar(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.danger)

            Text(error)
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(2)

            Spacer(minLength: 8)

            TextButton("Retry", tone: Tokens.accentText) {
                Task { await model.send() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.dangerSoft)
    }

    // MARK: Endless session

    /// One thread per bot: resume the stored session, or let the model create and store a
    /// new one, then attach to it. The id comes from the model, never from a session list —
    /// and the model does the attaching (bot switch, resume, transcript) in one place, so
    /// there is no second resume here.
    private func openConversation() async {
        isOpening = true

        if let sid = await model.endlessSession(for: bot.id) {
            sessionID = sid
        } else {
            sessionID = nil
        }

        // Requests that were already open when this session was resumed belong in the
        // transcript, not in a sheet the user never asked for; only *arrivals* pop one.
        lastSeenRequestCount = model.pendingRequests.count
        hasLoaded = true
        isOpening = false
        openScrollSignal += 1
    }

    /// Scroll to the newest message over the next few frames.
    ///
    /// `ScrollViewProxy.scrollTo` is only as good as the layout it is called from: on the first
    /// frame after `resume`, a lazy transcript has built its first screenful, so the proxy scrolls
    /// to a bottom that then moves as the rest lays out — which is why opening a conversation
    /// started somewhere in the middle of its history.
    private func settleAtBottom(_ proxy: ScrollViewProxy) {
        scroll(proxy, animated: false)
        Task {
            for delay in [UInt64(80_000_000), 220_000_000, 480_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard !isDraggingTranscript else { return }
                scroll(proxy, animated: false)
            }
        }
    }

    /// Forget this bot's stored session and open a fresh one. The old session is left on
    /// the host — resetting is a phone-side decision about what to continue from.
    private func resetConversation() async {
        Haptics.impact()
        // Clears this bot's stored id and the thread on screen; the next open creates and
        // stores a new session, so the composer is disabled until that lands.
        model.resetEndlessSession(for: bot.id)
        sessionID = nil
        isOpening = true

        if let sid = await model.endlessSession(for: bot.id) {
            sessionID = sid
        }

        lastSeenRequestCount = model.pendingRequests.count
        isOpening = false
    }

    // MARK: Helpers

    private var noticeBinding: Binding<Bool> {
        Binding(get: { notice != nil },
                set: { presented in
                    if !presented { notice = nil }
                })
    }

    /// The microphone's glyph and label, from the voice controller's own state — the composer
    /// cannot know whether it is idle, listening or transcribing.
    private var micGlyph: String {
        switch voice.state {
        case .recording: return "stop.circle.fill"
        case .requestingPermission, .transcribing: return "waveform"
        default: return "mic"
        }
    }

    private var micLabel: String {
        switch voice.state {
        case .recording: return "Stop and transcribe"
        case .requestingPermission: return "Waiting for microphone permission"
        case .transcribing: return "Transcribing"
        default: return "Record a voice message"
        }
    }

    // MARK: Voice

    /// The reply the speaker toggle would repeat: the newest assistant row on screen.
    private var lastAssistantReply: TranscriptEntry? {
        model.transcript.last { $0.role == .assistant && !$0.text.isEmpty }
    }

    private func toggleRecording() {
        // Refresh first: the pairing may have changed since this screen appeared.
        voice.transport = app.makeVoiceTransport()
        if voice.state == .recording {
            voice.stopAndTranscribe(onTranscript: insertTranscript)
        } else {
            voice.startRecording()
        }
    }

    /// Put the transcript where the user can read it before it is sent: replace an empty
    /// draft, otherwise append as a new sentence. Sending stays a deliberate tap.
    private func insertTranscript(_ text: String) {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        let existing = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.draft = existing.isEmpty ? spoken : existing + " " + spoken
    }

    /// Speak a reply only when it is new and the toggle was already on. The same row is
    /// never spoken twice, and toggling on marks the current reply as seen.
    private func speakNewReplyIfNeeded() {
        guard speakReplies, voice.state == .idle else { return }
        guard let reply = lastAssistantReply,
              !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard reply.id != lastSpokenEntryID else { return }
        lastSpokenEntryID = reply.id
        voice.transport = app.makeVoiceTransport()
        voice.speak(reply.text)
    }

    /// Scroll after the keyboard's safe-area animation has settled, not when focus first
    /// changes (at that point the scroll view still has its old height). Frame changes also
    /// cover keyboard size changes and rotation; dismissal never pulls history to the bottom.
    private func keyboardFrameChanged(_ notification: Notification, proxy: ScrollViewProxy) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let screen = UIScreen.main.bounds
        let intersection = screen.intersection(frame)
        let height = !intersection.isNull && frame.maxY >= screen.maxY - 1
            ? intersection.height : 0
        let previousHeight = keyboardHeight
        let sizeChanged = keyboardScreenSize != .zero && keyboardScreenSize != screen.size
        keyboardScreenSize = screen.size
        guard abs(height - previousHeight) > 1 || sizeChanged else { return }
        keyboardHeight = height
        keyboardScrollTask?.cancel()
        // A shrinking keyboard reveals more history; do not fight interactive dismissal.
        guard !isSearching, height > 0, !isDraggingTranscript,
              height > previousHeight || sizeChanged else { return }

        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        keyboardScrollTask = Task { @MainActor in
            // Allow the keyboard animation and the following SwiftUI layout pass to finish.
            let delay = max(0, min(duration, 2)) + 0.05
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch { return }
            guard !Task.isCancelled, !isDraggingTranscript else { return }
            scroll(proxy, animated: false)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !isSearching, (!model.transcript.isEmpty || model.isStreaming) else { return }
        if animated {
            withAnimation(Motion.messageIn) {
                proxy.scrollTo(ConversationScreen.bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(ConversationScreen.bottomID, anchor: .bottom)
        }
    }

    /// Pull down only while the end was already on screen: a reader mid-history keeps their place
    /// and gets the button instead of being dragged back by every token.
    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard isAtBottom else { return }
        scroll(proxy, animated: animated)
    }

    @ViewBuilder
    private func scrollToBottomControl(_ proxy: ScrollViewProxy) -> some View {
        if !isAtBottom {
            Button {
                Haptics.impact()
                scroll(proxy, animated: true)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Tokens.control))
                    .overlay(Circle().strokeBorder(Tokens.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.bottom, 12)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .accessibilityIdentifier("conversationScrollToBottom")
            .accessibilityLabel("Scroll to latest message")
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Conversation") {
    let environment = AppEnvironment.preview()
    NavigationStack {
        ConversationScreen(model: environment.model, bot: Bot(id: "assistant", displayName: "Assistant"))
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}
#endif

#if DEBUG
#Preview("Conversation · streaming") {
    let environment = AppEnvironment.preview(scenario: .streaming)
    NavigationStack {
        ConversationScreen(model: environment.model, bot: Bot(id: "assistant", displayName: "Assistant"))
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}
#endif

#if DEBUG
#Preview("Conversation · approval arrives") {
    let environment = AppEnvironment.preview(scenario: .approval)
    NavigationStack {
        ConversationScreen(model: environment.model, bot: Bot(id: "assistant", displayName: "Assistant"))
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}
#endif


