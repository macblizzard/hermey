"""Two Mac defects the owner reported on the same day.

**A.** "Show Tab Bar" and "Show All Tabs" sat in the View menu of an app that never has tabs, above
the Bigger/Smaller/Default Text Size entries he does use.

**B.** Settings ▸ Agents ▸ "Bot instructions" said *Unavailable* and its Install button did nothing.
Root cause: the host's `GET /v1/local-computers/skill` was a placeholder answering **404**, the app
reads any non-2xx as "the host did not answer", and the button's own POST result was thrown away by
`try?` — so the row had no way to change and no way to complain.

These are source guards: this repository has no macOS build host, so what is checked here is the
arrangement of the code that produces both behaviours.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Apps/HermesMac/HermesMacApp.swift"
MENU = ROOT / "Apps/HermesMac/Support/WindowTabMenu.swift"
VIEW = ROOT / "Apps/HermesMac/Views/LocalComputerSettingsView.swift"
SERVICE = ROOT / "Apps/HermesMac/LocalComputer/LocalComputerService.swift"


class TheViewMenuHasNoTabItems(unittest.TestCase):
    """`NSWindow.allowsAutomaticWindowTabbing` is process-wide and only honoured before the first
    window exists, which is why it is set in the app's own `init` and not in a view."""

    def setUp(self) -> None:
        self.app = APP.read_text(encoding="utf-8")

    def test_the_switch_is_off_and_set_before_any_window_can_exist(self) -> None:
        self.assertIn("NSWindow.allowsAutomaticWindowTabbing = false", self.app)
        switch = self.app.index("NSWindow.allowsAutomaticWindowTabbing = false")
        init = self.app.index("    init() {")
        # Inside `init`, and ahead of the first thing `init` builds.
        self.assertGreater(switch, init)
        self.assertLess(switch, self.app.index("UITestFixture.storeForLaunch()", init))
        # And before the scene body, i.e. before any window is created.
        self.assertLess(switch, self.app.index("var body: some Scene"))

    def test_the_belt_only_touches_tabbing_items(self) -> None:
        menu = MENU.read_text(encoding="utf-8")
        # The two the owner saw, by name, plus AppKit's own selectors for the same family.
        self.assertIn('"Show Tab Bar"', menu)
        self.assertIn('"Show All Tabs"', menu)
        self.assertIn('"toggleTabBar:"', menu)
        self.assertIn('"moveTabToNewWindow:"', menu)
        # The sweep is scoped: it may not name (or remove) anything the owner uses.
        for kept in ("Bigger Text", "Smaller Text", "Default Text Size", "Enter Full Screen"):
            self.assertNotIn(kept, menu)

    def test_the_sweep_runs_once_when_the_window_appears(self) -> None:
        self.assertIn(".onAppear { WindowTabMenu.purge() }", self.app)
        menu = MENU.read_text(encoding="utf-8")
        self.assertIn("guard !purged else { return }", menu)
        self.assertIn("view.removeItem(item)", menu)

    def test_the_text_size_and_full_screen_items_stay(self) -> None:
        # The View menu's own contents, untouched: these live in `CommandGroup(after: .sidebar)`.
        self.assertIn('Button("Bigger Text") { store.stepTextSize(1) }', self.app)
        self.assertIn('Button("Smaller Text") { store.stepTextSize(-1) }', self.app)
        self.assertIn('Button("Default Text Size") { store.resetTextSize() }', self.app)
        # The combinations themselves are registry rows now (`text.bigger`, `text.smaller`,
        # `text.default`); the menu item is still the discoverable copy of each.
        for identifier in ("text.bigger", "text.smaller", "text.default"):
            self.assertIn(f'.hermeyShortcut("{identifier}", using: shortcuts)', self.app)
        # Full screen is AppKit's own item and nothing here replaces or removes it.
        self.assertNotIn("Enter Full Screen", self.app)
        self.assertNotIn(".fullScreen", self.app)


class TheBotInstructionsRowTellsTheTruth(unittest.TestCase):
    """A disabled control has to say why, and a press has to leave a verdict behind."""

    def setUp(self) -> None:
        self.view = VIEW.read_text(encoding="utf-8")
        self.service = SERVICE.read_text(encoding="utf-8")

    def test_the_four_state_words_still_come_from_the_hosts_answer(self) -> None:
        for word in ('"Installed"', '"Update available"', '"Not installed"', '"Yours"'):
            self.assertIn(word, self.view)
        # "Unavailable" survives only for a host that did not answer — never for a healthy one,
        # which now gets a 200 with `present`/`up_to_date` in it.
        self.assertIn('guard let skill = service.skill else { return "Unavailable" }', self.view)

    def test_a_disabled_button_states_its_reason(self) -> None:
        self.assertIn("private var skillDisabledReason: String?", self.view)
        self.assertIn(".disabled(skillDisabledReason != nil)", self.view)
        # The reason is drawn, not just used as a tooltip.
        self.assertIn("if let reason = skillDisabledReason {", self.view)
        # The old gate disabled on the pairing with no explanation at all.
        self.assertNotIn(".disabled(pairedAddress == nil || service.skillBusy)", self.view)

    def test_the_button_is_pressable_whenever_it_can_be_explained(self) -> None:
        # Only two states may disable it, and both name themselves.
        reason = self.view.split("private var skillDisabledReason", 1)[1].split("private var skillTint", 1)[0]
        self.assertIn("service.skillBusy", reason)
        self.assertIn("pairedAddress == nil", reason)
        self.assertIn("return nil", reason)

    def test_the_install_result_is_never_swallowed(self) -> None:
        # The bug: `_ = try? await …` — a 500, a 404 and a dropped socket were all the same nothing.
        install = self.service.split("func installSkill(address:", 1)[1].split("private static func reason", 1)[0]
        self.assertNotIn("_ = try? await", install)
        self.assertIn("skillActionError = Self.reason(data: data, status: http.statusCode)", install)
        self.assertIn("skillActionError = \"The install did not finish:", install)
        self.assertIn("private static func reason(data: Data, status: Int) -> String", self.service)
        self.assertIn('"The host said \\(status): \\(detail)"', self.service)

    def test_the_read_explains_itself_too(self) -> None:
        self.assertIn("@Published private(set) var skillUnavailableReason: String?", self.service)
        self.assertIn('"The host did not answer: \\(error.localizedDescription)"', self.service)
        # A 200 that names work it could not do is not a success.
        self.assertIn('"script_error"', self.service)
        self.assertIn('"failed"', self.service)

    def test_the_row_draws_the_reason_and_the_error(self) -> None:
        self.assertIn("service.skillActionError", self.view)
        self.assertIn("service.skillUnavailableReason", self.view)
        # A host that did not answer is a warning; a host that answered badly is a failure.
        self.assertIn("Tokens.danger", self.view)
        self.assertIn("Tokens.warning", self.view)


if __name__ == "__main__":
    unittest.main()
