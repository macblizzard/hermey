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

    def test_both_shells_close_one_capture_before_opening_the_other(self) -> None:
        # One control, two gestures — and one microphone. A hold closes the conversation before it
        # records; a tap closes dictation before it listens. The Mac names the loop `loop`, the
        # phone `voiceLoop`.
        for shell, loop in ((MAC_BAR, "loop"), (PHONE, "voiceLoop")):
            hold = swift_body(shell, "private func voiceControlHold()")
            self.assertIn(f"if {loop}.isActive {{ {loop}.stop() }}", hold)
        # The tap ends the conversation it started: the Mac's tap and ⌥⌘V are one method,
        # `toggleVoiceMode`; the phone's tap goes through the same `toggleVoiceMode` the old loop
        # control used.
        mac_tap = swift_body(MAC_BAR, "private func toggleVoiceMode()")
        self.assertIn("if loop.isActive", mac_tap)
        self.assertIn("voice.cancel()", mac_tap)
        phone_tap = swift_body(PHONE, "private func voiceControlTap()")
        self.assertIn("toggleVoiceMode()", phone_tap)
        phone_loop = swift_body(PHONE, "private func toggleVoiceMode()")
        self.assertIn("if voiceLoop.isActive", phone_loop)
        self.assertIn("voice.cancel()", phone_loop)


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
        self.assertIn("transition(to: .listening)", body)
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
        body = swift_body(CONTROLLER, "public func stop(keepingSpeech: Bool = true)")
        self.assertIn("capture.stop()", body)
        self.assertIn("player.stopPlayback()", body)
        self.assertLess(body.index("capture.stop()"), body.index("player.stopPlayback()"))
        self.assertIn("pipelineTask?.cancel()", body)
        self.assertIn("watchdog?.cancel()", body)
        self.assertIn("transition(to: .off)", body)

    def test_backgrounding_goes_through_it(self) -> None:
        body = swift_body(CONTROLLER, "public func noteBackgrounded()")
        self.assertIn("stop(keepingSpeech: false)", body)
        # And the phone calls it when it leaves the foreground.
        self.assertIn("voiceLoop.noteBackgrounded()", PHONE)
        self.assertIn("scenePhase", PHONE)

    def test_leaving_the_conversation_goes_through_it(self) -> None:
        body = swift_body(CONTROLLER, "public func noteConversationChanged()")
        self.assertIn("stop(keepingSpeech: false)", body)
        self.assertIn("loop.noteConversationChanged()", MAC_BAR)
        self.assertIn("loop.stop()", MAC_BAR.split(".onDisappear {", 1)[1][:400])
        self.assertIn("voiceLoop.stop()", PHONE.split(".onDisappear {", 1)[1][:400])

    def test_a_failed_request_closes_the_microphone(self) -> None:
        # The first statement in the failure path is the teardown: a request that failed must never
        # leave a hot microphone behind a UI that has stopped promising an answer.
        body = swift_body(CONTROLLER, "private func fail(")
        first = body.index("stop(keepingSpeech: false)")
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
        # The engine asks the config for its levels; the multipliers and bounds stay in one struct.
        self.assertIn("config.listeningLevels(floor:", AUDIO)
        self.assertIn("triggerFloor * bargeMultiplier", VAD)
        self.assertIn("config.endpointSilenceBlocks", AUDIO)

    def test_a_blip_is_not_a_turn(self) -> None:
        # The gate reports `keep: false` below the minimum voiced length, and the controller drops
        # it without sending or failing.
        self.assertIn("voiced >= config.minimumUtteranceBlocks", VAD)
        body = swift_body(CONTROLLER, "private func handle(_ event: VoiceCaptureEvent)")
        self.assertIn("guard keep else", body)
        self.assertIn("capture.setPhase(.listening)", body)

    def test_silence_cannot_become_a_turn(self) -> None:
        body = swift_body(CONTROLLER, "private func transcribe(")
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
        body = swift_body(CONTROLLER, "private func transcribe(")
        stop_at = body.index("VoicePolicy.isStopPhrase(text)")
        send_at = body.index("self.wiring.sendTurn(text)")
        self.assertLess(stop_at, send_at)
        self.assertIn("self.stop(keepingSpeech: false)", body[stop_at:])

    def test_echo_is_filtered_after_a_reply(self) -> None:
        body = swift_body(CONTROLLER, "private func transcribe(")
        self.assertIn("VoicePolicy.isSelfEcho(text, spoken: self.lastSpokenText)", body)
        self.assertIn("echoGuardSeconds", body)
        self.assertIn("minimumEchoFragmentLength", POLICY)


class Visibility(unittest.TestCase):
    def test_the_states_are_words_a_person_reads(self) -> None:
        for word in ('"Listening"', '"Thinking"', '"Speaking"'):
            self.assertIn(word, STATE)
        self.assertIn("loop.state.title", BAR)
        self.assertIn("VoicePolicy.stopHint()", BAR)

    def test_the_composer_carries_the_one_control_on_both_platforms(self) -> None:
        # The Mac's tap is `toggleVoiceMode` (the ⌥⌘V method); the phone's is its gesture's name.
        for shell, tap in ((MAC_BAR, "toggleVoiceMode()"), (PHONE, "voiceControlTap()")):
            self.assertIn("voice: ", shell)
            self.assertIn("ComposerVoiceButton(systemImage:", shell)
            self.assertIn(f"onTap: {{ {tap} }}", shell)
            self.assertIn("onHold: { voiceControlHold() }", shell)
        self.assertIn("ComposerVoiceButton", COMPOSER)
        self.assertIn("private var voiceControl: some View", COMPOSER)

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
        self.assertIn("mode: mode", AUDIO)
        self.assertIn("static let mode: AVAudioSession.Mode = .spokenAudio", AUDIO)
        self.assertIn("AVAudioSession.interruptionNotification", AUDIO)
        # The Mac has no session: the permission path is the other half of the platform split.
        self.assertIn("AVCaptureDevice.authorizationStatus(for: .audio)", AUDIO)


class TheStartIsVisible(unittest.TestCase):
    """A loop that never begins must say so, step by step.

    The report was a hands-free conversation that "does nothing" on the phone with an empty log:
    no phase change, no error, nothing. That is the failure these guards make impossible — every
    step of the start path writes a named line, and a failure writes the reason before it stops.
    """

    def test_every_step_of_a_start_writes_a_line(self) -> None:
        # The microphone's own path: permission, session, format, tap, engine — then proof the
        # stream is alive, then the first thing the VAD heard.
        for step in ("permission: ", "session: ", "format: input ", "tap: installed",
                     "engine: running", "start failed: "):
            self.assertIn(f'VoiceLog.note("{step}', AUDIO, step)
        for step in ("first buffer: ", "vad: speech started", "endpoint: ", "vad: speech over"):
            self.assertIn(f'logFromAudioThread("{step}', AUDIO, step)
        # The frame count is the point of that line: it is what proves the tap is delivering audio
        # rather than reporting its own conversion failure.
        self.assertIn('logFromAudioThread("first buffer: \\(buffer.frameLength) frames', AUDIO)
        # And the loop's own: the tap arriving, phase changes, the turn and its transcript.
        for step in ("start: entered", "start: listening", "start: refused", "start: abandoned",
                     "phase: ", "failed: ", "transcribe: ", "turn: sent", "stop: "):
            self.assertIn(f'VoiceLog.note("{step}', CONTROLLER, step)

    def test_the_controller_logs_and_surfaces_a_thrown_failure(self) -> None:
        # A start that throws must log the case *and* reach the state the composer draws.
        body = swift_body(CONTROLLER, "public func start()")
        self.assertIn("self.fail(Self.message(for: error))", body)
        self.assertIn("self.transition(to: .listening)", body)
        fail = swift_body(CONTROLLER, "private func fail(")
        self.assertIn('VoiceLog.note("failed: ', fail)
        self.assertIn("errorMessage = message", fail)
        self.assertIn("transition(to: .failed)", fail)
        # The name, not just the sentence: "which step stopped it" is answered from a pasted log.
        self.assertIn("case .sessionFailed: return \"sessionFailed\"", AUDIO)
        self.assertIn("StartFailure.\\(failure.name)", CONTROLLER)

    def test_no_throw_in_the_start_path_bypasses_the_log(self) -> None:
        # Every failure goes through `failed(_:)`, which is what logs its name; `activate()` wraps
        # a session refusal into `sessionFailed` and logs it itself. One bare `throw` would be a
        # silent stop again, so the two named forms are the only ones allowed.
        for line in AUDIO.splitlines():
            text = line.strip()
            if text.startswith("throw "):
                self.assertTrue(text.startswith("throw failed(")
                                or text.startswith("throw VoiceCaptureEngine.StartFailure.sessionFailed("),
                                f"unlogged throw: {text}")
        self.assertNotIn("throw StartFailure", AUDIO)

    def test_a_refused_start_says_why_instead_of_nothing(self) -> None:
        body = swift_body(CONTROLLER, "public func start()")
        # No host / no conversation: a sentence, not a `return`.
        self.assertIn('VoiceLog.note("start: refused', body)
        self.assertIn("VoiceLoopFailure.noHost", body)
        # A tap the shells cannot honour speaks too.
        self.assertIn("public func reportUnavailable", CONTROLLER)
        self.assertIn("voiceLoop.reportUnavailable(", PHONE)

    def test_the_status_bar_shows_the_failure_sentence(self) -> None:
        # "Voice stopped" with no detail is the same silence in the composer that the log had.
        detail = swift_body(BAR, "private var detail")
        self.assertIn("loop.errorMessage", detail)
        self.assertIn("loop.state == .failed", detail)


class TheOneControl(unittest.TestCase):
    """One glyph, two gestures: the conversation on a tap, dictation on a hold.

    It was two controls — a microphone and a waveform — and the row read as crowded. What must
    survive the merge is the distinction they drew: a user has to be able to tell, from the one
    control, which of the two is running.
    """

    def test_the_loop_never_draws_a_bare_microphone(self) -> None:
        glyphs = swift_body(STATE, "public var glyph")
        cases = [line.strip() for line in glyphs.splitlines() if line.strip().startswith("case .")]
        self.assertEqual(len(cases), 6)
        for line in cases:
            self.assertNotIn('"mic', line, f"the loop is drawing the dictation glyph: {line}")
        self.assertIn('case .listening: return "waveform.circle.fill"', glyphs)
        self.assertIn('case .off: return "waveform"', glyphs)

    def test_one_element_and_one_identifier(self) -> None:
        # Exactly one audio control in the row, with one accessibility identifier: two identifiers
        # was the old two-control row, and a second glyph is what the owner asked to be rid of.
        self.assertIn('accessibilityIdentifier("composer.voice")', COMPOSER)
        self.assertNotIn('accessibilityIdentifier("composer.mic")', COMPOSER)
        self.assertNotIn('accessibilityIdentifier("composer.voicemode")', COMPOSER)
        self.assertEqual(COMPOSER.count("rowCentred(voiceControl)"), 1)
        self.assertNotIn("micControl", COMPOSER)
        self.assertNotIn("voiceModeControl", COMPOSER)

    def test_the_label_names_both_actions(self) -> None:
        for shell in (PHONE, MAC_BAR):
            label = swift_body(shell, "private var voiceControlLabel")
            self.assertIn('"Voice conversation; hold to dictate"', label)
            self.assertIn("tap to end it, hold to dictate", label)

    def test_the_control_wears_the_mode_that_is_running(self) -> None:
        # At rest it is the loop's waveform; while dictation runs it is dictation's own glyph. That
        # swap is the whole of "which promise is live".
        for shell, loop in ((PHONE, "voiceLoop"), (MAC_BAR, "loop")):
            glyph = swift_body(shell, "private var voiceControlGlyph")
            self.assertIn(f"if {loop}.state.ownsMicrophone {{ return {loop}.state.glyph }}", glyph)
            self.assertIn("if voice.state != .idle { return dictationGlyph }", glyph)
            self.assertIn("return VoiceLoopState.off.glyph", glyph)
        phone_glyph = swift_body(PHONE, "private var dictationGlyph")
        self.assertIn('"stop.circle.fill"', phone_glyph)
        # And the dictation's red while it records, so the recording is visible at a glance.
        for shell in (PHONE, MAC_BAR):
            self.assertIn("voice.state == .recording" if shell is PHONE else "voice.isRecording",
                          swift_body(shell, "private var voiceControlTint"))


class OneControllerPerScreen(unittest.TestCase):
    def test_the_phone_owns_exactly_one_loop(self) -> None:
        self.assertEqual(PHONE.count("VoiceLoopController("), 1)
        # And it is the same object the status strip observes and the one control's tap drives.
        self.assertIn("VoiceLoopStatusBar(loop: voiceLoop)", PHONE)
        self.assertIn("onTap: { voiceControlTap() }", PHONE)
        self.assertIn("voiceLoop.start()", swift_body(PHONE, "private func toggleVoiceMode()"))

    def test_both_shells_send_the_lines_to_the_client_log(self) -> None:
        for shell in (PHONE, MAC_BAR):
            self.assertIn("VoiceLog.shared.setSink", shell)
            self.assertIn('category: "voice"', shell)


class TheSilentStream(unittest.TestCase):
    """The phone opened the microphone, received buffers, and never heard a word.

    The owner's log from 0.1.690 had `tap: installed`, `engine: running`, `first buffer: 4 800
    frames at 48 000 Hz, 1 ch` — and then twenty seconds of him speaking without a single
    `vad: speech started`. Three things were missing from that log and from the code: the *level* of
    the blocks (silence and a quiet stream read identically), a session mode that a tap can hear
    (the loop used `.voiceChat`, whose voice processing the dictation recorder beside it does not),
    and a trigger that comes from the room the phone is actually in rather than from a desktop
    microphone's constant. These pin all three.
    """

    @staticmethod
    def code(text: str) -> str:
        """The Swift with its comment lines removed — a doc comment is not a behaviour."""
        return "\n".join(line for line in text.splitlines() if not line.strip().startswith("//"))

    def test_the_first_blocks_report_their_level_and_peak(self) -> None:
        body = swift_body(AUDIO, "private func noteBlockLevel(")
        # int16 RMS and the peak sample, both, because 0/0 is a dead stream and 20/90 is a real one.
        self.assertIn("vad: block \\(loggedBlockLevels) rms \\(Int(rms)) peak \\(peak)", body)
        # Once only: capped by the config and counted, not printed every block for a whole call.
        self.assertIn("guard loggedBlockLevels < config.diagnosticBlockCount else { return }", body)
        self.assertIn("loggedBlockLevels += 1", body)
        self.assertIn("diagnosticBlockCount: Int = 5", VAD)
        # Called from the block path itself, so it measures exactly what the VAD is fed.
        self.assertIn("noteBlockLevel(rms: rms, peak: peak)", AUDIO)
        self.assertIn("let rms = (sum / Double(block.count)).squareRoot()", AUDIO)
        # And it starts again on every start: a second conversation logs its own firsts.
        self.assertIn("loggedBlockLevels = 0", swift_body(AUDIO, "private func beginStreaming()"))

    def test_the_session_mode_is_chosen_and_logged_in_one_place(self) -> None:
        # One place sets a category in the module, and the mode is named there, not inline.
        self.assertEqual(self.code(AUDIO).count("setCategory("), 1)
        self.assertIn("static let mode: AVAudioSession.Mode = .spokenAudio", self.code(AUDIO))
        self.assertIn("mode: mode", self.code(AUDIO))
        # The log carries the mode's name: "active" alone cannot answer which session was used.
        self.assertIn('playAndRecord/\\(modeName)', AUDIO)
        self.assertIn('static var modeName: String { "spokenAudio" }', AUDIO)

    def test_no_voice_processing_mode_is_left_on_the_loop(self) -> None:
        # `.voiceChat` is the mode that engages the system voice-processing input; it is the suspect
        # for a tap that receives buffers nobody can hear, and it is gone from the executable code.
        self.assertNotIn(".voiceChat", self.code(AUDIO))
        # The mode the working dictation path uses is the mode the loop uses.
        dictation = (ROOT / "Apps" / "HermesMobile" / "Views" / "VoiceController.swift").read_text(encoding="utf-8")
        self.assertIn("mode: .spokenAudio", dictation)
        # And the same category and options are kept: the speaker by default, Bluetooth allowed.
        self.assertIn("options: [.defaultToSpeaker, .allowBluetooth]", AUDIO)

    def test_the_mac_path_sets_no_mode_and_keeps_its_config(self) -> None:
        activate = swift_body(AUDIO, "static func activate() throws")
        # iOS-only, and the Mac branch is the else of that same condition.
        ios = activate.index("#if os(iOS)")
        category = activate.index("setCategory(")
        mac = activate.index("#else")
        self.assertLess(ios, category)
        self.assertLess(category, mac)
        self.assertIn("session: macOS has no audio session to activate", activate[mac:])
        mac_code = "\n".join(line for line in activate[mac:].splitlines()
                             if not line.strip().startswith("//"))
        self.assertNotIn("setCategory", mac_code)
        self.assertNotIn("mode:", mac_code)
        # The engine's quiet-input tuning is iOS-only too: the Mac keeps the config it was handed.
        init = swift_body(AUDIO, "public init(config: VoiceVADConfig = VoiceVADConfig())")
        self.assertIn("tunedForQuietInput()", init)
        self.assertIn("#else", init)
        self.assertIn("self.config = config", init.split("#else", 1)[1])

    def test_the_desktop_levels_are_numerically_unchanged(self) -> None:
        """The Mac hears the same trigger and the same silence boundary as before this change."""
        config = swift_body(VAD, "public struct VoiceVADConfig")
        for field in ("silenceRMS: Double = 200", "bargeMultiplier: Double = 3.0",
                      "measuredFloorMinimum: Double = 200", "listeningTriggerFloor: Double = 400",
                      "endpointSilenceMultiplier: Double = 1.5",
                      "endpointSilenceMinimum: Double = 60"):
            self.assertIn(field, config)
        silence_rms, multiplier, floor_min, trigger_floor = 200.0, 3.0, 200.0, 400.0
        endpoint_multiplier, endpoint_min = 1.5, 60.0
        for floor in range(200, 4001, 25):
            # `max(floor * bargeMultiplier, silenceRMS * 2)` — the expression this replaced.
            before = max(floor * multiplier, silence_rms * 2)
            after = max(floor * multiplier, trigger_floor)
            self.assertEqual(before, after, f"trigger changed for a desktop floor of {floor}")
            # The endpoint boundary is now derived, but every floor a Mac can measure (clamped to
            # 200) lands on the old constant: the cap is the value the Mac always used.
            old_silence = min(silence_rms, max(floor, floor_min))
            new_silence = min(silence_rms, max(floor * endpoint_multiplier, endpoint_min))
            self.assertEqual(old_silence, silence_rms, f"the old boundary moved at floor {floor}")
            self.assertEqual(new_silence, silence_rms, f"the Mac boundary moved at floor {floor}")

    def test_the_listening_trigger_follows_the_measured_floor(self) -> None:
        # The trigger is untouched, on purpose: it fired at 120 on his phone and it must keep
        # doing exactly that. The engine asks the config for it from the detector's floor.
        listening = AUDIO.split("case .listening:", 1)[1].split("case .thinking, .speaking:", 1)[0]
        self.assertIn("config.listeningLevels(floor: detector.quietFloor).trigger", listening)
        self.assertIn("gate.feed(rms: rms, trigger: trigger)", listening)
        self.assertNotIn("silenceRMS * 2", self.code(AUDIO))
        self.assertNotIn("silenceRMS * 2", self.code(VAD))
        # The rule is a multiplier over the floor, floored at a low absolute bound — not a constant.
        levels = swift_body(VAD, "public func listeningLevels(triggerFloor: Double, roomFloor: Double)")
        self.assertIn("max(triggerFloor * bargeMultiplier, listeningTriggerFloor)", levels)
        # A phone's tuning moves the two *bounds* only: 8 RMS of floor is allowed, and 120 is the
        # lowest trigger. The multipliers are untouched, so the trigger still tracks the room.
        tuned = swift_body(VAD, "public func tunedForQuietInput()")
        self.assertIn("copy.measuredFloorMinimum = 8", tuned)
        self.assertIn("copy.listeningTriggerFloor = 120", tuned)
        self.assertNotIn("bargeMultiplier", tuned)

    def test_the_endpoint_follows_the_voice_not_the_room(self) -> None:
        """The 0.1.692 log: `vad: speech started, rms 130, floor 102, silence 154`.

        The floor was 102 because blocks 2 and 3 of the "room" were his own voice, and 1.5 × 102
        is 154 — above the 130 he was speaking at. Every pause at or above his voice read as
        speech, the 600 ms quiet run never accumulated, and no utterance ever ended. The boundary
        is now a fraction of the speech the utterance itself produced, so it cannot be above it.
        """
        boundary = swift_body(VAD, "public func endpointSilence(voicedAverage: Double, floor: Double)")
        self.assertIn(
            "guard endpointFollowsSpeech, voicedAverage > 0 else { return endpointSilence(floor: floor) }",
            boundary)
        self.assertIn(
            "min(silenceRMS, max(voicedAverage * endpointVoicedFraction, endpointSilenceMinimum))",
            boundary)
        config = swift_body(VAD, "public struct VoiceVADConfig")
        for field in ("endpointVoicedFraction: Double = 0.45",
                      "endpointSilenceMinimum: Double = 60",
                      "endpointSilenceSeconds: Double = 0.6"):
            self.assertIn(field, config)
        # Arithmetic: strictly under the voice it came from, never past the old cap, never under
        # the floor a phone's room can reach.
        for voiced in range(120, 4_001, 7):
            silence = min(200.0, max(voiced * 0.45, 60.0))
            self.assertLess(silence, voiced, f"the boundary rose into {voiced} of speech")
            self.assertGreaterEqual(silence, 60)
            self.assertLessEqual(silence, 200)
        # His quiet voice: 130 of speech ends against 60, where the old rule said 154.
        self.assertEqual(min(200.0, max(130 * 0.45, 60.0)), 60.0)
        self.assertEqual(min(200.0, max(2_600 * 0.45, 60.0)), 200.0)
        # The gate derives its own boundary and the engine passes nothing else in.
        gate = swift_body(VAD, "public struct VoiceUtteranceGate")
        self.assertIn("config.endpointSilence(voicedAverage: voicedAverage, floor: floor.level)", gate)
        self.assertIn("public var endpointLevel: Double", gate)
        self.assertNotIn("silence:", swift_body(VAD, "public mutating func feed(rms: Double, trigger: Double) -> Decision"))

    def test_the_floor_is_tracked_from_the_quiet_side_only(self) -> None:
        """The guard that fails if a voiced block can ever raise the floor."""
        tracker = swift_body(VAD, "public mutating func feed(rms: Double, trigger: Double)")
        # A block at or above the trigger is speech: not offered to the floor at all.
        self.assertIn("guard rms < trigger else { return }", tracker)
        # Falls quickly, rises slowly — hysteresis, not a one-shot percentile.
        self.assertIn("config.floorFallFraction", tracker)
        self.assertIn("config.floorRiseFraction", tracker)
        config = swift_body(VAD, "public struct VoiceVADConfig")
        self.assertIn("floorFallFraction: Double = 0.5", config)
        self.assertIn("floorRiseFraction: Double = 0.04", config)
        # Every block is offered to it, from the one place that judges blocks.
        gate = swift_body(VAD, "public struct VoiceUtteranceGate")
        self.assertIn("floor.feed(rms: rms, trigger: trigger)", gate)
        # And the one-shot estimator of the opening blocks is gone, not merely unused.
        self.assertNotIn("floorFromAmbient", self.code(VAD))
        self.assertNotIn("floorFromAmbient", self.code(AUDIO))

    def test_the_ceiling_ends_a_runaway_utterance(self) -> None:
        """An utterance that never goes quiet ends itself at ~20 s and is delivered."""
        config = swift_body(VAD, "public struct VoiceVADConfig")
        self.assertIn("maximumUtteranceSeconds: Double = 20", config)
        gate = swift_body(VAD, "public struct VoiceUtteranceGate")
        self.assertIn("blocks >= config.maximumUtteranceBlocks", gate)
        self.assertIn("return finish(.ceiling)", gate)
        self.assertIn("case ceiling", gate)
        # The log names it, so a ceiling is never confused with a pause in a pasted log.
        listening = AUDIO.split("case .listening:", 1)[1].split("case .thinking, .speaking:", 1)[0]
        self.assertIn("reason == .ceiling", listening)
        self.assertIn('"ceiling \\(String(format:', listening)

    def test_the_log_carries_each_endpoint_and_its_level(self) -> None:
        # Three ways an utterance can end, three lines: the pause, the ceiling (same line, named)
        # and the control. Each carries the numbers the next report is read against.
        endpoints = [line for line in AUDIO.splitlines()
                     if "endpoint: " in line and "logFromAudioThread" in line]
        self.assertEqual(len(endpoints), 3, "every endpoint path must log")
        # The listening pause carries the level the gate ended against; the barge-in collection
        # carries the floor-derived one; the manual stop carries the voiced seconds it kept.
        self.assertTrue(any("silence \\(level)" in line for line in endpoints))
        self.assertTrue(any("silence \\(Int(" in line for line in endpoints))
        manual = [line for line in endpoints if "endpoint: manual, " in line]
        self.assertEqual(len(manual), 1)
        self.assertIn("s voiced, keep ", manual[0])


class StoppingByHand(unittest.TestCase):
    """0.1.692, his second attempt: `stop: requested from listening` — and nothing was sent.

    The tap closed the microphone and took the sentence with it, which made the loop unusable even
    where the endpoint worked: ending a thought by hand is the ordinary way to use it.
    """

    def test_the_words_in_flight_are_taken_before_the_microphone_closes(self) -> None:
        body = swift_body(CONTROLLER, "public func stop(keepingSpeech: Bool = true)")
        self.assertIn("capture.finishCollecting()", body)
        # Before `capture.stop()`: closing the microphone is what drops the buffer.
        self.assertLess(body.index("capture.finishCollecting()"), body.index("capture.stop()"))
        # And sent once the loop has settled, so the state it is sent from is the final one.
        self.assertIn("sendAfterStop(pending)", body)
        self.assertLess(body.index("transition(to: .off)"), body.index("sendAfterStop(pending)"))

    def test_every_exit_he_did_not_ask_for_discards(self) -> None:
        for name in ("private func fail(", "public func noteBackgrounded()",
                     "public func noteConversationChanged()", "private func restartIfActive()"):
            self.assertIn("stop(keepingSpeech: false)", swift_body(CONTROLLER, name), name)
        # The control itself keeps the sentence: that is what the default means.
        self.assertIn("public func stop(keepingSpeech: Bool = true)", CONTROLLER)

    def test_the_engine_hands_back_the_voiced_audio(self) -> None:
        body = swift_body(AUDIO, "public func finishCollecting()")
        self.assertIn("guard collecting else { return nil }", body)
        self.assertIn("voicedBlocks >= config.minimumUtteranceBlocks", body)
        self.assertIn("VoiceWAV.encode(samples: audio", body)
        # The line the next log is read for, in the words the task named.
        self.assertIn('"endpoint: manual, ', body)
        self.assertIn("s voiced, keep ", body)

    def test_a_stopped_loop_still_sends_and_says_nothing(self) -> None:
        body = swift_body(CONTROLLER, "private func sendAfterStop(")
        self.assertIn("transcribe(utterance, how: .sendOnly)", body)
        # Nothing is spoken back into a room he has left, and no watchdog waits for a reply.
        self.assertNotIn("speakReply", body)
        self.assertNotIn("startReplyWatchdog", body)
        still = swift_body(CONTROLLER, "private func isStillDelivering(")
        self.assertIn("case .sendOnly: return state == .off", still)
        # A failed upload on that path cannot fail a conversation that has already ended.
        transcribe = swift_body(CONTROLLER, "private func transcribe(")
        self.assertIn("transcribe: failed after stop", transcribe)


class TheSpokenStop(unittest.TestCase):
    """"Also it was not stopping after i said stop."

    The phrase can only be read from a transcript, and on that phone no utterance ever produced
    one — so a spoken stop was never heard. It must not depend on the endpoint from either side:
    every path that produces a transcript tests for it, first, before anything is sent.
    """

    def test_a_recognised_stop_ends_the_loop_and_sends_nothing(self) -> None:
        body = swift_body(CONTROLLER, "private func transcribe(")
        stop_at = body.index("VoicePolicy.isStopPhrase(text)")
        self.assertLess(stop_at, body.index("self.wiring.sendTurn(text)"))
        after = body[stop_at:]
        self.assertIn("self.stop(keepingSpeech: false)", after)
        self.assertIn("stop phrase: heard", after)
        # The branch returns: the turn is never sent.
        self.assertIn("return", after[:after.index("VoicePolicy.isHallucination(text)")])

    def test_it_is_tested_before_the_other_verdicts(self) -> None:
        body = swift_body(CONTROLLER, "private func transcribe(")
        self.assertLess(body.index("VoicePolicy.isStopPhrase(text)"),
                        body.index("VoicePolicy.isHallucination(text)"))

    def test_no_path_needs_an_endpoint_to_have_fired(self) -> None:
        # Both ways an utterance reaches the host call the same function — the pause/ceiling one
        # and the manual one — and neither holds the stop test itself. A stop test inside `deliver`
        # would be a stop test that only runs when the endpoint worked, which is the bug.
        deliver = swift_body(CONTROLLER, "private func deliver(")
        stopped = swift_body(CONTROLLER, "private func sendAfterStop(")
        self.assertIn("transcribe(utterance, how: .turn)", deliver)
        self.assertIn("transcribe(utterance, how: .sendOnly)", stopped)
        for name in ("private func deliver(", "private func sendAfterStop("):
            self.assertNotIn("isStopPhrase", swift_body(CONTROLLER, name))
        # One shared transcription, so one stop test, in the one place every path arrives.
        self.assertEqual(CONTROLLER.count("VoicePolicy.isStopPhrase(text)"), 1)
        # The pause and the ceiling both leave the capture as the one `.utterance` event; the
        # manual path hands the utterance back to the caller instead, because there is no loop left
        # to receive an event — and both arrive at the same transcription.
        self.assertEqual(AUDIO.count(".utterance(VoiceUtterance("), 2)
        self.assertIn("return VoiceUtterance(", AUDIO)


if __name__ == "__main__":
    unittest.main()
