import AppKit
import HermesKit
import HermesRender
import OpenBotUI
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
    /// "Select Text" is presented by `TranscriptScroll`: a row inside a `LazyVStack` is torn down
    /// when it scrolls out, and a sheet it owns goes with it. The row asks; the transcript shows.
    var onSelectText: (String) -> Void = { _ in }
    /// Replying needs the model (it holds the reply target), and a row is torn down as it scrolls,
    /// so the transcript owns that decision and the row only asks.
    var onReply: ((TranscriptEntry) -> Void)? = nil
    @State private var showingReactions = false
    @AppStorage("mac.messageReactions.v1") private var storedReactions = "{}"
    /// The window's one voice. `@ObservedObject` so the row repaints the moment another message
    /// takes the speaker away from it.
    @ObservedObject private var speech = SpeechReader.shared
    @State private var isHovered = false
    /// Which glyph the pointer is over. One shared flag lit every button at once, which read as a
    /// selection rather than a hover.
    @State private var hoveredAction: String?
    /// The attachment whose viewer is open. Held here rather than in the transcript so a scroll
    /// cannot take the sheet's data away with it.
    @State private var viewingImage: ViewedImage?

    /// One decoded attachment, ready for `ImageViewer`.
    struct ViewedImage: Identifiable {
        let id = UUID()
        let name: String
        let data: Data
    }

    private var reactionKey: String? {
        guard let session else { return nil }
        let message = entry.rowID.map { "row:\($0)" } ?? "live:\(entry.id)"
        return [host, bot, session, message].map { "\($0.utf8.count):\($0)" }.joined()
    }

    private var reactions: [String: String] {
        guard let data = storedReactions.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    private func toggleReaction(_ emoji: String) {
        guard let key = reactionKey else { return }
        var values = reactions
        values[key] = values[key] == emoji ? nil : emoji
        if let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) {
            storedReactions = text
        }
    }

    var body: some View {
        VStack(alignment: entry.role == .user ? .trailing : .leading, spacing: 4) {
            content.contextMenu { messageMenu }
            if let key = reactionKey, let emoji = reactions[key] {
                Button(emoji) { toggleReaction(emoji) }
                    .accessibilityLabel("Remove local reaction \(emoji)")
            }
        }
        .popover(isPresented: $showingReactions) {
            VStack(spacing: 6) {
                QuickReactionRow(selected: reactionKey.flatMap { reactions[$0] }) { emoji in
                    toggleReaction(emoji)
                    showingReactions = false
                }
                Text("Saved on this Mac")
                    .font(TypeScale.font(10))
                    .foregroundStyle(Tokens.textDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
    }

    @ViewBuilder private var messageMenu: some View {
        if entry.role == .user || entry.role == .assistant {
            Button("Select Text") { onSelectText(entry.text) }
            Button(isSpeaking ? "Stop Reading" : "Read Aloud") {
                speech.toggle(id: entry.id, text: entry.text)
            }
            if reactionKey != nil { Button("Add Local Reaction…") { showingReactions = true } }
        }
        ShareLink(item: entry.text) { Label("Share", systemImage: "square.and.arrow.up") }
        Button("Copy Message") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string) }
    }

    @ViewBuilder private var content: some View {
        switch entry.role {
        case .user:
            userRow
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

    // MARK: User

    private var userRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: Geometry.conversationMeasure * 0.18)

            VStack(alignment: .trailing, spacing: 6) {
                // The pictures that went with the words. The host's transcript carries no
                // attachment metadata, so a message's own memory is all there is to draw.
                if !bubbleAttachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(bubbleAttachments.filter { $0.isImage && $0.imageData != nil }) { attachment in
                            if let data = attachment.imageData, let image = NSImage(data: data) {
                                imageThumbnail(attachment, data: data, image: image)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                        .fill(Tokens.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
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
            // The picture, at its own size, with Save and Copy — the same viewer a generated
            // artifact opens.
            .sheet(item: $viewingImage) { item in
                ImageViewer(data: item.data, title: item.name, canExport: false) { viewingImage = nil }
                    .frame(minWidth: 640, minHeight: 460)
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
    /// doing nothing, and the corner glyph says so before the cursor tries.
    private func imageThumbnail(_ attachment: SentAttachment, data: Data, image: NSImage) -> some View {
        Button {
            viewingImage = ViewedImage(name: attachment.name, data: data)
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

    // MARK: Assistant

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownTextView(text: entry.text)
                .accessibilityLabel("Hermes said: \(entry.text)")

            messageTime

            // Three glyphs on the message itself: speak, copy, answer. Visible at rest — at 45 %
            // they were invisible on a dark surface, which is why they looked absent altogether.
            messageActions
                .opacity(isHovered || isSpeaking ? 1 : 0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    // MARK: Actions

    private var messageActions: some View {
        HStack(spacing: 2) {
            // Six reactions on one press. It sits first because it is the lightest verb on the row
            // and the one a person reaches for while reading.
            if reactionKey != nil {
                actionGlyph("react",
                            systemImage: "face.smiling",
                            tint: reactionKey.flatMap { reactions[$0] } != nil ? Tokens.accentText
                                                                                : Tokens.textMuted,
                            help: "React to this message") {
                    showingReactions = true
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
