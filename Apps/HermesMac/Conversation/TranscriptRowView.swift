import AppKit
import HermesKit
import HermesRender
import HermeyUI
import HermesA2UI
import HermesCards
import SwiftUI

/// One transcript entry, drawn by role.
///
/// The roles are deliberately *not* the same shape: a user turn is a right-aligned bubble
/// you wrote, an assistant turn is a document you read, a tool line is a card, and a system
/// line is punctuation. Colour alone never carries the difference — the alignment and the
/// surface do.
struct TranscriptRowView: View {
    let entry: TranscriptEntry
    var host: String = ""
    var bot: String = ""
    var session: String? = nil
    /// The selected bot's colour, for the user's own bubble. Passed in rather than looked up: a row
    /// inside a lazy stack must not reach for a store, and the pane already has the face.
    var userBubbleTint: Color = Tokens.control
    /// "Select Text" is presented by `TranscriptScroll`: a row inside a `LazyVStack` is torn down
    /// when it scrolls out, and a sheet it owns goes with it. The row asks; the transcript shows.
    var onSelectText: (String) -> Void = { _ in }
    /// Replying needs the model (it holds the reply target), and a row is torn down as it scrolls,
    /// so the transcript owns that decision and the row only asks.
    var onReply: ((TranscriptEntry) -> Void)? = nil
    /// The attribution line on a bot-to-bot message asks the transcript to open the pair's exchange
    /// (the sheet lives there: a row is torn down as it scrolls and a sheet it owns goes with it).
    var onOpenPair: ((String) -> Void)? = nil
    /// Where a native card is read from (`GET /v1/cards/{id}`). A closure, not the model: a row in
    /// a lazy stack must not reach for a store, and the pane already holds the connection. The
    /// third argument is this row's message id — the host snapshots a card per message.
    var fetchCard: ((String, SessionID, String) async throws -> CardFetch)? = nil
    /// The emoji on this message, and the way to change it — `AppModel`'s map, reached through the
    /// transcript rather than by handing a row the whole app. Both are closures for the same reason
    /// `fetchCard` is: a row inside a `LazyVStack` is torn down and rebuilt as it scrolls.
    ///
    /// The host owns reactions now (`/v1/reactions`), so this is one conversation's shared state
    /// rather than this device's private copy — which is what makes a reaction set on the phone
    /// appear here, live, over `/v1/ws`.
    var reaction: (ReactionKey) -> String? = { _ in nil }
    var onReact: (ReactionKey, String?) -> Void = { _, _ in }
    @State private var showingReactions = false
    /// The window's one voice. `@ObservedObject` so the row repaints the moment another message
    /// takes the speaker away from it.
    @ObservedObject private var speech = SpeechReader.shared
    @State private var isHovered = false
    /// Which glyph the pointer is over. One shared flag lit every button at once, which read as a
    /// selection rather than a hover.
    @State private var hoveredAction: String?
    /// The attachment whose viewer is open. Held here rather than in the transcript so a scroll
    /// cannot take the sheet's data away with it.
    /// Every picture this message carries, and which one was clicked — `ImageViewer` pages through
    /// the rest, so a message with three screenshots no longer means closing and reopening.
    @State private var viewingImage: ViewedGallery?
    /// What the marker parser found and what each card's read came back as, keyed by card id.
    ///
    /// Held here rather than in `CardLoader` because this is what makes the row repaint: the
    /// loader is the shared, fetch-once cache, and a row is torn down long before the cache is.
    @State private var cardStates: [String: CardLoader.State] = [:]

    /// The pictures a message carried, ready for `ImageViewer`, and where the viewer opens.
    struct ViewedGallery: Identifiable {
        let id = UUID()
        let items: [ImageViewer.Item]
        let startIndex: Int
    }

    /// This message's identity for a reaction: the one rule both apps share (`ReactionKey`), fed
    /// from the row and the pane. `nil` for a row with no conversation to belong to.
    private var reactionKey: ReactionKey? {
        guard let session else { return nil }
        return ReactionKey(host: host, bot: bot, session: session,
                           message: ReactionKey.message(rowID: entry.rowID, entryID: entry.id))
    }

    /// The emoji this message wears, from the conversation's shared state.
    private var currentReaction: String? {
        guard let key = reactionKey else { return nil }
        return reaction(key)
    }

    /// One emoji per message: picking the emoji already there removes it, exactly as before — only
    /// the storage changed (the host, not `@AppStorage`).
    private func toggleReaction(_ emoji: String) {
        guard let key = reactionKey else { return }
        onReact(key, currentReaction == emoji ? nil : emoji)
    }

    var body: some View {
        VStack(alignment: entry.role == .user ? .trailing : .leading, spacing: 4) {
            content.contextMenu { messageMenu }
            if let emoji = currentReaction {
                Button(emoji) { toggleReaction(emoji) }
                    .help("Remove your \(ReactionEmoji.name(emoji)) reaction")
                    .accessibilityLabel("Remove \(ReactionEmoji.name(emoji)) reaction")
            }
        }
    }

    @ViewBuilder private var messageMenu: some View {
        if entry.role == .user || entry.role == .assistant {
            Button("Select Text") { onSelectText(entry.text) }
            Button(isSpeaking ? "Stop Reading" : "Read Aloud") {
                speech.toggle(id: entry.id, text: entry.text)
            }
            if reactionKey != nil { Button("Add Reaction…") { showingReactions = true } }
        }
        ShareLink(item: entry.text) { Label("Share", systemImage: "square.and.arrow.up") }
        Button("Copy Message") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string) }
    }

    @ViewBuilder private var content: some View {
        switch entry.role {
        case .user:
            // Written by another bot (it arrives in this bot's conversation as a user row): it gets
            // the sender's name over the words instead of the owner's bubble (asked for 2026-11-15).
            if let label = BotMessageLabel.parse(entry.text) {
                botMessageRow(label)
            } else {
                userRow
            }
        case .assistant:
            assistantRow
        case .tool:
            toolRow
        case .reasoning:
            reasoningRow
        case .system:
            systemRow
        }
    }

    // MARK: A message from another bot

    /// `Message from <face> Cody` over the words. Left-aligned on purpose: it is not the owner's
    /// message, and the right edge is what says "you wrote this" everywhere else in the app.
    @ViewBuilder
    private func botMessageRow(_ label: BotMessageLabel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if let profile = label.senderProfile { onOpenPair?(profile) }
            } label: {
                HStack(spacing: 6) {
                    if let profile = label.senderProfile {
                        // `animates: false`: a transcript row is a record of what was said, not a live status.
                        // Every other face site already gates on activity; this one did not, so an
                        // idle 30 Hz timeline ran per bot-message row (Tinker's measurement,
                        // 2026-11-16: ~19 pp of a core from face animation alone).
                        BotAvatarView(identity: profile,
                                      size: Geometry.rosterAvatarCompact,
                                      animates: false)
                    }
                    Text(label.headerTitle)
                        .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                        .foregroundStyle(Tokens.accentText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(label.senderProfile == nil)
            .help("Show the conversation between these two bots")
            // The same rendering an assistant reply gets: a bot's message to another bot is prose
            // written in the same editor, so its lists, bold and code blocks belong as markup.
            MarkdownTextView(text: label.body, metrics: .macOSScaled)
                .foregroundStyle(Tokens.textPrimary)
                .padding(.horizontal, Geometry.bubblePaddingH)
                .padding(.vertical, Geometry.bubblePaddingV)
                .background(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                    .fill(Tokens.surface))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: User

    private var userRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: Geometry.conversationMeasure * 0.18)

            VStack(alignment: .trailing, spacing: 6) {
                // The pictures that went with the words. The host's transcript carries no
                // attachment metadata, so a message's own memory is all there is to draw.
                if !bubbleAttachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(viewablePictures) { attachment in
                            if let data = attachment.imageData, let image = NSImage(data: data) {
                                imageThumbnail(attachment, image: image)
                            }
                        }
                        ForEach(bubbleAttachments.filter { !$0.isImage || $0.imageData == nil }) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: "doc").font(.system(size: 9))
                                Text(attachment.name)
                                    .font(TypeScale.font(Tokens.textSM))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Tokens.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Tokens.control, in: Capsule())
                        }
                    }
                }

                if !entry.displayText.isEmpty {
                Text(entry.displayText)
                .font(TypeScale.font(TypeScale.chatBody))
                // The same leading the assistant's prose gets: one table for chat text.
                .lineSpacing(TypeScale.chatLineSpacing)
                .foregroundStyle(Tokens.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Geometry.bubblePaddingH)
                .padding(.vertical, Geometry.bubblePaddingV)
                // The bot's own colour, at the opacity a bubble can carry behind body text, with
                // a border in the same colour: the one place in the transcript that says *which*
                // bot you are talking to without a label.
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusBubble, style: .continuous)
                        .fill(userBubbleTint.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusBubble, style: .continuous)
                        .strokeBorder(userBubbleTint.opacity(0.45), lineWidth: 1)
                )
                .accessibilityLabel("You said: \(entry.displayText)")
                }

                HStack(spacing: 8) {
                    messageTime
                    // Your own messages get the same three glyphs: copying what you wrote and
                    // answering it are not assistant-only acts.
                    messageActions
                        .opacity(isHovered ? 1 : 0.8)
                }
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            // The pictures, at their own size, with Save and Copy — the same viewer a generated
            // artifact opens, and one that pages through every picture of the message.
            .sheet(item: $viewingImage) { gallery in
                ImageViewer(items: gallery.items,
                            startIndex: gallery.startIndex,
                            canExport: false) { viewingImage = nil }
                    .frame(minWidth: 640, minHeight: 460)
                .hermesSheetChrome()
            }
        }
    }

    /// When a message was sent, quiet enough to ignore until it is looked for.
    @ViewBuilder private var messageTime: some View {
        // Times belong to messages: a row with no words and no pictures is a tool-call banner, and
        // its time is what was left showing after the cards were hidden.
        if let at = entry.at, TranscriptVisibility.hasContent(entry) {
            Text(MessageTime.label(for: at))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Tokens.textMuted)
                .accessibilityLabel("Sent \(MessageTime.label(for: at))")
        }
    }

    /// The pictures that went with the words, each of them a door to the viewer.
    ///
    /// A thumbnail is a promise that the picture is here: clicking it opens `ImageViewer` rather than
    /// doing nothing, and the corner glyph says so before the cursor tries. Clicking one of several
    /// opens the viewer on that one, with the others a keystroke away.
    private func imageThumbnail(_ attachment: SentAttachment, image: NSImage) -> some View {
        Button {
            openImage(attachment)
        } label: {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Tokens.textSecondary)
                        .padding(3)
                        .background(Tokens.canvas.opacity(0.75), in: Circle())
                        .padding(4)
                        .opacity(isHovered ? 1 : 0.55)
                }
        }
        .buttonStyle(.plain)
        .help("Open \(attachment.name)")
        .accessibilityLabel("Attached image \(attachment.name)")
        .accessibilityHint("Opens the image")
    }

    /// Pictures the row remembers, or the host's references looked up in the image cache.
    private var bubbleAttachments: [SentAttachment] {
        entry.attachments.isEmpty ? entry.referenceAttachments : entry.attachments
    }

    /// The pictures of this message the row can actually draw, in the order they were attached.
    private var viewablePictures: [SentAttachment] {
        bubbleAttachments.filter { $0.isImage && $0.imageData != nil }
    }

    /// Open the viewer on this picture, with the rest of the message's pictures behind it.
    private func openImage(_ attachment: SentAttachment) {
        let pictures = viewablePictures
        let start = pictures.firstIndex { $0.id == attachment.id } ?? 0
        viewingImage = ViewedGallery(items: pictures.compactMap { picture in
            picture.imageData.map { ImageViewer.Item(data: $0, name: picture.name) }
        }, startIndex: start)
    }

    // MARK: Assistant

    /// Every A2UI surface this reply carries, in order. Parsed once per body evaluation.
    private var surfacePayloads: [A2UISurfacePayload] { A2UIMarker.surfaces(in: entry.text) }

    /// Every native card marker this reply carries, and the prose with those lines taken out.
    ///
    /// The parser runs before the genui check below, which is the whole order: a reply may carry a
    /// card, a `::blocks` board or neither, and only the card path knows how to strip its own lines.
    private var cardScan: CardScan { CardMarker.scan(entry.text) }

    /// `cards.enabled`, read per body pass. Off is the old behaviour — the marker line stays as
    /// text, nothing is stripped and nothing is fetched (the rollback switch is `defaults write`).
    private var cardsEnabled: Bool { CardsSettings.isEnabled }

    /// Whether this row can actually draw: the flag on, and a session to resolve the files in.
    /// Without a session the marker would be stripped and nothing could replace it, so the line
    /// stays as text instead.
    private var cardsActive: Bool { cardsEnabled && !(session ?? "").isEmpty }

    /// The app's palette, handed to the card renderer. `HermesCards` never imports `HermeyUI`:
    /// the values are mapped here, where both modules already are.
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

    /// Changes when the set of cards (or the session they belong to) does, so a finished turn —
    /// whose markers arrive last — is the moment the reads are asked for. Never a timer: P1 does
    /// not poll.
    private var cardTaskKey: String {
        guard cardsActive else { return "" }
        return ([session ?? ""] + cardScan.refs.map(\.id)).joined(separator: "\u{1F}")
    }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // An A2UI surface arrives as one `::a2ui{…}` line: the compiled, validated wire JSON
            // the plugin produced. The prose around it is the reply; the surfaces are drawn in its
            // place, in order. Turning `a2ui.surfaces.disabled` on falls through to `::blocks`.
            if A2UISurfaceSettings.isEnabled, !surfacePayloads.isEmpty {
                let prose = A2UIMarker.textWithoutMarkers(entry.text)
                if !prose.isEmpty {
                    MarkdownTextView(text: prose)
                        .accessibilityLabel("Hermes said: \(prose)")
                }
                // Every surface, not just the first: a reply that compares three cards is one
                // reply, and dropping all but the first made the rest vanish with their markers.
                ForEach(Array(surfacePayloads.enumerated()), id: \.offset) { _, payload in
                    A2UISurfaceView(payload: payload)
                        .padding(.vertical, 2)
                }
            } else if cardsActive, !cardScan.refs.isEmpty {
                // A `::card{…}` line is a reference, not prose: the line is taken out and the card
                // is drawn under the words. A card that cannot be read says so and leaves the prose
                // exactly as the bot wrote it.
                cardBubble(cardScan)
            } else if let boardID = GenUITag.boardID(in: entry.text) {
                // A `::blocks{id="…"}` line is not prose: the plugin's board is drawn in its place, and
                // the directive itself must never be read as text.
                let prose = GenUITag.textWithoutTags(entry.text)
                if !prose.isEmpty {
                    MarkdownTextView(text: prose)
                        .accessibilityLabel("Hermes said: \(prose)")
                }
                GenUICard(blockID: boardID)
                    .padding(.vertical, 2)
            } else {
                MarkdownTextView(text: entry.text)
                    .accessibilityLabel("Hermes said: \(entry.text)")
            }

            // The stamp and the glyphs are one line, not two. Stacked, every reply spent a whole
            // extra line on a time and three verbs that belong together — and the user row already
            // reads that way, at this spacing, so the two roles now share one shape.
            HStack(spacing: 8) {
                messageTime
                // Three glyphs on the message itself: speak, copy, answer. Visible at rest — at 45 %
                // they were invisible on a dark surface, which is why they looked absent altogether.
                messageActions
                    .opacity(isHovered || isSpeaking ? 1 : 0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .task(id: cardTaskKey) { await loadCards() }
    }

    // MARK: Native cards

    /// The reply's prose, then one card per marker, in the order the bot wrote them.
    @ViewBuilder
    private func cardBubble(_ scan: CardScan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !scan.prose.isEmpty {
                MarkdownTextView(text: scan.prose)
                    .accessibilityLabel("Hermes said: \(scan.prose)")
            }
            // The offset, not the ref: two identical markers in one reply are still two cards, and
            // `CardRef` would give them one identity.
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
            // The one apology the contract allows, shaped like a card so the bubble does not look
            // like it is still loading.
            CardView(model: .unavailable(CardModel.unavailableMessage), theme: cardTheme)
                .padding(.vertical, 2)
        case .idle, .loading:
            // Nothing yet. Drawing "Card not available" while the read is in the air is a lie that
            // would flash on every scroll; the prose above is already the whole message.
            EmptyView()
        }
    }

    private func loadCards() async {
        guard cardsActive, let fetchCard, let session else { return }
        for ref in cardScan.refs where cardStates[ref.id] == nil {
            cardStates[ref.id] = .loading
            // The row's own message id travels with every read: two replies naming one card file
            // are two snapshots on the host, and one cache entry here would show the wrong one.
            cardStates[ref.id] = await CardLoader.shared.load(ref,
                                                              session: session,
                                                              message: entry.messageID) { id, cardSession, message in
                try await fetchCard(id, cardSession, message)
            }
        }
    }

    /// A tap sends the action's text as the owner's next message, through the composer's own path.
    ///
    /// The tick is optimistic: the card is answered the instant it is tapped, and every other button
    /// locks with it. The send is the same notification a genui board's button posts, so there is no
    /// second delivery path to keep honest.
    private func choose(_ action: Card.Action, ref: CardRef) {
        guard let session else { return }
        cardStates[ref.id] = CardLoader.shared.choose(action,
                                                     cardID: ref.id,
                                                     session: session,
                                                     message: entry.messageID)
        NotificationCenter.default.post(name: .genUICardSend, object: nil,
                                        userInfo: ["text": action.send, "bot": bot])
    }

    // MARK: Actions

    private var reactionPicker: some View {
        VStack(spacing: 5) {
            QuickReactionRow(selected: currentReaction) { emoji in
                toggleReaction(emoji)
                showingReactions = false
            }
            Text("Shared across your devices")
                .font(TypeScale.font(10))
                .foregroundStyle(Tokens.textDim)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private var messageActions: some View {
        HStack(spacing: 2) {
            // Six reactions on one press. It sits first because it is the lightest verb on the row
            // and the one a person reaches for while reading.
            if reactionKey != nil {
                // The popover hangs off this button, not off the row. On the row it anchored to the
                // message's whole width — so it opened below and to the right of the smiley, 465 pt
                // wide, pointing its arrow at nothing in particular.
                actionGlyph("react",
                            systemImage: "face.smiling",
                            tint: currentReaction != nil ? Tokens.accentText : Tokens.textMuted,
                            help: "React to this message") {
                    showingReactions = true
                }
                .popover(isPresented: $showingReactions,
                         attachmentAnchor: .rect(.bounds),
                         arrowEdge: .bottom) {
                    reactionPicker
                }
            }

            actionGlyph("speak",
                        systemImage: isSpeaking ? "stop.fill" : "speaker.wave.2",
                        tint: isSpeaking ? Tokens.accentText : Tokens.textMuted,
                        help: isSpeaking ? "Stop reading this message" : "Read this message aloud") {
                speech.toggle(id: entry.id, text: entry.text)
            }

            actionGlyph("copy", systemImage: "doc.on.doc", help: "Copy this message") {
                copyMessage()
            }

            if let onReply {
                actionGlyph("reply", systemImage: "arrowshape.turn.up.left",
                            help: "Reply to this message") {
                    onReply(entry)
                }
            }
        }
    }

    private func actionGlyph(_ id: String,
                             systemImage: String,
                             tint: Color = Tokens.textMuted,
                             help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hoveredAction == id ? Tokens.textPrimary : tint)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                        .fill(hoveredAction == id ? Tokens.controlHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { inside in
            if inside { hoveredAction = id }
            else if hoveredAction == id { hoveredAction = nil }
        }
        .help(help)
        .accessibilityLabel(help)
    }

    /// The message's own words, not its rendering: what the user copies is what was said.
    private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.displayText, forType: .string)
    }

    // MARK: Read aloud

    private var isSpeaking: Bool { speech.speakingEntryID == entry.id }

    private var readAloudControl: some View {
        Button {
            speech.toggle(id: entry.id, text: entry.text)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSpeaking ? "stop.fill" : "speaker.wave.2")
                    .font(.system(size: 9, weight: .semibold))
                Text(isSpeaking ? "Stop" : "Read aloud")
                    .font(TypeScale.font(TypeScale.micro, weight: .medium))
            }
            .foregroundStyle(isSpeaking ? Tokens.accentText : Tokens.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                    .fill(isSpeaking ? Tokens.controlActive : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSpeaking ? "Stop reading this message" : "Read this message aloud")
        .accessibilityLabel(isSpeaking ? "Stop reading this message" : "Read this message aloud")
        .accessibilityIdentifier("message.readAloud")
    }

    // MARK: Tool

    private var toolRow: some View {
        // The headline comes from the call's arguments when the host kept them whole: its
        // `context` is a ~80-character preview, often cut mid-object. The status comes from the
        // result — a command that exited 2 is not "done".
        ToolCard(name: toolProjection.name,
                 summary: ToolPayload.headline(raw: entry.tool?.args)
                    ?? ToolPayload.headline(raw: toolProjection.summary)
                    ?? toolProjection.summary,
                 status: ToolCard.status(ok: !ToolPayload.failed(raw: toolProjection.output)),
                 output: toolProjection.output,
                 startsExpanded: false)
    }

    /// A history tool row from the host's projection carries its own `name`, `context` and `args`
    /// (plus `content` for the editing tools), so the card is built from those. The flat-string
    /// split below only covers old rows that predate the projection — those rendered as a card
    /// labelled "tool" with nothing expandable in it.
    private var toolProjection: (name: String, summary: String?, output: String?) {
        if let tool = entry.tool {
            let name = tool.name.isEmpty ? "tool" : tool.name
            return (name, tool.context ?? legacyProjection.summary, tool.detail)
        }
        return legacyProjection
    }

    private var legacyProjection: (name: String, summary: String?, output: String?) {
        let parts = entry.text
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let name = parts.first else { return ("tool", nil, nil) }
        let rest = parts.dropFirst()
        return (name, rest.isEmpty ? nil : rest.joined(separator: " · "), nil)
    }

    // MARK: Reasoning

    /// The model's reasoning for a finished turn, kept in the thread.
    ///
    /// Recessed and quiet: it explains the answer rather than competing with it, which is why it
    /// is dim text and not a bubble.
    private var reasoningRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokens.textDim)
                .padding(.top, 3)

            Text(entry.text)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textMuted)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Reasoning: \(entry.text)")
    }

    // MARK: System

    private var systemRow: some View {
        HStack(spacing: 8) {
            Hairline(color: Tokens.borderStrong)
                .frame(width: 18)
            Text(entry.text)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Hairline(color: Tokens.borderStrong)
                .frame(width: 18)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Previews

private struct TranscriptRowViewPreview: View {
    private let entries: [TranscriptEntry] = [
        TranscriptEntry(id: "1", role: .user, text: "Back up the vault and re-sync docs."),
        TranscriptEntry(id: "2", role: .assistant,
                        text: "Snapshotting the vault first, then I'll diff the `docs/` tree.\n\n1. `rsync` the vault\n2. Diff `docs/`\n\n> Nothing is deleted yet."),
        TranscriptEntry(id: "3", role: .tool,
                        text: "bash · rsync -a ~/vault/ ~/backup/vault/ · 0.8s"),
        TranscriptEntry(id: "4", role: .system, text: "Turn interrupted by you"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(entries) { entry in
                    TranscriptRowView(entry: entry)
                }
            }
            .padding(20)
            .frame(width: Geometry.conversationMeasure, alignment: .leading)
        }
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Transcript rows") {
    TranscriptRowViewPreview()
}
#endif
