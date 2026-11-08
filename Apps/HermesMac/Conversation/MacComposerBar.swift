import AppKit
import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The composer, wired to the model's single draft.
///
/// `Composer` (design system) owns the field and the send/interrupt swap; this bar owns the
/// things the shell adds: the failed-send strip, the pending attachments, the paperclip's compact
/// menu, the ⌘↩/⌘. bindings the menu exposes, and the per-session draft the store restores.
struct MacComposerBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    /// The paperclip opens a popover with two items, never a page: the phone's action menu, at
    /// desktop density.
    @State private var showsAttachmentMenu = false

    /// One capture per composer: the transcript lands in the draft that was on screen when the
    /// microphone was pressed, and nothing outlives this bar.
    @StateObject private var voice = MacVoiceController()

    private var interrupt: (() -> Void)? {
        model.isStreaming ? { store.interrupt() } : nil
    }

    /// Voice needs a device pairing and a session to dictate into. A ticket-only pairing cannot
    /// mint the fresh ticket each request needs, so the control stays dimmed rather than failing
    /// after the recording.
    private var canRecordVoice: Bool {
        store.canTranscribeVoice && model.selectedSessionID != nil
    }

    private var hint: String {
        // The recording state is the one thing the composer itself cannot know: it changes what
        // the microphone glyph means, so it is said in the hint line above the field.
        if voice.isRecording { return "recording · tap the square to transcribe" }
        if voice.state == .requestingPermission { return "waiting for microphone permission…" }
        if voice.state == .transcribing { return "transcribing…" }
        if model.isStreaming {
            return "streaming · ⏎ steers into this turn · ⌘. interrupt"
        }
        return "⏎ or ⌘↩ send · ⇧⏎ newline · ⌘K commands"
    }

    /// The microphone's glyph and tint, from the controller's own state.
    private var micGlyph: String {
        switch voice.state {
        case .recording: return "stop.circle.fill"
        case .requestingPermission, .transcribing: return "waveform"
        case .idle: return "mic"
        }
    }

    private var micLabel: String {
        switch voice.state {
        case .recording: return "Stop and transcribe"
        case .requestingPermission: return "Waiting for microphone permission"
        case .transcribing: return "Transcribing"
        case .idle: return "Record a voice message"
        }
    }


    var body: some View {
        VStack(spacing: 0) {
            // A failed transcription uses the strip a failed send uses: one place to look when
            // the composer did not do what was asked. No retry — the audio is already gone.
            if let error = voice.errorMessage {
                MacErrorStrip(message: error,
                              onRetry: nil,
                              onDismiss: { voice.clearError() })
            }

            // A message sent mid-turn: the host steered, redirected or queued it, and the user is
            // told which — the bubble alone cannot say whether it joined the turn or waits for it.
            if let notice = model.deliveryNotice {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.circle")
                        .font(.system(size: 11, weight: .medium))
                    Text(notice)
                        .font(TypeScale.font(TypeScale.caption))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button { model.clearDeliveryNotice() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityLabel("Dismiss")
                }
                .foregroundStyle(Tokens.accentText)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = model.lastSendError {
                MacErrorStrip(message: error,
                              onRetry: store.canSend ? { store.retrySend() } : nil,
                              onDismiss: { model.clearSendError() })
            }

            // What a reply is anchored to: the quoted line is in the prompt, but a person has to see
            // it to know they are answering the right message.
            if let reply = model.replyTarget {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Replying to \(reply.author): \(reply.snippet.replacingOccurrences(of: "\n", with: " "))")
                        .font(TypeScale.font(TypeScale.caption))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button { model.clearReply() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityLabel("Cancel reply")
                }
                .foregroundStyle(Tokens.textMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Picked attachments wait here until the user sends, so cancelling uploads nothing.
            if !model.pendingAttachments.isEmpty {
                pendingAttachmentsBar
            }

            Composer(text: $model.draft,
                     placeholder: store.isPaired
                        ? "Ask \(model.selectedBot?.displayName ?? model.hostName) anything"
                        : "Pair a host to start a conversation",
                     isSending: model.isStreaming,
                     isDisabled: model.selectedSessionID == nil,
                     // Inside the card, immediately left of the send arrow.
                     showsMic: store.isPaired,
                     micSystemImage: micGlyph,
                     micTint: voice.isRecording ? Tokens.danger : nil,
                     micAccessibilityLabel: micLabel,
                     isMicEnabled: canRecordVoice && !voice.isBusy,
                     hint: hint,
                     onSend: { store.send() },
                     onAttach: { showsAttachmentMenu = true },
                     onMic: { toggleVoice() },
                     onInterrupt: interrupt,
                     // A pasted screenshot or a file dropped on the field is an attachment, exactly
                     // like one picked from the paperclip's menu.
                     onAttachItems: { items in
                         for item in items {
                             model.addPendingAttachment(name: item.name,
                                                        data: item.data,
                                                        isImage: item.isImage)
                         }
                     },
                     // Anchored on the paperclip, not on the card: the menu used to drop from
                     // the middle of the composer, under the field, nowhere near the clip.
                     attachPopoverPresented: $showsAttachmentMenu,
                     attachPopoverContent: AnyView(
                        MacAttachmentMenu(model: model, isPresented: $showsAttachmentMenu)
                     ))
                // The card is its content: one row of text and controls, the hint under it. A
                // fixed resting height used to hand the slack to the field, which left the
                // paperclip and the send arrow hanging below the line of text they act on.
                // Measured, then inset. Padding first shrank the field to 592 pt and put its left
                // edge 24 pt inside every other column's.
                .frame(maxWidth: Geometry.conversationMeasure)
                .padding(.horizontal, Geometry.readingInset)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity)
        }
        .background(Tokens.canvas)
        .onAppear { wireVoice() }
        // A re-pair must not leave the controller minting tickets for the old host.
        .onChange(of: store.pairing) { _, _ in wireVoice() }
        // The draft belongs to the session that was open when recording started, so leaving it
        // drops the capture instead of typing into somebody else's message.
        .onChange(of: model.selectedSessionID) { _, _ in voice.cancel() }
        .onDisappear { voice.cancel() }
    }

    // MARK: Voice

    /// Point the controller at the host this window is paired with, and at the field the
    /// transcript belongs in. Re-run on a pairing change; the closure reads the pairing at call
    /// time, so a host switch cannot send audio to the old one.
    private func wireVoice() {
        voice.transcribe = { [weak store] audio, mimeType in
            guard let store else { throw MacVoiceFailure.notConfigured }
            return try await store.transcribeVoice(audio, mimeType: mimeType)
        }
        // Appended to the draft, never sent: the user reads the words before they leave the Mac.
        voice.transcriptSink = { text in
            let existing = model.draft
            if existing.isEmpty {
                model.draft = text
            } else if existing.hasSuffix(" ") || existing.hasSuffix("\n") {
                model.draft = existing + text
            } else {
                model.draft = existing + " " + text
            }
        }
    }

    private func toggleVoice() {
        guard canRecordVoice else { return }
        if voice.isRecording {
            voice.stopAndTranscribe()
        } else {
            voice.startRecording()
        }
    }

    private var pendingAttachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.pendingAttachments) { attachment in
                    HStack(spacing: 5) {
                        if attachment.isImage, let image = NSImage(data: attachment.data) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 26, height: 26).clipped().cornerRadius(4)
                        } else {
                            Image(systemName: attachment.isImage ? "photo" : "doc")
                                .font(.system(size: 9)).foregroundStyle(Tokens.textSecondary)
                        }

                        Text(attachment.name)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textSecondary)
                            .lineLimit(1)

                        Button {
                            model.removePendingAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Tokens.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Tokens.surface))
                }
            }
            .padding(.horizontal, Geometry.readingInset)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Previews

private struct MacComposerBarPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            MacComposerBar(model: store.model, store: store)
        }
        .frame(width: Geometry.conversationMeasure + 200, height: 260)
        .background(Tokens.canvas)
        .task { await store.attachPreviewHost() }
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Composer bar") {
    MacComposerBarPreview()
}
#endif
