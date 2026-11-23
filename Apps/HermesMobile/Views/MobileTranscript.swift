import SwiftUI
import AVFoundation
import UIKit
import HermesKit
import HermesRender
import HermeyUI
import HermesA2UI
import HermesCards

/// One row of the conversation.
///
/// The shapes are three: the user's message is a right-aligned tinted bubble,
/// the assistant is plain body text on the canvas (no bubble — a long answer in a bubble
/// is a wall inside a wall), and a tool result keeps the card the design system already
/// has. Markers come from the block layer so a list looks the same everywhere.
/// `.sheet(item:)` needs an identity; the peer's profile id is the identity.
struct PeerRef: Identifiable {
    let id: String
}

struct MobileTranscriptRow: View {
    let entry: TranscriptEntry
    /// The bot's swatch, for the user's own bubble. Passed in: a row inside a lazy stack must not
    /// reach for a model, and the screen already knows whose conversation this is.
    var botTint: Color = Tokens.accentSoft
    /// Calls that have not finished. Inside a folded run the group says it once; the card still
    /// shows its own state, so a call that is still going does not look like one that is done.
    var running: Set<String> = []
    @EnvironmentObject private var app: AppEnvironment
    @State private var showingSelection = false
    /// Pictures fetched back from the host, by attachment name.
    @State private var fetchedImages: [String: Data] = [:]
    /// The pictures the viewer is showing, if any.
    @State private var viewingImage: ViewedGallery?
    /// This row's markdown, parsed once per text rather than once per body pass.
    ///
    /// A body pass happens every time the model publishes — every 40 ms while a turn streams — and
    /// parsing every visible row's markdown on each of those was the single most expensive thing the
    /// phone did while reading a conversation (the jitter reported 2026-11-14).
    @State private var markdownCache = RowMarkdownCache()
    /// What the card markers in this row resolved to, keyed by card id.
    ///
    /// The shared `CardLoader` is the fetch-once cache; this is the copy the row repaints from,
    /// because a row inside a lazy stack is torn down long before the cache is.
    @State private var cardStates: [String: CardLoader.State] = [:]
    /// The bot whose conversation this row is in — the near side of a bot-to-bot exchange.
    var botID: String = ""
    /// The other bot, when the pair sheet is open.
    @State private var pairPeer: String?

    /// Every picture this message carries, and which one was tapped — `ImageViewer` pages through
    /// the rest, so a message with three photographs no longer means closing and reopening.
    struct ViewedGallery: Identifiable {
        let id = UUID()
        let items: [ImageViewer.Item]
        let startIndex: Int
    }
    /// The compact action card, raised by a long press on a message.
    @State private var showingActions = false
    /// Where this row sits on screen, so the card can open on the side that has room.
    @State private var rowFrame: CGRect = .zero
    /// The row's size, needed to turn a touch into a unit point.
    @State private var rowSize: CGSize = .zero
    /// True when the card must open *above* the message.
    ///
    /// A word-processor's worth of text sits under a long press at the bottom of the screen: with the
    /// card always opening below, iOS had nowhere to put it and clipped the top of the content — the
    /// six reactions vanished and only slivers of colour showed. The side is decided before the
    /// popover is asked for, from the row's own frame.
    @State private var opensAbove = false
    private static let speaker = AVSpeechSynthesizer()

    /// This message's identity for a reaction, from the one rule both apps share (`ReactionKey`).
    /// `nil` when no conversation is open: there is nothing to key a reaction by.
    private var reactionKey: ReactionKey? {
        guard let session = app.model.selectedSessionID else { return nil }
        // `app.model.hostName` rather than `app.hostLabel`: the key has to be the one `AppModel`
        // built its map with, byte for byte, or the lookup misses. (They are the same string — both
        // come from the pairing — but the model owns the rule, so it is the one asked.)
        //
        // A live message may have no durable history row yet; `ReactionKey.message` allows a
        // temporary reaction too, and it persists across reloads once the host gives the row an id.
        return ReactionKey(host: app.model.hostName,
                           bot: app.model.selectedBotID ?? "",
                           session: session,
                           message: ReactionKey.message(rowID: entry.rowID, entryID: entry.id))
    }

    /// The emoji this message wears, from the conversation's shared state — the host's copy when
    /// paired, so a reaction set on the Mac is already here.
    private var currentReaction: String? {
        guard let key = reactionKey else { return nil }
        return app.model.reaction(for: key)
    }

    /// One emoji per message: tapping the one already there removes it.
    private func setReaction(_ emoji: String) {
        guard let key = reactionKey else { return }
        let next: String? = currentReaction == emoji ? nil : emoji
        Task { await app.model.setReaction(next, for: key) }
    }

    var body: some View {
        VStack(alignment: entry.role == .user ? .trailing : .leading, spacing: 4) {
            rowContent
            if let emoji = currentReaction {
                Button(emoji) { setReaction(emoji) }
                    .accessibilityLabel("Remove \(ReactionEmoji.name(emoji)) reaction")
            }
        }
        // A long press raises one small card: the six reactions on top, the verbs under them.
        // The system menu it replaces was taller than the message it was about, and it hid the
        // emoji behind a second menu ("Add reaction").
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: RowFrameKey.self, value: geo.frame(in: .global))
                    .onAppear { rowSize = geo.size }
                    .onChange(of: geo.size) { _, size in rowSize = size }
            }
        )
        .onPreferenceChange(RowFrameKey.self) { rowFrame = $0 }
        .popover(isPresented: $showingActions,
                 attachmentAnchor: .point(anchorPoint),
                 arrowEdge: opensAbove ? .bottom : .top) {
            actionCard
                .presentationCompactAdaptation(.popover)
        }
        // The viewer fills the screen: a picture at 132 pt is a preview, not the picture.
        .fullScreenCover(item: $viewingImage) { gallery in
            ImageViewer(items: gallery.items,
                        startIndex: gallery.startIndex,
                        canExport: false) { viewingImage = nil }
                .preferredColorScheme(.dark)
            .hermesSheetChrome()
        }
        .sheet(item: Binding(get: { pairPeer.map(PeerRef.init) },
                             set: { pairPeer = $0?.id })) { peer in
            BotPairSheet(current: botID, peer: peer.id,
                         faces: app.botFaces,
                         displayName: { profile in
                             app.model.bots.first { $0.id == profile }?.displayName
                                 ?? profile.capitalized
                         },
                         load: { await app.model.transfers(between: botID, and: peer.id) })
            .hermesSheetChrome()
        }
        .sheet(isPresented: $showingSelection) {
            NavigationStack {
                ScrollView {
                    MobileSelectableText(attributed: MobileProse.plain(entry.text), allowsSelection: true)
                        .padding()
                }
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSelection = false } } }
            }
            .hermesSheetChrome()
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        if entry.role == .user || entry.role == .assistant {
            content
        } else {
            content.contextMenu { menu }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.role {
        case .user:
            // A message another bot wrote lands here as a user row, because it is one: it arrived in
            // this bot's conversation. It is not the owner's, though, so it is drawn with the sender's
            // face and name instead of as a bubble the owner typed (asked for 2026-11-15).
            if let label = BotMessageLabel.parse(entry.text) {
                botMessageRow(label)
            } else {
                userBubble
            }
        case .assistant:
            assistant
        case .tool:
            toolResult
        case .reasoning:
            MobileReasoningBlock(text: entry.text, standaloneMenu: false)
        case .system:
            systemNote
        }
    }

    /// `Message from <face> Cody` above the words — the recipient's side of a bot-to-bot exchange.
    @ViewBuilder
    private func botMessageRow(_ label: BotMessageLabel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The attribution is the door to the exchange itself: tapping it opens the record of
            // what these two bots said to each other (asked for 2026-11-15).
            Button {
                pairPeer = label.senderProfile
            } label: {
                HStack(spacing: 6) {
                    if let profile = label.senderProfile {
                        BotAvatarView(identity: profile,
                                      color: app.botFaces[profile]?.raw,
                                      activity: app.model.activity(forBot: profile),
                                      size: Geometry.rosterAvatarCompact)
                    }
                    Text(label.headerTitle)
                        .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                        .foregroundStyle(Tokens.accentText)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Tokens.textDim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(label.senderProfile == nil)
            .accessibilityLabel("\(label.headerTitle). Show the conversation between these two bots.")

            // Markdown, not a plain `Text`: a bot writes to another bot exactly as it writes to the
            // owner — lists, bold, code fences — and the recipient's side used to show the source
            // (`**bold**`, `- item`) instead of the rendering. Reported 2026-11-16.
            MobileMarkdownText(blocks: IncrementalMarkdown.parse(markdownCache.sanitized(label.body)), rawText: label.body)
                .foregroundStyle(Tokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Geometry.bubblePaddingH)
                .padding(.vertical, Geometry.bubblePaddingV)
                .background(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                    .fill(Tokens.surface))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var menu: some View {
        if entry.role == .user || entry.role == .assistant {
            Button { showingSelection = true } label: {
                Label("Select Text", systemImage: "text.cursor")
            }
            Button {
                Self.speaker.stopSpeaking(at: .immediate)
                Self.speaker.speak(AVSpeechUtterance(string: entry.text))
            } label: {
                Label("Read Aloud", systemImage: "speaker.wave.2")
            }
            Button { app.model.reply(to: entry) } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        }
        ShareLink(item: entry.text) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button {
            UIPasteboard.general.string = entry.text
            Haptics.success()
        } label: {
            Label("Copy message", systemImage: "doc.on.doc")
        }

        if let code = Self.firstCodeBlock(in: entry.text) {
            Button {
                UIPasteboard.general.string = code
                Haptics.success()
            } label: {
                Label("Copy code block", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
    }

    // MARK: Action card

    /// Where the card's arrow points: the middle of the part of this message you can actually see.
    ///
    /// Anchoring to the row's whole rectangle is right for a one-line bubble and wrong for a long
    /// message — that rectangle can start above the header and end under the composer, so "above the
    /// row" means the top of the page. Measuring the *visible* slice keeps the card beside the text
    /// the reader is looking at, and it needs no gesture: a `DragGesture` on every row competed with
    /// the scroll view for each touch and stopped the chat scrolling altogether.
    private func visibleAnchorY() -> CGFloat {
        guard rowSize.height > 0, rowFrame.height > 0 else { return 0.5 }
        let screen = UIScreen.main.bounds.height
        let visibleTop = max(rowFrame.minY, 96)
        let visibleBottom = min(rowFrame.maxY, screen - 150)
        let middle = (visibleTop + visibleBottom) / 2
        let unit = (middle - rowFrame.minY) / rowSize.height
        return min(max(unit, 0.02), 0.98)
    }

    private var anchorPoint: UnitPoint { UnitPoint(x: 0.5, y: visibleAnchorY()) }

    /// Open the card on whichever side has room for it.
    private func raiseActions() {
        // The card is ~250 pt tall; it opens above the visible slice when there is less room than
        // that below it, and below the slice otherwise.
        let screen = UIScreen.main.bounds
        let anchorY = rowFrame.minY + visibleAnchorY() * rowSize.height
        let spaceBelow = screen.height - anchorY
        let spaceAbove = anchorY
        opensAbove = spaceBelow < 250 && spaceAbove > spaceBelow
        Haptics.selection()
        showingActions = true
    }

    /// The card a long press raises: six reactions, then four rows, then share.
    ///
    /// Small on purpose. The system menu it replaces drew a full-height icon list for six verbs and
    /// put the reactions behind another menu, so a person who wanted to react pressed two things and
    /// read a menu taller than the message. Here the emoji are the first thing under the thumb and
    /// every verb is one 32 pt row.
    private var actionCard: some View {
        VStack(spacing: 0) {
            if reactionKey != nil {
                QuickReactionRow(selected: currentReaction) { emoji in
                    setReaction(emoji)
                    Haptics.selection()
                    showingActions = false
                }
                .padding(.horizontal, 5)

                Rectangle()
                    .fill(Tokens.borderStrong)
                    .frame(height: 1)
                    .padding(.top, 2)
            }

            actionRow("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = entry.text
                Haptics.success()
                showingActions = false
            }
            actionRow("Reply", systemImage: "arrowshape.turn.up.left") {
                showingActions = false
                app.model.reply(to: entry)
            }
            actionRow("Select", systemImage: "text.cursor") {
                showingActions = false
                showingSelection = true
            }
            actionRow(Self.speaker.isSpeaking ? "Stop" : "Read",
                      systemImage: Self.speaker.isSpeaking ? "stop.fill" : "speaker.wave.2") {
                if Self.speaker.isSpeaking {
                    Self.speaker.stopSpeaking(at: .immediate)
                } else {
                    Self.speaker.speak(AVSpeechUtterance(string: entry.text))
                }
                showingActions = false
            }
            if let code = Self.firstCodeBlock(in: entry.text) {
                actionRow("Copy code", systemImage: "chevron.left.forwardslash.chevron.right") {
                    UIPasteboard.general.string = code
                    Haptics.success()
                    showingActions = false
                }
            }

            Rectangle()
                .fill(Tokens.borderStrong)
                .frame(height: 1)

            ShareLink(item: entry.text) {
                HStack(spacing: 9) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Tokens.textMuted)
                        .frame(width: 16)
                    Text("Share")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .frame(width: 232)
    }

    private func actionRow(_ title: String,
                           systemImage: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.textMuted)
                    .frame(width: 16)
                Text(title)
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// The first fenced block, so a long answer with code does not force a whole-message copy.
    static func firstCodeBlock(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") })
        else { return nil }
        let body = lines[(open + 1)...]
        guard let close = body.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") })
        else { return nil }
        let code = lines[(open + 1)..<close].joined(separator: "\n")
        return code.isEmpty ? nil : code
    }

    // MARK: User

    private var userBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 6) {
                // What was sent with the words: pictures as pictures, files as chips. Without this
                // the chat looked like the attachment had never gone anywhere.
                // Pictures the row's own memory holds, or — after a relaunch — the references the
                // host stored, looked up in the image cache by the name it quotes.
                if !bubbleAttachments.isEmpty {
                    sentAttachments
                }
                // An attachment-only send has no sentence left once the references are stripped:
                // the pictures and the clock are the whole bubble.
                if !entry.displayText.isEmpty { bubbleText }
                messageTime
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Everything the bubble should draw for this message.
    private var bubbleAttachments: [SentAttachment] {
        entry.attachments.isEmpty ? entry.referenceAttachments : entry.attachments
    }

    /// Thumbnails arrive with the message, in the order they were attached.
    private var sentAttachments: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(bubbleAttachments.filter { $0.isImage }) { attachment in
                if let data = attachment.imageData ?? fetchedImages[attachment.name] {
                    // A tap on a picture opens it: the thumbnail promises the full image is here.
                    // The whole message's pictures go with it, so the viewer can page.
                    Button {
                        openImage(attachment)
                    } label: {
                        AttachmentThumbnail(data: data, size: 132)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                            )
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Tokens.textSecondary)
                                    .padding(4)
                                    .background(Tokens.canvas.opacity(0.7), in: Circle())
                                    .padding(6)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Attached image \(attachment.name)")
                    .accessibilityHint("Opens the image")
                } else {
                    // The host holds the picture; ask for it once per bubble. Until it arrives —
                    // or if this device cannot reach the host — the file is named, not invented.
                    attachmentChip(attachment.name)
                        .task(id: attachment.name) { await fetchImage(attachment.name) }
                }
            }
            ForEach(bubbleAttachments.filter { !$0.isImage }) { attachment in
                attachmentChip(attachment.name)
            }
        }
    }

    /// Every picture of this message that has bytes on the device, in attachment order.
    ///
    /// What is missing is being fetched from the host: a picture with no bytes is a chip, not a
    /// thumbnail, so it is not in the gallery either — the pages are only the pictures that are here.
    private var viewableImages: [(attachment: SentAttachment, data: Data)] {
        bubbleAttachments
            .filter { $0.isImage }
            .compactMap { attachment in
                guard let data = attachment.imageData ?? fetchedImages[attachment.name] else { return nil }
                return (attachment: attachment, data: data)
            }
    }

    /// Open the viewer on this picture, with its neighbours behind it.
    private func openImage(_ attachment: SentAttachment) {
        let pictures = viewableImages
        let start = pictures.firstIndex { $0.attachment.id == attachment.id } ?? 0
        viewingImage = ViewedGallery(items: pictures.map { ImageViewer.Item(data: $0.data, name: $0.attachment.name) },
                                     startIndex: start)
    }

    /// One file named, for a bubble that has no picture to draw.
    private func attachmentChip(_ name: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "doc")
                .font(.system(size: 10))
            Text(name)
                .font(TypeScale.font(TypeScale.sm))
                .lineLimit(1)
        }
        .foregroundStyle(Tokens.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Tokens.surface, in: Capsule())
    }

    /// Bytes fetched from the host, by attachment name — one dictionary per bubble.
    private func fetchImage(_ name: String) async {
        guard fetchedImages[name] == nil else { return }
        guard let profile = app.model.selectedBotID else { return }
        if let data = await app.attachmentImage(named: name, profile: profile) {
            fetchedImages[name] = data
        }
    }

    private var bubbleText: some View {
        HStack(alignment: .bottom, spacing: 8) {
            MobileSelectableText(attributed: MobileProse.plain(entry.displayText,
                                                               color: Tokens.textPrimary,
                                                               size: TypeScale.chatBody))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Geometry.bubblePaddingH)
                .padding(.vertical, Geometry.bubblePaddingV)
                // The bot's own colour: the phone shows one conversation at a time, but the
                // bubble is the one place that says which bot it is without a name on screen.
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusBubble, style: .continuous)
                        .fill(botTint.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusBubble, style: .continuous)
                        .strokeBorder(botTint.opacity(0.45), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusBubble, style: .continuous))
                .onLongPressGesture(minimumDuration: 0.35) { raiseActions() }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Assistant

    /// Every A2UI surface this reply carries, in order.
    private var surfacePayloads: [A2UISurfacePayload] { A2UIMarker.surfaces(in: entry.text) }

    /// Every native card marker this reply carries, and the prose with those lines taken out.
    ///
    /// Parsed before the genui check below on purpose: a reply carries a card, a `::blocks` board
    /// or neither, and only the card path knows which of its own lines to strip.
    private var cardScan: CardScan { CardMarker.scan(entry.text) }

    /// `cards.enabled`, read per body pass. Off is today's behaviour: the marker line stays text,
    /// nothing is stripped and nothing is fetched.
    private var cardsEnabled: Bool { CardsSettings.isEnabled }

    /// Whether this row can actually draw: the flag on, and a session to resolve the files in.
    private var cardsActive: Bool { cardsEnabled && !(app.model.selectedSessionID ?? "").isEmpty }

    /// The app's palette for the card renderer, mapped here because `HermesCards` must not import
    /// `HermeyUI` — the values travel in, never the module.
    private var cardTheme: CardTheme {
        CardTheme(canvas: Tokens.canvas,
                  surface: Tokens.surface,
                  ink: Tokens.textPrimary,
                  mutedInk: Tokens.textMuted,
                  accent: Tokens.accent,
                  accentInk: Tokens.textPrimary,
                  danger: Tokens.danger,
                  border: Tokens.border,
                  radiusCard: Tokens.radiusCard,
                  radiusControl: Tokens.radiusControl)
    }

    /// Changes when the cards (or their session) do, so the reads are asked for once the markers
    /// exist. Never a timer: P1 does not poll.
    private var cardTaskKey: String {
        guard cardsActive else { return "" }
        let session = app.model.selectedSessionID ?? ""
        return ([session] + cardScan.refs.map(\.id)).joined(separator: "\u{1F}")
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 2) {
            // An A2UI surface arrives as one `::a2ui{…}` line: the compiled, validated wire JSON
            // the plugin produced. The prose around it is the reply; the surfaces are drawn in its
            // place, in order. Turning `a2ui.surfaces.disabled` on falls through to `::blocks`.
            if A2UISurfaceSettings.isEnabled, !surfacePayloads.isEmpty {
                let prose = A2UIMarker.textWithoutMarkers(entry.text)
                if !prose.isEmpty {
                    MobileMarkdownText(blocks: markdownCache.parse(markdownCache.sanitized(prose)), rawText: prose)
                        .accessibilityLabel(prose)
                        .padding(.vertical, 4)
                }
                // Every surface, not just the first: dropping the rest made their cards vanish.
                ForEach(Array(surfacePayloads.enumerated()), id: \.offset) { _, payload in
                    A2UISurfaceView(payload: payload)
                        .padding(.vertical, 2)
                }
            } else if cardsActive, !cardScan.refs.isEmpty {
                // A `::card{…}` line is a reference, not prose: the line goes, the card draws under
                // the words, and a card that cannot be read says so without touching the prose.
                cardBubble(cardScan)
            } else if let boardID = GenUITag.boardID(in: entry.text) {
                // A `::blocks{id="…"}` line is a directive, not prose: the plugin's board is drawn in
                // its place, and the tag itself never appears in the transcript.
                let prose = GenUITag.textWithoutTags(entry.text)
                if !prose.isEmpty {
                    MobileMarkdownText(blocks: markdownCache.parse(markdownCache.sanitized(prose)), rawText: prose)
                        .accessibilityLabel(prose)
                        .padding(.vertical, 4)
                }
                GenUICard(blockID: boardID)
                    .padding(.vertical, 2)
            } else {
                MobileMarkdownText(blocks: markdownCache.parse(markdownCache.sanitized(entry.text)), rawText: entry.text)
                    .accessibilityLabel(entry.text)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.35) { raiseActions() }
            }
            messageTime
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: cardTaskKey) { await loadCards() }
    }

    // MARK: Native cards

    /// The reply's prose, then one card per marker, in the order they appear.
    @ViewBuilder
    private func cardBubble(_ scan: CardScan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !scan.prose.isEmpty {
                MobileMarkdownText(blocks: markdownCache.parse(markdownCache.sanitized(scan.prose)), rawText: scan.prose)
                    .accessibilityLabel(scan.prose)
                    .padding(.vertical, 4)
            }
            // Offsets, not refs: two identical markers are still two cards.
            ForEach(Array(scan.refs.enumerated()), id: \.offset) { _, ref in
                cardView(ref)
            }
        }
    }

    @ViewBuilder
    private func cardView(_ ref: CardRef) -> some View {
        switch cardStates[ref.id] ?? .idle {
        case .loaded(let model):
            CardView(model: model, theme: cardTheme) { action in
                choose(action, ref: ref)
            }
            .padding(.vertical, 2)
        case .unavailable:
            CardView(model: .unavailable(CardModel.unavailableMessage), theme: cardTheme)
                .padding(.vertical, 2)
        case .idle, .loading:
            // Nothing while the read is in the air: the prose above is already the whole message,
            // and a flash of "Card not available" is a lie about a card that is on its way.
            EmptyView()
        }
    }

    private func loadCards() async {
        guard cardsActive, let session = app.model.selectedSessionID else { return }
        for ref in cardScan.refs where cardStates[ref.id] == nil {
            cardStates[ref.id] = .loading
            // This row's message id is part of the read: the host snapshots a card per
            // `(session, message, card)`, so two replies naming one file keep their own copy.
            cardStates[ref.id] = await CardLoader.shared.load(ref,
                                                              session: session,
                                                              message: entry.messageID) { id, cardSession, message in
                try await app.model.fetchCard(id: id, session: cardSession, message: message)
            }
        }
    }

    /// A tap answers the card: the tick is immediate and the rest lock, then the action's text goes
    /// out as the owner's next message through the composer's own send path.
    private func choose(_ action: Card.Action, ref: CardRef) {
        guard let session = app.model.selectedSessionID else { return }
        cardStates[ref.id] = CardLoader.shared.choose(action,
                                                     cardID: ref.id,
                                                     session: session,
                                                     message: entry.messageID)
        NotificationCenter.default.post(name: .genUICardSend, object: nil,
                                        userInfo: ["text": action.send, "bot": botID])
    }

    /// When it was sent, dim and small: something to check, not something to read.
    @ViewBuilder private var messageTime: some View {
        // A time under an empty row is just a lone line of grey digits — the "blank lines with
        // timestamps" that surviving tool-call hides left behind. Times belong to messages.
        if let at = entry.at, TranscriptVisibility.hasContent(entry) {
            Text(MessageTime.label(for: at))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Tokens.textMuted)
                .accessibilityLabel("Sent \(MessageTime.label(for: at))")
        }
    }

    /// A tool entry restored from the host's transcript projection.
    ///
    /// The projection carries one line — `bash · rsync … · 0.8s · exit 0` — so the name is
    /// the token before the first separator. Labelling every row "tool" (what this used to
    /// do) threw away the only identifying word the row has.
    private var toolResult: some View {
        let parsed = MobileToolRow.parse(entry.text)
        let detail = entry.tool
        // A projected row names its tool and ships the arguments (and, for the editing tools, the
        // result). Falling back to parsing the text line is only for rows that predate that
        // projection — those drew a card labelled "Tool" with nothing behind it.
        let name = detail?.name.isEmpty == false ? (detail?.name ?? parsed.name) : parsed.name
        // The headline comes from the call's arguments when the host kept them whole; its `context`
        // is a ~80-character preview that is often cut mid-object.
        let summary = ToolPayload.headline(raw: detail?.args)
            ?? ToolPayload.headline(raw: detail?.context)
            ?? parsed.summary
        return MobileToolRow(name: name,
                             summary: summary,
                             output: entry.tool?.detail,
                             isRunning: running.contains(entry.id),
                             durationMS: nil,
                             standaloneMenu: false)
    }

    private var systemNote: some View {
        Text(entry.text)
            .font(TypeScale.font(TypeScale.sm))
            .foregroundStyle(Tokens.textDim)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}

// MARK: - Tool card

/// One tool call, live or restored.
///
/// The name is always a real name: `tool.start`'s `name` for a live call, the projection's
/// leading token for a restored one. Output is drawn only when the caller supplies it
/// (a non-empty result), so the card never claims "No output." about
/// a tool it simply chose not to show. Long output scrolls inside the card rather than
/// pushing the answer off screen.
struct MobileToolRow: View {
    let name: String
    var summary: String? = nil
    var output: String? = nil
    var isRunning: Bool = false
    var durationMS: Int? = nil
    var standaloneMenu = true

    @State private var expanded = false

    /// The text behind the disclosure: a stored JSON result unwrapped to the words inside it.
    private var payload: ToolPayload.Info? { ToolPayload.info(raw: output) }

    /// A command that exited non-zero is not a success, whatever the row's role says.
    private var failed: Bool { !isRunning && ToolPayload.failed(raw: output) }

    /// Never an empty box: the disclosure only exists when there is something behind it.
    private var shownOutput: String? {
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let body = payload?.body, !body.isEmpty { return body }
        return output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if expanded, let shownOutput {
                Hairline()
                VStack(alignment: .leading, spacing: 6) {
                    ToolBodyView(text: shownOutput,
                                 font: Tokens.mono,
                                 color: Tokens.textSecondary,
                                 gutterColor: Tokens.textMuted)

                    // Counts and sizes belong under the text, not inside it.
                    if let notes = payload?.notes, !notes.isEmpty {
                        Text(notes.joined(separator: " · "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Tokens.textMuted)
                    }
                }
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                            .fill(Tokens.sheetInset)
                    )
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .cardSurface()
        .animation(Motion.toolCard, value: expanded)
        .modifier(MobileStandaloneShareMenu(enabled: standaloneMenu,
                                            text: [name, summary, shownOutput].compactMap { $0 }.joined(separator: "\n")))
    }

    private var header: some View {
        Button {
            guard shownOutput != nil else { return }
            Haptics.selection()
            withAnimation(Motion.toolCard) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                statusGlyph

                Text(name)
                    .font(Tokens.mono)
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)

                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(Tokens.mono)
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                // The one machine fact worth showing on a failed row: how it failed.
                if let code = payload?.exitCode, code != 0 {
                    Text("exit \(code)")
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.danger)
                        .fixedSize()
                }

                if let durationText {
                    Text(durationText)
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.textDim)
                        .fixedSize()
                }

                if shownOutput != nil {
                    DisclosureGlyph(expanded: expanded)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(shownOutput == nil ? "" : (expanded ? "Collapse tool output" : "Expand tool output"))
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if isRunning {
            SpinningRing(color: Tokens.accent, size: 11, lineWidth: 1.5)
                .frame(width: 14, height: 14)
        } else {
            // Red for a row whose result says it failed: an exit status other than zero is the
            // one fact that must not be dressed as a success tick.
            ZStack {
                Circle().fill(failed ? Tokens.dangerSoft : Tokens.controlActive)
                Image(systemName: failed ? "xmark" : "checkmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(failed ? Tokens.danger : Tokens.textMuted)
            }
            .frame(width: 14, height: 14)
        }
    }

    private var durationText: String? {
        guard let durationMS else { return nil }
        if durationMS < 1_000 { return "\(max(0, durationMS)) ms" }
        let seconds = Double(durationMS) / 1_000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds)
        let rest = whole % 60
        return rest == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(rest)s"
    }

    private var accessibilityText: String {
        var parts = ["Tool", name, isRunning ? "running" : "done"]
        if let summary, !summary.isEmpty { parts.append(summary) }
        if let durationText { parts.append(durationText) }
        return parts.joined(separator: ", ")
    }

    // MARK: Parsing a restored row

    /// `bash · rsync -a ~/vault/ · 0.8s · exit 0` → (`bash`, `rsync -a ~/vault/ · 0.8s · exit 0`).
    ///
    /// A name is a single token; anything with a space in it is prose and stays in the
    /// summary, so a projection line that carries no name is labelled "Tool" rather than
    /// slicing a sentence in half.
    static func parse(_ text: String) -> (name: String, summary: String?) {
        let parts = text.components(separatedBy: " · ")
        let head = (parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isName = !head.isEmpty
            && head.count <= 32
            && !head.contains(" ")
            && !head.contains("\n")

        guard isName else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ("Tool", trimmed.isEmpty ? nil : trimmed)
        }

        let rest = parts.dropFirst().joined(separator: " · ")
        return (head, rest.isEmpty ? nil : rest)
    }
}

// MARK: - Reasoning

/// The model's thinking, as a secondary block.
///
/// Collapsed by default and recessed behind the answer: reasoning is context for why the
/// reply says what it says, not the reply itself. It only exists when the host streamed
/// `thinking.delta` text *and* the user asked for it in Settings.
struct MobileReasoningBlock: View {
    let text: String
    var standaloneMenu = true
    /// The user's preference (Settings ▸ Chat): open on arrival rather than on a tap.
    var startsExpanded = false

    @State private var expanded: Bool

    init(text: String, standaloneMenu: Bool = true, startsExpanded: Bool = false) {
        self.text = text
        self.standaloneMenu = standaloneMenu
        self.startsExpanded = startsExpanded
        _expanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.selection()
                withAnimation(Motion.toolCard) { expanded.toggle() }
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
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .fill(Tokens.sheetInset)
        )
        .hairlineBorder()
        .animation(Motion.toolCard, value: expanded)
        .modifier(MobileStandaloneShareMenu(enabled: standaloneMenu, text: text))
    }
}

/// Live cards are not transcript rows, so give them their own share menu.
private struct MobileStandaloneShareMenu: ViewModifier {
    let enabled: Bool
    let text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                ShareLink(item: text) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Empty state

/// An empty conversation is a prompt, not an apology.
/// Preview fixture only: the empty chat itself is `ConversationScreen.blankState`, which fills the
/// viewport. This stays small so the transcript previews below have something to stand in for it.
struct MobileTranscriptEmpty: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Avatar(title, size: .hero, presence: .idle)
            Text(title)
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
                .multilineTextAlignment(.center)
            Text("Ask anything.")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 40)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Transcript rows") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            MobileTranscriptRow(entry: TranscriptEntry(id: "1",
                                                       role: .user,
                                                       text: "Back up the vault, then re-sync the docs tree."))
            MobileTranscriptRow(entry: TranscriptEntry(id: "2",
                                                       role: .assistant,
                                                       text: "Snapshotting the vault first.\n\n- `restic backup ~/vault`\n- then a **dry-run** diff of `docs/`"))
            MobileTranscriptRow(entry: TranscriptEntry(id: "3",
                                                       role: .tool,
                                                       text: "bash · rsync -a ~/vault/ ~/backup/vault/ · 0.8s · exit 0"))
            MobileTranscriptRow(entry: TranscriptEntry(id: "4",
                                                       role: .system,
                                                       text: "Session resumed from history."))
        }
        .padding(16)
    }
    .background(Tokens.canvas)
    .environmentObject(AppEnvironment.preview())
    .preferredColorScheme(.dark)
}
#endif

#if DEBUG
#Preview("Tool + reasoning") {
    ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            MobileReasoningBlock(text: "The vault is large; a dry-run first keeps the diff small. Then rsync with --delete only after the diff is reviewed.")
            MobileToolRow(name: "read_file",
                          summary: "Sources/HermesKit/GatewayClient.swift",
                          output: "public struct Bot: Identifiable, Hashable, Sendable { … }",
                          durationMS: 240)
            MobileToolRow(name: "bash",
                          summary: "swift build",
                          isRunning: true)
        }
        .padding(16)
    }
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif

#if DEBUG
#Preview("Empty conversation") {
    MobileTranscriptEmpty(title: "Assistant")
        .frame(maxHeight: .infinity)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
}
#endif

/// Where a message row sits, in screen coordinates.
private struct RowFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
