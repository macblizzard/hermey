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
    /// The longest an utterance may run before it ends itself and is delivered. It exists so a
    /// stream that never goes quiet (a fan, a held-open microphone, someone talking for a minute)
    /// cannot grow a buffer forever: at 20 s the words are sent, and the next sentence starts a
    /// fresh collection rather than inheriting this one.
    public var maximumUtteranceSeconds: Double = 20
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
    /// Whether the end-of-speech boundary follows the speech this utterance has actually produced,
    /// instead of a level derived from a measured floor.
    ///
    /// False on the Mac, which endpoints correctly and whose numbers must not move; true for a
    /// quiet input (`tunedForQuietInput()`), where every calibrated-floor derivation has failed:
    /// a floor measured before anyone speaks is a floor measured wrong, and 0.1.692 is exactly that
    /// (blocks 2 and 3 of the "room" were his voice, so the room became 102 and the boundary 154 —
    /// above the voice it was supposed to sit under). A level that is a fraction of the speech just
    /// heard cannot make that mistake: it is strictly below the voice by construction.
    public var endpointFollowsSpeech: Bool = false
    /// Where the end-of-speech boundary sits inside the utterance's own voiced level: 0.45 of its
    /// average, so a pause has to be quieter than roughly half his volume to count as a pause.
    public var endpointVoicedFraction: Double = 0.45
    /// How much of the way to a quieter block the tracked floor falls in one step. Fast: the room
    /// gets quieter between sentences and the next one must not be judged against the old room.
    public var floorFallFraction: Double = 0.5
    /// How much of the way to a louder quiet block the tracked floor rises in one step. Slow (4 %
    /// a block, ~0.75 s to converge): a fan or a passing car must not become the new floor in one
    /// block and swallow the person talking under it.
    public var floorRiseFraction: Double = 0.04
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
    /// — it is the half that works, and it must keep working. The endpoint boundary is the desktop
    /// rule, kept for the phase where a reply is being collected (`case .thinking, .speaking`);
    /// the listening phase derives its boundary from the utterance's own speech instead
    /// (`VoiceUtteranceGate.endpointLevel`).
    public func listeningLevels(triggerFloor: Double, roomFloor: Double) -> VoiceLevels {
        VoiceLevels(trigger: max(triggerFloor * bargeMultiplier, listeningTriggerFloor),
                    silence: endpointSilence(floor: roomFloor))
    }

    /// The boundary a collection ends against, for a room whose floor is `floor`.
    ///
    /// This is the desktop rule and the default: a step above the floor, never the floor itself,
    /// capped at `silenceRMS`. A Mac's floor is clamped to ≥200, so every floor it can measure
    /// lands on the constant 200 it has always used — macOS is numerically unchanged by design.
    /// It is also the fallback for `endpointSilence(voicedAverage:floor:)` before any speech has
    /// been heard.
    public func endpointSilence(floor: Double) -> Double {
        min(silenceRMS, max(floor * endpointSilenceMultiplier, endpointSilenceMinimum))
    }

    /// The boundary a collection ends against when the utterance has produced `voicedAverage` RMS.
    ///
    /// `clamp(endpointVoicedFraction × voicedAverage, endpointSilenceMinimum, silenceRMS)` — 0.45,
    /// 60, 200. Three properties, and each one is a failure of the old derivation:
    ///
    /// * **Strictly below the speech that has just been heard.** 0.45 × average is under the
    ///   average for any positive level, and the 60 floor is under the lowest level that can open
    ///   a trigger at all (`listeningTriggerFloor`, 120), so a boundary can never sit above the
    ///   voice it is supposed to let rest on it. That is the 0.1.692 bug inverted.
    /// * **It moves with him.** A quiet talker gets a quiet boundary; a loud room does not raise it
    ///   past his own voice, because it is not derived from the room at all.
    /// * **It still cannot drift into the floor of a silent room**, because 60 is above a phone's
    ///   ambient (15–30) and below every block that could be called speech.
    public func endpointSilence(voicedAverage: Double, floor: Double) -> Double {
        guard endpointFollowsSpeech, voicedAverage > 0 else { return endpointSilence(floor: floor) }
        return min(silenceRMS, max(voicedAverage * endpointVoicedFraction, endpointSilenceMinimum))
    }

    /// The same rules, calibrated for an input that is not a desktop microphone.
    ///
    /// A Mac's built-in mic sits in a quiet room at a few hundred RMS, which is why the floor was
    /// allowed to bottom out at 200. A phone's input route — behind the receiver, behind the
    /// playAndRecord category, and until now behind `.voiceChat`'s voice processing — reports one
    /// to two orders of magnitude less for the same room. The *multipliers* are unchanged, so the
    /// trigger still tracks whatever floor is measured; only the two absolute bounds move, and one
    /// rule changes shape: the end-of-speech boundary stops being derived from a room measurement
    /// at all and becomes a fraction of the speech the utterance itself produced
    /// (`endpointFollowsSpeech`). Only iOS gets this (the engine applies it; the Mac keeps the
    /// desktop constants exactly).
    public func tunedForQuietInput() -> VoiceVADConfig {
        var copy = self
        copy.measuredFloorMinimum = 8
        copy.listeningTriggerFloor = 120
        copy.endpointFollowsSpeech = true
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

/// The room's level, tracked from the quiet side, block by block, for as long as the stream runs.
///
/// The estimator this replaces took the 90th percentile of the opening blocks, once. That is right
/// only if the first blocks are room tone, and in the owner's log they were not: `block 1 rms 25`,
/// `block 2 rms 102`, `block 3 rms 130` — he starts talking immediately, so the "room" was read as
/// 102 and the end-of-speech boundary came out at 154, *above* his quiet speech. Every pause at or
/// above his voice then read as speech, the 600 ms quiet run never accumulated, and no utterance
/// ever ended on that phone.
///
/// A window of percentiles cannot tell room from the beginning of a sentence. A gate can:
///
/// * a block at or above the trigger is speech, and never moves the floor at all — speech can only
///   ever lower the bar it has to clear, which is the inverse of the bug;
/// * a quiet block *below* the floor drops it most of the way at once (`floorFallFraction`): the
///   room gets quieter when the fan stops, and the next sentence must not be judged against the old
///   room;
/// * a quiet block *above* the floor raises it slowly (`floorRiseFraction`, ~0.75 s to converge):
///   a fan switching on, or a car passing, must not become the new floor in one block and silence
///   the person talking underneath it.
public struct VoiceFloorTracker {
    /// The floor in force now, int16 RMS, never under `measuredFloorMinimum`.
    public private(set) var level: Double
    private let config: VoiceVADConfig

    public init(config: VoiceVADConfig = VoiceVADConfig()) {
        self.config = config
        self.level = config.measuredFloorMinimum
    }

    /// Consume one block. `trigger` is the level that block was judged against, so "this is
    /// speech" means the same thing here as it does in the gate.
    public mutating func feed(rms: Double, trigger: Double) {
        guard rms < trigger else { return }
        let target = Swift.max(rms, config.measuredFloorMinimum)
        if target < level {
            level += (target - level) * config.floorFallFraction
        } else {
            level += (target - level) * config.floorRiseFraction
        }
        level = Swift.max(level, config.measuredFloorMinimum)
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
    /// A trip is a latch, not an edge. `recentAbove` stays saturated for as long as the person
    /// keeps talking, so without this every 30 ms block would report the same trip again — ~33
    /// `.bargeIn` events a second, each one re-seeding the collection from the pre-roll.
    private var latched = false
    /// Consecutive blocks below the endpoint boundary. A latch opens only on the same quiet run
    /// that ends a collection (`endpointSilenceBlocks`), never on a momentary dip.
    private var latchQuietRun = 0
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
        if latched {
            // Sustained speech over a reply is one barge, not thirty-three a second. The latch
            // opens only after the room has been quiet for the same run the collection endpoints
            // against, so a new utterance a moment later can trip normally.
            let silence = config.listeningLevels(floor: quietFloor).silence
            latchQuietRun = rms < silence ? latchQuietRun + 1 : 0
            if latchQuietRun >= config.endpointSilenceBlocks {
                latched = false
                latchQuietRun = 0
                recentAbove.removeAll()
                graceRemaining = 0
            }
            return nil
        }
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
        latched = true
        latchQuietRun = 0
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
        latched = false
        latchQuietRun = 0
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
///
/// The end-of-speech boundary is *not* an input. It is derived here, per block, from the speech this
/// utterance has actually produced (`config.endpointSilence(voicedAverage:floor:)`, on a quiet input
/// 0.45 × the running voiced average clamped to 60…200). That inversion is the fix for 0.1.692:
/// as long as the boundary came from a floor measured before he spoke, it could sit above his voice
/// and the utterance could never end. A boundary that is a fraction of the voice cannot.
public struct VoiceUtteranceGate {
    /// Why a collection ended. It is in the log because "the sentence ended" and "the sentence was
    /// cut at the ceiling" are different things to whoever reads a pasted log.
    public enum EndReason: String, Sendable, Equatable {
        /// `endpointSilenceSeconds` of quiet below the utterance's own end-of-speech level.
        case silence
        /// The utterance outgrew `maximumUtteranceSeconds` and was delivered anyway.
        case ceiling
    }

    public enum Decision: Equatable, Sendable {
        /// Nothing to do: no speech has started, or the collection is still running.
        case idle
        /// Speech just started; the caller should begin buffering from here.
        case started
        /// The utterance ended. `keep` is false for a blip that was too short to be a turn.
        case ended(keep: Bool, reason: EndReason)
    }

    private let config: VoiceVADConfig
    private var isCollecting = false
    private var blocks = 0
    private var voiced = 0
    private var quietRun = 0
    /// The room, tracked continuously from the quiet side. Kept across `reset()` on purpose: the
    /// room does not change because a sentence ended.
    private var floor: VoiceFloorTracker
    /// What this utterance's voiced blocks have averaged. The end-of-speech level is derived from
    /// it, so it may only ever be fed by speech.
    private var voicedSum = 0.0
    private var voicedCount = 0

    public init(config: VoiceVADConfig = VoiceVADConfig()) {
        self.config = config
        self.floor = VoiceFloorTracker(config: config)
    }

    public var hasStarted: Bool { isCollecting }

    /// The floor this stream has tracked. Logged with the first speech, so a pasted log shows the
    /// room it was heard in rather than a number the reader has to guess at.
    public var floorLevel: Double { floor.level }

    /// The average of this utterance's voiced blocks — 0 before it has said anything.
    public var voicedAverage: Double { voicedCount == 0 ? 0 : voicedSum / Double(voicedCount) }

    /// The level a block must fall below to count as quiet, right now.
    public var endpointLevel: Double {
        config.endpointSilence(voicedAverage: voicedAverage, floor: floor.level)
    }

    /// Drop the utterance, keep the room. Called between phases and after every collection.
    public mutating func reset() {
        isCollecting = false
        blocks = 0
        voiced = 0
        quietRun = 0
        voicedSum = 0
        voicedCount = 0
    }

    /// Consume one block against `trigger`, the level the caller judged it by.
    public mutating func feed(rms: Double, trigger: Double) -> Decision {
        // Every block is offered to the floor, and only the quiet ones move it.
        floor.feed(rms: rms, trigger: trigger)
        guard isCollecting else {
            guard rms >= trigger else { return .idle }
            isCollecting = true
            blocks = 1
            voiced = 1
            voicedSum = rms
            voicedCount = 1
            quietRun = 0
            return .started
        }
        blocks += 1
        if rms >= trigger {
            voiced += 1
            voicedSum += rms
            voicedCount += 1
        }
        // The boundary in force for this block, already below the speech heard so far.
        quietRun = rms < endpointLevel ? quietRun + 1 : 0
        if quietRun >= config.endpointSilenceBlocks {
            return finish(.silence)
        }
        if blocks >= config.maximumUtteranceBlocks {
            // At the ceiling, keep what was said rather than throwing the words away — the same
            // choice the recorder's duration limit makes.
            return finish(.ceiling)
        }
        return .idle
    }

    private mutating func finish(_ reason: EndReason) -> Decision {
        let keep = voiced >= config.minimumUtteranceBlocks
        reset()
        return .ended(keep: keep, reason: reason)
    }
}

private extension Double {
    /// The floor is never allowed under the configured minimum: a window that flushed during an
    /// inter-sentence pause would otherwise collapse toward zero and trip on the next sentence.
    /// The minimum is the desktop microphone's `silenceRMS` by default and follows the input
    /// (`measuredFloorMinimum`) where the input is quieter.
    func clampedBelow(_ minimum: Double) -> Double { Swift.max(self, minimum) }
}
