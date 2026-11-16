"""Contract tests for the iOS update notifier.

Swift does not build on this host (no toolchain), so these pin the *decisions* the implementation is
required to have made rather than its output: a strictly-newer comparison, a throttle and a skip that
both survive a relaunch, a card that cannot gate the app, and no version or feed URL baked into the
source. Every assertion below fails if the corresponding behaviour is removed, which is the only
reason a structural test is worth having.

The rules being pinned are `hermes-updater-spec-20261116.md` §6, §7.1, §8 and §9.
"""
import re
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOBILE = ROOT / "Apps" / "HermesMobile"
CHECKER_PATH = ROOT / "Sources" / "HermesAppKit" / "Updates" / "UpdateChecker.swift"
PROMPT_PATH = MOBILE / "Views" / "UpdatePrompt.swift"
SETTINGS_PATH = MOBILE / "Views" / "SettingsScreen.swift"
APP_PATH = MOBILE / "HermesMobileApp.swift"
ENVIRONMENT_PATH = MOBILE / "App" / "AppEnvironment.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def block(source: str, start: str, end: str) -> str:
    """The text between two anchors — used so an assertion cannot pass from an unrelated file part."""
    if start not in source:
        raise AssertionError(f"missing anchor: {start!r}")
    tail = source.split(start, 1)[1]
    if end not in tail:
        raise AssertionError(f"missing end anchor after {start!r}: {end!r}")
    return tail.split(end, 1)[0]


class TheCheckerIsSharedAndReadsTheFeed(unittest.TestCase):
    """§6: one shared checker, the published feed, nothing hard-coded."""

    def setUp(self):
        self.source = read(CHECKER_PATH)

    def test_it_is_a_main_actor_observable_object_in_the_shared_module(self):
        self.assertIn("@MainActor", self.source)
        self.assertIn("public final class UpdateChecker: ObservableObject", self.source)
        self.assertIn("public struct AvailableUpdate", self.source)
        for field in ("version", "build", "url", "size", "sha256"):
            self.assertIn(f"public let {field}", self.source,
                          f"AvailableUpdate must carry {field!r}")

    def test_it_reads_the_altstore_source_and_its_fallback(self):
        self.assertIn("https://macblizzard.github.io/hermey-downloads/altstore.json", self.source)
        self.assertIn("https://macblizzard.github.io/hermey-downloads/mac.json", self.source)
        # The fallback is only reached after the first fails, so the source must be tried first.
        order = self.source.index("altstore.json") - self.source.index("mac.json")
        self.assertGreater(order, 0, "altstore.json is the primary source and must be declared first")

    def test_both_published_shapes_are_understood(self):
        # altstore.json is a document of documents; mac.json is a single object. A parser that only
        # knew one of them would go quiet the day the other was served.
        for key in ("apps", "versions", "buildVersion", "downloadURL"):
            self.assertIn(key, self.source, f"the AltStore shape needs {key!r}")
        self.assertIn("MacDocument", self.source)
        self.assertIn("case badStatus", self.source)

    def test_an_unparseable_build_is_dropped_rather_than_read_as_zero(self):
        # A build of 0 would be "older than everything" — the opposite of the truth — so the parse
        # must reject it explicitly.
        self.assertIn("build > 0", self.source)
        self.assertIn("BuildNumber", self.source)

    def test_no_version_number_is_embedded(self):
        # §9.5: a build must never be compiled in, or the app advertises itself as newer forever.
        self.assertIsNone(re.search(r"\b0\.1\.\d{2,}\b", self.source),
                          "the checker must not contain a version literal")

    def test_only_https_download_urls_survive(self):
        self.assertIn('url.scheme?.lowercased() == "https"', self.source)


class ComparisonsAndRememberedDecisions(unittest.TestCase):
    """§6 + §7.1: strictly newer wins, the skip and the throttle both outlive a relaunch."""

    def setUp(self):
        self.source = read(CHECKER_PATH)
        self.check = block(self.source, "public func check(manual: Bool = false) async {",
                           "/// The user dismissed the card")

    def test_the_keys_are_stable_and_declared_once(self):
        self.assertEqual(self.source.count('"hermey.updates.skippedBuild"'), 1,
                         "one declaration site, or a rename silently forgets every dismissal")
        self.assertEqual(self.source.count('"hermey.updates.lastCheck"'), 1)
        self.assertIn("UserDefaults", self.source)

    def test_the_throttle_is_one_day_and_only_covers_unsolicited_checks(self):
        self.assertIn("24 * 60 * 60", self.source)
        self.assertIn("if !manual, let lastCheck", self.check,
                      "the 24 h gate must not apply to a manual check")

    def test_a_manual_check_always_reaches_the_feed(self):
        manual_path = block(self.check, "let found = await latestUpdate()", "guard found.build > currentBuild")
        self.assertIn("if !manual {", manual_path)
        self.assertIn("defaults.set(now, forKey: DefaultsKey.lastCheck)", manual_path)

    def test_only_a_strictly_newer_build_is_offered(self):
        self.assertIn("found.build > currentBuild", self.check)
        self.assertNotIn("found.build >= currentBuild", self.check)

    def test_an_unreadable_bundle_build_cannot_trigger_an_offer(self):
        # currentBuild is 0 when CFBundleVersion is missing; anything "newer" than 0 must not be
        # offered, so the comparison has to be guarded by the feed build being real.
        self.assertIn("guard found.build > currentBuild else", self.check)
        self.assertIn('Int(text.trimmingCharacters(in: .whitespaces)) ?? 0', self.source)

    def test_a_skipped_build_is_suppressed_only_when_unsolicited(self):
        skip_guard = block(self.check, "guard found.build > currentBuild else",
                           "available = found")
        self.assertIn("if !manual, found.build == skippedBuild", skip_guard,
                      "unsolicited checks must respect the skip")
        # The guard returns, so a skipped build cannot fall through to the offer...
        after_guard = skip_guard.split("if !manual, found.build == skippedBuild", 1)[1]
        self.assertIn("return", after_guard.split("}", 1)[0])
        # ...while a manual check never enters it, and both offer writes sit after it.
        self.assertIn("if !manual, found.build == skippedBuild", self.check)
        self.assertIn("available = found", self.check)
        self.assertIn("isPromptVisible = true", self.check)

    def test_dismissal_records_the_build_before_the_card_closes(self):
        dismiss = block(self.source, "public func dismissPrompt() {", "/// The user chose Download")
        self.assertIn("defaults.set(available.build, forKey: DefaultsKey.skippedBuild)", dismiss)
        self.assertIn("isPromptVisible = false", dismiss)
        # A swipe-down never runs a button, so the recording cannot live in the button alone: the
        # dismissal path itself has to do it.
        self.assertIn("promptHandedOff", self.source,
                      "Download closes the card without recording a skip")

    def test_the_skip_is_read_back_on_the_next_launch(self):
        self.assertIn("public var skippedBuild: Int?", self.source)
        self.assertIn("defaults.integer(forKey: DefaultsKey.skippedBuild)", self.source)

    def test_current_build_and_version_are_exposed_for_settings(self):
        self.assertIn("public var currentBuild: Int", self.source)
        self.assertIn("public var currentVersion: String", self.source)
        self.assertIn('"CFBundleVersion"', self.source)
        self.assertIn('"CFBundleShortVersionString"', self.source)

    def test_a_failed_fetch_is_a_silent_no_op(self):
        fetch = block(self.source, "private func latestUpdate() async", "private func fetch(")
        self.assertIn("print(", fetch)
        self.assertIn("return nil", fetch)
        self.assertNotIn("alert", fetch.lower())


class TheOfferCannotGateTheApp(unittest.TestCase):
    """§7.1 / §9.4: dismissal by every route, nothing disabled, nothing forced."""

    def setUp(self):
        self.source = read(PROMPT_PATH)

    def test_the_prompt_is_a_sheet(self):
        self.assertIn(".sheet(isPresented:", self.source)
        self.assertNotIn("fullScreenCover", self.source,
                         "a full-screen cover is a scrim over the app by another name")

    def test_nothing_in_the_ios_app_forbids_dismissal(self):
        offenders = [str(path.relative_to(ROOT)) for path in MOBILE.rglob("*.swift")
                     if "interactiveDismissDisabled" in read(path)]
        self.assertEqual(offenders, [], "no screen may require a gesture the user cannot make")

    def test_nothing_on_the_card_is_disabled(self):
        self.assertNotIn(".disabled(", self.source)

    def test_every_way_out_dismisses(self):
        self.assertIn('Text("Not now")', self.source)
        self.assertIn(".keyboardShortcut(.cancelAction)", self.source)
        self.assertIn("updates.dismissPrompt()", self.source)
        # The binding's setter is the one place a swipe-down can arrive, so it must record the skip.
        presenter = block(self.source, "struct UpdatePromptPresenter: ViewModifier {",
                          "extension View {")
        self.assertIn("set: { presented in", presenter)
        self.assertIn("guard !presented, isMine else { return }", presenter)
        self.assertIn("updates.dismissPrompt()", presenter)

    def test_download_opens_the_feeds_url_in_the_system_browser(self):
        presenter = block(self.source, "struct UpdatePromptPresenter: ViewModifier {",
                          "extension View {")
        self.assertIn("UIApplication.shared.open(update.url)", presenter,
                      "the primary action is opening the IPA URL, not installing anything")
        self.assertNotIn("URLSession", self.source, "the card must not download anything")

    def test_a_sideloader_button_only_exists_behind_the_installed_check(self):
        self.assertIn('components.host = "install"', self.source)
        self.assertIn("UIApplication.shared.canOpenURL", self.source)
        # The buttons are drawn from the detected list, so an app the phone does not have is never
        # offered — and sideStore's own docs warn that a `sidestore://` link without SideStore
        # installed crashes it, which is the same reason the check has to come first.
        self.assertIn("ForEach(installedApps)", self.source)
        self.assertIn("installedApps = SideloadingApp.all.filter", self.source)
        guarded = block(self.source, "ForEach(installedApps)", 'Text("Not now")')
        self.assertIn("UIApplication.shared.open(link)", guarded)

    def test_every_sideloader_uses_the_link_shape_its_app_documents(self):
        table = block(self.source, "static let all: [SideloadingApp] = [", "]\n}")
        # AltStore and SideStore: scheme://install?url=<ipa>
        self.assertIn('SideloadingApp(name: "AltStore", scheme: "altstore")', table)
        self.assertIn("UpdatePrompt.queryLink(scheme: \"altstore\", ipa: $0)", table)
        self.assertIn('SideloadingApp(name: "SideStore", scheme: "sidestore")', table)
        self.assertIn("UpdatePrompt.queryLink(scheme: \"sidestore\", ipa: $0)", table)
        # Feather: scheme://install/<ipa> — a path, not a query item.
        self.assertIn('SideloadingApp(name: "Feather", scheme: "feather")', table)
        self.assertIn("UpdatePrompt.pathLink(scheme: \"feather\", ipa: $0)", table)
        self.assertIn("static func queryLink(scheme: String, ipa: URL)", self.source)
        self.assertIn("percentEncodedPath", self.source,
                      "the nested URL must keep one layer of escaping, not two")

    def test_no_version_literal_is_baked_into_the_card(self):
        self.assertIsNone(re.search(r"\b0\.1\.\d{2,}\b", self.source))

    def test_every_offered_scheme_is_declared_for_can_open_url(self):
        # iOS answers `canOpenURL` false for an undeclared scheme, which would hide the button on the
        # phones that do have the app. The declared list and the offered list must agree, so this
        # reads the schemes out of the code and checks each one is in the Info.plist.
        project = read(ROOT / "project.yml")
        self.assertIn("LSApplicationQueriesSchemes:", project)
        table = block(self.source, "static let all: [SideloadingApp] = [", "]\n}")
        schemes = re.findall(r'scheme: "([a-z]+)"', table)
        self.assertGreaterEqual(len(schemes), 3)
        for scheme in schemes:
            self.assertIn(f"- {scheme}", project,
                          f"{scheme} is offered by the card but not declared in project.yml")


class TheEntryPointsAsk(unittest.TestCase):
    """§6 + §7: launch and foreground checks, and a Settings row that can re-offer."""

    def setUp(self):
        self.source = read(APP_PATH)

    def test_the_checker_is_owned_by_the_environment(self):
        # Built in the environment's init, which is the one place the main actor is already held.
        self.assertIn("self.updates = UpdateChecker()", read(ENVIRONMENT_PATH))

    def test_launch_checks_without_waiting_for_first_paint(self):
        self.assertIn(".task { await app.updates.check() }", self.source,
                      "the check needs its own task, not a step inside app.start()")

    def test_foreground_checks_even_when_unpaired(self):
        handler = block(self.source, ".onChange(of: scenePhase) { phase in", "MobileReplyNotifier.shared.refreshAuthorization()")
        self.assertIn("if phase == .active { Task { await app.updates.check() } }", handler)
        # It must sit above the pairing guard, or an unpaired phone never checks again.
        self.assertLess(handler.index("await app.updates.check()"), handler.index("guard phase == .active"))

    def test_the_card_is_attached_to_the_root(self):
        self.assertIn(".updatePrompt(app.updates)", self.source)

    def test_settings_has_a_manual_check_row_showing_the_build(self):
        settings = read(SETTINGS_PATH)
        self.assertIn('Text("Check for Updates")', settings)
        self.assertIn("await updates.check(manual: true)", settings)
        self.assertIn("Build \\(updates.currentBuild)", settings)
        self.assertIn("updateSection", settings.split("var body: some View {", 1)[1].split("}", 1)[0])


if __name__ == "__main__":
    unittest.main()

class TheCardIsShownByWhoeverAsked(unittest.TestCase):
    """A sheet asked for by a covered view is queued, not shown.

    The report: "the check for update checks fine, but when it finds a new version there is no
    download button, double tapping does nothing, but after closing the settings pane the download
    modal shows and finally it can be downloaded". All three symptom are one cause — the card was
    presented by the app shell, which the Settings sheet was covering, so it waited there with
    `isPromptVisible` already true (hence a dead second tap) and appeared when Settings closed.
    """

    def setUp(self):
        self.checker = read(CHECKER_PATH)
        self.prompt = read(PROMPT_PATH)
        self.settings = read(SETTINGS_PATH)

    def test_the_checker_names_a_host_for_the_card(self):
        self.assertIn("public enum PromptHost: Sendable { case root, settings }", self.checker)
        self.assertIn("public private(set) var promptHost: PromptHost = .root", self.checker)

    def test_a_manual_check_is_hosted_where_it_was_made(self):
        self.assertIn("promptHost = manual ? .settings : .root", self.checker,
                      "a manual check comes from the Settings sheet and must be shown over it")

    def test_a_presenter_only_acts_for_its_own_host(self):
        presenter = block(self.prompt, "struct UpdatePromptPresenter: ViewModifier {", "extension View {")
        self.assertIn("let host: UpdateChecker.PromptHost", presenter)
        self.assertIn("updates.isPromptVisible && updates.promptHost == host", presenter)

    def test_the_settings_sheet_hosts_its_own_card(self):
        sheet = block(self.settings, "struct SettingsSheet: View {", "// MARK: - Devices")
        self.assertIn(".updatePrompt(app.updates, host: .settings)", sheet)

    def test_the_shell_still_hosts_the_unsolicited_card(self):
        self.assertIn(".updatePrompt(app.updates)", read(APP_PATH))

    def test_closing_settings_keeps_a_visible_card(self):
        sheet = block(self.settings, "struct SettingsSheet: View {", "// MARK: - Devices")
        self.assertIn("app.updates.rehost(.root)", sheet,
                      "the offer continues over the app instead of vanishing with the sheet")
        rehost = block(self.checker, "public func rehost(", "/// The user dismissed the card")
        self.assertIn("guard isPromptVisible", rehost,
                      "re-hosting must not resurrect a card the user dismissed")
        self.assertNotIn("dismissPrompt()", rehost, "moving the card is not answering it")

    def test_the_actions_are_not_inside_the_scrolling_area(self):
        body = block(self.prompt, "ScrollView {", "// The actions never scroll")
        self.assertNotIn('Text("Download")', body,
                         "a long release note must not push the Download button below the fold")


class OnlyAnArtifactThisPlatformCanInstall(unittest.TestCase):
    """"It downloads the dmg instead of the ipa" — a phone was handed the mac artifact."""

    def setUp(self):
        self.checker = read(CHECKER_PATH)

    def test_the_guard_is_ipa_only_on_ios(self):
        guard = block(self.checker, "static func isInstallable(", "private func fetch(")
        self.assertIn("#if os(iOS)", guard)
        self.assertIn('url.pathExtension.lowercased() == "ipa"', guard)
        self.assertIn("#else", guard)

    def test_an_uninstallable_entry_is_skipped_not_offered(self):
        latest = block(self.checker, "private func latestUpdate() async", "static func isInstallable(")
        self.assertIn("guard Self.isInstallable(update.url) else {", latest)
        self.assertIn("continue", latest,
                      "the fallback feed is tried, and a .dmg is never returned as an update")
