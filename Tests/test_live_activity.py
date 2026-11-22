"""The Live Activity: a card that says a bot is working on the message, and gets out of the way.

This is Swift that cannot run here — ActivityKit only exists on an iOS device, and the widget is a
second process — so the contract is pinned from source, the way the rest of the cross-platform
shells are:

* **one type in two processes.** `HermeyTurnAttributes` is compiled into the app *and* the
  extension. Two declarations of it would be a runtime failure, not a compile error, so the file
  exists once and neither side imports the other's module;
* **every presentation has a view.** The Dynamic Island picks a region, not us: a missing
  `compactTrailing` is a blank trailing slot, invisible in code review;
* **the coordinator rides `isStreaming`.** No hook in `AppModel`, no second notion of "a turn is
  running", and no second activity when a new turn starts on top of a showing card;
* **nothing is unguarded.** The Mac and any SDK without ActivityKit must keep compiling, and a
  phone with the feature switched off must log one reason instead of 400.

What a real device has to confirm (it cannot be asserted here): that the extension is embedded and
signed, that the island's compact trailing timer is not clipped, and that ending with
`.after(6s)` is long enough to read "Replied" on the lock screen.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXT = ROOT / "Apps" / "HermesLiveActivity"
ATTRIBUTES = (EXT / "HermeyTurnAttributes.swift").read_text(encoding="utf-8")
WIDGET = (EXT / "HermeyTurnLiveActivity.swift").read_text(encoding="utf-8")
PLIST = (EXT / "Info.plist").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "Apps" / "HermesMobile" / "Views" / "LiveActivityCoordinator.swift").read_text(encoding="utf-8")
APP_MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")


def braced(source: str, start: int) -> str:
    """The contents of the first brace-balanced block at or after `start`."""
    open_brace = source.index("{", start)
    depth = 0
    for index in range(open_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[open_brace:index + 1]
    raise AssertionError("block is not closed")


def body(symbol: str, source: str = COORDINATOR) -> str:
    """The opening brace's contents of `symbol`."""
    return braced(source, source.index(symbol))


def region(name: str) -> str:
    """The view body of one Dynamic Island expanded region."""
    return braced(WIDGET, WIDGET.index(f"DynamicIslandExpandedRegion(.{name})"))


def section(heading: str) -> str:
    """One `// MARK: -` section of the widget file."""
    start = WIDGET.index(heading)
    end = WIDGET.find("// MARK: -", start + len(heading))
    return WIDGET[start:end if end != -1 else len(WIDGET)]


class TheCardIsOneTypeInTwoProcesses(unittest.TestCase):
    def test_the_attributes_are_declared_once(self) -> None:
        # The app asks for an activity and the extension draws it, so both must compile the *same*
        # `ActivityAttributes` conformance. A copy in each target type-checks and then hands the
        # extension a type it has never heard of, and the card silently never appears.
        self.assertTrue((EXT / "HermeyTurnAttributes.swift").exists())
        self.assertFalse((ROOT / "Apps" / "HermesMobile" / "Views" / "HermeyTurnAttributes.swift").exists())
        self.assertIn("public struct HermeyTurnAttributes: ActivityAttributes", ATTRIBUTES)
        self.assertIn("public struct ContentState: Codable, Hashable, Sendable", ATTRIBUTES)

    def test_the_two_states_are_working_and_done(self) -> None:
        phase = body("public enum Phase: String, Codable, Hashable, Sendable", ATTRIBUTES)
        self.assertIn("case working", phase)
        self.assertIn("case done", phase)
        # Nothing else. A queue/error/paused state here would be state the card cannot be told
        # about without the app pushing an update for every one of them.
        self.assertEqual(len(re.findall(r"\bcase \w+", phase)), 2)

    def test_elapsed_time_is_a_date_not_a_measured_number(self) -> None:
        # A stored duration freezes at whatever the app last sent; a date lets the system's own
        # clock count, which is why the app sends one update per turn instead of one per second.
        self.assertIn("public var startedAt: Date", ATTRIBUTES)
        self.assertIn("Text(state.startedAt, style: .timer)", WIDGET)

    def test_the_bot_name_travels_in_the_attributes(self) -> None:
        # One turn belongs to one bot from start to finish, so the name is fixed at request time.
        self.assertIn("public var botName: String", ATTRIBUTES)
        self.assertIn("HermeyTurnAttributes(botName: name)", COORDINATOR)

    def test_the_extension_does_not_link_the_app(self) -> None:
        # A widget extension loads in its own process; importing the app's module or package stack
        # drags the socket client and every view in with it.
        for name, source in (("attributes", ATTRIBUTES), ("widget", WIDGET)):
            for forbidden in ("import HermesAppKit", "import HermesKit", "import HermeyUI",
                              "import UIKit", "import AppModel"):
                self.assertNotIn(forbidden, source, f"{name} links the app: {forbidden}")


class EveryPresentationHasAView(unittest.TestCase):
    def test_one_activity_configuration_for_the_shared_type(self) -> None:
        self.assertIn("ActivityConfiguration(for: HermeyTurnAttributes.self)", WIDGET)
        self.assertIn("@main", WIDGET)
        self.assertIn(": Widget {", WIDGET)

    def test_all_four_expanded_regions_are_drawn(self) -> None:
        # The island composes these four; a missing one is a blank slot, which reads as a bug in
        # the type system rather than in the layout.
        for name in ("leading", "trailing", "center", "bottom"):
            self.assertEqual(WIDGET.count(f"DynamicIslandExpandedRegion(.{name})"), 1,
                             f"{name} is missing or drawn twice")
            self.assertGreater(len(region(name).strip()), 2, f"{name} has an empty view")

    def test_all_three_compact_presentations_are_drawn(self) -> None:
        self.assertIn("compactLeading: {", WIDGET)
        self.assertIn("compactTrailing: {", WIDGET)
        self.assertIn("minimal: {", WIDGET)
        for closure in ("compactLeading", "compactTrailing", "minimal"):
            content = braced(WIDGET, WIDGET.index(f"{closure}: {{"))
            self.assertGreater(len(content.strip()), 2, f"{closure} has an empty view")

    def test_the_lock_screen_card_is_the_content_builder(self) -> None:
        content = WIDGET[WIDGET.index("ActivityConfiguration(for:"):WIDGET.index("} dynamicIsland:")]
        self.assertIn("HermeyTurnLockScreen(", content)
        # A tint on the canvas, not a colour of its own: the lock-screen card is the app's paper.
        self.assertIn(".activityBackgroundTint(HermeyTurnInk.canvas)", content)

    def test_the_state_picks_the_glyph_and_the_sentence(self) -> None:
        # Working → an in-progress bubble and "Working on your message"; done → a tick and "Replied".
        self.assertIn('"ellipsis.bubble"', WIDGET)
        self.assertIn('"checkmark.circle"', WIDGET)
        status = section("// MARK: - Pieces")
        self.assertIn("Working on your message", status)
        self.assertIn('return "Replied"', status)

    def test_a_stale_card_stops_claiming_to_work(self) -> None:
        # `staleDate` fires when the app could not update the card (killed mid-turn). The sentence
        # has to step back to what is still true rather than keep animating a turn that may be over.
        self.assertIn("isStale", WIDGET)
        self.assertIn('"Still waiting on \\(botName)"', WIDGET)


class ThePaletteIsTheApps(unittest.TestCase):
    def test_only_the_theme_s_two_colours_and_its_ink(self) -> None:
        # `Theme.carbon`: accent #CC6543, canvas #FAF9F5, ink #141413. The extension cannot import
        # `HermeyUI` (see above), so the values are restated — the same values, not a second palette.
        self.assertIn("0xCC6543", WIDGET)
        self.assertIn("0xFAF9F5", WIDGET)
        found = set(re.findall(
            r"Color\(\.sRGB, red: (\d+) / 255, green: (\d+) / 255, blue: (\d+) / 255", WIDGET))
        self.assertEqual(found, {("204", "101", "67"), ("250", "249", "245"), ("20", "20", "19")})

    def test_the_island_borrows_none_of_the_cards_ink(self) -> None:
        # The island is near-black in *both* appearances while the lock-screen card is pinned to
        # light paper, so a shared text colour is dark-on-dark in one of the two places. The tone
        # is what keeps one palette legible on both surfaces.
        island = WIDGET[WIDGET.index("} dynamicIsland:"):WIDGET.index("// MARK: - Pieces")]
        self.assertNotIn("HermeyTurnInk.ink", island)
        self.assertEqual(island.count("tone: .island"), 3)
        self.assertIn("case island", WIDGET)
        self.assertIn(".white", WIDGET)

    def test_no_asset_catalogue_or_remote_image_is_involved(self) -> None:
        # Live Activity snapshots get a small memory budget and no async image loading worth the
        # complexity; the card is text and SF Symbols.
        for forbidden in ("Image(\"", "AsyncImage", "UIImage", "Image(uiImage"):
            self.assertNotIn(forbidden, WIDGET, forbidden)


class TheCoordinatorRidesTheModelsExistingState(unittest.TestCase):
    def test_it_subscribes_to_the_published_flag(self) -> None:
        self.assertIn("@MainActor", COORDINATOR)
        self.assertIn("final class LiveActivityCoordinator: ObservableObject", COORDINATOR)
        self.assertIn("model.$isStreaming", COORDINATOR)
        # A second turn is not a second transition, and a redraw is not a turn.
        self.assertIn(".removeDuplicates()", COORDINATOR)
        self.assertIn("func attach(to model: AppModel)", COORDINATOR)

    def test_a_turn_begin_starts_and_a_turn_end_finishes(self) -> None:
        sink = COORDINATOR[COORDINATOR.index(".sink"):COORDINATOR.index(".store(in:")]
        self.assertIn("guard let self else { return }", sink)
        self.assertIn("if streaming {", sink)
        self.assertLess(sink.index("self.begin()"), sink.index("self.finish()"))

    def test_a_second_turn_updates_instead_of_stacking(self) -> None:
        # `Activity.request` stacks a second island happily, and the one nobody ended is a leak on
        # the owner's lock screen until it goes stale.
        begin = body("private func begin()")
        self.assertIn("if let activity {", begin)
        self.assertIn("await activity.update(", begin)
        self.assertEqual(COORDINATOR.count("Activity.request("), 1)

    def test_it_ends_the_card_with_the_reply(self) -> None:
        finish = body("private func finish()")
        self.assertIn("phase: .done", finish)
        self.assertIn("dismissalPolicy: .after(", finish)
        self.assertIn("Self.doneLinger", finish)

    def test_termination_leaves_nothing_behind(self) -> None:
        # Activities outlive the process. `endAll` is the sweep at attach, and the same verb a shell
        # calls from a termination callback; `.immediate` because no turn is behind the card.
        sweep = body("func endAll()")
        self.assertIn("Activity<HermeyTurnAttributes>.activities", sweep)
        self.assertIn("dismissalPolicy: .immediate", sweep)
        attach = body("func attach(to model: AppModel)")
        self.assertIn("endAll()", attach)

    def test_the_name_is_the_selected_bots(self) -> None:
        self.assertIn("model?.selectedBot?.displayName", body("private func begin()"))

    def test_the_model_is_never_edited(self) -> None:
        # The whole point of the design: `isStreaming` is already published, so the feature observes
        # it. A hook in the model would be this feature's problem leaking into everyone else's.
        self.assertNotIn("LiveActivity", APP_MODEL)
        self.assertNotIn("ActivityKit", APP_MODEL)
        # The coordinator reads the flag; nothing writes it.
        self.assertEqual(re.findall(r"\bisStreaming\s*=\s*(?:true|false)", COORDINATOR), [])
        self.assertNotIn("model.isStreaming", COORDINATOR)


class ItDegradesInsteadOfCrashing(unittest.TestCase):
    def _activitykit_region(self) -> str:
        start = COORDINATOR.index("#if os(iOS) && canImport(ActivityKit)")
        end = COORDINATOR.index("#else", start)
        return COORDINATOR[start:end]

    def test_every_activitykit_call_sits_inside_the_guard(self) -> None:
        real = self._activitykit_region()
        for symbol in ("Activity<", "Activity.request(", "ActivityAuthorizationInfo(",
                       "ActivityContent(", "import ActivityKit"):
            self.assertIn(symbol, real, f"{symbol} should be in the guarded half")
            # …and nowhere else: the stub half must not name the framework at all.
            rest = COORDINATOR.replace(real, "")
            self.assertNotIn(symbol, rest, f"{symbol} escaped the guard")

    def test_the_api_floor_is_checked_before_asking(self) -> None:
        begin = body("private func begin()")
        self.assertIn("guard #available(iOS 16.2, *) else", begin)
        self.assertLess(begin.index("#available(iOS 16.2, *)"),
                        begin.index("Activity.request("))

    def test_the_widget_sources_are_guarded_too(self) -> None:
        # Both files are compiled into the app as well (the attributes) or into a target that may
        # one day be added elsewhere, so an unguarded `import ActivityKit` would break the Mac.
        self.assertIn("#if os(iOS) && canImport(ActivityKit)", ATTRIBUTES)
        self.assertIn("#if os(iOS) && canImport(ActivityKit) && canImport(WidgetKit)", WIDGET)
        self.assertIn("import WidgetKit", WIDGET)
        self.assertIn("#endif", WIDGET)

    def test_every_refusal_is_explained_once(self) -> None:
        # Three distinct reasons, each one line, each written through `ClientLog` so it lands in
        # Settings → View log *and* in `log stream`.
        self.assertIn("Live Activities need iOS 16.2 or later", COORDINATOR)
        self.assertIn("Live Activities are turned off for Hermey in Settings", COORDINATOR)
        self.assertIn("the system refused the request", COORDINATOR)
        self.assertIn("ClientLog.shared.record(", COORDINATOR)
        self.assertIn('category: "live-activity"', COORDINATOR)
        self.assertIn("logged.insert(reason).inserted", COORDINATOR)

    def test_it_does_not_print(self) -> None:
        # `ClientLog.record` already mirrors to `os.Logger`; a `print` is a second, unread line.
        self.assertNotIn("print(", COORDINATOR)

    def test_another_platform_gets_a_silent_stub(self) -> None:
        stub = COORDINATOR[COORDINATOR.index("#else"):]
        self.assertIn("final class LiveActivityCoordinator: ObservableObject", stub)
        self.assertIn("func endAll()", stub)
        self.assertIn("not available on this platform", stub)


class TheExtensionIsItsOwnBundle(unittest.TestCase):
    def test_it_declares_the_widgetkit_extension_point(self) -> None:
        self.assertIn("com.apple.widgetkit-extension", PLIST)
        self.assertIn("<key>NSExtension</key>", PLIST)
        self.assertIn("<string>Hermey</string>", PLIST)

    def test_it_shares_no_app_group(self) -> None:
        # Prefer attributes only. A group would mean an entitlement, a provisioning profile that
        # carries it, and a second place for state to live.
        self.assertEqual(list(EXT.glob("*.entitlements")), [])
        self.assertNotIn("application-groups", PLIST)

    def test_its_bundle_id_is_recorded_for_the_project_file(self) -> None:
        # The target id is the parent's to write in project.yml; the file states which one, so the
        # requirement cannot drift out of the artifact.
        self.assertIn("dev.hermey.app.LiveActivity", PLIST)


if __name__ == "__main__":
    unittest.main()
