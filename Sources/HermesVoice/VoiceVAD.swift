import Foundation

/// Every timing and level the endpointing and barge-in logic uses, in one place and named.
///
/// The numbers are Hermes Agent's (`tools/voice_mode.py`), which tuned them on real conversations
/// against a 16 kHz mono microphone:
///
/// * `silenceRMS` 200 — `SILENCE_RMS_THRESHOLD`, an int16 RMS.
/// * `playbackMinimumTrigger` 1500 / `triggerCeiling` 4000 — `PLAYBACK_MIN_TRIGGER` and
///   `TRIGGER_CEILING`: speaker bleed alone (a few hundred RMS into the microphone) must never trip
///   speech detection, and a loud room must never raise the bar past ordinary speech (3 000–8 000).
/// * `bargeMultiplier` 3.0 — `DEFAULT_BARGE_MULTIPLIER`, applied to the calibrated quiet floor.
/// * `calibrationSeconds` 0.45 / `sustainedSeconds` 0.30 / `graceSeconds` 0.50 — `full_duplex_listen`'s
///   defaults: the floor is learned before anything is playing, a trip needs a *windowed majority*
///   rather than one loud block, and the first half-second of playback is ignored while the speaker
///   ramps up.
/// * `preRollSeconds` 1.2 — speech is kept from its first syllable, not from the moment detection
///   tripped.
/// * `endpointSilenceSeconds` 0.6 — **the one deliberate divergence**: the host waits 1.25 s, tuned
///   for a desktop microphone and a slow typist. This is a conversation: 600 ms is the pause a
///   person leaves between turns, and a hands-free loop that waits a full second and a quarter feels
///   like it has stopped listening.
public struct VoiceVADConfig: Sendable, Equatable {
    public var sampleRate: Double = 16_000
    public var blockSeconds: Double = 0.030
    public var silenceRMS: Double = 200
    public var playbackMinimumTrigger: Double = 1_500
    public var triggerCeiling: Double = 4_000
    public var bargeMultiplier: Double = 3.0
    public var calibrationSeconds: Double = 0.45
    public var sustainedSeconds: Double = 0.30
    public var graceSeconds: Double = 0.50
    public var preRollSeconds: Double = 1.2
    public var endpointSilenceSeconds: Double = 0.6
    public var minimumUtteranceSeconds: Double = 0.30
    public var maximumUtteranceSeconds: Double = 30
    /// The share of the `sustainedSeconds` window that must be above the trigger. 0.8 of 300 ms is
    /// 240 ms of speech — long enough that a cough or a keyboard thump cannot do it.
    public var majorityFraction: Double = 0.8
    /// The rolling floor window: ~3 s at 30 ms blocks, as the host's `deque(maxlen=100)`.
    public var floorWindowBlocks: Int = 100

    public init() {}

    public var calibrationBlocks: Int { max(1, Int((calibrationSeconds / blockSeconds).rounded())) }
    public var sustainedBlocks: Int { max(1, Int((sustainedSeconds / blockSeconds).rounded())) }
    public var graceBlocks: Int { max(0, Int((graceSeconds / blockSeconds).rounded())) }
    public var preRollBlocks: Int { max(1, Int((preRollSeconds / blockSeconds).rounded())) }
    public var endpointSilenceBlocks: Int { max(1, Int((endpointSilenceSeconds / blockSeconds).rounded())) }
    public var minimumUtteranceBlocks: Int { max(1, Int((minimumUtteranceSeconds / blockSeconds).rounded())) }
    public var maximumUtteranceBlocks: Int { max(1, Int((maximumUtteranceSeconds / blockSeconds).rounded())) }
    /// Above-trigger blocks needed inside the window, rounded the way the host rounds it.
    public var tripBlocks: Int { max(1, Int((Double(sustainedBlocks) * majorityFraction).rounded())) }
    /// Frames per block at 16 kHz.
    public var framesPerBlock: Int { Int(sampleRate * blockSeconds) }
}

/// Which side of the loop heard the speech, as `full_duplex_listen`'s `on_trigger(phase)` reports it.
public enum VoiceBargePhase: String, Sendable, Equatable {
    /// The reply was playing.
    case playback
    /// The turn was still being generated.
    case generation
}

/// The rolling-floor detector behind barge-in, ported from `_BargeDetector` in `voice_mode.py`.
///
/// The shape that matters and is easy to get wrong:
///
/// * the floor is learned from the **quiet** blocks only, before anything is playing, and locked;
/// * it keeps tracking ambient drift, but never absorbs a block that is already above the trigger —
///   otherwise speech inflates the floor and the next sentence can never trip it;
/// * during playback the trigger is clamped *up* to `playbackMinimumTrigger`, so the speaker's own
///   bleed cannot open the microphone;
/// * a trip needs `tripBlocks` of the last `sustainedBlocks` above the trigger, so a single
///   transient is not a turn.
public struct VoiceBargeDetector {
    public private(set) var quietFloor: Double
    public private(set) var isFloorLocked = false
    private var ambient: [Double] = []
    private var recentAbove: [Bool] = []
    private var graceRemaining = 0
    private var wasPlaying = false
    private var playbackSeen = false
    private var blocksSincePlayback = 10_000
    private let config: VoiceVADConfig

    public init(config: VoiceVADConfig = VoiceVADConfig()) {
        self.config = config
        self.quietFloor = config.silenceRMS
    }

    /// Consume one block. Returns the phase when speech tripped, `nil` otherwise.
    public mutating func feed(rms: Double, playing: Bool) -> VoiceBargePhase? {
        if !isFloorLocked && !calibrate(rms: rms, playing: playing) { return nil }
        trackPlayback(playing)
        var trigger = max(quietFloor * config.bargeMultiplier,
                          playing ? config.playbackMinimumTrigger : config.silenceRMS * 2)
        trigger = min(trigger, config.triggerCeiling)
        if !playing && rms < trigger {
            // Ambient drift only: a block of speech must never raise the floor it has to beat.
            ambient.append(rms)
            if ambient.count > config.floorWindowBlocks { ambient.removeFirst() }
            quietFloor = percentile90(ambient).clampedBelow(config.silenceRMS)
        }
        var above = rms >= trigger
        if above && graceRemaining > 0 {
            // Playback onset: the speaker's first hundred milliseconds are louder than its average.
            above = false
        }
        if graceRemaining > 0 { graceRemaining -= 1 }
        recentAbove.append(above)
        while recentAbove.count > config.sustainedBlocks { recentAbove.removeFirst() }
        guard above, recentAbove.filter({ $0 }).count >= config.tripBlocks else { return nil }
        return playing ? .playback : .generation
    }

    /// Start a fresh trip window without forgetting the room.
    ///
    /// The floor is the expensive part — it is learned from the quiet room and is what keeps the
    /// speaker's bleed out of the microphone — so every phase change keeps it and only the evidence
    /// of "someone is talking right now" is dropped.
    public mutating func resetWindow() {
        recentAbove.removeAll()
        graceRemaining = 0
        wasPlaying = false
        playbackSeen = false
        blocksSincePlayback = 10_000
    }

    private mutating func calibrate(rms: Double, playing: Bool) -> Bool {
        if !playing {
            ambient.append(rms)
            if ambient.count > config.floorWindowBlocks { ambient.removeFirst() }
        }
        guard ambient.count >= config.calibrationBlocks || playing else { return false }
        quietFloor = percentile90(ambient).clampedBelow(config.silenceRMS)
        isFloorLocked = true
        return true
    }

    private mutating func trackPlayback(_ playing: Bool) {
        // Grace only after a real gap: the audio-active flag flaps between sentences, and chaining
        // grace windows across an interjection would swallow it.
        if playing && !wasPlaying {
            if !playbackSeen || blocksSincePlayback > 33 {
                graceRemaining = config.graceBlocks
            }
            playbackSeen = true
        }
        wasPlaying = playing
        blocksSincePlayback = playing ? 0 : blocksSincePlayback + 1
    }

    private func percentile90(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return config.silenceRMS }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)
        return sorted[max(0, index)]
    }
}

/// End-of-utterance detection for the listening phase.
///
/// Kept apart from the barge detector on purpose: this one answers "has this person finished a
/// sentence?", which is a different question from "did someone talk over me?". The minimum voiced
/// length is what stops a cough, a door or a keyboard from becoming a turn — a cough is above the
/// trigger for ~150 ms and then silent, so it collected audio but never enough of it.
public struct VoiceUtteranceGate {
    public enum Decision: Equatable, Sendable {
        /// Nothing to do: no speech has started, or the collection is still running.
        case idle
        /// Speech just started; the caller should begin buffering from here.
        case started
        /// The utterance ended. `keep` is false for a blip that was too short to be a turn.
        case ended(keep: Bool)
    }

    private let config: VoiceVADConfig
    private var isCollecting = false
    private var blocks = 0
    private var voiced = 0
    private var quietRun = 0

    public init(config: VoiceVADConfig = VoiceVADConfig()) {
        self.config = config
    }

    public var hasStarted: Bool { isCollecting }

    public mutating func reset() {
        isCollecting = false
        blocks = 0
        voiced = 0
        quietRun = 0
    }

    public mutating func feed(rms: Double, trigger: Double) -> Decision {
        guard isCollecting else {
            guard rms >= trigger else { return .idle }
            isCollecting = true
            blocks = 1
            voiced = 1
            quietRun = 0
            return .started
        }
        blocks += 1
        if rms >= trigger { voiced += 1 }
        quietRun = rms < config.silenceRMS ? quietRun + 1 : 0
        if quietRun >= config.endpointSilenceBlocks {
            return finish()
        }
        if blocks >= config.maximumUtteranceBlocks {
            // At the ceiling, keep what was said rather than throwing the words away — the same
            // choice the recorder's duration limit makes.
            return finish()
        }
        return .idle
    }

    private mutating func finish() -> Decision {
        let keep = voiced >= config.minimumUtteranceBlocks
        reset()
        return .ended(keep: keep)
    }
}

private extension Double {
    /// The floor is never allowed under the silence threshold: a window that flushed during an
    /// inter-sentence pause would otherwise collapse toward zero and trip on the next sentence.
    func clampedBelow(_ minimum: Double) -> Double { Swift.max(self, minimum) }
}
