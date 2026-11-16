"""Structural guards for the three build-453 iOS reports.

Run without the iOS SDK (the views only compile in CI), so each test pins the *shape* of the fix
rather than pixels: a navigation container at the sheet boundary, a device row with both one-way
verbs on it, and cache controls that are neither disabled nor merely re-rendered from the store.

The three defects had one thing in common: the source read as if it worked. Caching and Devices
were unreachable because the settings *sheet* had no `NavigationStack` (a sheet does not inherit the
one it was presented from), which SwiftUI renders as a disabled row; and the bot list's top fade was
an 84 pt overlay anchored to the window's top edge, i.e. entirely behind the status and navigation
bars.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOBILE = ROOT / "Apps" / "HermesMobile" / "Views"
SETTINGS = (MOBILE / "SettingsScreen.swift").read_text(encoding="utf-8")
LIST = (MOBILE / "BotListScreen.swift").read_text(encoding="utf-8")
CACHING = (MOBILE / "CachingSettingsScreen.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")


def block(source: str, start: str, end: str) -> str:
    return source.split(start, 1)[1].split(end, 1)[0]


class SettingsSheetHasANavigationContainer(unittest.TestCase):
    """Report 1 + 2: both rows are `NavigationLink`s, and both were inert."""

    def test_the_sheet_is_presented_through_a_sheet_that_owns_a_stack(self):
        sheet = block(LIST, ".sheet(isPresented: $showAppSettings) {", ".sheet(isPresented: $showStartGroupChat)")
        self.assertIn("SettingsSheet(model: model)", sheet)
        # The bare form is the defect: no stack, so every link inside Settings is disabled.
        self.assertNotIn("SettingsScreen(model: model)", sheet)

    def test_settings_sheet_wraps_the_screen_in_a_navigation_stack(self):
        wrapper = block(SETTINGS, "struct SettingsSheet: View {", "// MARK: - Devices")
        self.assertIn("NavigationStack {", wrapper)
        self.assertIn("SettingsScreen(model: model)", wrapper)
        # A sheet that can push two levels down still needs one way out that is not a gesture.
        self.assertIn('Button("Done")', wrapper)
        self.assertIn("@Environment(\\.dismiss)", wrapper)


class DevicesScreenOffersBothOneWayVerbs(unittest.TestCase):
    """Report 2: revoke and permanent removal, reachable, confirmed, and refreshed."""

    def setUp(self):
        self.screen = block(SETTINGS, "struct DevicesScreen: View {", "// MARK: - Previews")

    def test_revoke_is_a_button_on_the_row_behind_a_confirmation(self):
        self.assertIn('Button("Revoke") {', self.screen)
        self.assertIn("prompt = .revoke(device)", self.screen)
        self.assertIn(".confirmationDialog(prompt?.title", self.screen)
        self.assertIn("titleVisibility: .visible", self.screen)

    def test_removal_is_reachable_without_knowing_about_swipes(self):
        # A trailing swipe alone is a gesture nobody is told about, and the revoked row's toggle was
        # disabled, so removal was effectively unreachable.
        self.assertIn('Button("Remove") {', self.screen)
        self.assertIn("prompt = .remove(device)", self.screen)
        self.assertIn("case remove(PairedDevice)", self.screen)
        self.assertIn('case .remove: return "Remove device"', self.screen)

    def test_both_actions_go_through_the_bridge_and_refresh(self):
        confirm = block(self.screen, "private func confirm(_ prompt: Prompt)", "}\n}")
        self.assertIn("await app.revoke(device)", confirm)
        self.assertIn("await app.loadDevices()", confirm)
        self.assertIn("await app.removeRevoked(device)", confirm)
        # One confirmation surface, not two dialogs stacked on the same list.
        self.assertEqual(self.screen.count(".confirmationDialog("), 1)

    def test_the_one_way_toggle_machinery_is_gone(self):
        # A switch that can only be switched off is not a switch; it also made the row's state read
        # from a local override instead of the host's answer.
        self.assertNotIn("allowedBinding", self.screen)
        self.assertNotIn("allowedOverrides", self.screen)
        self.assertNotIn("Toggle(\"\", isOn:", self.screen)


class CachingControlsAreLive(unittest.TestCase):
    """Report 1: nothing on the screen may be disabled, and every change writes through."""

    def setUp(self):
        self.toggles = block(CACHING, "private var sections: some View {", "// MARK: - Limit")
        self.limit = block(CACHING, "private var limit: some View {", "// MARK: - Usage")
        self.bindings = block(CACHING, "private func binding(for section: CacheSection)", "}\n}")

    def test_the_toggles_are_not_disabled(self):
        self.assertNotIn(".disabled(", self.toggles)

    def test_each_toggle_writes_through_immediately(self):
        self.assertIn("set: { isOn in", self.bindings)
        self.assertIn("await model.setCacheSection(section, enabled: isOn)", self.bindings)
        # Optimistic: the switch keeps the user's position until the store answers, otherwise it
        # snaps back for the length of a disk write and reads as inert.
        self.assertIn("pendingSection[section] = isOn", self.bindings)
        self.assertIn("pendingSection[section] ?? model.cachePreferences.isEnabled(section)", self.bindings)

    def test_the_limit_row_is_the_three_option_menu(self):
        self.assertIn("CacheChatLimit.options", self.limit)
        self.assertIn(".pickerStyle(.menu)", self.limit)
        self.assertIn('accessibilityIdentifier("caching.chatLimit")', self.limit)
        self.assertNotIn("Stepper", self.limit)
        self.assertNotIn(".disabled(", self.limit)
        # The picker's own binding writes through, as the switches do.
        self.assertIn("await model.setCacheChatLimit(chats)", self.bindings)
        self.assertIn("pendingLimit = chats", self.bindings)

    def test_only_the_destructive_reset_is_gated_by_cache_busy(self):
        self.assertEqual(CACHING.count(".disabled(model.cacheBusy)"), 1)
        reset = block(CACHING, "private var reset: some View {", "private func header")
        self.assertIn(".disabled(model.cacheBusy)", reset)
        self.assertIn('accessibilityIdentifier("caching.reset")', reset)

    def test_cache_busy_always_returns_to_false(self):
        # The suspect behind "everything is greyed out": a busy flag that never clears. It is set
        # for a reset only, and cleared by `defer` on every path out of it.
        reset = block(MODEL, "public func resetCache() async {", "// MARK: - Lifecycle")
        self.assertIn("guard !cacheBusy else { return }", reset)
        self.assertIn("cacheBusy = true", reset)
        self.assertIn("defer { cacheBusy = false }", reset)


if __name__ == "__main__":
    unittest.main()
