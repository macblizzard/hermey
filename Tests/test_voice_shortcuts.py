"""Two keyboard rows for the composer's one audio control: ⌥⌘V talks, ⌥⌘D dictates.

The owner asked: *"do we have keyboard shortcut set for the voice conversation mode? if not then
please add that option on shortcut settings, i need that to be able to just hit the keys and talk
to the bots"*. Until this file there was no `voice.` row in `ShortcutRegistry`, so the one audio
control in the composer — tap for hands-free, hold to dictate — was mouse-only.

What is pinned here, and why each half matters:

* **The rows are the registry's, not the pane's.** `ShortcutsSettingsTab` iterates
  `ShortcutRegistry.actions`, so adding a row is enough to make it rebindable, clearable with ⌫,
  resettable per row and by Restore Defaults, refused on conflict and applied live by
  `ShortcutMenuSync`. Nothing in this feature reimplements any of that, and a title spelled in the
  pane would be the second copy that pane exists to refuse.
* **The menu resolves both ids through `.hermeyShortcut`.** A row whose `menuItemTitles` are not
  read by the menu bar is a row with no key at all (`test_shortcuts_panel` already refuses that),
  and a key spelled by hand is the drift the registry was built to stop.
* **The keys land where the microphone already lives.** The loop and the recorder belong to
  `MacComposerBar` (one microphone per conversation, wired to the bot on screen and torn down with
  the bar), so the menu posts a request the bar answers — the pattern
  `MessageMenuDirectory.requestActions()` already uses — and the bar runs the *same* methods its
  gesture runs. A second `VoiceLoopController` would be a second listener on one input device.
* **Neither action is a stub.** Each function a key reaches is asserted to contain the start *and*
  the stop it promises, so a row that posts a notification nobody answers, or answers it with a
  `return`, fails here rather than on the owner's desk.
* **The conversation's item says which state it is in**, like "Show/Hide Bot Panel": the loop
  cannot be read from the menu, so the composer mirrors one published bit onto the store.
* **Mac only, and it says so.** The phone has no keyboard; it reaches the same two methods through
  the control's tap and hold, and the rows carry a note saying exactly that.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

# The registry table parsed by the pane's own guard: one parser, so the two files cannot disagree
# about what "the registry has this row" means.
from test_shortcuts_panel import registry_rows  # noqa: E402

REGISTRY = ROOT / "Sources" / "HermesKit" / "ShortcutRegistry.swift"
APP = ROOT / "Apps" / "HermesMac" / "HermesMacApp.swift"
PANE = ROOT / "Apps" / "HermesMac" / "Views" / "ShortcutsSettingsTab.swift"
STORE = ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift"
BAR = ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerBar.swift"
DIRECTORY = ROOT / "Apps" / "HermesMac" / "Conversation" / "VoiceShortcutDirectory.swift"
PHONE = ROOT / "Apps" / "HermesMobile"

CONVERSATION = "voice.conversation"
DICTATE = "voice.dictate"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def without_comments(text: str) -> str:
    """The source with its `//` lines stripped: a guard about code must not read prose."""
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def between(text: str, start: str, end: str) -> str:
    assert start in text, f"missing start marker: {start!r}"
    body = text.split(start, 1)[1]
    assert end in body, f"missing end marker: {end!r}"
    return body.split(end, 1)[0]


def rows_by_id() -> dict[str, dict]:
    return {row["id"]: row for row in registry_rows()}


class TheRows(unittest.TestCase):
    def test_both_ids_exist_with_a_default_a_group_and_a_title(self) -> None:
        rows = rows_by_id()
        for identifier in (CONVERSATION, DICTATE):
            self.assertIn(identifier, rows, f"{identifier} has no registry row")
            row = rows[identifier]
            self.assertTrue(row["title"], f"{identifier} has no title for the pane")
            self.assertTrue(row["raw"].count("defaultCombo:"), f"{identifier} declares no default")
            self.assertIsNotNone(row["combo"], f"{identifier} ships unbound — the owner asked for keys")

    def test_the_defaults_are_what_was_asked_for(self) -> None:
        rows = rows_by_id()
        self.assertEqual(rows[CONVERSATION]["combo"], ("v", frozenset({"option", "command"})),
                         "Voice Conversation must ship on ⌥⌘V")
        self.assertEqual(rows[DICTATE]["combo"], ("d", frozenset({"option", "command"})),
                         "Dictate a Message must ship on ⌥⌘D — ⌃⌘D is macOS's Look Up in Dictionary")

    def test_the_groups_are_conversation_and_message(self) -> None:
        rows = rows_by_id()
        self.assertEqual(rows[CONVERSATION]["group"], "conversation")
        self.assertEqual(rows[DICTATE]["group"], "message")

    def test_the_conversation_row_names_both_states_and_dictation_names_one(self) -> None:
        rows = rows_by_id()
        self.assertEqual(rows[CONVERSATION]["menu_titles"],
                         ["Start Voice Conversation", "Stop Voice Conversation"],
                         "the menu sync finds an item by title: both states must be declared")
        self.assertIn("Dictate a Message", rows[DICTATE]["menu_titles"])

    def test_the_titles_are_not_spelled_in_the_pane(self) -> None:
        # The pane is a view of the registry. A literal here is the second copy the pane refuses.
        pane = read(PANE)
        for identifier in (CONVERSATION, DICTATE):
            title = rows_by_id()[identifier]["title"]
            self.assertNotIn(title, pane, f"{title!r} is spelled in the pane; draw it from the registry")
        self.assertIn("ShortcutRegistry.actions", pane, "the pane must still be a view of the registry")

    def test_neither_row_collides_with_the_other_or_with_macos(self) -> None:
        # THE duplicate guard, stated for these two rows as well as by `test_shortcuts_panel`.
        holders: dict[tuple, list[str]] = {}
        for row in registry_rows():
            if row["combo"] is None:
                continue
            holders.setdefault(row["combo"], []).append(row["id"])
        clashes = {combo: ids for combo, ids in holders.items() if len(ids) > 1}
        self.assertEqual(clashes, {}, f"two actions share a combination: {clashes}")
        self.assertNotEqual(rows_by_id()[CONVERSATION]["combo"], rows_by_id()[DICTATE]["combo"])

        reserved = between(read(REGISTRY), "public static let reserved: [ShortcutCombo] = [", "\n    ]")
        reserved_combos = set(re.findall(r'ShortcutCombo\(\s*"([^"]+)"((?:\s*,\s*\.\w+)*)\s*\)', reserved))
        for key, modifiers in reserved_combos:
            rendered = (key.lower(), frozenset(re.findall(r"\.(\w+)", modifiers)))
            for identifier in (CONVERSATION, DICTATE):
                self.assertNotEqual(rows_by_id()[identifier]["combo"], rendered,
                                    f"{identifier} ships on a combination macOS keeps")

    def test_both_rows_say_they_are_mac_only(self) -> None:
        for identifier in (CONVERSATION, DICTATE):
            note = rows_by_id()[identifier]["raw"]
            self.assertIn("Mac only", note, f"{identifier} must say the phone has no keyboard")
            self.assertIn("phone", note, f"{identifier} must name the phone as the reason")


class TheMenu(unittest.TestCase):
    def test_the_menu_resolves_both_ids_through_the_registry(self) -> None:
        app = read(APP)
        for identifier in (CONVERSATION, DICTATE):
            self.assertIn(f'.hermeyShortcut("{identifier}", using: shortcuts)', app,
                          f"{identifier} is not wired through the registry in the menu bar")
        self.assertNotIn(".keyboardShortcut(", app, "a menu must not spell a combination")

    def test_the_menu_posts_a_request_rather_than_holding_a_controller(self) -> None:
        app = without_comments(read(APP))
        self.assertIn("VoiceShortcutDirectory.requestConversationToggle()", app)
        self.assertIn("VoiceShortcutDirectory.requestDictation()", app)
        # The loop is the composer's. A menu that constructed one would be a second listener.
        self.assertNotIn("VoiceLoopController(", app)
        self.assertNotIn("MacVoiceController(", app)

    def test_the_conversation_item_reads_the_state_it_flips(self) -> None:
        app = read(APP)
        self.assertIn('store.isVoiceConversationRunning ? "Stop Voice Conversation" : "Start Voice Conversation"',
                      app, "the item must flip its title like Show/Hide Bot Panel")
        self.assertIn('Button("Dictate a Message")', app)


class TheDirectory(unittest.TestCase):
    def test_both_requests_post_the_names_the_bar_receives(self) -> None:
        directory = read(DIRECTORY)
        posts = re.findall(r"NotificationCenter\.default\.post\(name: \.(\w+)", directory)
        self.assertEqual(sorted(posts), ["voiceConversationToggleRequested", "voiceDictationRequested"])

        bar = read(BAR)
        for name in posts:
            self.assertIn(f"publisher(for: .{name})", bar,
                          f"nothing in the composer answers .{name}")

    def test_the_directory_is_not_a_singleton_controller(self) -> None:
        directory = read(DIRECTORY)
        self.assertNotIn("static let shared", directory,
                         "the pattern is a request, not a shared controller")
        self.assertIn("enum VoiceShortcutDirectory", directory)


class TheActionsAreReal(unittest.TestCase):
    """Each key must reach the code the composer control already uses — and that code must work."""

    def setUp(self) -> None:
        self.bar = read(BAR)

    def body(self, signature: str) -> str:
        return between(self.bar, signature, "\n    }")

    def test_the_controls_two_gestures_are_the_two_actions(self) -> None:
        # The tap and the hold call the same methods the keys do; that is what makes this the
        # control's keyboard, not a second audio path.
        self.assertIn("onTap: { toggleVoiceMode() }", self.bar)
        self.assertIn("onHold: { voiceControlHold() }", self.bar)

    def test_the_conversation_key_runs_the_toggle_and_the_toggle_works(self) -> None:
        receive = between(self.bar,
                          "publisher(for: .voiceConversationToggleRequested)) { _ in",
                          "        }")
        self.assertIn("toggleVoiceMode()", receive)

        toggle = self.body("private func toggleVoiceMode() {")
        self.assertIn("loop.start()", toggle, "the toggle never starts the conversation")
        self.assertIn("loop.stop()", toggle, "the toggle never stops the conversation")
        # The one-microphone rule, kept in the action both doors share.
        self.assertIn("voice.cancel()", toggle)
        self.assertIn("voice.stopAndTranscribe()", toggle)

    def test_the_dictation_key_starts_and_stops_the_same_recording(self) -> None:
        receive = between(self.bar,
                          "publisher(for: .voiceDictationRequested)) { _ in",
                          "        }")
        self.assertIn("toggleDictation()", receive)

        toggle = self.body("private func toggleDictation() {")
        self.assertIn("voice.stopAndTranscribe()", toggle,
                      "a second press must stop and transcribe, not start a second capture")
        self.assertIn("voiceControlHold()", toggle,
                      "the start must be the hold's own method, not a second copy of it")

        hold = self.body("private func voiceControlHold() {")
        self.assertIn("voice.startRecording()", hold, "dictation never opens the microphone")
        # One start, one microphone: the hold closes the loop before it records, and refuses
        # without a session rather than opening a capture with nowhere to send it.
        self.assertLess(hold.index("if loop.isActive { loop.stop() }"),
                        hold.index("voice.startRecording()"))
        self.assertIn("canRecordVoice", hold)

    def test_the_transcript_lands_in_the_draft_and_sends_nothing(self) -> None:
        # The promise on the row ("nothing is sent") is the recorder's own sink.
        self.assertIn("voice.transcriptSink", self.bar)
        sink = between(self.bar, "voice.transcriptSink = { text in", "\n        }")
        self.assertIn("model.draft", sink)
        self.assertNotIn("store.send()", sink, "dictation must never send what it heard")


class TheStateTitle(unittest.TestCase):
    def test_the_store_publishes_the_one_bit_the_menu_reads(self) -> None:
        store = read(STORE)
        self.assertIn("@Published private(set) var isVoiceConversationRunning = false", store)
        self.assertIn("func noteVoiceConversationRunning(_ running: Bool)", store)

    def test_the_composer_is_the_only_writer_and_it_writes_every_exit(self) -> None:
        bar = read(BAR)
        self.assertIn("store.noteVoiceConversationRunning(loop.isActive)", bar,
                      "a spoken stop or a failure must flip the title back")
        self.assertIn(".onChange(of: loop.state)", bar)
        self.assertIn("store.noteVoiceConversationRunning(false)", bar,
                      "leaving the bar must clear it")

    def test_the_phone_does_not_bind_either_key(self) -> None:
        # No keyboard on the phone, so the rows are Mac-only in effect.
        for path in PHONE.rglob("*.swift"):
            text = read(path)
            for identifier in (CONVERSATION, DICTATE):
                self.assertNotIn(f'.hermeyShortcut("{identifier}"', text,
                                 f"{path.name} binds {identifier}; the phone has no keyboard")


if __name__ == "__main__":
    unittest.main()
