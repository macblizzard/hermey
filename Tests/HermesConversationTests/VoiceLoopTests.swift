import XCTest
@testable import HermesVoice

/// The text half of the loop, exercised for real: these are the rules that decide whether a silent
/// room, a speaker's own words, or the word "stop" become a turn.
final class VoicePolicyTests: XCTestCase {

    func testWhisperInventingAPhraseOnSilence() {
        // The exact strings `voice_mode_transcript.is_whisper_hallucination` filters, including the
        // repetition form the exact-match set cannot catch.
        XCTAssertTrue(VoicePolicy.isHallucination("Thank you for watching."))
        XCTAssertTrue(VoicePolicy.isHallucination("thank you"))
        XCTAssertTrue(VoicePolicy.isHallucination("Thank you. Thank you. Thank you."))
        XCTAssertTrue(VoicePolicy.isHallucination(""))
        XCTAssertTrue(VoicePolicy.isHallucination("   "))
        // A real sentence that happens to contain the words is still a sentence.
        XCTAssertFalse(VoicePolicy.isHallucination("thank you for the update, what is next"))
        XCTAssertFalse(VoicePolicy.isHallucination("what is the weather in Berlin"))
    }

    func testTheStopPhraseIsTheWholeUtterance() {
        XCTAssertTrue(VoicePolicy.isStopPhrase("stop"))
        XCTAssertTrue(VoicePolicy.isStopPhrase("  Stop!  "))
        XCTAssertTrue(VoicePolicy.isStopPhrase("stop.", phrases: ["stop"]))
        // The strictness is the point: an instruction that contains "stop" reaches the agent.
        XCTAssertFalse(VoicePolicy.isStopPhrase("stop doing that and try again"))
        XCTAssertFalse(VoicePolicy.isStopPhrase("stopping"))
        XCTAssertFalse(VoicePolicy.isStopPhrase(""))
        XCTAssertFalse(VoicePolicy.isStopPhrase("stop", phrases: []))
    }

    func testOurOwnReplyComingBackThroughTheMicrophone() {
        let spoken = "The gateway ticket is single use, so the retry has to mint a new one before every request."
        // A capture of the reply, or of a fragment of it, is the speaker — not the user.
        XCTAssertTrue(VoicePolicy.isSelfEcho(spoken, spoken: spoken))
        XCTAssertTrue(VoicePolicy.isSelfEcho("the gateway ticket is single use", spoken: spoken))
        // A question about it is not.
        XCTAssertFalse(VoicePolicy.isSelfEcho("why is the ticket single use then", spoken: spoken))
        XCTAssertFalse(VoicePolicy.isSelfEcho("what time is it", spoken: spoken))
        // A short interjection never matches a long reply: the fragment window needs 10 characters.
        XCTAssertFalse(VoicePolicy.isSelfEcho("yes", spoken: spoken))
    }

    func testMarkdownIsNotReadOutLoud() {
        let reply = """
        ## Summary

        The build **succeeded** on both platforms.

        ```swift
        let x = 1
        ```

        See [the log](https://example.com/build/123) for details.
        """
        let spoken = VoicePolicy.speechText(from: reply)
        XCTAssertFalse(spoken.contains("#"))
        XCTAssertFalse(spoken.contains("**"))
        XCTAssertFalse(spoken.contains("let x = 1"))
        XCTAssertFalse(spoken.contains("http"))
        XCTAssertTrue(spoken.contains("The build succeeded on both platforms."))
        XCTAssertTrue(spoken.contains("the log"))
    }

    func testALongReplyIsCutAtASentence() {
        let sentence = "This is a sentence that goes on for a while. "
        let reply = String(repeating: sentence, count: 60)
        let spoken = VoicePolicy.speechText(from: reply)
        XCTAssertLessThanOrEqual(spoken.count, VoicePolicy.maximumSpokenCharacters)
        XCTAssertTrue(spoken.hasSuffix("."), "the last thing heard must not be half a word")
    }

    func testSentencesAreCutForSpeechAndShortOnesMerge() {
        // A sentence is complete once whitespace follows it: the first is spoken while the rest of
        // the reply is still being synthesized.
        var chunker = VoiceSentenceChunker()
        XCTAssertEqual(chunker.feed("The ticket is single use. Every request needs a fresh one."),
                       ["The ticket is single use. "])
        // The last sentence is not complete until it is followed by something, so it comes out of
        // `flush()` — never dropped, and never cut mid-word.
        XCTAssertEqual(chunker.flush(), ["Every request needs a fresh one."])

        // A fragment under the minimum merges into the sentence after it rather than spending its
        // own request: "Yes." alone is not worth a synthesis round trip.
        var short = VoiceSentenceChunker()
        XCTAssertEqual(short.feed("Yes. "), [])
        XCTAssertEqual(short.feed("That is the whole point of the ticket. "),
                       ["Yes. That is the whole point of the ticket. "])

        var tail = VoiceSentenceChunker()
        XCTAssertEqual(tail.feed("No full stop here"), [])
        XCTAssertEqual(tail.flush(), ["No full stop here"])
    }
}

/// The endpointing gate and the barge detector, driven block by block with synthesised levels.
///
/// The numbers matter and they are the host's: a quiet room is 50–300 RMS, direct speech 3 000–8 000,
/// and speaker bleed through the microphone a few hundred.
final class VoiceVADTests: XCTestCase {

    private let config = VoiceVADConfig()

    /// Run `blocks` of `rms` through the gate and return every decision it made.
    private func gate(_ gate: inout VoiceUtteranceGate,
                      rms: Double,
                      blocks: Int,
                      trigger: Double = 600) -> [VoiceUtteranceGate.Decision] {
        (0..<blocks).map { _ in gate.feed(rms: rms, trigger: trigger) }
    }

    func testAnUtteranceEndsAfterTheSilenceThreshold() {
        var gate = VoiceUtteranceGate()
        XCTAssertEqual(gate.feed(rms: 120, trigger: 600), .idle, "a quiet room starts nothing")

        let started = self.gate(&gate, rms: 4_000, blocks: 20)
        XCTAssertEqual(started.first, .started)
        XCTAssertEqual(started.filter { $0 == .started }.count, 1)

        // 600 ms of silence ends it: 20 blocks at 30 ms.
        let quietNeeded = config.endpointSilenceBlocks
        let decisions = self.gate(&gate, rms: 120, blocks: quietNeeded)
        XCTAssertEqual(decisions.last, .ended(keep: true))
        XCTAssertEqual(decisions.dropLast().filter { $0 == .ended(keep: true) }.count, 0)
    }

    func testACoughIsNotATurn() {
        var gate = VoiceUtteranceGate()
        // 150 ms above the trigger — a cough, a door, a keyboard — then silence.
        _ = self.gate(&gate, rms: 4_000, blocks: 5)
        let decisions = self.gate(&gate, rms: 80, blocks: config.endpointSilenceBlocks)
        XCTAssertEqual(decisions.last, .ended(keep: false))
    }

    func testASpeakerNeverOpensTheMicrophone() {
        var detector = VoiceBargeDetector(config: config)
        // Calibrate on the quiet room first, the way the loop does before a turn exists.
        for _ in 0..<config.calibrationBlocks {
            XCTAssertNil(detector.feed(rms: 120, playing: false))
        }
        XCTAssertTrue(detector.isFloorLocked)
        XCTAssertEqual(detector.quietFloor, config.silenceRMS, accuracy: 0.001,
                       "the floor never drops below the silence threshold")

        // Playback starts; the microphone hears the speaker at a few hundred RMS. The raised
        // playback trigger is what keeps this from ending the reply.
        var trips = 0
        for _ in 0..<200 {
            if detector.feed(rms: 900, playing: true) != nil { trips += 1 }
        }
        XCTAssertEqual(trips, 0, "speaker bleed tripped the barge detector")
    }

    func testGenuineSpeechOverTheReplyTrips() {
        var detector = VoiceBargeDetector(config: config)
        for _ in 0..<config.calibrationBlocks { _ = detector.feed(rms: 120, playing: false) }
        for _ in 0..<30 { XCTAssertNil(detector.feed(rms: 900, playing: true)) }
        // Direct speech at the microphone, sustained past the majority window.
        var phase: VoiceBargePhase?
        for _ in 0..<config.sustainedBlocks {
            phase = detector.feed(rms: 6_000, playing: true) ?? phase
        }
        XCTAssertEqual(phase, .playback)
    }

    func testOneLoudBlockIsNotBargeIn() {
        var detector = VoiceBargeDetector(config: config)
        for _ in 0..<config.calibrationBlocks { _ = detector.feed(rms: 120, playing: false) }
        _ = detector.feed(rms: 900, playing: true)
        // A single transient inside the window must not be enough: the trip needs a majority.
        XCTAssertNil(detector.feed(rms: 9_000, playing: false))
        XCTAssertNil(detector.feed(rms: 120, playing: false))
    }

    func testTheOnsetOfPlaybackIsForgiven() {
        var detector = VoiceBargeDetector(config: config)
        for _ in 0..<config.calibrationBlocks { _ = detector.feed(rms: 120, playing: false) }
        // The speaker's first blocks are louder than its average: suppressed by the grace window.
        var tripped = false
        for _ in 0..<(config.graceBlocks / 2) {
            if detector.feed(rms: 9_000, playing: true) != nil { tripped = true }
        }
        XCTAssertFalse(tripped)
    }

    func testTheListeningLevelsFollowTheMeasuredFloor() {
        // The desktop microphone: unchanged. A floor at the silence threshold still gives exactly
        // the constant the engine used before — a 600 trigger and a 200 silence boundary.
        let desktop = config.listeningLevels(floor: config.silenceRMS)
        XCTAssertEqual(desktop.trigger, 600, accuracy: 0.001)
        XCTAssertEqual(desktop.silence, config.silenceRMS, accuracy: 0.001)

        // A phone: the same rules against its own floor. 20 RMS of room becomes a 120 trigger and a
        // 20 silence boundary, instead of a 600 trigger and a 200 boundary it could never beat.
        let phone = config.tunedForQuietInput().listeningLevels(floor: 20)
        XCTAssertEqual(phone.trigger, 120, accuracy: 0.001)
        XCTAssertEqual(phone.silence, 20, accuracy: 0.001)

        // And it still tracks a louder room rather than being a constant: 3 × floor.
        XCTAssertEqual(config.tunedForQuietInput().listeningLevels(floor: 300).trigger, 900,
                       accuracy: 0.001)
    }

    func testAQuietStreamCanBecomeATurn() {
        // The old fixed trigger: a stream that peaks at 300 RMS could never start an utterance.
        var desktopGate = VoiceUtteranceGate()
        XCTAssertEqual(desktopGate.feed(rms: 300, trigger: 600), .idle)

        var gate = VoiceUtteranceGate()
        let levels = config.tunedForQuietInput().listeningLevels(floor: 20)
        XCTAssertEqual(gate.feed(rms: 300, trigger: levels.trigger, silence: levels.silence),
                       .started)
        for _ in 0..<(config.minimumUtteranceBlocks - 1) {
            _ = gate.feed(rms: 300, trigger: levels.trigger, silence: levels.silence)
        }
        // The room's own floor is the quiet boundary, so 0.6 s of it ends the sentence rather than
        // every single block counting as silence and cutting the speaker off mid-word.
        var decision: VoiceUtteranceGate.Decision?
        for _ in 0..<config.endpointSilenceBlocks {
            decision = gate.feed(rms: 10, trigger: levels.trigger, silence: levels.silence)
        }
        XCTAssertEqual(decision, .ended(keep: true))
    }
}

/// The container the device uploads. The host sniffs the mime type, so a malformed header is a
/// transcription failure with no useful error.
final class VoiceWAVTests: XCTestCase {

    func testTheHeaderSaysWhatTheHostExpects() {
        let samples = [Int16](repeating: 0, count: 1_000)
        let data = VoiceWAV.encode(samples: samples, sampleRate: 16_000)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        // Little-endian: sample rate, channels and bits are the three the bridge's decoder reads.
        func u32(_ offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func u16(_ offset: Int) -> UInt16 {
            data[offset..<(offset + 2)].reversed().reduce(0) { ($0 << 8) | UInt16($1) }
        }
        XCTAssertEqual(u32(24), 16_000, "sample rate")
        XCTAssertEqual(u32(28), 32_000, "byte rate = rate * channels * 2")
        XCTAssertEqual(u16(22), 1, "mono")
        XCTAssertEqual(u16(34), 16, "16-bit")
        XCTAssertEqual(u32(40), UInt32(samples.count * 2), "data size")
    }
}
