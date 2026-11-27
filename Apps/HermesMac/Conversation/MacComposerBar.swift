import AppKit
import HermesAppKit
import HermesKit
import HermesVoice
import HermeyUI
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
    @State private var showingCommandHelp = false

    /// One capture per composer: the transcript lands in the draft that was on screen when the
    /// microphone was pressed, and nothing outlives this bar.
    @StateObject private var voice = MacVoiceController()

    /// The hands-free conversation. One per composer, because the microphone it opens belongs to
    /// the conversation on screen — leaving this bar tears it down (`onDisappear`).
    @StateObject private var loop = VoiceLoopController()

    private var interrupt: (() -> Void)? {
        model.isStreaming ? { store.interrupt() } : nil
    }

    /// Voice needs a device pairing and a session to dictate into. A ticket-only pairing cannot
    /// mint the fresh ticket each request needs, so the control stays dimmed rather than failing
    /// after the recording.
    private var canRecordVoice: Bool {
        store.canTranscribeVoice && model.selectedSessionID != nil
    }

    /// The loop needs the same pairing (it mints a ticket per transcribe *and* per sentence it
    /// speaks) and the same open session, because a turn has to be sent somewhere.
    private var canStartVoiceMode: Bool {
        store.canTranscribeVoice && model.selectedSessionID != nil
    }

    /// The line under the field: **state only**, and `nil` the rest of the time.
    ///
    /// The resting keyboard reference is gone — a permanent cost for a one-time lesson. What stays
    /// is what the composer cannot show by itself: that it is recording, waiting on the
    /// microphone, or transcribing, which changes what the mic glyph means.
    private var hint: String? {
        if voice.isRecording { return "recording · tap the square to transcribe" }
        if voice.state == .requestingPermission { return "waiting for microphone permission…" }
        if voice.state == .transcribing { return "transcribing…" }
        return nil
    }

    /// The microphone's glyph and tint, from the controller's own state.
    private var micGlyph: String {
        switch voice.state {
        case .recording: return "stop.circle.fill"
        case .requestingPermission, .transcribing: return "waveform"
        case .idle: return "mic"
        }
    }

    /// The same words iOS puts in an empty composer: "Message Cody".
    private var composerTitle: String {
        model.selectedBot?.displayName ?? model.hostName
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
            // A conversation that stopped takes the same strip: the loop has already closed the
            // microphone by the time this shows, and the retry restarts it deliberately.
            if let error = loop.errorMessage {
                MacErrorStrip(message: error,
                              onRetry: canStartVoiceMode ? { loop.start() } : nil,
                              onDismiss: { loop.clearError() })
            }

            // The loop's own line, above the field: what it is doing, what it heard, and the way
            // out. Only while it owns the microphone, or after it stopped on its own.
            if loop.state.ownsMicrophone || loop.state == .failed {
                VoiceLoopStatusBar(loop: loop)
                    .frame(maxWidth: Geometry.conversationMeasure)
                    .padding(.horizontal, Geometry.readingInset)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
            }

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
                    .help("Dismiss this notice")
                    .accessibilityLabel("Dismiss")
                    .hermeyFocusQuiet()
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
                    .help("Cancel this reply")
                    .accessibilityLabel("Cancel reply")
                    .hermeyFocusQuiet()
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
                     // A capsule over the transcript: no bar, no frame at rest.
                     floats: true,
                     // The same prompt the phone shows: it names the bot you are about to write to,
                     // and it vanishes the moment there is something to say.
                     placeholder: "Message \(composerTitle)",
                     isSending: model.isStreaming,
                     isDisabled: model.selectedSessionID == nil,
                     // Inside the card, immediately left of the send arrow.
                     showsMic: store.isPaired,
                     micSystemImage: micGlyph,
                     micTint: voice.isRecording ? Tokens.danger : nil,
                     micAccessibilityLabel: micLabel,
                     // One listener. While the conversation owns the microphone, hold-to-talk is
                     // disabled rather than ignored: two taps on one input device is a feedback
                     // loop, not a feature.
                     isMicEnabled: canRecordVoice && !voice.isBusy && !loop.isActive,
                     showsVoiceMode: true,
                     voiceModeSystemImage: loop.state.glyph,
                     voiceModeTint: loop.isActive ? Tokens.accentText : nil,
                     voiceModeAccessibilityLabel: loop.isActive
                        ? "End the voice conversation"
                        : "Start a hands-free voice conversation",
                     isVoiceModeEnabled: canStartVoiceMode,
                     onVoiceMode: { toggleVoiceMode() },
                     hint: hint,
                     // The session's own facts, inside the composer: which model answers, how full
                     // its context is, and the door to the one picker the Mac already has. Both
                     // values come from the host (`contextUsed` arrives with a completed turn's
                     // usage, so until then the pill is the model alone), and the pill is
                     // `Equatable`, so typing cannot lay it out again.
                     sessionRow: ComposerSessionRow(provider: model.modelProvider,
                                                    model: model.modelLabel,
                                                    used: model.contextUsed,
                                                    limit: model.contextMax,
                                                    isEnabled: model.selectedBot != nil,
                                                    onOpen: openModelPicker),
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
                     ),
                     onCommand: runCommand)
                // The card is its content: one row of text and controls, the hint under it. A
                // fixed resting height used to hand the slack to the field, which left the
                // paperclip and the send arrow hanging below the line of text they act on.
                // Measured, then inset. Padding first shrank the field to 592 pt and put its left
                // edge 24 pt inside every other column's.
                .frame(maxWidth: Geometry.conversationMeasure)
                .padding(.horizontal, Geometry.readingInset)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
        }
        // No canvas strip: the transcript runs under the capsule and fades into it. The pane owns
        // the fade and the height measurement, because the transcript needs both.
        .onAppear { wireVoice() }
        // A re-pair must not leave the controller minting tickets for the old host, and must not
        // leave a conversation open against one that no longer exists.
        .onChange(of: store.pairing) { _, _ in
            loop.stop()
            wireVoice()
        }
        // The draft belongs to the session that was open when recording started, so leaving it
        // drops the capture instead of typing into somebody else's message. The conversation goes
        // with it: its next utterance would otherwise be sent to a conversation nobody is watching.
        .onChange(of: model.selectedSessionID) { _, _ in
            voice.cancel()
            loop.noteConversationChanged()
        }
        // The host's completion, and the only thing that may make this window speak. The loop
        // checks that the turn is one it sent; an interrupted or foreign turn is ignored there.
        .onChange(of: model.lastCompletion) { _, completion in
            guard let completion else { return }
            loop.noteTurnCompleted(text: completion.text)
        }
        // Leaving the conversation closes the microphone. A capture that outlives its window keeps
        // the input device indicator on with nothing reading it.
        .onDisappear {
            voice.cancel()
            loop.stop()
        }
        .sheet(isPresented: $showingCommandHelp) {
            HermesCommandsHelpSheet { command in
                runCommand(command)
            }
            .hermesSheetChrome()
        }
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
        // The conversation's four moves, each the same call the manual controls make — no second
        // transport, no second credential.
        loop.wiring = VoiceLoopWiring(
            transcribe: { [weak store] audio, mimeType in
                guard let store else { throw MacVoiceFailure.notConfigured }
                return try await store.transcribeVoice(audio, mimeType: mimeType)
            },
            synthesize: { [weak store] text in
                guard let store else { throw MacVoiceFailure.notConfigured }
                return try await store.synthesizeVoice(text)
            },
            sendTurn: { [model, weak store] text in
                guard let store else { return }
                // Appended, never replacing: words typed while the microphone was open belong to
                // the same message.
                let existing = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                model.draft = existing.isEmpty ? text : existing + " " + text
                store.send()
            },
            interruptTurn: { [weak store] in store?.interrupt() },
            canRun: { [weak store, model] in
                guard let store else { return false }
                return store.canTranscribeVoice && model.selectedSessionID != nil
            }
        )
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

    /// The pill's one action: the same sheet the bot panel's Model row opens, for the bot this
    /// composer writes to. `store.openModel` is the Mac's only model door — nothing new is
    /// presented, and the sheet writes through `configureModel`, which refreshes `modelLabel` for
    /// the open bot, so the pill's own name changes as soon as the pick lands.
    private func openModelPicker() {
        guard let bot = model.selectedBot else { return }
        store.openModel(bot)
    }

    private func toggleVoice() {
        guard canRecordVoice else { return }
        if voice.isRecording {
            voice.stopAndTranscribe()
        } else {
            voice.startRecording()
        }
    }

    /// One tap starts the conversation; the same tap (or a spoken "stop") ends it.
    private func toggleVoiceMode() {
        if loop.isActive {
            loop.stop()
            return
        }
        guard canStartVoiceMode else { return }
        // Close the dictation recorder first: it holds its own capture on the same input, and a
        // loop started underneath it would be the second listener on one microphone.
        if voice.isRecording || voice.isBusy { voice.cancel() }
        loop.start()
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
                            // The type's own symbol, so a spreadsheet does not look like a PDF
                            // in the strip you check before sending.
                            Image(systemName: AttachmentKind(name: attachment.name).symbolName)
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
                        .help("Remove \(attachment.name)")
                        .accessibilityLabel("Remove \(attachment.name)")
                        .hermeyFocusQuiet()
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
    /// Native actions for the commands this window can perform itself; the rest stay in the field
    /// with their argument hint, for the host to run on send.
    private func runCommand(_ command: HermesCommand) {
        switch command.action {
        case .help:
            model.draft = ""
            showingCommandHelp = true
        case .newSession:
            model.draft = ""
            Task { await model.newSession() }
        case .resetConversation:
            model.draft = ""
            Task { await model.resetConversation() }
        case .compact:
            model.draft = ""
            Task { await model.compressNow() }
        case .model, .reasoning:
            model.draft = ""
            if let bot = model.selectedBot {
                store.openModel(bot)
            }
        case .memory, .status, .insertOnly:
            break
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
