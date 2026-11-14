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
    @State private var showWorkspace = false
    @State private var showSkills = false
    @State private var showMCP = false
    @State private var notice: String?
    @State private var lastSeenRequestCount = 0
    /// The prepend counter this screen has already reacted to (see the transcript's onChange).
    @State private var lastSeenEarlierLoads = 0
    @State private var hasLoaded = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardScreenSize: CGSize = .zero
    @State private var keyboardScrollTask: Task<Void, Never>?
    @State private var isDraggingTranscript = false
    /// The composer's measured height, so the transcript's last row can be scrolled clear of it.
    /// The capsule changes height with the field, and a guessed constant left the last message
    /// under the controls as soon as a second line was typed.
    @State private var composerHeight: CGFloat = 0

    /// The bot's swatch, from the shared face cache: your own bubbles are drawn in it, so the one
    /// place that says which bot you are talking to does not need a label.
    private var botTint: Color {
        (app.botFaces[bot.id] ?? BotFace.default(for: bot.id)).color.swatch
    }

    /// The conversation's verbs, as a page rather than the bar's ⋯ (see `ConversationDrawer`).
    @State private var showDrawer = false
    /// The transcript's own width, so "the trailing edge" is a measurement and not a guess.
    @State private var transcriptWidth: CGFloat = 0
    /// How far in from the right edge a drag counts as the drawer's rather than the transcript's.
    private static let drawerEdge: CGFloat = 28

    /// Whether the transcript's own end is on screen, and whether the reader still wants it there.
    ///
    /// Two facts, deliberately separate. `bottomDistance` is measured — how far the sentinel sits
    /// below the viewport — so it cannot be fooled by a lazy row being re-laid out. `followsStream`
    /// is intent: a reader who drags upward stops being followed until they come back to the end,
    /// which is why the transcript no longer yanks itself down while a bot is still writing.
    @State private var isAtBottom = true
    @State private var followsStream = true
    @State private var bottomDistance: CGFloat = .greatestFiniteMagnitude
    /// The scroll view's own height, needed to turn the sentinel's position into a distance.
    @State private var transcriptHeight: CGFloat = 0
    /// At most one coalesced scroll in flight: a token arriving while one is queued must not queue
    /// a second. That, not the scrolling itself, is what made the screen flicker.
    @State private var followTask: Task<Void, Never>?
    private static let scrollSpace = "conversation-scroll"

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
        .overlay(alignment: .top) { floatingTop }
        .overlay(alignment: .bottom) { floatingComposer }
        // The verbs, over the whole screen (composer included): a page, not a card.
        .overlay {
            if showDrawer {
                ConversationDrawer(
                    title: title,
                    subtitle: bot.description,
                    face: app.botFaces[bot.id] ?? BotFace.default(for: bot.id),
                    isCompressing: model.isCompressing,
                    hasAnyUnread: model.hasAnyUnread,
                    canSpeak: lastAssistantReply != nil,
                    speakReplies: speakReplies,
                    onComputer: { closeDrawer(); showComputer = true },
                    onWorkspace: { closeDrawer(); showWorkspace = true },
                    onSkills: { closeDrawer(); showSkills = true },
                    onMCP: { closeDrawer(); showMCP = true },
                    onSearch: { closeDrawer(); isSearching = true; searchFocused = true },
                    onSettings: { closeDrawer(); showBotSettings = true },
                    onCompact: { closeDrawer(); Task { await model.compressNow() } },
                    onMarkAllRead: { closeDrawer(); model.markAllRead() },
                    onSpeakChange: { enabled in
                        speakReplies = enabled
                        if !enabled { voice.stopSpeaking() }
                        // History is not replayed: mark what exists now.
                        if enabled { lastSpokenEntryID = lastAssistantReply?.id }
                    },
                    onReset: { closeDrawer(); showResetConfirm = true },
                    onClose: { closeDrawer() })
                    // Rises from the bottom: the page belongs to this chat, and one that slid in
                    // from the side read as a panel someone had pushed into it.
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
        }
        // The pill and the composer, floating over the transcript rather than framing it.

        .animation(Motion.messageIn, value: showDrawer)
        // No navigation bar: it drew an opaque band over the top of the transcript, and the pill
        // that says which bot this is had to live inside it. Both are the desktop's arrangement
        // now — the transcript runs the full height of the screen and the chrome floats over it.
        .toolbar(.hidden, for: .navigationBar)
        // The bar went; the swipe back is not allowed to go with it.
        .restoresSwipeBack()
        .background(Tokens.canvas)
        // The wire's own notice, when it has one: a socket that dropped mid-turn still has to say
        // so, and it went out with the chrome that used to carry it.
        .mobileConnectionBanner(connection: app.visibleConnection,
                                turnRunning: model.isStreaming,
                                host: app.hostLabel,
                                retry: { Task { await app.reconnect() } })
        // A card in this conversation: the phone already holds the pairing, so the resolver is one
        // call, and a card's button comes back as a notification.
        .environment(\.genUICards, app.genUICards(for: bot.id))
        .onReceive(NotificationCenter.default.publisher(for: .genUICardSend)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            model.draft = text
            Task { await model.send() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .genUICardFill)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            model.draft = text
        }
        .onAppear { model.setVisibleBot(bot.id) }
        .onDisappear { model.setVisibleBot(nil) }
        .task(id: bot.id) {
            voice.transport = app.makeVoiceTransport()
            await openConversation()
        }
        // Another chat's unread is this screen's badge, so the rooms are swept while the
        // conversation is open instead of waiting for the list to reappear. The *bots* are not
        // swept here: `AppModel` runs one clock for those (`unreadSweepInterval`) and a second
        // loop in this view meant every open chat polled the host twice as often as the model
        // asked for — which is how an innocent-looking `.task` becomes battery.
        .task {
            while !Task.isCancelled {
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
        .sheet(isPresented: $showWorkspace) {
            WorkspaceSheet(bot: bot, client: app.workspace)
        }
        .sheet(isPresented: $showSkills) {
            BotToolsSheet(bot: bot, kind: .skills, model: model)
        }
        .sheet(isPresented: $showMCP) {
            BotToolsSheet(bot: bot, kind: .mcp, model: model)
        }
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
                icon: app.botFaces[bot.id],
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

    // MARK: - Floating chrome

    /// The pill, over the transcript: the bot's face, its name, and the drawer's door.
    ///
    /// The desktop's arrangement, ported: the pill is the control, so there is no ⋯ beside it and
    /// no title bar above it. A chevron sits to its left because a phone needs a way back and the
    /// bar that carried one is gone.
    private var floatingTop: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Haptics.selection()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .frame(width: 44, height: 44)
                        .hermeyGlass(Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the bots")

                Spacer(minLength: 0)

                pill

                Spacer(minLength: 0)

                // A mirror of the chevron's width, so the pill is centred on the screen rather
                // than on the space the chevron left over.
                Color.clear.frame(width: 44, height: 44)
            }

            if isSearching {
                searchBar
            }

            // Only the two facts that are asking to be acted on. The model, the context count and
            // the latency live in the drawer now: a strip of chips under a floating pill is a bar
            // with a pill on top of it, which is the thing this replaces.
            if unreadElsewhere > 0 || model.isCompressing {
                HStack(spacing: 6) {
                    if unreadElsewhere > 0 {
                        Button {
                            dismiss()
                        } label: {
                            StatusChip("\(unreadElsewhere) unread", tone: .success,
                                       showsDot: true, size: .small)
                        }
                        .buttonStyle(.plain)
                    }
                    if model.isCompressing {
                        StatusChip("compacting…", tone: .neutral, showsProgress: true, size: .small)
                            .accessibilityIdentifier("compactingChip")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    /// The pill itself: the whole capsule opens the verbs, which is what the ⋯ used to do.
    private var pill: some View {
        Button {
            Haptics.impact()
            withAnimation(.easeOut(duration: 0.2)) { showDrawer.toggle() }
        } label: {
            HStack(spacing: 7) {
                BotIconPortrait(app.botFaces[bot.id] ?? BotFace.default(for: bot.id),
                                size: 32,
                                status: portraitStatus)
                Text(title)
                    .font(TypeScale.font(Tokens.chatHeaderTitle, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 5)
            .padding(.trailing, 14)
            .frame(height: 52)
            .hermeyGlass(Capsule(), interactive: true)
            .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), chat actions")
        .accessibilityIdentifier("chatDrawerButton")
    }

    /// What the face says, the same precedence the desktop uses.
    private var portraitStatus: PortraitStatus? {
        if model.hasPendingRequests { return .needsYou }
        if model.isCompressing { return .compacting }
        if model.isStreaming { return .working }
        return nil
    }

    /// The composer over the transcript, measured: the last row scrolls clear of whatever height
    /// the field has grown to, and the transcript's fade sits under it.
    private var floatingComposer: some View {
        composerArea
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { composerHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in composerHeight = height }
                }
            )
            // No slab behind it: an opaque gradient under a glass capsule is the one thing that
            // stops the glass from being glass. The transcript's own mask does the fading — from
            // the composer's height up — so the words dissolve and the capsule refracts what is
            // left of them.
            .padding(.bottom, 2)
    }

    // The status strip is gone: the pill carries the bot and its state, and the drawer carries
    // the host's own facts. What is left of it is the two chips in `floatingTop`.

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
                    // The pill sits over this: a fresh transcript starts below it, and a long one
                    // scrolls behind it.
                    .padding(.top, 74)
                    .padding(.bottom, 20)
            }
            // The sentinel reports its position in this space; without a name there is nothing to
            // measure against and the bottom has to be inferred from `onAppear`, which lies during
            // streaming.
            .coordinateSpace(name: Self.scrollSpace)
            .background(GeometryReader { geo in
                Color.clear
                    // Width as well as height: the drawer's gesture is defined as "a drag that
                    // starts within 28 pt of the trailing edge", which needs the edge measured.
                    .onAppear {
                        transcriptHeight = geo.size.height
                        transcriptWidth = geo.size.width
                    }
                    .onChange(of: geo.size.height) { _, height in transcriptHeight = height }
                    .onChange(of: geo.size.width) { _, width in transcriptWidth = width }
            })
            .scrollDismissesKeyboard(.interactively)
            // Text leaves the screen instead of being cut by it: a mask on the transcript itself,
            // not a gradient laid over it, so nothing is painted on top of the words — they fade
            // out. The chrome is drawn above this and stays crisp.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 96)
                    Rectangle().fill(Color.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 44)
                    // Behind the capsule the transcript stays at full strength on purpose: glass
                    // refracts what is under it, and a fade that reached this far left it with
                    // nothing but canvas to refract — which reads as a black box, not as glass.
                    Rectangle().fill(Color.black)
                        .frame(height: composerHeight + 12)
                }
            )
            // The way back to the newest message, on the same rule as the desktop's: it appears
            // only while the transcript's end is off screen.
            // The fade belongs to the button alone. Animating the scroll view is what made a
            // streaming reply shimmer: every token's layout pass went through the animation.
            .overlay(alignment: .bottom) {
                scrollToBottomControl(proxy)
                    .animation(.easeOut(duration: 0.18), value: isAtBottom)
            }

            // A swipe in from the trailing edge belongs to the drawer. It is a *second* gesture on
            // the same view, so vertical scrolling is untouched: only a mostly-horizontal drag that
            // started inside the edge band is taken.
            .simultaneousGesture(DragGesture(minimumDistance: 14)
                .onEnded { value in
                    guard isDrawerSwipe(value) else { return }
                    Haptics.impact()
                    showDrawer = true
                })
            .simultaneousGesture(DragGesture(minimumDistance: 5)
                .onChanged { value in
                    // The edge swipe must not be read as the reader parking the transcript.
                    guard !isDrawerSwipe(value) else { return }
                    isDraggingTranscript = true
                    keyboardScrollTask?.cancel()
                    // Dragging is the reader saying where they want to look. A finger on the
                    // transcript outranks a bot that is still writing.
                    followTask?.cancel()
                    followsStream = false
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
            .onChange(of: model.transcriptReloads) {
                // A foreground re-reads the transcript. The rows are replaced in place, so the scroll
                // view keeps the offset it had — which is what put the reader in the middle of the
                // chat after minimizing the app. Newest message, same rule as opening it.
                followsStream = true
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
            // Streaming changes faster than the screen refreshes. Each of these used to call
            // `scrollTo` directly, so a reply arriving at 40 tokens a second asked the transcript to
            // re-lay itself out 40 times a second — the flicker — and any drag was overridden by the
            // next token. `followStreaming` queues one scroll at a time instead.
            .onChange(of: model.streamingText) {
                followStreaming(proxy)
            }
            .onChange(of: model.liveTools.count) {
                followStreaming(proxy)
            }
            .onChange(of: model.reasoningText) {
                followStreaming(proxy)
            }
            .onPreferenceChange(BottomDistanceKey.self) { distance in
                // Before the first layout pass the key holds its default; a sentinel nobody has
                // measured is not evidence that the reader is somewhere else.
                guard distance.isFinite else { return }
                bottomDistance = distance
                guard !isDraggingTranscript else { return }
                let atEnd = distance <= Self.bottomSlack
                if atEnd != isAtBottom {
                    isAtBottom = atEnd
                    followsStream = atEnd
                }
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

            // Consecutive tool calls fold into one line, the same way they do on the Mac: a turn
            // that makes thirty calls should not fill the screen with thirty cards.
            ForEach(TranscriptGrouping.rows(model.visibleTranscript + model.visibleLiveToolEntries,
                                            running: runningToolIDs)) { row in
                switch row {
                case .entry(let entry):
                    MobileTranscriptRow(entry: entry, botTint: botTint)
                        .overlay {
                            if selectedSearchID == entry.id {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Tokens.accentText, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                        .id(entry.id)
                case .toolRun(let run):
                    ToolRunGroup(run: run) { entry in
                        MobileTranscriptRow(entry: entry, botTint: botTint, running: runningToolIDs)
                    }
                    .id(run.id)
                }
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

            // The running calls are already in the grouped rows above (`visibleLiveToolEntries`), so
            // a second list of them here would draw every card twice.

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

                // Half the composer's height, not all of it: the last message's tail runs under
                // the capsule, which is what gives the glass something to refract at rest instead
                // of a strip of empty canvas. It is measured, not guessed — the field grows.
                Color.clear
                    .frame(height: composerHeight * 0.5 + 8)
                // Reports where the end of the transcript is, in the scroll view's own space, on
                // every layout pass — including the ones a growing reply causes. Reading a position
                // is honest; watching a lazy row appear and disappear is not.
                .background(GeometryReader { geo in
                    Color.clear.preference(
                        key: BottomDistanceKey.self,
                        value: geo.frame(in: .named(ConversationScreen.scrollSpace)).minY - transcriptHeight)
                })
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
    /// The calls of the turn that has not finished, so a card inside a run can say it is still going.
    private var runningToolIDs: Set<String> {
        Set(model.visibleLiveToolEntries.map(\.id))
    }

    // MARK: Header controls

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

            // Nothing sits above the field, and no hairline either: the composer floats, and a
            // full-width rule under a floating capsule re-draws the bar it was meant to replace.

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
                     // Floating, like the desktop's: the field is a capsule over the transcript,
                     // not a bordered box standing on the floor of a bar.
                     floats: true,
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

    private func closeDrawer() {
        showDrawer = false
    }

    /// The drawer's gesture: in from the trailing edge, leftwards, and more horizontal than vertical
    /// (a diagonal scroll toward the bot list must not open a panel).
    private func isDrawerSwipe(_ value: DragGesture.Value) -> Bool {
        guard transcriptWidth > 0 else { return false }
        return value.translation.width < -24
            && abs(value.translation.width) > abs(value.translation.height)
            && value.startLocation.x > transcriptWidth - Self.drawerEdge
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

    /// The transcript is "at the bottom" when its end is this close to the bottom of the viewport.
    /// A slack of one line, so a reader sitting on the last message is not asked to chase it.
    /// How close to the end counts as "at the end". Tight on purpose: the jump control is meant to
    /// appear as soon as there is anything below the fold, and 24 pt of slack read as the chat being
    /// at the bottom while a line and a half were still hidden.
    private static let bottomSlack: CGFloat = 6

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
        guard followsStream, !isDraggingTranscript else { return }
        scroll(proxy, animated: animated)
    }

    /// One queued scroll at a time for a stream that changes hundreds of times a second.
    ///
    /// Coalescing matters twice over: it stops the transcript re-laying itself out per token (the
    /// flicker), and it means a drag started mid-token wins, because the queued scroll re-checks
    /// intent when it runs rather than when it was asked for.
    private func followStreaming(_ proxy: ScrollViewProxy) {
        guard followsStream, !isDraggingTranscript, followTask == nil else { return }
        followTask = Task { @MainActor in
            defer { followTask = nil }
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, followsStream, !isDraggingTranscript else { return }
            // Already there: a scroll that lands where the view sits is not free, it is a layout.
            guard bottomDistance > 2 else { return }
            scroll(proxy, animated: false)
        }
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
                    .frame(width: 38, height: 38)
                    .hermeyGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Centred, and centred *by the layout* rather than by a padding that happens to look
            // right on one screen width.
            .frame(maxWidth: .infinity)
            // Above the composer, not behind it: the composer floats, and a control pinned to the
            // floor sits under the capsule that is hiding the very rows it would take you to.
            .padding(.bottom, composerHeight + 12)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .accessibilityIdentifier("conversationScrollToBottom")
            .accessibilityLabel("Scroll to latest message")
        }
    }
}

/// How far the end of the transcript sits below the bottom of the viewport. Negative means it is on
/// screen; the smallest reported value wins, because a `LazyVStack` can report several.
private struct BottomDistanceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
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


