"""Guards for the hands-free voice conversation.

Each test pins one decision the loop cannot afford to lose, because every one of them is the
difference between a conversation and a microphone that is left open. They read the Swift and the
project file as text — the loop itself needs a Mac, a microphone and a paired host to run, and none
of those exist in CI.

The reference for the architecture is Hermes Agent's own chained voice mode (`tools/voice_mode.py`,
`tools/voice_mode_transcript.py`); the comments in `Sources/HermesVoice` say which function each
piece came from.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOOP_DIR = ROOT / "Sources" / "HermesVoice"

CONTROLLER = (LOOP_DIR / "VoiceLoopController.swift").read_text(encoding="utf-8")
AUDIO = (LOOP_DIR / "VoiceAudio.swift").read_text(encoding="utf-8")
VAD = (LOOP_DIR / "VoiceVAD.swift").read_text(encoding="utf-8")
POLICY = (LOOP_DIR / "VoicePolicy.swift").read_text(encoding="utf-8")
STATE = (LOOP_DIR / "VoiceLoopState.swift").read_text(encoding="utf-8")
BAR = (LOOP_DIR / "VoiceLoopStatusBar.swift").read_text(encoding="utf-8")
MAC_BAR = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerBar.swift").read_text(encoding="utf-8")
PHONE = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
COMPOSER = (ROOT / "Sources" / "HermeyUI" / "Composer.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "project.yml").read_text(encoding="utf-8")
PACKAGE = (ROOT / "Package.swift").read_text(encoding="utf-8")


def swift_body(text: str, signature: str) -> str:
    """The body of the first function whose declaration contains *signature*, braces balanced."""
    index = text.index(signature)
    start = text.index("{", index)
    depth = 0
    for position in range(start, len(text)):
        if text[position] == "{":
            depth += 1
        elif text[position] == "}":
            depth -= 1
            if depth == 0:
                return text[start:position + 1]
    raise AssertionError(f"unbalanced braces after {signature!r}")


class OneOwner(unittest.TestCase):
    def test_one_capture_engine_and_one_controller(self) -> None:
        # A second engine is a second tap on the same input device, which is a feedback loop rather
        # than a feature. The controller is the only thing that may construct one.
        self.assertEqual(CONTROLLER.count("VoiceCaptureEngine(config: config)"), 1)
        self.assertNotIn("VoiceCaptureEngine(", AUDIO.split("public final class VoiceCaptureEngine")[0])

    def test_the_state_says_whether_the_microphone_is_open(self) -> None:
        body = swift_body(STATE, "public var ownsMicrophone")
        for case in (".starting", ".listening", ".thinking", ".speaking"):
            self.assertIn(case, body)
        self.assertIn("case .off, .failed: return false", body)

    def test_both_shells_disable_the_other_capture(self) -> None:
        # Hold-to-talk stays, but not while the loop is open: one microphone, one listener.
        self.assertIn("!loop.isActive", MAC_BAR)
        self.assertIn("!voiceLoop.isActive", PHONE)


class BargeIn(unittest.TestCase):
    def body(self) -> str:
        return swift_body(CONTROLLER, "private func handleBargeIn")

    def test_playback_stops_before_anything_else(self) -> None:
        body = self.body()
        # The first thing the handler does: silence the speaker the user is talking over.
        self.assertIn("player.stopPlayback()", body)
        first = body.index("player.stopPlayback()")
        self.assertLess(first, body.index("wiring.interruptTurn()"))
        self.assertLess(first, body.index("pipelineTask?.cancel()"))
        # Everything before it is the function's own doc comment and nothing executable.
        self.assertNotIn("sendTurn", body[:first])
        self.assertNotIn("deliver(", body[:first])

    def test_the_phase_decides_whether_the_turn_is_cut(self) -> None:
        body = self.body()
        # Talking over a generation cancels it; talking over playback only ends the playback.
        self.assertIn("if phase == .generation", body)
        self.assertIn("awaitingReply = false", body)

    def test_the_visible_state_follows_without_moving_the_capture(self) -> None:
        # The engine is mid-collection when the trip fires; moving its phase would throw the
        # utterance away. The handler sets the published state only.
        body = self.body()
        self.assertIn("state = .listening", body)
        self.assertNotIn("capture.setPhase", body)

    def test_the_capture_keeps_rolling_from_the_pre_roll(self) -> None:
        # Speech is kept from its first syllable, not from the block that tripped the detector —
        # `_capture_until_quiet` in the host's voice_mode.py.
        armed = AUDIO.split("case .thinking, .speaking:", 1)[1].split("case .off, .starting, .failed:", 1)[0]
        self.assertIn("collected = preRoll.flatMap { $0 }", armed)
        self.assertIn("quietRun >= config.endpointSilenceBlocks", armed)
        self.assertIn("events.append(.bargeIn(trip))", armed)


class BargeInDuringAGeneration(unittest.TestCase):
    """Talking over a *generation* is the one place two turns can cross.

    The host answers an interrupt with an ordinary completion carrying whatever had been produced.
    Speaking that would read as an answer to the sentence the user has just spoken — so the cut
    turn's completion is treated as a signal that the turn is over, and the sentence he spoke is
    sent from there. One reply per thing said, in the order they were said.
    """

    def test_the_cut_turns_reply_is_never_spoken(self) -> None:
        body = swift_body(CONTROLLER, "public func noteTurnCompleted")
        branch = body.split("if interruptedTurn {", 1)[1].split("}", 1)[0]
        self.assertNotIn("speakReply", branch)
        self.assertIn("interruptedTurn = false", branch)

    def test_the_sentence_spoken_over_it_is_sent_from_there(self) -> None:
        body = swift_body(CONTROLLER, "public func noteTurnCompleted")
        branch = body.split("if interruptedTurn {", 1)[1].split("}", 1)[0]
        self.assertIn("heldUtterance", branch)
        self.assertIn("deliver(held)", branch)

    def test_an_utterance_waits_instead_of_crossing(self) -> None:
        body = swift_body(CONTROLLER, "private func handle(_ event: VoiceCaptureEvent)")
        self.assertIn("if interruptedTurn {", body)
        self.assertLess(body.index("heldUtterance = utterance"), body.index("deliver(utterance)"))
        self.assertIn("startInterruptWatchdog()", body)

    def test_a_lost_completion_does_not_strand_it(self) -> None:
        self.assertIn("interruptGraceSeconds", CONTROLLER)
        body = swift_body(CONTROLLER, "private func startInterruptWatchdog()")
        self.assertIn("heldUtterance", body)
        self.assertIn("deliver(held)", body)


class Teardown(unittest.TestCase):
    def test_the_one_stop_closes_capture_and_playback(self) -> None:
        body = swift_body(CONTROLLER, "public func stop()")
        self.assertIn("capture.stop()", body)
        self.assertIn("player.stopPlayback()", body)
        self.assertLess(body.index("capture.stop()"), body.index("player.stopPlayback()"))
        self.assertIn("pipelineTask?.cancel()", body)
        self.assertIn("watchdog?.cancel()", body)
        self.assertIn("state = .off", body)

    def test_backgrounding_goes_through_it(self) -> None:
        body = swift_body(CONTROLLER, "public func noteBackgrounded()")
        self.assertIn("stop()", body)
        # And the phone calls it when it leaves the foreground.
        self.assertIn("voiceLoop.noteBackgrounded()", PHONE)
        self.assertIn("scenePhase", PHONE)

    def test_leaving_the_conversation_goes_through_it(self) -> None:
        body = swift_body(CONTROLLER, "public func noteConversationChanged()")
        self.assertIn("stop()", body)
        self.assertIn("loop.noteConversationChanged()", MAC_BAR)
        self.assertIn("loop.stop()", MAC_BAR.split(".onDisappear {", 1)[1][:400])
        self.assertIn("voiceLoop.stop()", PHONE.split(".onDisappear {", 1)[1][:400])

    def test_a_failed_request_closes_the_microphone(self) -> None:
        # The first statement in the failure path is the teardown: a request that failed must never
        # leave a hot microphone behind a UI that has stopped promising an answer.
        body = swift_body(CONTROLLER, "private func fail(")
        first = body.index("stop()")
        self.assertLess(first, body.index("errorMessage = message"))
        self.assertNotIn("sendTurn", body)

    def test_the_engine_releases_the_session_and_the_tap(self) -> None:
        body = swift_body(AUDIO, "private func teardown()")
        self.assertIn("engine.inputNode.removeTap(onBus: 0)", body)
        self.assertIn("engine.stop()", body)
        body = swift_body(AUDIO, "public func stop()")
        self.assertIn("VoiceAudioSession.deactivate()", body)
        # Deactivation must hand the session back, not just drop it.
        self.assertIn(".notifyOthersOnDeactivation", AUDIO)


class Endpointing(unittest.TestCase):
    def test_the_thresholds_are_named_constants(self) -> None:
        config = swift_body(VAD, "public struct VoiceVADConfig")
        for name, value in (
            ("silenceRMS: Double = 200", None),
            ("playbackMinimumTrigger: Double = 1_500", None),
            ("triggerCeiling: Double = 4_000", None),
            ("bargeMultiplier: Double = 3.0", None),
            ("endpointSilenceSeconds: Double = 0.6", None),
            ("minimumUtteranceSeconds: Double = 0.30", None),
            ("majorityFraction: Double = 0.8", None),
        ):
            self.assertIn(name, config)

    def test_the_engine_does_not_carry_its_own_numbers(self) -> None:
        # Levels and timings live in `VoiceVADConfig`; a literal in the engine is a second opinion
        # about what counts as speech.
        for literal in ("1500", "1_500", "4000", "4_000", "0.45"):
            self.assertNotIn(literal, AUDIO, f"{literal} belongs in VoiceVADConfig")
        self.assertIn("config.bargeMultiplier", AUDIO)
        self.assertIn("config.endpointSilenceBlocks", AUDIO)

    def test_a_blip_is_not_a_turn(self) -> None:
        # The gate reports `keep: false` below the minimum voiced length, and the controller drops
        # it without sending or failing.
        self.assertIn("voiced >= config.minimumUtteranceBlocks", VAD)
        body = swift_body(CONTROLLER, "private func handle(_ event: VoiceCaptureEvent)")
        self.assertIn("guard keep else", body)
        self.assertIn("capture.setPhase(.listening)", body)

    def test_silence_cannot_become_a_turn(self) -> None:
        body = swift_body(CONTROLLER, "private func deliver(")
        self.assertIn("VoicePolicy.isHallucination(text)", body)
        self.assertIn("isHallucination", POLICY)
        self.assertIn("thank you for watching", POLICY)


class Speaking(unittest.TestCase):
    def test_only_a_completed_turn_is_spoken(self) -> None:
        body = swift_body(CONTROLLER, "public func noteTurnCompleted")
        self.assertIn("guard state == .thinking, awaitingReply else { return }", body)
        self.assertIn("speakReply(", body)
        # And nothing else calls it: the streaming delta path cannot make the app talk.
        self.assertEqual(CONTROLLER.count("speakReply("), 2)  # the declaration and the one call

    def test_the_reply_is_projected_to_prose(self) -> None:
        body = swift_body(CONTROLLER, "public func noteTurnCompleted")
        self.assertIn("VoicePolicy.speechText(from: text)", body)
        self.assertIn("func speechText(from reply: String)", POLICY)

    def test_the_reply_is_spoken_in_sentences(self) -> None:
        body = swift_body(CONTROLLER, "private func speakReply")
        self.assertIn("VoiceSentenceChunker()", body)
        self.assertIn("chunker.flush()", body)
        self.assertIn("self.wiring.synthesize(sentence)", body)

    def test_a_spoken_stop_ends_it(self) -> None:
        body = swift_body(CONTROLLER, "private func deliver(")
        stop_at = body.index("VoicePolicy.isStopPhrase(text)")
        send_at = body.index("self.wiring.sendTurn(text)")
        self.assertLess(stop_at, send_at)
        self.assertIn("self.stop()", body[stop_at:])

    def test_echo_is_filtered_after_a_reply(self) -> None:
        body = swift_body(CONTROLLER, "private func deliver(")
        self.assertIn("VoicePolicy.isSelfEcho(text, spoken: self.lastSpokenText)", body)
        self.assertIn("echoGuardSeconds", body)
        self.assertIn("minimumEchoFragmentLength", POLICY)


class Visibility(unittest.TestCase):
    def test_the_states_are_words_a_person_reads(self) -> None:
        for word in ('"Listening"', '"Thinking"', '"Speaking"'):
            self.assertIn(word, STATE)
        self.assertIn("loop.state.title", BAR)
        self.assertIn("VoicePolicy.stopHint()", BAR)

    def test_the_composer_carries_the_control_on_both_platforms(self) -> None:
        self.assertIn("showsVoiceMode: true", MAC_BAR)
        self.assertIn("showsVoiceMode: true", PHONE)
        self.assertIn("onVoiceMode: { toggleVoiceMode() }", MAC_BAR)
        self.assertIn("onVoiceMode: { toggleVoiceMode() }", PHONE)
        self.assertIn("showsVoiceMode", COMPOSER)

    def test_the_loop_is_wired_to_the_host_it_is_paired_with(self) -> None:
        for shell in (MAC_BAR, PHONE):
            self.assertIn("VoiceLoopWiring(", shell)
            self.assertIn("noteTurnCompleted(text:", shell)
        # The Mac speaks through the same service the transcription uses, one ticket per request.
        mac_service = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MacVoiceController.swift").read_text(encoding="utf-8")
        self.assertIn("func synthesize(text: String) async throws -> Data", mac_service)
        self.assertIn("v1/voice/synthesize", mac_service)


class ThePlatforms(unittest.TestCase):
    def test_both_apps_link_the_loop(self) -> None:
        self.assertIn('.library(name: "HermesVoice"', PACKAGE)
        self.assertEqual(PROJECT.count("product: HermesVoice"), 2)

    def test_both_apps_ask_for_the_microphone_in_words(self) -> None:
        # iOS terminates the app on first capture input without this string, and the Mac does the
        # same: the sentence is the whole feature.
        self.assertEqual(PROJECT.count("NSMicrophoneUsageDescription"), 2)
        for line in PROJECT.splitlines():
            if "NSMicrophoneUsageDescription" in line:
                self.assertIn("keep listening", line)

    def test_ios_configures_a_session_and_listens_for_interruptions(self) -> None:
        self.assertIn("setCategory(.playAndRecord", AUDIO)
        self.assertIn("mode: .voiceChat", AUDIO)
        self.assertIn("AVAudioSession.interruptionNotification", AUDIO)
        # The Mac has no session: the permission path is the other half of the platform split.
        self.assertIn("AVCaptureDevice.authorizationStatus(for: .audio)", AUDIO)


if __name__ == "__main__":
    unittest.main()
