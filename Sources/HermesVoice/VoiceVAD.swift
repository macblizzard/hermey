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
    /// The lowest a measured floor may be clamped to. 200 is `silenceRMS`, the desktop microphone's
    /// threshold, and it is what every number here was tuned against. A phone's input is a quieter
    /// instrument (see `tunedForQuietInput()`): clamping it to 200 is what made the listening
    /// trigger a constant 600 no matter what the phone actually heard.
    public var measuredFloorMinimum: Double = 200
    /// The lowest the listening trigger may fall, whatever the floor is. `silenceRMS * 2` was this
    /// bound under another name; it is a field so a quiet input can lower it without changing the
    /// rule that the trigger is a multiple of the room.
    public var listeningTriggerFloor: Double = 400
    /// How far above the measured floor the end-of-speech boundary sits, as a multiple of it.
    /// 1.5 is close enough to the room that its ordinary drift stays under the boundary, and far
    /// enough above it that the boundary is never the floor itself (see `listeningLevels(floor:)`).
    public var endpointSilenceMultiplier: Double = 1.5
    /// The lowest the end-of-speech boundary may sit, in int16 RMS. A phone's room reads 15–30;
    /// a constant below that is a boundary the room itself can never be quiet enough to cross.
    public var endpointSilenceMinimum: Double = 60
    /// How many blocks report their own level at the head of a stream. Five is 150 ms: enough to
    /// tell a silent tap from a quiet one, and short enough to be five lines in a pasted log.
    public var diagnosticBlockCount: Int = 5

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

    /// The two levels the listening gate is held to, both read from the floor this room has.
    ///
    /// The trigger is the barge multiplier over the measured floor — the same arithmetic the
    /// detector already uses while the speaker plays — floored at `listeningTriggerFloor`.
    ///
    /// The endpointing boundary is a step *above* the floor, never the floor itself: see
    /// `endpointSilence(floor:)` for why the 0.1.691 room (15–28 RMS of ambient) could not end an
    /// utterance against a boundary of 8, and why the Mac still gets its constant 200.
    public func listeningLevels(floor: Double) -> VoiceLevels {
        listeningLevels(triggerFloor: floor, roomFloor: floor)
    }

    /// The same two levels when the trigger's floor and the room's are not the same measurement.
    ///
    /// The trigger follows the floor the barge detector holds, exactly as it did before this change
    /// — it is the half that works, and it must keep working. The endpoint boundary follows the
    /// room the stream itself reported, which at the head of a conversation is read from its first
    /// quiet blocks (`floorFromAmbient`) because the detector has not calibrated yet.
    public func listeningLevels(triggerFloor: Double, roomFloor: Double) -> VoiceLevels {
        VoiceLevels(trigger: max(triggerFloor * bargeMultiplier, listeningTriggerFloor),
                    silence: endpointSilence(floor: roomFloor))
    }

    /// The boundary a collection ends against, for a room whose floor is `floor`.
    ///
    /// A step above the floor, never the floor itself: a room's own blocks sit at its floor and
    /// drift around the 90th percentile, so a boundary drawn *at* the floor can never be met by
    /// the room it was measured in — the 0.1.691 log is exactly that (ambient 5–28 RMS against a
    /// boundary of 8, so a sentence that had already tripped never ended). `floor × 1.5` with a 60
    /// minimum lands between that room (15–28) and that speech (130+), and the cap at `silenceRMS`
    /// leaves the Mac — whose floor is clamped to ≥200 — on the constant 200 it always used.
    public func endpointSilence(floor: Double) -> Double {
        min(silenceRMS, max(floor * endpointSilenceMultiplier, endpointSilenceMinimum))
    }

    /// The floor a stream is reporting *before* anyone speaks, read from its own quiet blocks.
    ///
    /// The barge detector learns a floor by calibrating for 450 ms, but the listening phase at the
    /// head of a conversation has not fed it yet — speech can arrive inside that window (in the
    /// 0.1.691 log it arrived after five blocks), and `quietFloor` is then only its initial
    /// minimum. Rather than falling back to a constant, the same estimator the detector would have
    /// used — the 90th percentile of the quiet blocks, never under the input's minimum — is
    /// applied to the blocks this stream has actually reported.
    public func floorFromAmbient(_ blocks: [Double]) -> Double {
        guard !blocks.isEmpty else { return measuredFloorMinimum }
        let sorted = blocks.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)
        return max(sorted[max(0, index)], measuredFloorMinimum)
    }

    /// The same rules, calibrated for an input that is not a desktop microphone.
    ///
    /// A Mac's built-in mic sits in a quiet room at a few hundred RMS, which is why the floor was
    /// allowed to bottom out at 200. A phone's input route — behind the receiver, behind the
    /// playAndRecord category, and until now behind `.voiceChat`'s voice processing — reports one
    /// to two orders of magnitude less for the same room. The *multipliers* are unchanged, so the
    /// trigger still tracks whatever floor is measured; only the two absolute bounds move, and only
    /// on iOS (the engine applies this; the Mac keeps the desktop constants exactly).
    public func tunedForQuietInput() -> VoiceVADConfig {
        var copy = self
        copy.measuredFloorMinimum = 8
        copy.listeningTriggerFloor = 120
        return copy
    }
}

/// The listening gate's trigger and its "this block is quiet" boundary, together.
///
/// They are one value because they usually come from one floor: a gate that tripped on the room
/// and then endpointed against a louder constant would end the sentence it just heard. In the
/// listening phase the two measurements can differ — the trigger follows the barge detector's
/// floor, which is the one that already trips, while the boundary follows the room the stream
/// itself reported, because at the head of a conversation the detector has not calibrated yet.
public struct VoiceLevels: Sendable, Equatable {
    public let trigger: Double
    public let silence: Double

    public init(trigger: Double, silence: Double) {
        self.trigger = trigger
        self.silence = silence
    }
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
        self.quietFloor = config.measuredFloorMinimum
    }

    /// Consume one block. Returns the phase when speech tripped, `nil` otherwise.
    public mutating func feed(rms: Double, playing: Bool) -> VoiceBargePhase? {
        if !isFloorLocked && !calibrate(rms: rms, playing: playing) { return nil }
        trackPlayback(playing)
        var trigger = max(quietFloor * config.bargeMultiplier,
                          playing ? config.playbackMinimumTrigger : config.listeningTriggerFloor)
        trigger = min(trigger, config.triggerCeiling)
        if !playing && rms < trigger {
            // Ambient drift only: a block of speech must never raise the floor it has to beat.
            ambient.append(rms)
            if ambient.count > config.floorWindowBlocks { ambient.removeFirst() }
            quietFloor = percentile90(ambient).clampedBelow(config.measuredFloorMinimum)
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
        quietFloor = percentile90(ambient).clampedBelow(config.measuredFloorMinimum)
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

    public mutating func feed(rms: Double, trigger: Double, silence: Double? = nil) -> Decision {
        // The "no voice" boundary is the caller's, because it comes from the floor the caller
        // measured; the desktop default is what it was before the two could differ.
        let silenceRMS = silence ?? config.silenceRMS
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
        quietRun = rms < silenceRMS ? quietRun + 1 : 0
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
    /// The floor is never allowed under the configured minimum: a window that flushed during an
    /// inter-sentence pause would otherwise collapse toward zero and trip on the next sentence.
    /// The minimum is the desktop microphone's `silenceRMS` by default and follows the input
    /// (`measuredFloorMinimum`) where the input is quieter.
    func clampedBelow(_ minimum: Double) -> Double { Swift.max(self, minimum) }
}
