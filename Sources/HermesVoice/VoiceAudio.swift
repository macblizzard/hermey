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
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access is denied. Allow Hermey in Settings ▸ Privacy & Security ▸ Microphone, then start the conversation again."
            case .descriptionMissing:
                return "The microphone usage description is missing from the app configuration."
            case .noInputDevice:
                return "No microphone is available. Connect one and start the conversation again."
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
    private var quietRun = 0
    private var voicedBlocks = 0
    private var blockCount = 0
    private var isRunning = false

    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    /// Fired when the system takes the audio session away (a call, Siri, another app). The
    /// controller tears the loop down: a microphone that the OS has muted while the UI says
    /// "Listening" is the exact failure this exists to prevent.
    public var onInterruption: (@MainActor (String) -> Void)?
    #endif

    public init(config: VoiceVADConfig = VoiceVADConfig()) {
        self.config = config
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
        guard !isRunning else { return }
        // macOS terminates the process on first capture input without this string, and iOS only
        // shows the prompt when the key is present — so check it before touching AVFoundation.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String != nil else {
            throw StartFailure.descriptionMissing
        }
        guard await Self.requestMicrophonePermission() else {
            throw StartFailure.microphoneDenied
        }
        try VoiceAudioSession.activate()
        try beginStreaming()
    }

    /// Close the microphone and release the audio session. Safe to call in any state, from any
    /// exit: toggle-off, leaving the bot, backgrounding, a failed request.
    @MainActor
    public func stop() {
        teardown()
        VoiceAudioSession.deactivate()
    }

    private func beginStreaming() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw StartFailure.noInputDevice
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: config.sampleRate,
                                        channels: 1,
                                        interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw StartFailure.engineFailed("the input format could not be converted")
        }
        self.targetFormat = target
        self.converter = converter

        // 30 ms at the hardware rate: one block per VAD step, so no second buffer to lose.
        let blockFrames = AVAudioFrameCount(max(256, format.sampleRate * config.blockSeconds))
        input.installTap(onBus: 0, bufferSize: blockFrames, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw StartFailure.engineFailed(error.localizedDescription)
        }
        lock.lock()
        isRunning = true
        lock.unlock()
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
        guard let target = targetFormat, let converter, let converted = convert(buffer, to: target, with: converter) else {
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
        for index in block.indices {
            let clamped = min(1, max(-1, block[index]))
            let sample = Int16(clamped * 32_767)
            samples[index] = sample
            sum += Double(sample) * Double(sample)
        }
        let rms = (sum / Double(block.count)).squareRoot()

        var events: [VoiceCaptureEvent] = []

        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        blockCount += 1
        preRoll.append(samples)
        if preRoll.count > config.preRollBlocks { preRoll.removeFirst() }

        switch phase {
        case .listening:
            // The gate answers "has this person finished a sentence?"; its trigger is the quiet
            // floor learned before the loop opened speech, raised the same way the host's
            // generation phase raises it.
            let trigger = max(detector.quietFloor * config.bargeMultiplier, config.silenceRMS * 2)
            let decision = gate.feed(rms: rms, trigger: trigger)
            switch decision {
            case .started:
                // Seed with the last 300 ms, which already contains this block, so the syllable
                // that tripped the gate is not clipped. Nothing is appended a second time.
                collected = preRoll.suffix(min(10, preRoll.count)).flatMap { $0 }
                collecting = true
                voicedBlocks = 1
            case .idle:
                if collecting {
                    collected += samples
                    if rms >= trigger { voicedBlocks += 1 }
                }
            case .ended(let keep):
                if collecting { collected += samples }
                let audio = collected
                collected = []
                collecting = false
                let voiced = Double(voicedBlocks) * config.blockSeconds
                voicedBlocks = 0
                events.append(.utterance(VoiceUtterance(wav: VoiceWAV.encode(samples: audio, sampleRate: Int(config.sampleRate)),
                                                        duration: Double(audio.count) / config.sampleRate,
                                                        voicedDuration: voiced),
                                         keep: keep))
            }

        case .thinking, .speaking:
            let trip = detector.feed(rms: rms, playing: phase == .speaking)
            if let trip {
                // Trip: report it immediately so playback stops before anything else happens, then
                // keep rolling from the pre-roll buffer — the words that tripped the detector are
                // already in it, so the utterance starts at the first syllable, not at the trip.
                collected = preRoll.flatMap { $0 }
                collecting = true
                quietRun = 0
                voicedBlocks = config.tripBlocks
                events.append(.bargeIn(trip))
            } else if collecting {
                collected += samples
                quietRun = rms < config.silenceRMS ? quietRun + 1 : 0
                if quietRun >= config.endpointSilenceBlocks || collected.count / config.framesPerBlock >= config.maximumUtteranceBlocks {
                    let audio = collected
                    collected = []
                    collecting = false
                    let voiced = Double(voicedBlocks) * config.blockSeconds
                    let keep = voicedBlocks >= config.minimumUtteranceBlocks
                    voicedBlocks = 0
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
        switch session.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            return false
        }
        #endif
    }
}

/// The session underneath the loop, on the platform that has one.
///
/// iOS: `.playAndRecord` with the `.voiceChat` mode, which is what enables the system echo
/// canceller. That matters more here than anywhere else in the app — the microphone stays open
/// while the speaker talks, and without AEC the reply would be captured and sent back as the user's
/// own turn. macOS has no `AVAudioSession` and no system AEC, which is why the playback-phase
/// trigger (`playbackMinimumTrigger`) and `VoicePolicy.isSelfEcho` exist on both platforms.
enum VoiceAudioSession {
    static func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        // 30 ms is the block the VAD reasons in; asking the hardware for it avoids a second copy.
        try? session.setPreferredIOBufferDuration(0.03)
        try session.setActive(true)
        #endif
    }

    static func deactivate() {
        #if os(iOS)
        // `.notifyOthersOnDeactivation` is what lets the user's music come back after the loop
        // ends; without it the session stays claimed until the app is suspended.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
