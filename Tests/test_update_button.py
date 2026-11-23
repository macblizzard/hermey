"""An update is offered on the panel, not opened over it.

Two halves, both pinned from source because neither can be run on Linux:

* the launch check stays — one background check per launch — but the standard user driver is told
  **no** for a *scheduled* update, so nothing opens over the workspace at boot;
* what that check found becomes a glyph on the bot panel's floor bar, immediately left of search,
  which exists only while a version is waiting, and whose press is the *user-initiated* check the
  menu bar and Settings → About run — Sparkle's own download-and-install UI, no second installer.

The README for the arrangement is `UpdateReminder.swift`; these guards are what a later edit could
quietly undo (a `return true`, a button that is always there, a press that runs a background check).
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"

APP = (MAC / "HermesMacApp.swift").read_text(encoding="utf-8")
SIDEBAR = (MAC / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
STORE = (MAC / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
ABOUT = (MAC / "Views" / "AboutSettingsTab.swift").read_text(encoding="utf-8")
REMINDER = (MAC / "Support" / "UpdateReminder.swift").read_text(encoding="utf-8")


def block(source: str, opening: str, closing: str) -> str:
    """The text between one declaration and the next marker, exclusive."""
    assert opening in source, f"{opening!r} is gone"
    tail = source.split(opening, 1)[1]
    assert closing in tail, f"{closing!r} did not follow {opening!r}"
    return tail.split(closing, 1)[0]


class TheLaunchCheckStaysButDrawsNothing(unittest.TestCase):
    """One ask per launch, and no window of Sparkle's over the workspace."""

    def setUp(self) -> None:
        self.launch = block(APP, "private func checkForUpdatesAtLaunch() {", "var body: some Scene {")
        self.should_handle = block(
            REMINDER,
            "func standardUserDriverShouldHandleShowingScheduledUpdate(",
            "    /// Called whether the standard driver handles the update or not.")

    def test_the_launch_still_asks(self) -> None:
        # The trigger is unchanged: a cold start asks, because "at most once a day" would leave a
        # Mac restarted after a release sitting on the old build until tomorrow.
        self.assertIn("updater.updater.checkForUpdatesInBackground()", self.launch)
        self.assertEqual(APP.count("updater.updater.checkForUpdatesInBackground()"), 1,
                         "one launch check, not a second timer")

    def test_the_standard_driver_is_told_no_for_a_scheduled_update(self) -> None:
        # This is the whole behaviour change: the driver's own alert is what used to appear at boot.
        self.assertIn("return false", self.should_handle)
        self.assertNotIn("return true", self.should_handle)

    def test_gentle_scheduled_reminders_are_declared(self) -> None:
        # Without this Sparkle keeps drawing its scheduled alert and the "no" above is never asked.
        self.assertIn("var supportsGentleScheduledUpdateReminders: Bool { true }", REMINDER)

    def test_the_controller_owns_that_delegate_in_both_slots(self) -> None:
        self.assertIn("SPUStandardUpdaterController(startingUpdater: true", APP)
        controller = block(APP, "updater = SPUStandardUpdaterController(", "        #endif")
        self.assertIn("userDriverDelegate: reminder", controller)
        # The updater's delegate is the same object: it is what reports "found nothing".
        self.assertIn("updaterDelegate: reminder", controller)

    def test_a_user_initiated_update_is_not_intercepted(self) -> None:
        # Sparkle handles those itself, and the delegate must not pretend otherwise: the glyph
        # retires on `state.userInitiated` and Sparkle's window takes over.
        will_handle = block(REMINDER, "func standardUserDriverWillHandleShowingUpdate(",
                            "    /// The session ended")
        self.assertIn("state.userInitiated ? nil : update.displayVersionString", will_handle)


class TheFoundVersionReachesTheStore(unittest.TestCase):
    """The delegate reports; the store holds one plain string; the panel reads it."""

    def test_the_store_publishes_the_waiting_version(self) -> None:
        self.assertIn("@Published private(set) var updateAvailable: String?", STORE)
        self.assertIn("@Published private(set) var isInstallingUpdate = false", STORE)

    def test_the_app_hands_the_store_to_the_delegate(self) -> None:
        self.assertIn("reminder.onUpdate = { [weak store] version in store?.offerUpdate(version) }", APP)
        self.assertIn("var onUpdate: (@MainActor (String?) -> Void)?", REMINDER)

    def test_the_delegate_never_imports_the_store_or_sparkle_into_it(self) -> None:
        # The hop is a closure: the delegate knows "a version", and the app knows what to do with it.
        self.assertNotIn("WorkspaceStore", REMINDER)
        # And it is a main-actor hop, not a queue: Sparkle calls these on the main thread already.
        self.assertIn("MainActor.assumeIsolated { deliver(version) }", REMINDER)
        self.assertNotIn("DispatchQueue", REMINDER)

    def test_a_check_that_finds_nothing_retires_the_glyph(self) -> None:
        self.assertIn("func updaterDidNotFindUpdate(", REMINDER)
        self.assertIn("func standardUserDriverWillFinishUpdateSession() {", REMINDER)


class TheButtonIsOnlyThereWhenSomethingWaits(unittest.TestCase):
    def setUp(self) -> None:
        self.bar = block(SIDEBAR, "private var bottomBar: some View {", "    // MARK: Waiting")

    def test_the_glyph_is_inside_the_conditional(self) -> None:
        guard = self.bar.index("if let version = store.updateAvailable {")
        glyph = self.bar.index('HermeyIconButton("arrow.down.circle"')
        self.assertLess(guard, glyph, "the glyph must be behind the version, not beside it")
        # Nothing outside that `if` draws it: the block ends, and no second copy follows.
        self.assertEqual(self.bar.count('HermeyIconButton("arrow.down.circle"'), 1)

    def test_the_label_names_the_version(self) -> None:
        self.assertIn('"Update to \\(version) available"', self.bar)
        self.assertIn('"Downloading \\(version)"', self.bar)
        self.assertIn('.accessibilityIdentifier("sidebar.updateAvailable")', self.bar)

    def test_hover_and_press_are_the_bars_own_treatment(self) -> None:
        # Same control as Settings, search and the toggle — not a bespoke button with its own look.
        # All four wear `.bar`, the 25%-larger bar size.
        glyph = block(self.bar, 'HermeyIconButton("arrow.down.circle"', "            HermeyIconButton(\"magnifyingglass\"")
        self.assertIn("size: .bar", glyph)
        self.assertIn("isBusy: store.isInstallingUpdate", glyph)
        self.assertNotIn(".buttonStyle(", glyph)


class TheButtonSitsInTheRightHandGroupLeftOfSearch(unittest.TestCase):
    def setUp(self) -> None:
        self.bar = block(SIDEBAR, "private var bottomBar: some View {", "    // MARK: Waiting")

    def test_settings_left_then_the_glyph_then_search_then_the_toggle(self) -> None:
        gear = self.bar.index("SettingsLink")
        spacer = self.bar.index("Spacer(minLength: 0)")
        glyph = self.bar.index('HermeyIconButton("arrow.down.circle"')
        search = self.bar.index('HermeyIconButton("magnifyingglass"')
        toggle = self.bar.index('HermeyIconButton("sidebar.left"')
        self.assertLess(gear, spacer, "Settings is still the left group")
        self.assertLess(spacer, glyph, "the update glyph is in the right group")
        self.assertLess(glyph, search, "the update glyph is immediately left of search")
        self.assertLess(search, toggle, "the toggle stays the last control")

    def test_the_bar_keeps_its_height_and_its_dissolve(self) -> None:
        # The 34 pt floor and the gradient above it are the arrangement; a bigger bar or a hairline
        # here would be the cut the dissolve replaced.
        self.assertIn("Self.bottomBarHeight", self.bar)
        self.assertNotIn("Divider()", self.bar)
        self.assertIn("private static let bottomBarHeight: CGFloat = 34", SIDEBAR)


class ThePressIsTheUserInitiatedCheck(unittest.TestCase):
    def setUp(self) -> None:
        self.install = block(STORE, "func installAvailableUpdate() {", "    /// Open one of them")

    def test_the_sidebar_presses_the_stores_verb(self) -> None:
        self.assertIn("store.installAvailableUpdate()", SIDEBAR)

    def test_the_verb_runs_the_shared_user_initiated_closure(self) -> None:
        self.assertIn("let check = checkForUpdates", self.install)
        # Never the silent one: a press is a request for Sparkle's window, not another background
        # probe whose answer nobody asked for.
        self.assertNotIn("checkForUpdatesInBackground", self.install)

    def test_a_second_press_cannot_start_a_second_check(self) -> None:
        guard = self.install.index("guard updateAvailable != nil, !isInstallingUpdate")
        latch = self.install.index("isInstallingUpdate = true")
        press = self.install.index("check()")
        self.assertLess(guard, latch)
        self.assertLess(latch, press, "the latch has to be set before the check is started")

    def test_the_closure_is_still_sparkles_own_check(self) -> None:
        # The glyph adds no updater of its own: it calls the very closure the menu bar, the palette
        # and Settings → About call, which is `updater.checkForUpdates(nil)`.
        self.assertIn("return { self.updater.checkForUpdates(nil) }", APP)
        self.assertIn("store.checkForUpdates = checkForUpdates", APP)
        self.assertNotIn("SPU", SIDEBAR)


class SettingsStillAsksOnItsOwn(unittest.TestCase):
    def test_the_manual_check_is_untouched(self) -> None:
        self.assertIn('Button("Check for Updates…")', ABOUT)
        self.assertIn("checkForUpdates()", ABOUT)
        self.assertIn('.accessibilityIdentifier("aboutCheckForUpdates")', ABOUT)
        menu = APP.split("struct WorkspaceCommands: Commands {", 1)[1]
        self.assertIn('Button("Check for Updates…")', menu)

    def test_the_explicit_check_still_gets_sparkles_window(self) -> None:
        # The delegate only refuses *scheduled* updates; nothing in the app mutes the user's own ask.
        self.assertNotIn("standardUserDriverShouldHandleShowingScheduledUpdate", APP)
        self.assertNotIn("dismissUpdateInstallation", APP)
        self.assertNotIn("supportsGentleScheduledUpdateReminders = false", APP)


class NothingInstallsWithoutAPress(unittest.TestCase):
    def test_no_automatic_downloads_anywhere(self) -> None:
        for name, source in (("app", APP), ("reminder", REMINDER), ("sidebar", SIDEBAR)):
            self.assertNotIn("automaticallyDownloadsUpdates", source, name)
            self.assertNotIn("automaticallyChecksForUpdates", source, name)

    def test_the_delegate_only_reports(self) -> None:
        # It may answer "no", record a version and log it. Anything else here would be a second
        # install path beside Sparkle's.
        for forbidden in ("hdiutil", "Process(", "installUpdate", "checkForUpdates("):
            self.assertNotIn(forbidden, REMINDER, forbidden)


class TheFileCompilesWithoutSparkle(unittest.TestCase):
    def test_the_whole_file_is_behind_the_package_guard(self) -> None:
        self.assertIn("#if canImport(Sparkle)\nimport Sparkle\n", REMINDER)
        self.assertLess(REMINDER.index("#if canImport(Sparkle)"), REMINDER.index("final class UpdateReminder"))
        self.assertEqual(REMINDER.rstrip().rsplit("\n", 1)[-1], "#endif")
        # The guard is a source guard, not a runtime check: a tree without the package simply has
        # no delegate, and the glyph cannot appear because nothing publishes a version.
        self.assertNotIn("#if canImport(Sparkle)\n#endif", REMINDER)


if __name__ == "__main__":
    unittest.main()
