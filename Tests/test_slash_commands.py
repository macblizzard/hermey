"""Slash-command autocomplete in both apps' composers.

The catalogue mirrors the host's own registry; the composer fills a picked command into the draft and
callers that own a native panel act on it. Everything else is left for the user to send, so a command
is never silently swallowed.
"""

from __future__ import annotations

import json
import os
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOGUE = (ROOT / "Sources/HermeyUI/HermesCommandCatalogue.swift").read_text(encoding="utf-8")
COMMAND = (ROOT / "Sources/HermeyUI/HermesCommand.swift").read_text(encoding="utf-8")
COMPOSER = (ROOT / "Sources/HermeyUI/Composer.swift").read_text(encoding="utf-8")
HELP = (ROOT / "Sources/HermeyUI/HermesCommandsHelpSheet.swift").read_text(encoding="utf-8")
IOS = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text(encoding="utf-8")
MAC = (ROOT / "Apps/HermesMac/Conversation/MacComposerBar.swift").read_text(encoding="utf-8")
# An optional cross-check against a host's own command inventory, supplied by whoever runs the
# suite. It used to point at one developer's scratch file, which made the check silently skip for
# everyone else and published that machine's home path in a public repo.
_inventory = os.environ.get("HERMES_COMMAND_INVENTORY")
HOST = json.loads(Path(_inventory).read_text()) \
    if _inventory and Path(_inventory).is_file() else []


class TheCatalogueIsTheHosts(unittest.TestCase):
    def test_every_host_handler_is_offered(self) -> None:
        if not HOST:
            self.skipTest("host command inventory unavailable")
        names = set(re.findall(r'HermesCommand\(name: "([a-z0-9_-]+)"', CATALOGUE))
        missing = {row["name"] for row in HOST} - names
        self.assertEqual(missing, set())
        # The client's own alias for /compress is an addition, not a replacement.
        self.assertIn("compact", names)

    def test_the_verbs_that_have_a_native_panel_are_marked(self) -> None:
        for name, action in (("new", "newSession"), ("reset", "resetConversation"),
                             ("compress", "compact"), ("model", "model"),
                             ("reasoning", "reasoning"), ("help", "help"),
                             ("status", "status")):
            with self.subTest(name=name):
                self.assertRegex(CATALOGUE,
                                 rf'HermesCommand\(name: "{name}",[^\n]*\n\s+systemImage: [^\n]*\.{action}')

    def test_host_only_verbs_are_labelled(self) -> None:
        for name in ("update", "restart", "stop", "approve", "yolo"):
            with self.subTest(name=name):
                self.assertRegex(CATALOGUE,
                                 rf'HermesCommand\(name: "{name}",[\s\S]{{0,240}}?isHostCommand: true\)')


class TypingSlashShowsTheList(unittest.TestCase):
    def test_only_a_single_leading_word_opens_the_popup(self) -> None:
        self.assertIn('text.hasPrefix("/")', COMPOSER)
        self.assertIn('!text.contains(" ")', COMPOSER)
        self.assertIn('HermesCommandCatalogue.all.matching(query)', COMPOSER)
        self.assertIn('ScrollView(.vertical, showsIndicators: true)', COMPOSER)
        self.assertIn('min(CGFloat(commandMatches.count) * 44, 332)', COMPOSER)
        self.assertIn('.frame(height: commandRowHeight)', COMPOSER)
        self.assertIn('LazyVStack', COMPOSER)
        # The height must be on the ScrollView, never on the enclosing VStack: that squashed every
        # row onto one baseline in 546.
        self.assertNotIn(".frame(height: commandPopupHeight)", COMPOSER)

    def test_picking_completes_the_command_and_calls_the_owner(self) -> None:
        self.assertIn("text = command.invocation", COMPOSER)
        self.assertIn("onCommand?(command)", COMPOSER)
        self.assertIn('"/" + name + (argument == nil ? "" : " ")', COMMAND)

    def test_prefix_matches_come_before_substring_matches(self) -> None:
        self.assertIn('filter { $0.name.hasPrefix(needle) }', COMMAND)
        self.assertIn("prefixed.isEmpty", COMMAND)

    def test_return_on_an_exact_native_verb_runs_it(self) -> None:
        self.assertIn('exact.action != .insertOnly', COMPOSER)
        self.assertIn('choose(exact)', COMPOSER)

    def test_both_apps_pass_a_handler(self) -> None:
        self.assertIn("onCommand: runCommand", IOS)
        self.assertIn("onCommand: runCommand", MAC)
        self.assertIn("HermesCommandsHelpSheet", IOS)
        self.assertIn("HermesCommandsHelpSheet", MAC)

    def test_native_actions_run_real_app_methods(self) -> None:
        for source in (IOS, MAC):
            self.assertIn("await model.newSession()", source)
            self.assertIn("await model.resetConversation()", source)
            self.assertIn("await model.compressNow()", source)

    def test_mac_opens_its_model_sheet_for_model_and_reasoning(self) -> None:
        self.assertIn("case .model, .reasoning:", MAC)
        self.assertIn("store.openModel(bot)", MAC)

    def test_help_is_searchable_and_marks_host_commands(self) -> None:
        self.assertIn(".searchable(text: $query", HELP)
        self.assertIn("HermesCommandCatalogue.all.matching(query)", HELP)
        self.assertIn("command.isHostCommand", HELP)
