import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// One finished utterance, ready to upload.
public struct VoiceUtterance: Sendable, Equatable {
    /// 16 kHz mono 16-bit PCM in a RIFF/WAVE container — the container the bridge lists as
    /// `audio/wav` and the format Whisper is trained on.
    public let wav: Data
    public let duration: TimeInterval
    /// How much of that was actually speech, above the trigger. A blip below the minimum never
    /// reaches here; this is carried so the caller can log a turn it would rather not send.
    public let voicedDuration: TimeInterval
}

/// What the capture hands back.
public enum VoiceCaptureEvent: Sendable, Equatable {
    /// Speech was detected while the reply was playing or the turn was generating. The caller must
    /// stop playback *now* — before it does anything else with the utterance.
    case bargeIn(VoiceBargePhase)
    /// An utterance ended. `keep` is false for a blip that was too short to be a turn, which is how
    /// a cough stops being a message.
    case utterance(VoiceUtterance, keep: Bool)
}

/// RIFF/WAVE, 16-bit mono.
///
/// The host takes a container, not samples (`POST /v1/voice/transcribe` sniffs the mime type), so
/// the device has to write one. A WAV is 44 bytes of header and no encoder, which is why this is a
/// pure function instead of a file the recorder leaves behind: nothing to clean up, nothing to leak,
/// and it can be checked in a test.
public enum VoiceWAV {
    public static func encode(samples: [Int16], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataBytes = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataBytes)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                       // PCM chunk size
        append(UInt16(1))                        // format: PCM
        append(UInt16(1))                        // channels
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerSample))  // byte rate
        append(UInt16(bytesPerSample))           // block align
        append(UInt16(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        for sample in samples { append(UInt16(bitPattern: sample)) }
        return data
    }
}

#if canImport(AVFoundation)

/// The microphone, the endpointing gate and the barge detector — one owner for the whole loop.
///
/// Shape, and why it is one object rather than a recorder plus a monitor:
///
/// * The microphone opens once, when the loop starts, and closes when it stops. Between those two
///   moments the *phase* changes, not the stream: `listening` endpoints an utterance, `thinking`
///   and `speaking` watch for speech over the top of the turn. This is `full_duplex_listen` from
///   `tools/voice_mode.py`, which arms one listener for the entire turn instead of opening the mic
///   per turn — and it is what makes barge-in possible at all.
/// * Audio is resampled to 16 kHz mono and measured as int16 RMS, so every threshold in
///   `VoiceVADConfig` means the same thing here as it does on the host.
/// * The tap runs on a realtime thread. Everything that could allocate or hop actors is kept out of
///   it: the per-block work is arithmetic over a fixed buffer, and callbacks are forwarded to the
///   main actor as a `Task`.
public final class VoiceCaptureEngine {

    public enum StartFailure: LocalizedError {
        case microphoneDenied
        case descriptionMissing
        case noInputDevice
        /// The audio session itself refused: the one failure that never reached the microphone,
        /// and the only place an OSStatus from iOS survives for the person reading the log.
        case sessionFailed(String)
        case engineFailed(String)

        /// The name the log carries. A sentence is what the person reads; a name is what makes
        /// "which step stopped it" answerable from a pasted log, and the two must not drift.
        public var name: String {
            switch self {
            case .microphoneDenied: return "microphoneDenied"
            case .descriptionMissing: return "descriptionMissing"
            case .noInputDevice: return "noInputDevice"
            case .sessionFailed: return "sessionFailed"
            case .engineFailed: return "engineFailed"
            }
        }

        public var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access is denied. Allow Hermey in Settings ▸ Privacy & Security ▸ Microphone, then start the conversation again."
            case .descriptionMissing:
                return "The microphone usage description is missing from the app configuration."
            case .noInputDevice:
                return "No microphone is available. Connect one and start the conversation again."
            case .sessionFailed(let why):
                return "The audio session could not be started: \(why)"
            case .engineFailed(let why):
                return "The microphone could not start: \(why)"
            }
        }
    }

    /// On the main actor: called once per event. `bargeIn` arrives on the block where the VAD
    /// tripped, which is why playback can stop within ~30 ms of the first word.
    public var onEvent: (@MainActor (VoiceCaptureEvent) -> Void)?
    /// Set by the controller from its own state. Read on the audio thread, so it is guarded.
    public var isPlaybackActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return playing }
        set { lock.lock(); playing = newValue; lock.unlock() }
    }

    private let config: VoiceVADConfig
    private let lock = NSLock()
    private var phase: VoiceLoopState = .off
    private var playing = false

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var pending: [Float] = []
    private var preRoll: [[Int16]] = []

    // Per-collection state. Only touched on the audio thread, guarded by the same lock.
    private var detector = VoiceBargeDetector()
    private var gate = VoiceUtteranceGate()
    private var collected: [Int16] = []
    private var collecting = false
    /// True when the collection that is running started from a barge-in rather than from the
    /// listening gate: it is speech by definition, so a manual stop must not discard it as a blip.
    private var bargedIn = false
    private var quietRun = 0
    private var voicedBlocks = 0
    private var blockCount = 0
    private var isRunning = false
    /// The start attempt that owns this engine. `start()` is async (the permission prompt is an
    /// await), so a stop followed by a new start can run two attempts against one engine; every
    /// resumption past an await compares this token, and `stop()` invalidates it. Without it an
    /// abandoned attempt could install a tap or tear down the microphone of the attempt that
    /// replaced it — the UI says Listening over a dead stream.
    private var startEpoch = UUID()
    /// Diagnostics only: was a buffer ever handed to us, and did the first speech start already
    /// make it into the log. Reset by every start, so a second conversation logs its own firsts.
    private var sawFirstRawBuffer = false
    private var loggedConvertFailure = false
    private var loggedFirstSpeech = false
    /// Diagnostics only: how many blocks have reported their level. Capped by
    /// `config.diagnosticBlockCount`, reset by every start, so it is five lines per conversation.
    private var loggedBlockLevels = 0

    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    /// Fired when the system takes the audio session away (a call, Siri, another app). The
    /// controller tears the loop down: a microphone that the OS has muted while the UI says
    /// "Listening" is the exact failure this exists to prevent.
    public var onInterruption: (@MainActor (String) -> Void)?
    #endif

    public init(config: VoiceVADConfig = VoiceVADConfig()) {
        #if os(iOS)
        // A phone's input is not the Mac's built-in microphone: the floor it reports for a quiet
        // room is far lower, and the desktop constants made the listening trigger a fixed 600 that
        // such a stream never reaches. iOS gets the same *rules* against its own measured floor.
        self.config = config.tunedForQuietInput()
        #else
        self.config = config
        #endif
    }

    deinit {
        #if os(iOS)
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        #endif
        if isRunning { teardown() }
    }

    // MARK: - Phase

    /// Move the loop's phase. `listening` arms the endpointing gate; `thinking` and `speaking` arm
    /// the barge detector only (a reply in progress is not the place to start a new utterance —
    /// unless it is interrupted, and then the barge handler starts one).
    public func setPhase(_ new: VoiceLoopState) {
        lock.lock()
        phase = new
        if new == .off || new == .starting {
            // A new conversation learns the room again; a phase change inside one keeps it.
            detector = VoiceBargeDetector(config: config)
        } else {
            detector.resetWindow()
        }
        gate.reset()
        collecting = false
        bargedIn = false
        collected.removeAll()
        quietRun = 0
        voicedBlocks = 0
        pending.removeAll()
        preRoll.removeAll()
        blockCount = 0
        lock.unlock()
    }

    // MARK: - Lifecycle

    /// Ask for the microphone, then start reading it. Returns once the stream is running, or throws
    /// the sentence to show. Idempotent: a second call while running does nothing.
    @MainActor
    public func start() async throws {
        VoiceLog.note("start: entered")
        guard !isRunning else {
            VoiceLog.note("start: already running")
            return
        }
        let epoch = UUID()
        startEpoch = epoch
        // macOS terminates the process on first capture input without this string, and iOS only
        // shows the prompt when the key is present — so check it before touching AVFoundation.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String != nil else {
            throw failed(.descriptionMissing)
        }
        guard await Self.requestMicrophonePermission() else {
            throw failed(.microphoneDenied)
        }
        guard startEpoch == epoch else {
            // The permission prompt was up when the loop was stopped, or a newer start took over.
            // Either way this attempt owns nothing: it must not activate, install a tap, or stop
            // the capture that does.
            VoiceLog.note("start: abandoned at the permission boundary")
            return
        }
        try VoiceAudioSession.activate()
        guard startEpoch == epoch else {
            // A stop or a newer start happened during activation. A newer attempt owns the
            // session now; if there is none, `stop()` has already released it.
            VoiceLog.note("start: abandoned after activating the session")
            return
        }
        try beginStreaming()
        VoiceLog.note("start: microphone open")
    }

    /// Log the named failure and hand it back, so the throw and the log cannot drift apart: every
    /// `throw` in the start path goes through here, which is what makes a silent failure impossible.
    private func failed(_ failure: StartFailure) -> StartFailure {
        VoiceLog.note("start failed: \(failure.name) — \(failure.errorDescription ?? "")")
        return failure
    }

    /// A log line from the audio thread. Hopped like every other callback the tap makes, because
    /// nothing in the realtime block may block or allocate its way into a sink.
    private func logFromAudioThread(_ message: String) {
        Task { @MainActor in VoiceLog.note(message) }
    }

    /// Close the microphone and release the audio session. Safe to call in any state, from any
    /// exit: toggle-off, leaving the bot, backgrounding, a failed request.
    @MainActor
    public func stop() {
        // Invalidate any start still sitting in the permission prompt before closing: its
        // resumption must see that it no longer owns this engine.
        startEpoch = UUID()
        teardown()
        VoiceAudioSession.deactivate()
    }

    /// Hand back the sentence still being collected, if it is worth sending.
    ///
    /// Ending a thought with a tap on the control is the ordinary way to use this loop — it is
    /// easier than waiting out a pause, and on 0.1.692 it was the only thing that worked, except
    /// that it threw away everything he had said. Whatever was voiced up to the tap is returned
    /// here and still becomes a turn; only a collection with too little voice in it is discarded,
    /// by the same rule that makes a cough not a turn.
    ///
    /// Called *before* `stop()` closes the microphone, because closing it is what drops the buffer.
    @MainActor
    public func finishCollecting() -> VoiceUtterance? {
        lock.lock()
        defer { lock.unlock() }
        guard collecting else { return nil }
        let audio = collected
        collected = []
        collecting = false
        gate.reset()
        let voiced = Double(voicedBlocks) * config.blockSeconds
        // An interrupt is speech even when it is only 240 ms long; a listening collection has to
        // clear the same minimum a cough does.
        let keep = bargedIn || voicedBlocks >= config.minimumUtteranceBlocks
        voicedBlocks = 0
        bargedIn = false
        logFromAudioThread("endpoint: manual, \(String(format: "%.2f", voiced)) s voiced, keep \(keep)")
        guard keep, !audio.isEmpty else { return nil }
        return VoiceUtterance(wav: VoiceWAV.encode(samples: audio, sampleRate: Int(config.sampleRate)),
                              duration: Double(audio.count) / config.sampleRate,
                              voicedDuration: voiced)
    }

    private func beginStreaming() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        VoiceLog.note("format: input \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw failed(.noInputDevice)
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: config.sampleRate,
                                        channels: 1,
                                        interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw failed(.engineFailed("the input format could not be converted"))
        }
        self.targetFormat = target
        self.converter = converter
        lock.lock()
        sawFirstRawBuffer = false
        loggedConvertFailure = false
        loggedFirstSpeech = false
        loggedBlockLevels = 0
        lock.unlock()

        // 30 ms at the hardware rate: one block per VAD step, so no second buffer to lose.
        let blockFrames = AVAudioFrameCount(max(256, format.sampleRate * config.blockSeconds))
        input.installTap(onBus: 0, bufferSize: blockFrames, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        VoiceLog.note("tap: installed on input bus 0, up to \(blockFrames) frames per callback")
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw failed(.engineFailed(error.localizedDescription))
        }
        lock.lock()
        isRunning = true
        lock.unlock()
        VoiceLog.note("engine: running")
        #if os(iOS)
        observeInterruptions()
        #endif
    }

    /// Deliberately not `deinit`-only: every exit path calls this, and it must be safe twice.
    private func teardown() {
        lock.lock()
        let wasRunning = isRunning
        isRunning = false
        phase = .off
        collecting = false
        bargedIn = false
        collected.removeAll()
        preRoll.removeAll()
        pending.removeAll()
        gate.reset()
        lock.unlock()
        guard wasRunning else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
        targetFormat = nil
        VoiceLog.note("stop: microphone closed")
        #if os(iOS)
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        #endif
    }

    #if os(iOS)
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .began:
                    VoiceLog.note("interruption: began (a call or another app took the microphone)")
                    self.onInterruption?("A call or another app took the microphone. The conversation stopped.")
                case .ended:
                    // `.shouldResume` is the system saying the interruption is over; restarting
                    // capture is the honest response, because the loop's UI still says listening.
                    let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    if options.contains(.shouldResume) {
                        self.onInterruption?("__resume__")
                    }
                @unknown default:
                    self.onInterruption?("Audio was interrupted. The conversation stopped.")
                }
            }
        }
    }
    #endif

    // MARK: - Audio thread

    /// Resample to 16 kHz, cut into fixed blocks, and run the per-block state machine.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        noteFirstBuffer(buffer)
        guard let target = targetFormat, let converter, let converted = convert(buffer, to: target, with: converter) else {
            noteConvertFailure(buffer)
            return
        }
        guard let channel = converted.floatChannelData?[0] else { return }
        let count = Int(converted.frameLength)
        guard count > 0 else { return }

        lock.lock()
        let running = isRunning
        lock.unlock()
        guard running else { return }

        pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        let blockFrames = config.framesPerBlock
        while pending.count >= blockFrames {
            let slice = Array(pending[0..<blockFrames])
            pending.removeFirst(blockFrames)
            process(block: slice)
        }
    }

    /// Once per start: proof that the tap is actually firing.
    ///
    /// This is the line that separates "the microphone never opened" from "the microphone is open
    /// and nothing is coming out of it", and those two have different fixes.
    private func noteFirstBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let first = !sawFirstRawBuffer
        if first { sawFirstRawBuffer = true }
        lock.unlock()
        guard first else { return }
        logFromAudioThread("first buffer: \(buffer.frameLength) frames at \(Int(buffer.format.sampleRate)) Hz, \(buffer.format.channelCount) ch")
    }

    /// A tap that fires and a conversion that always fails reads identically from the outside —
    /// silence. Say it once, with the format the conversion refused.
    private func noteConvertFailure(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let first = !loggedConvertFailure
        if first { loggedConvertFailure = true }
        lock.unlock()
        guard first else { return }
        logFromAudioThread("first buffer: could not convert \(buffer.frameLength) frames at \(Int(buffer.format.sampleRate)) Hz")
    }

    /// The first blocks of a stream, measured. Five lines, once per start.
    ///
    /// This is the line that separates the two failures that both read as "nothing happens": a
    /// stream of zeros (0 RMS, 0 peak) is a conversion or a route with no microphone behind it, and
    /// a stream of 1–50 is a real but quiet stream whose trigger was written for a desktop
    /// microphone. Nothing else in the log can tell those apart, which is why it is measured before
    /// any threshold is compared against it.
    ///
    /// Called with the lock held, like the rest of `process(block:)`; the log call hops to the main
    /// actor so the audio thread never touches a sink.
    private func noteBlockLevel(rms: Double, peak: Int) {
        guard loggedBlockLevels < config.diagnosticBlockCount else { return }
        loggedBlockLevels += 1
        logFromAudioThread("vad: block \(loggedBlockLevels) rms \(Int(rms)) peak \(peak)")
    }

    private func convert(_ buffer: AVAudioPCMBuffer,
                         to target: AVAudioFormat,
                         with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, statusPointer in
            if supplied {
                statusPointer.pointee = .noDataNow
                return nil
            }
            supplied = true
            statusPointer.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    private func process(block: [Float]) {
        // int16 RMS, the domain every threshold in `VoiceVADConfig` is written in.
        var samples = [Int16](repeating: 0, count: block.count)
        var sum = 0.0
        var peak = 0
        for index in block.indices {
            let clamped = min(1, max(-1, block[index]))
            let sample = Int16(clamped * 32_767)
            samples[index] = sample
            sum += Double(sample) * Double(sample)
            let magnitude = Swift.abs(Int(sample))
            if magnitude > peak { peak = magnitude }
        }
        let rms = (sum / Double(block.count)).squareRoot()

        var events: [VoiceCaptureEvent] = []

        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        blockCount += 1
        noteBlockLevel(rms: rms, peak: peak)
        preRoll.append(samples)
        if preRoll.count > config.preRollBlocks { preRoll.removeFirst() }

        switch phase {
        case .listening:
            // The trigger is unchanged, on purpose: it follows the detector's floor and it is the
            // one part that already fires (`max(floor × 3, 120)` on the phone). The end-of-speech
            // boundary is not passed in any more — the gate derives it from the speech this
            // utterance has produced, so it can never sit above the voice it is meant to end.
            let trigger = config.listeningLevels(floor: detector.quietFloor).trigger
            // Read before the block is judged: a quiet block does not change the voiced average,
            // so this is the level that ended the collection even though `finish()` has reset the
            // average by the time the decision comes back.
            let level = Int(gate.endpointLevel)
            let decision = gate.feed(rms: rms, trigger: trigger)
            switch decision {
            case .started:
                // Seed with the last 300 ms, which already contains this block, so the syllable
                // that tripped the gate is not clipped. Nothing is appended a second time.
                collected = preRoll.suffix(min(10, preRoll.count)).flatMap { $0 }
                collecting = true
                voicedBlocks = 1
                if !loggedFirstSpeech {
                    loggedFirstSpeech = true
                    logFromAudioThread("vad: speech started, rms \(Int(rms)), floor \(Int(gate.floorLevel)), silence \(Int(gate.endpointLevel))")
                }
            case .idle:
                if collecting {
                    collected += samples
                    if rms >= trigger { voicedBlocks += 1 }
                }
            case .ended(let keep, let reason):
                if collecting { collected += samples }
                let audio = collected
                collected = []
                collecting = false
                let voiced = Double(voicedBlocks) * config.blockSeconds
                voicedBlocks = 0
                let duration = Double(audio.count) / config.sampleRate
                // The ceiling names itself: an utterance that ran out of clock and one that ended
                // on a pause read identically otherwise, and they are different events.
                let why = reason == .ceiling ? "ceiling \(String(format: "%.2f", duration))" : String(format: "%.2f", duration)
                logFromAudioThread("endpoint: \(why) s, \(String(format: "%.2f", voiced)) s voiced, keep \(keep), silence \(level)")
                events.append(.utterance(VoiceUtterance(wav: VoiceWAV.encode(samples: audio, sampleRate: Int(config.sampleRate)),
                                                        duration: duration,
                                                        voicedDuration: voiced),
                                         keep: keep))
            }

        case .thinking, .speaking:
            let trip = detector.feed(rms: rms, playing: phase == .speaking)
            if let trip, !collecting {
                // Trip: report it immediately so playback stops before anything else happens, then
                // keep rolling from the pre-roll buffer — the words that tripped the detector are
                // already in it, so the utterance starts at the first syllable, not at the trip.
                //
                // Once only: the detector latches at the trip, and `!collecting` is the second
                // guard. Re-seeding here on a later block would cut the question back to its last
                // 1.2 s every 30 ms, which is what a barge that re-trips 33 times a second sounds
                // like from the other side.
                collected = preRoll.flatMap { $0 }
                collecting = true
                bargedIn = true
                quietRun = 0
                voicedBlocks = config.tripBlocks
                logFromAudioThread("vad: speech over \(trip.rawValue), rms \(Int(rms)) — barge-in")
                events.append(.bargeIn(trip))
            } else if collecting {
                collected += samples
                // The same measured floor the listening phase endpoints against: a stream that is
                // quiet but real must not be cut off by the desktop microphone's 200.
                let levels = config.listeningLevels(floor: detector.quietFloor)
                quietRun = rms < levels.silence ? quietRun + 1 : 0
                if quietRun >= config.endpointSilenceBlocks || collected.count / config.framesPerBlock >= config.maximumUtteranceBlocks {
                    let audio = collected
                    collected = []
                    collecting = false
                    let voiced = Double(voicedBlocks) * config.blockSeconds
                    let keep = voicedBlocks >= config.minimumUtteranceBlocks
                    voicedBlocks = 0
                    let wasBarge = bargedIn
                    bargedIn = false
                    logFromAudioThread("endpoint: \(String(format: "%.2f", Double(audio.count) / config.sampleRate)) s after \(wasBarge ? "barge-in" : "a turn"), \(String(format: "%.2f", voiced)) s voiced, keep \(keep), silence \(Int(levels.silence))")
                    events.append(.utterance(VoiceUtterance(wav: VoiceWAV.encode(samples: audio, sampleRate: Int(config.sampleRate)),
                                                            duration: Double(audio.count) / config.sampleRate,
                                                            voicedDuration: voiced),
                                             keep: keep))
                }
            }

        case .off, .starting, .failed:
            break
        }

        for event in events {
            let callback = onEvent
            Task { @MainActor in callback?(event) }
        }
    }

    // MARK: - Permission

    private static func requestMicrophonePermission() async -> Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let before = session.recordPermission
        VoiceLog.note("permission: \(word(before))")
        switch before {
        case .granted: return true
        case .denied: return false
        default:
            let granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
            VoiceLog.note("permission: prompt answered \(granted ? "granted" : "denied")")
            return granted
        }
        #else
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        VoiceLog.note("permission: \(word(status))")
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            VoiceLog.note("permission: prompt answered \(granted ? "granted" : "denied")")
            return granted
        default:
            return false
        }
        #endif
    }

    #if os(iOS)
    /// The permission state in the log's words. `undetermined` is the one that matters: it is the
    /// prompt, and a start that stops there is a prompt the user dismissed, not a dead microphone.
    private static func word(_ status: AVAudioSession.RecordPermission) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        default: return "undetermined"
        }
    }
    #else
    private static func word(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .denied, .restricted: return "denied"
        default: return "undetermined"
        }
    }
    #endif
}

/// The session underneath the loop, on the platform that has one.
///
/// iOS: `.playAndRecord` in the **`.spokenAudio`** mode — the one the dictation recorder beside this
/// loop uses on the same phone, where the microphone is proven to work
/// (`Apps/HermesMobile/Views/VoiceController.swift`).
///
/// It used to be `.voiceChat`, for the system echo canceller the loop believed it needed because
/// the microphone stays open while the speaker talks. `.voiceChat` is not a hint: it engages the
/// system voice-processing input (AEC/AGC) for the whole session, and a tap on `AVAudioEngine`'s
/// input node on that route is a well-known way to receive a processed — or silent — stream. The
/// owner's log was exactly that shape: tap installed, buffers arriving at 48 kHz, no conversion
/// failure, and no VAD trigger for twenty seconds of speech.
///
/// AEC is not what keeps the loop from answering itself: the playback trigger
/// (`playbackMinimumTrigger`, 1 500 RMS — far above speaker bleed) and `VoicePolicy.isSelfEcho`
/// do, and macOS has run with neither `AVAudioSession` nor AEC since the loop shipped. This makes
/// the phone behave like the Mac, which is the configuration known to work.
///
/// If speaker bleed ever does turn into self-turns while a reply is playing, the fix is a
/// `.voiceChat` re-entry *for the speaking phase only*, here, in this one function — never a
/// second place that sets a category.
enum VoiceAudioSession {
    /// The session mode, in one place and named, because the log has to say which one was used.
    #if os(iOS)
    static let mode: AVAudioSession.Mode = .spokenAudio
    static var modeName: String { "spokenAudio" }
    #endif

    static func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: mode,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            // 30 ms is the block the VAD reasons in; asking the hardware for it avoids a second copy.
            try? session.setPreferredIOBufferDuration(0.03)
            try session.setActive(true)
        } catch {
            // The one failure that never reaches the microphone, so the OSStatus is the whole
            // explanation: keep it in the sentence and in the log rather than reporting a
            // generic "could not start".
            let code = (error as NSError).code
            let why = "\(error.localizedDescription) [OSStatus \(code)]"
            VoiceLog.note("session: activate failed — \(why)")
            throw VoiceCaptureEngine.StartFailure.sessionFailed(why)
        }
        // The mode is in the line: a log that says only "active" cannot answer which of the two
        // sessions this build used, and that is the whole question this change is about.
        VoiceLog.note("session: active — playAndRecord/\(modeName), speaker by default")
        #else
        // Nothing to activate: macOS has no `AVAudioSession`. No mode is set, so nothing about the
        // Mac's input route changes here — the category, the mode and the AEC all do not exist.
        VoiceLog.note("session: macOS has no audio session to activate")
        #endif
    }

    static func deactivate() {
        #if os(iOS)
        // `.notifyOthersOnDeactivation` is what lets the user's music come back after the loop
        // ends; without it the session stays claimed until the app is suspended.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        VoiceLog.note("session: released")
        #endif
    }
}

/// Plays the synthesized reply, and stops the instant it is told to.
///
/// `AVAudioPlayer` rather than a streaming player because the host returns one mp3 per request and
/// `stop()` is immediate and synchronous — which is the requirement: barge-in has to be heard as an
/// interruption, not as a fade.
@MainActor
public final class VoiceReplyPlayer {
    private var player: AVAudioPlayer?

    public init() {}

    public var isPlaying: Bool { player?.isPlaying ?? false }

    /// Play `audio` and return when it finishes (or when playback is stopped, or the task is
    /// cancelled). Throws only when the audio cannot be decoded at all.
    public func play(_ audio: Data, onStart: () -> Void, onFinish: () -> Void) async throws {
        let player = try AVAudioPlayer(data: audio)
        guard player.prepareToPlay() else { throw PlaybackFailure.undecodable }
        self.player = player
        guard player.play() else { throw PlaybackFailure.undecodable }
        onStart()
        while player.isPlaying {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        player.stop()
        if self.player === player { self.player = nil }
        onFinish()
    }

    /// Stops whatever is playing. Synchronous, so the caller can sequence it before anything else.
    public func stopPlayback() {
        player?.stop()
        player = nil
    }

    public enum PlaybackFailure: LocalizedError {
        case undecodable
        public var errorDescription: String? {
            "The reply's audio could not be played."
        }
    }
}

#endif
