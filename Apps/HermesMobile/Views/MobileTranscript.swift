import SwiftUI
import AVFoundation
import UIKit
import HermesKit
import HermesRender
import OpenBotUI

/// One row of the conversation.
///
/// The shapes are OpenBot's three: the user's message is a right-aligned tinted bubble,
/// the assistant is plain body text on the canvas (no bubble — a long answer in a bubble
/// is a wall inside a wall), and a tool result keeps the card the design system already
/// has. Markers come from the block layer so a list looks the same everywhere.
struct MobileTranscriptRow: View {
    let entry: TranscriptEntry
    @EnvironmentObject private var app: AppEnvironment
    @State private var showingSelection = false
    /// Pictures fetched back from the host, by attachment name.
    @State private var fetchedImages: [String: Data] = [:]
    /// The picture the viewer is showing, if any.
    @State private var viewingImage: ViewedAttachment?

    /// One decoded attachment, ready for `ImageViewer`.
    struct ViewedAttachment: Identifiable {
        let id = UUID()
        let name: String
        let data: Data
    }
    @State private var showingReactionPicker = false
    @AppStorage("mobile.messageReactions.v1") private var storedReactions = "{}"
    private static let speaker = AVSpeechSynthesizer()
    private static let emojis = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

    private var reactionKey: String? {
        guard let session = app.model.selectedSessionID else { return nil }
        // Live messages may not have a durable history row yet; allow a temporary reaction too.
        // It can only persist across reloads when the host provides a stable row ID.
        let messageID = entry.rowID.map { "row:\($0)" } ?? "live:\(entry.id)"
        // Length-prefixed components cannot collide even when identifiers contain separators.
        return [app.hostLabel, app.model.selectedBotID ?? "", session, messageID]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    private var reactions: [String: String] {
        guard let data = storedReactions.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    private func setReaction(_ emoji: String) {
        guard let key = reactionKey else { return }
        var values = reactions
        values[key] = values[key] == emoji ? nil : emoji
        if let data = try? JSONEncoder().encode(values), let encoded = String(data: data, encoding: .utf8) {
            storedReactions = encoded
        }
    }

    var body: some View {
        VStack(alignment: entry.role == .user ? .trailing : .leading, spacing: 4) {
            rowContent
            if let key = reactionKey, let emoji = reactions[key] {
                Button(emoji) { setReaction(emoji) }
                    .accessibilityLabel("Remove reaction \(emoji)")
            }
        }
        .popover(isPresented: $showingReactionPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            reactionPicker
                .presentationCompactAdaptation(.popover)
        }
        // The viewer fills the screen: a picture at 132 pt is a preview, not the picture.
        .fullScreenCover(item: $viewingImage) { item in
            ImageViewer(data: item.data, title: item.name, canExport: false) { viewingImage = nil }
                .preferredColorScheme(.dark)
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
            userBubble
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
            if reactionKey != nil {
                Button { showingReactionPicker = true } label: {
                    Label("Add reaction", systemImage: "face.smiling")
                }
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

    private var reactionPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 4), count: 3), spacing: 4) {
            ForEach(Self.emojis, id: \.self) { emoji in
                Button {
                    setReaction(emoji)
                    showingReactionPicker = false
                } label: {
                    Text(emoji)
                        .font(.system(size: 26))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("React with \(emoji)")
                .accessibilityHint("Select again to remove this reaction")
            }
        }
        .padding(8)
        .frame(width: 156)
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
                    Button {
                        viewingImage = ViewedAttachment(name: attachment.name, data: data)
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous)
                        .fill(Tokens.accentSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous))
                .contextMenu { menu }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Assistant

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 2) {
            MobileMarkdownText(blocks: IncrementalMarkdown.parse(entry.text))
                .accessibilityLabel(entry.text)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .contextMenu { menu }
            messageTime
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                             isRunning: false,
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
struct MobileTranscriptEmpty: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Avatar(title, size: .hero, presence: .idle)
            Text(title)
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
                .multilineTextAlignment(.center)
            Text("Ask anything. Approvals show up here the moment Hermes needs one.")
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
