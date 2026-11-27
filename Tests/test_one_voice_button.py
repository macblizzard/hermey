"""Guards for the composer's **one** audio control.

The row used to carry two: a bare `mic` that dictated one message, and a `waveform` that opened a
hands-free conversation. The owner's report was that the composer "seems crowded now with multiple
buttons". The decision was one control, no popover:

* **tap** opens the hands-free conversation (and ends it when it is running);
* **hold** dictates — one recording, transcribed into the draft, nothing sent;
* while either is running the control wears that mode, so the state is never ambiguous;
* one line under the composer says so the first time a composer is seen with a session open, once
  per device, and never again;
* one accessibility element that names both actions, with the hold reachable as a named action.

These read the Swift as text: the real gesture needs a finger, a microphone and a paired host, and
none of those exist in CI. Each test pins one thing the merge could silently lose.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
COMPOSER = (UI / "Composer.swift").read_text(encoding="utf-8")
PREFERENCES = (UI / "ComposerPreferences.swift").read_text(encoding="utf-8")
MAC_BAR = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerBar.swift").read_text(encoding="utf-8")
PHONE = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")

SHELLS = (("Mac", MAC_BAR, "loop"), ("iPhone", PHONE, "voiceLoop"))


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


def between(text: str, start: str, end: str) -> str:
    assert start in text, f"missing start marker: {start!r}"
    assert end in text, f"missing end marker: {end!r}"
    return text.split(start, 1)[1].split(end, 1)[0]


class OneControlInTheRow(unittest.TestCase):
    def test_the_composer_draws_exactly_one_audio_control(self) -> None:
        row = between(COMPOSER,
                      "HStack(alignment: .bottom, spacing: 8) {",
                      "rowCentred(Group {")
        # One insertion, at the foot of the row, where the microphone used to be.
        self.assertEqual(row.count("rowCentred(voiceControl)"), 1)
        self.assertNotIn("micControl", row)
        self.assertNotIn("voiceModeControl", row)
        # And one slot to fill: a single config, not a pair of independent buttons.
        self.assertEqual(COMPOSER.count("private let voice: ComposerVoiceButton?"), 1)

    def test_the_two_glyphs_and_their_plumbing_are_gone(self) -> None:
        # A stale `onMic` that nothing calls is a trap for the next change, so it is removed rather
        # than left as a second, hidden way in.
        for dead in ("showsMic", "micSystemImage", "micTint", "micAccessibilityLabel",
                     "isMicEnabled", "onMic", "showsVoiceMode", "voiceModeSystemImage",
                     "voiceModeTint", "voiceModeAccessibilityLabel", "onVoiceMode",
                     "micControl", "voiceModeControl", "toggleRecording"):
            self.assertNotIn(dead, COMPOSER, f"{dead} is still declared or drawn")
        for name, shell, _ in SHELLS:
            for dead in ("showsMic", "micSystemImage", "onMic:", "onVoiceMode", "showsVoiceMode"):
                self.assertNotIn(dead, shell, f"{name} still wires {dead}")

    def test_each_shell_supplies_one_control_with_both_gestures(self) -> None:
        for name, shell, _ in SHELLS:
            self.assertEqual(shell.count("ComposerVoiceButton("), 1, name)
            # The Mac's tap is also ⌥⌘V's method, so it carries the verb's name: the gesture and
            # the menu item are one path (`toggleVoiceMode`). The phone has no keyboard and keeps
            # the gesture's own name.
            tap = "toggleVoiceMode()" if name == "Mac" else "voiceControlTap()"
            self.assertIn(f"onTap: {{ {tap} }}", shell, name)
            self.assertIn("onHold: { voiceControlHold() }", shell, name)

    def test_the_dictation_controller_survives_the_merge(self) -> None:
        # The microphone went; what it drove did not. Long-press is a second door onto the same
        # recorder, not a reimplementation of it.
        for shell, _ in ((MAC_BAR, "voice"), (PHONE, "voice")):
            hold = swift_body(shell, "private func voiceControlHold()")
            self.assertIn("voice.startRecording()", hold)
        self.assertTrue((ROOT / "Apps" / "HermesMac" / "Conversation" / "MacVoiceController.swift").exists())
        self.assertTrue((ROOT / "Apps" / "HermesMobile" / "Views" / "VoiceController.swift").exists())


class TwoGestures(unittest.TestCase):
    def test_the_composer_tells_a_tap_from_a_hold(self) -> None:
        body = swift_body(COMPOSER, "private var voiceControl: some View")
        # Exclusive, not simultaneous: a `Button` fires on touch-up even after a long press has
        # begun, which would make one press read as two actions.
        self.assertIn("TapGesture()", body)
        self.assertIn(".exclusively(before: LongPressGesture(minimumDuration: Self.voiceHoldSeconds)",
                      body)
        self.assertIn("case .first: voice.onTap()", body)
        self.assertIn("case .second: voice.onHold()", body)
        # The hold is a real duration, not the platform's accidental one.
        self.assertIn("static let voiceHoldSeconds: Double = 0.45", COMPOSER)

    def test_the_tap_opens_the_conversation(self) -> None:
        for name, shell, loop in SHELLS:
            # The Mac's tap is `toggleVoiceMode` (⌥⌘V is the same method); the phone's tap is the
            # gesture's name and routes through its own `toggleVoiceMode`.
            signature = ("private func toggleVoiceMode()" if name == "Mac"
                         else "private func voiceControlTap()")
            tap = swift_body(shell, signature)
            if name == "Mac":
                self.assertIn(f"{loop}.start()", tap)
            else:
                # The phone routes through the same `toggleVoiceMode` the loop always used, after
                # it has dealt with a dictation that is already running.
                self.assertIn("toggleVoiceMode()", tap)
                self.assertIn("voiceLoop.start()", swift_body(shell, "private func toggleVoiceMode()"))
            self.assertNotIn("startRecording", tap,
                             f"{name}: the tap is not a dictation")

    def test_the_hold_dictates_and_sends_nothing(self) -> None:
        for name, shell, _ in SHELLS:
            hold = swift_body(shell, "private func voiceControlHold()")
            self.assertIn("voice.startRecording()", hold)
            # Dictation puts words in the draft. It has never sent, and the merge must not start.
            self.assertNotIn("send(", hold)
            self.assertNotIn("sendTurn", hold)
            self.assertNotIn("loop.start()", hold)


class OneMicrophone(unittest.TestCase):
    """Starting one of the two always stops the other. Two captures on one input is a howl."""

    def test_a_hold_ends_the_conversation_before_it_records(self) -> None:
        for name, shell, loop in SHELLS:
            hold = swift_body(shell, "private func voiceControlHold()")
            stop = hold.index(f"if {loop}.isActive {{ {loop}.stop() }}")
            start = hold.index("voice.startRecording()")
            self.assertLess(stop, start, f"{name}: the loop is still open when dictation starts")

    def test_a_tap_ends_dictation_before_it_listens(self) -> None:
        mac = swift_body(MAC_BAR, "private func toggleVoiceMode()")
        self.assertLess(mac.index("voice.cancel()"), mac.index("loop.start()"))
        phone = swift_body(PHONE, "private func toggleVoiceMode()")
        self.assertLess(phone.index("voice.cancel()"), phone.index("voiceLoop.start()"))

    def test_the_tap_that_stops_dictation_is_not_the_tap_that_starts_the_loop(self) -> None:
        # A tap while dictation is recording stops and transcribes; it does not open the loop over
        # the top of a live capture.
        body = swift_body(PHONE, "private func voiceControlTap()")
        self.assertLess(body.index("if voice.state == .recording"),
                        body.index("toggleVoiceMode()"))
        mac = swift_body(MAC_BAR, "private func toggleVoiceMode()")
        self.assertLess(mac.index("if voice.isRecording"), mac.index("loop.start()"))


class TheOneTimeHint(unittest.TestCase):
    def test_the_hint_is_remembered_per_device(self) -> None:
        # `@AppStorage` over a `UserDefaults` key: per device by construction, written once, read
        # on every composer after that.
        self.assertIn('voiceHintSeenKey = "hermey.composer.voiceHintSeen"', PREFERENCES)
        self.assertIn("@AppStorage(ComposerPreferences.voiceHintSeenKey)", COMPOSER)
        self.assertIn("private var voiceHintSeen = false", COMPOSER)

    def test_it_waits_for_a_session_and_never_repeats(self) -> None:
        body = swift_body(COMPOSER, "private var showsVoiceHint: Bool")
        self.assertIn("guard voice != nil, !voiceHintSeen, !isDisabled else { return false }", body)
        # The state line wins the space while something is recording: one line, not two.
        self.assertIn("return hint?.isEmpty ?? true", body)

    def test_one_line_that_can_be_dismissed(self) -> None:
        body = swift_body(COMPOSER, "private var voiceHintRow: some View")
        self.assertIn("Text(ComposerPreferences.voiceHintText)", body)
        self.assertIn("Button { voiceHintSeen = true }", body)
        self.assertIn('accessibilityLabel("Dismiss the voice hint")', body)
        # Quiet and inline: a line under the card, not a modal, a sheet, a popover or a toast.
        for loud in (".sheet", ".alert", ".popover", ".confirmationDialog"):
            self.assertNotIn(loud, body)

    def test_using_the_control_also_teaches_it(self) -> None:
        # Once it has been used, the lesson has landed — the hint cannot come back next launch.
        usage = swift_body(COMPOSER, "private var voiceControl: some View")
        self.assertIn("voiceHintSeen = true", usage)

    def test_the_line_names_both_gestures(self) -> None:
        self.assertIn('voiceHintText = "Tap to talk hands-free · hold to dictate"', PREFERENCES)


class OneAccessibleElement(unittest.TestCase):
    def test_the_element_names_both_actions(self) -> None:
        for name, shell, _ in SHELLS:
            label = swift_body(shell, "private var voiceControlLabel")
            self.assertIn('"Voice conversation; hold to dictate"', label, name)
        body = swift_body(COMPOSER, "private var voiceControl: some View")
        self.assertIn(".accessibilityLabel(voice.label)", body)

    def test_the_hold_is_reachable_without_holding(self) -> None:
        # VoiceOver cannot time a press, so dictation is a named action on the same element.
        body = swift_body(COMPOSER, "private var voiceControl: some View")
        self.assertIn(".accessibilityAction(named: Text(ComposerPreferences.dictationActionName))",
                      body)
        self.assertIn("voice.onHold()", body)
        self.assertIn('dictationActionName = "Dictate"', PREFERENCES)

    def test_it_is_one_element_and_not_two_glyphs(self) -> None:
        body = swift_body(COMPOSER, "private var voiceControl: some View")
        self.assertIn(".accessibilityElement()", body)
        self.assertIn(".accessibilityAddTraits(.isButton)", body)
        self.assertIn('accessibilityIdentifier("composer.voice")', body)
        self.assertNotIn('"composer.mic"', COMPOSER)
        self.assertNotIn('"composer.voicemode"', COMPOSER)
        # The label is the state while something runs, so the element is never silent about it.
        for name, shell, _ in SHELLS:
            label = swift_body(shell, "private var voiceControlLabel")
            self.assertIn("tap to end it, hold to dictate", label, name)
            self.assertIn('"Recording a dictation; tap to stop and transcribe"', label, name)


class WhatTheControlShows(unittest.TestCase):
    def test_at_rest_it_is_the_conversation(self) -> None:
        # The resting glyph is the loop's own "off" symbol, taken from the loop rather than typed
        # again: a tap at rest opens the conversation, so the control must look like one.
        for name, shell, loop in SHELLS:
            glyph = swift_body(shell, "private var voiceControlGlyph")
            self.assertIn(f"if {loop}.state.ownsMicrophone {{ return {loop}.state.glyph }}",
                          glyph, name)
            self.assertIn("return VoiceLoopState.off.glyph", glyph, name)

    def test_dictation_owns_the_glyph_while_it_records(self) -> None:
        for name, shell, _ in SHELLS:
            self.assertIn('"stop.circle.fill"',
                          swift_body(shell, "private var dictationGlyph"), name)
            tint = swift_body(shell, "private var voiceControlTint")
            self.assertIn("Tokens.danger", tint, name)

    def test_the_loop_owns_the_tint_while_it_listens(self) -> None:
        for name, shell, loop in SHELLS:
            tint = swift_body(shell, "private var voiceControlTint")
            self.assertLess(tint.index(f"{loop}.state.ownsMicrophone"), tint.index("Tokens.danger"),
                            f"{name}: the recording red must not outrank the live conversation")


if __name__ == "__main__":
    unittest.main()
