import Combine
import Foundation

/// What the loop needs from the app around it.
///
/// Injected rather than imported so this file holds no host knowledge: the same controller runs in
/// the Mac window and on the phone, and the only platform difference is which object mints the
/// tickets. `unconfigured` throws instead of pretending, so a composer built without wiring fails
/// visibly rather than silently hearing nothing.
public struct VoiceLoopWiring {
    /// Upload one utterance; the host transcribes it (Groq through `POST /v1/voice/transcribe`).
    public var transcribe: (Data, String) async throws -> String
    /// Synthesize one sentence (ElevenLabs through `POST /v1/voice/synthesize`).
    public var synthesize: (String) async throws -> Data
    /// Put a finished transcript into the conversation as a turn. The shell owns this because the
    /// draft, the send button and the session are the shell's.
    public var sendTurn: (String) -> Void
    /// Stop the turn in flight — used when the user talks over a generation.
    public var interruptTurn: () -> Void
    /// False when there is no pairing to talk to, so the loop refuses to open the microphone.
    public var canRun: () -> Bool

    public init(transcribe: @escaping (Data, String) async throws -> String,
                synthesize: @escaping (String) async throws -> Data,
                sendTurn: @escaping (String) -> Void,
                interruptTurn: @escaping () -> Void,
                canRun: @escaping () -> Bool) {
        self.transcribe = transcribe
        self.synthesize = synthesize
        self.sendTurn = sendTurn
        self.interruptTurn = interruptTurn
        self.canRun = canRun
    }

    public static let unconfigured = VoiceLoopWiring(
        transcribe: { _, _ in throw VoiceLoopFailure.notConfigured },
        synthesize: { _ in throw VoiceLoopFailure.notConfigured },
        sendTurn: { _ in },
        interruptTurn: {},
        canRun: { false }
    )
}

/// Failures the loop reports. Sentences, not codes: this string is what the user reads.
public enum VoiceLoopFailure: LocalizedError, Equatable {
    case notConfigured
    case noHost
    case emptyTranscript
    case replyTimedOut

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Voice conversation is not configured in this window."
        case .noHost:
            return "Voice conversation needs a paired host. Pair this device and try again."
        case .emptyTranscript:
            return "The host heard nothing in that. Try again."
        case .replyTimedOut:
            return "No reply arrived, so the conversation stopped. Try again."
        }
    }
}

/// The hands-free conversation: speak, hear the answer, and be listening again — turn after turn,
/// until it is stopped.
///
/// The loop is a single chain per turn, mirroring Hermes Agent's chained voice mode
/// (`tools/voice_mode.py`) rather than a duplex audio model:
///
/// ```
/// capture ──utterance──▶ transcribe (Groq) ──text──▶ sendTurn ──▶ turn completes
///                                                                    │
///                        back to listening ◀──play── synthesize (ElevenLabs)
/// ```
///
/// Three decisions are worth knowing before changing anything here:
///
/// 1. **The microphone opens once per conversation, not once per turn.** That is what makes
///    barge-in possible: the same stream that endpoints an utterance is the one watching for speech
///    over a reply. It is also why every exit has to close it explicitly.
/// 2. **One owner.** There is exactly one `VoiceCaptureEngine` here, and `state.ownsMicrophone`
///    tells the composer's hold-to-talk control to refuse while this is open. Two listeners on one
///    input device is not a UI problem, it is a feedback loop.
/// 3. **Speaking follows a completed turn, never a guess.** `noteTurnCompleted` is the only door
///    into `.speaking`, and it is called from the host's own completion event.
@MainActor
public final class VoiceLoopController: ObservableObject {

    // MARK: Published state

    /// The state, read through a computed property so that **every** move goes through
    /// `transition(to:)`. A `@Published var` written from six places is how a loop ends up saying
    /// "Listening" with nothing in the log to say how it got there — which is the report this
    /// exists to answer.
    @Published private var currentState: VoiceLoopState = .off
    public var state: VoiceLoopState { currentState }
    /// The sentence to show when something failed. Cleared on the next start.
    @Published public private(set) var errorMessage: String?
    /// The most recent thing the host heard, so a mis-hearing is visible before the turn is spoken
    /// about. Never sent on its own: it is what already went to the host.
    @Published public private(set) var heardText: String?
    /// A non-error line: how the conversation ended ("you said stop"), or that the system took the
    /// microphone away.
    @Published public private(set) var notice: String?

    /// Dismiss the failure sentence. The conversation stays off; the toggle restarts it.
    public func clearError() {
        errorMessage = nil
        if state == .failed { transition(to: .off) }
    }

    /// Say why a tap did nothing, for the paths the shells reach *before* `start()` — no session
    /// yet, a control tapped while the conversation is still opening. Those used to `return` into
    /// silence, which is indistinguishable from a dead button.
    public func reportUnavailable(_ message: String) {
        guard !state.ownsMicrophone, state != .failed else { return }
        VoiceLog.note("blocked: \(message)")
        errorMessage = message
        // `.failed` is the only state the composer draws while the microphone is shut, and a
        // sentence nobody can see is the same as no sentence at all.
        transition(to: .failed)
    }

    /// The one door into a new state, and the one log line that says the loop moved.
    private func transition(to new: VoiceLoopState) {
        guard currentState != new else { return }
        VoiceLog.note("phase: \(currentState.rawValue) → \(new.rawValue)")
        currentState = new
    }

    // MARK: Wiring

    public var wiring: VoiceLoopWiring = .unconfigured {
        didSet { restartIfActive() }
    }

    /// How long a turn may take before the loop gives up. A turn that never completes would
    /// otherwise leave the microphone open with a UI that says "Thinking" forever; the host's own
    /// providers time out at 30 s, so this is only the backstop for a lost event.
    public static let replyTimeout: TimeInterval = 120
    /// How long after a reply finishes its own words are still treated as possible echo. Long
    /// enough to cover a sentence's tail, short enough that a real question a moment later is a
    /// question.
    public static let echoGuardSeconds: TimeInterval = 8

    private let capture: VoiceCaptureEngine
    private let player = VoiceReplyPlayer()

    private var pipelineTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// Bumped by every stop and every restart: an answer that lands afterwards belongs to a
    /// conversation that no longer exists and must not speak or send.
    private var generation = UUID()
    /// True between "the turn was sent" and "its reply arrived". A completion that arrives when
    /// this is false is either a turn the user interrupted or another window's; neither is spoken.
    private var awaitingReply = false
    private var lastSpokenText = ""
    private var lastSpokenAt: Date?
    /// A turn the user cut into. Its completion is still on its way, and it must be neither spoken
    /// nor mistaken for the answer to the sentence that replaced it.
    private var interruptedTurn = false
    /// The utterance spoken *over* an interrupted turn. It waits for that turn's completion so the
    /// two turns cannot cross: one reply in the transcript per thing he said.
    private var heldUtterance: VoiceUtterance?
    private var interruptWatchdog: Task<Void, Never>?
    /// How long a held utterance waits for the cut turn's completion before it is sent anyway. The
    /// host answers an interrupt as a normal completion, so this only covers a completion that is
    /// lost — waiting forever would be the microphone open with nothing listening for a turn.
    static let interruptGraceSeconds: TimeInterval = 4

    public init(config: VoiceVADConfig = VoiceVADConfig()) {
        capture = VoiceCaptureEngine(config: config)
        capture.onEvent = { [weak self] event in self?.handle(event) }
        #if os(iOS)
        capture.onInterruption = { [weak self] reason in
            guard let self else { return }
            guard reason != "__resume__" else {
                // The system handed the session back. Restarting capture is the honest response:
                // the indicator still says the conversation is live, so the microphone must be.
                if self.state.ownsMicrophone { self.start() }
                return
            }
            self.fail(reason)
        }
        #endif
    }

    // MARK: - Public surface

    /// True while this loop owns the microphone. The composer's hold-to-talk control reads this and
    /// stays disabled, so the two captures can never run at once.
    public var isActive: Bool { state.ownsMicrophone }

    public func toggle() {
        if state.ownsMicrophone { stop() } else { start() }
    }

    /// Open the microphone and start listening. Safe to call when `.off` or `.failed`; ignored while
    /// a conversation is already running, so a double tap cannot open two streams.
    ///
    /// Every step of this path writes a line to the `voice` category. The phone's report was "it
    /// does nothing" with an empty log, and that is the failure mode this method exists to make
    /// impossible: either the loop starts and says so, or it stops and says which step stopped it.
    public func start() {
        guard state == .off || state == .failed else {
            VoiceLog.note("start: ignored — already \(state.rawValue)")
            return
        }
        guard wiring.canRun() else {
            // Refuse before the microphone: a prompt the user grants and then a request that cannot
            // be made is worse than never starting.
            VoiceLog.note("start: refused — no host or no open conversation")
            fail(VoiceLoopFailure.noHost.errorDescription ?? "")
            return
        }
        VoiceLog.note("start: entered from \(state.rawValue)")
        errorMessage = nil
        notice = nil
        heardText = nil
        awaitingReply = false
        lastSpokenText = ""
        lastSpokenAt = nil
        let current = UUID()
        generation = current
        transition(to: .starting)
        capture.setPhase(.starting)
        capture.isPlaybackActive = false

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.capture.start()
                guard self.generation == current, self.state == .starting else {
                    // Stopped while the permission prompt was up. Worth a line: a start that is
                    // abandoned here looks exactly like one that never ran.
                    VoiceLog.note("start: abandoned — the loop was stopped before the microphone opened")
                    self.capture.stop()
                    return
                }
                VoiceLog.note("start: listening")
                self.capture.setPhase(.listening)
                self.transition(to: .listening)
            } catch {
                guard self.generation == current else {
                    VoiceLog.note("start: \(Self.describe(error)) — after the loop was stopped")
                    return
                }
                self.fail(Self.message(for: error))
            }
        }
    }

    /// The one teardown. Every exit — the toggle, leaving the bot, backgrounding, a failed request,
    /// the spoken stop phrase — comes through here, because a path that forgets to stop the capture
    /// leaves the microphone open with nothing reading it.
    ///
    /// `keepingSpeech` is true for the person's own stop and false for every exit they did not ask
    /// for. A tap on the control in the middle of a sentence is the ordinary way to end a thought on
    /// this loop, so the words are handed to the host before the microphone closes; backgrounding,
    /// changing conversation and failing all discard, because there is either no conversation left
    /// to send them to or no time to upload them.
    public func stop(keepingSpeech: Bool = true) {
        if state != .off { VoiceLog.note("stop: requested from \(state.rawValue)") }
        // Before the microphone closes: closing it is what throws the buffer away.
        let pending = keepingSpeech ? capture.finishCollecting() : nil
        generation = UUID()
        awaitingReply = false
        pipelineTask?.cancel()
        pipelineTask = nil
        watchdog?.cancel()
        watchdog = nil
        interruptWatchdog?.cancel()
        interruptWatchdog = nil
        interruptedTurn = false
        heldUtterance = nil
        // Order matters: nothing may produce a turn from the audio still in flight, and playback
        // must be silent before the session is released or the tail is cut mid-word.
        capture.stop()
        player.stopPlayback()
        capture.isPlaybackActive = false
        transition(to: .off)
        if let pending { sendAfterStop(pending) }
    }

    /// Called by the shell when the app leaves the foreground — and, on the Mac, when the window
    /// closes. Backgrounding must never leave a hot microphone: iOS suspends the process but the
    /// session indicator would still show a recording, and a resumed app would have a dead stream.
    public func noteBackgrounded() {
        guard state.ownsMicrophone else { return }
        stop(keepingSpeech: false)
        notice = "The conversation stopped when the app went to the background."
    }

    /// Called by the shell when the conversation moves to another bot or session: the utterance in
    /// flight belongs to the conversation that was on screen.
    public func noteConversationChanged() {
        guard state.ownsMicrophone else { return }
        // The utterance in flight was said to the conversation that is no longer on screen.
        stop(keepingSpeech: false)
    }

    /// The host finished a turn. Only a turn this loop sent gets spoken, and only if it has not been
    /// interrupted in the meantime.
    public func noteTurnCompleted(text: String) {
        if interruptedTurn {
            // The cut turn ended. Speak nothing: whatever it had produced was already answered by
            // the interruption, and the sentence he spoke over it is the question now.
            interruptedTurn = false
            interruptWatchdog?.cancel()
            interruptWatchdog = nil
            if let held = heldUtterance {
                heldUtterance = nil
                deliver(held)
            } else if state == .listening {
                capture.setPhase(.listening)
            }
            return
        }
        guard state == .thinking, awaitingReply else { return }
        awaitingReply = false
        watchdog?.cancel()
        watchdog = nil
        let spoken = VoicePolicy.speechText(from: text)
        guard !spoken.isEmpty else {
            // An interrupted or empty turn has nothing to say; go back to listening rather than
            // sitting in "Thinking" with the microphone open for no reason.
            returnToListening()
            return
        }
        speakReply(spoken)
    }

    // MARK: - Capture events

    private func handle(_ event: VoiceCaptureEvent) {
        switch event {
        case .bargeIn(let phase):
            handleBargeIn(phase)
        case .utterance(let utterance, let keep):
            guard keep else {
                // A cough, a door, a keyboard: the capture ran, but there were not enough voiced
                // blocks to be a turn. Resume normal listening rather than reporting a failure.
                if state == .listening { capture.setPhase(.listening) }
                return
            }
            if interruptedTurn {
                // The turn he just cut is still finishing. Hold the sentence and send it from that
                // turn's completion, so the transcript keeps one reply per thing said.
                heldUtterance = utterance
                startInterruptWatchdog()
                return
            }
            deliver(utterance)
        }
    }

    /// The user talked over the reply (or over the generation).
    ///
    /// Playback stops first and synchronously, before the utterance is allowed to become a turn:
    /// the engine has already been recording from the pre-roll buffer since the block that tripped,
    /// so the words are kept and the speaker is silent by the time they are transcribed.
    private func handleBargeIn(_ phase: VoiceBargePhase) {
        player.stopPlayback()
        capture.isPlaybackActive = false
        pipelineTask?.cancel()
        pipelineTask = nil
        if phase == .generation {
            // He is cutting into a turn that is still running: stop it before its reply can arrive
            // and be spoken over the new question. `interruptedTurn` is what stops that reply from
            // being spoken when its completion lands a moment later — the completion is the signal
            // that the cut turn is over, not an answer.
            interruptedTurn = true
            awaitingReply = false
            watchdog?.cancel()
            watchdog = nil
            wiring.interruptTurn()
        }
        // The visible state follows him, but the capture keeps the phase it had: it is mid-collection
        // and switching phase would discard the audio it is holding.
        transition(to: .listening)
    }

    /// One utterance → one turn.
    private func deliver(_ utterance: VoiceUtterance) {
        guard state.ownsMicrophone else {
            VoiceLog.note("turn: dropped — the loop no longer owns the microphone")
            return
        }
        guard state != .starting else {
            VoiceLog.note("turn: dropped — the loop is still starting")
            return
        }
        interruptedTurn = false
        setState(.thinking, engine: .thinking)
        transcribe(utterance, how: .turn)
    }

    /// The sentence he ended with the control.
    ///
    /// The microphone is already closed and nothing is spoken back — he stopped the conversation,
    /// so a reply read aloud to a room he has left would be absurd. What he said still goes to the
    /// host, because the alternative is that tapping stop quietly deletes the sentence he just
    /// spoke. That path is also how "stop" itself gets recognised: it is a transcript like any
    /// other, and it is tested for before anything is sent.
    private func sendAfterStop(_ utterance: VoiceUtterance) {
        guard state == .off else { return }
        VoiceLog.note("turn: ended by the control — sending \(String(format: "%.2f", utterance.voicedDuration)) s of it")
        transcribe(utterance, how: .sendOnly)
    }

    /// The two shapes a transcription takes.
    private enum Delivery: Equatable {
        /// The loop is live: the words become a turn and its reply is spoken.
        case turn
        /// The loop was stopped with the words still in hand: they become a turn, and nothing is
        /// spoken back, because there is nobody listening for it.
        case sendOnly
    }

    /// One utterance → text → a turn (or nothing at all).
    ///
    /// **Every** transcript passes through here, whichever way the utterance ended — a pause, the
    /// ceiling, or a tap on the control. That is deliberate: the stop phrase can only be recognised
    /// from a transcript, so a build in which the stop test only ran on one of those paths could not
    /// hear "stop" at all. In 0.1.692 it ran on none of them, because no utterance ever ended.
    private func transcribe(_ utterance: VoiceUtterance, how: Delivery) {
        let current = generation
        VoiceLog.note("transcribe: \(utterance.wav.count) bytes, \(String(format: "%.2f", utterance.duration)) s → host")

        Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.wiring.transcribe(utterance.wav, "audio/wav")
                guard self.isStillDelivering(how, generation: current) else {
                    VoiceLog.note("transcribe: answered after the loop moved on — dropped")
                    return
                }
                let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                VoiceLog.note("transcribe: answered with \(text.count) characters")

                // The stop phrase, first: it is the one thing he says that must never become a
                // turn, and the only thing that has to work whatever path produced the text.
                if VoicePolicy.isStopPhrase(text) {
                    VoiceLog.note("stop phrase: heard \"\(text)\"")
                    self.stop(keepingSpeech: false)
                    self.notice = "Said “\(text.lowercased())” — the conversation ended."
                    return
                }

                // A silent room must not become a turn: Whisper answers silence with a phrase of
                // its own invention. Dropping it here is what keeps the loop from talking to itself.
                if VoicePolicy.isHallucination(text) {
                    VoiceLog.note("transcribe: dropped as silence — “\(text)”")
                    self.returnToListening(how)
                    return
                }
                // Our own reply, back through the microphone. Only within a few seconds of the
                // reply — a real question a moment later is a question.
                if let at = self.lastSpokenAt,
                   Date().timeIntervalSince(at) < Self.echoGuardSeconds,
                   VoicePolicy.isSelfEcho(text, spoken: self.lastSpokenText) {
                    VoiceLog.note("transcribe: dropped as our own reply coming back")
                    self.returnToListening(how)
                    return
                }

                self.heardText = text
                switch how {
                case .turn:
                    self.awaitingReply = true
                    VoiceLog.note("turn: sent — “\(text)”")
                    self.wiring.sendTurn(text)
                    self.startReplyWatchdog()
                case .sendOnly:
                    // No watchdog and no `awaitingReply`: the loop is off, so the reply arrives as
                    // text in the conversation rather than being spoken into an empty room.
                    VoiceLog.note("turn: sent after stop — “\(text)”")
                    self.wiring.sendTurn(text)
                }
            } catch {
                guard self.generation == current else { return }
                switch how {
                case .turn:
                    self.fail(Self.message(for: error))
                case .sendOnly:
                    // A failed upload cannot fail a conversation that has already ended; it is a
                    // sentence that did not arrive, and it says so rather than pretending.
                    VoiceLog.note("transcribe: failed after stop — \(Self.describe(error))")
                    self.errorMessage = Self.message(for: error)
                }
            }
        }
    }

    /// Is the answer still wanted? A turn must still be in flight; a sentence sent from a stopped
    /// loop must still be the last thing that happened.
    private func isStillDelivering(_ how: Delivery, generation: UUID) -> Bool {
        guard self.generation == generation else { return false }
        switch how {
        case .turn: return state == .thinking
        case .sendOnly: return state == .off
        }
    }

    // MARK: - Speaking

    /// Synthesize and play, one sentence at a time so the first words arrive while the rest is still
    /// being made. Sentence boundaries come from `VoiceSentenceChunker`, the app-side twin of the
    /// host's `SentenceChunker`.
    private func speakReply(_ spoken: String) {
        lastSpokenText = spoken
        lastSpokenAt = Date()
        setState(.speaking, engine: .speaking)
        capture.isPlaybackActive = true
        let current = generation

        pipelineTask = Task { [weak self] in
            guard let self else { return }
            var chunker = VoiceSentenceChunker()
            var sentences = chunker.feed(spoken)
            sentences += chunker.flush()
            for sentence in sentences {
                if Task.isCancelled || self.generation != current { return }
                do {
                    let audio = try await self.wiring.synthesize(sentence)
                    if Task.isCancelled || self.generation != current { return }
                    try await self.player.play(audio, onStart: {}, onFinish: {})
                } catch is CancellationError {
                    return
                } catch {
                    guard self.generation == current else { return }
                    self.fail(Self.message(for: error))
                    return
                }
            }
            guard !Task.isCancelled, self.generation == current else { return }
            self.capture.isPlaybackActive = false
            self.returnToListening()
        }
    }

    // MARK: - Transitions

    private func returnToListening() {
        guard state.ownsMicrophone else { return }
        capture.isPlaybackActive = false
        setState(.listening, engine: .listening)
    }

    /// The same, for a transcript that may have come back after the loop was stopped: there is
    /// nothing to return to, and arming the capture would be a microphone the person just closed.
    private func returnToListening(_ how: Delivery) {
        guard how == .turn else { return }
        returnToListening()
    }

    /// Publish the state, and optionally move the capture with it.
    ///
    /// The two are separate because a barge-in changes what the *user* sees without changing what
    /// the capture is doing — it is still collecting the interruption it just detected.
    private func setState(_ new: VoiceLoopState, engine: VoiceLoopState? = nil) {
        transition(to: new)
        // Still moved when the visible state did not change: `capture.setPhase` is what re-arms the
        // endpointing gate for the next utterance.
        if let engine { capture.setPhase(engine) }
    }

    /// The cut turn's completion never arrived: send the held sentence anyway rather than leaving
    /// it in a variable only a later event could read.
    private func startInterruptWatchdog() {
        interruptWatchdog?.cancel()
        let current = generation
        interruptWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.interruptGraceSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == current,
                  self.interruptedTurn, let held = self.heldUtterance else { return }
            self.heldUtterance = nil
            self.interruptedTurn = false
            self.deliver(held)
        }
    }

    private func startReplyWatchdog() {
        watchdog?.cancel()
        let current = generation
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.replyTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == current, self.state == .thinking else { return }
            self.fail(VoiceLoopFailure.replyTimedOut.errorDescription ?? "")
        }
    }

    /// The one failure path. It stops everything first: a failed request must never leave the
    /// microphone running, because the UI has already stopped promising an answer.
    ///
    /// The message is logged *before* the teardown, so the log reads in the order the failure
    /// happened rather than after the stop it triggered.
    private func fail(_ message: String) {
        VoiceLog.note("failed: \(message)")
        stop(keepingSpeech: false)
        errorMessage = message
        transition(to: .failed)
    }

    private func restartIfActive() {
        guard state.ownsMicrophone else { return }
        stop(keepingSpeech: false)
        start()
    }

    /// The failure in the log's words: the named case for a microphone that would not open, the
    /// sentence the user is shown for everything else.
    private static func describe(_ error: Error) -> String {
        if let failure = error as? VoiceCaptureEngine.StartFailure {
            return "StartFailure.\(failure.name) — \(failure.errorDescription ?? "")"
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? VoiceCaptureEngine.StartFailure {
            return failure.errorDescription ?? failure.name
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
