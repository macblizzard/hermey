"""The Live Activity: a card that says a bot is working on the message, and stays there until the
owner takes it away.

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

And two rules that came from the owner's screenshot of 0.1.618 — a black pill two-thirds of the
phone wide, covering the status bar, saying nothing but an icon and `1:06`:

* **a compact slot owns no width.** The island sizes itself from what `compactLeading`,
  `compactTrailing` and `minimal` *report*, so a `Spacer()`, an `.frame(maxWidth: .infinity)` or a
  `Text` measuring against the full proposal widens the pill until it sits on top of the clock and
  the battery. Every compact view is pinned to its intrinsic size, and the bot's name is shortened in
  code so that size is small. Pinning was not enough on its own: the one view that has no ideal size
  to pin is a live timer, and that is the third block below;
* **a glance answers "which bot" and "what did it say".** Compact carries the bot's name; the
  expanded island and the lock-screen card carry the first line or two of the reply, which is a
  field on `ContentState` and is flattened and capped by the type, not by each view.

And one rule from the screenshot after it — a lock-screen card that was a pale tint and no words:

* **every word travels in the state, and the state is never empty.** The card is drawn in a second
  process that can see nothing of the app's model, so a sentence written as a literal in the view,
  or a name captured once when the activity is requested, is all the card can ever say — and a card
  whose only fields are fixed at `request` time never learns anything about the turn it is showing.
  `ContentState.step` is the line the coordinator fills from `liveTools`/`activity(forBot:)`/
  `streamingText`, `update` is called when it changes, and both the initialiser and the decoder end
  at a neutral word so no caller and no older activity can put a blank line on the lock screen.

And three rules from the screenshots after that — a pill again two-thirds of the phone wide, a card
that vanished seconds after it appeared, and a blank gold panel while the turn ran:

* **no clock in this feature is a live timer.** `Text(date, style: .timer)` is the one view that
  cannot be pinned: it has to be able to render any elapsed value, so the layout hands it the width
  it proposed and `.fixedSize(horizontal:)` pins a size the text does not have. In the compact
  trailing slot that widened the island to ~82% of the screen — the mark and the name hugged at the
  leading edge of a mostly empty pill — and on the Lock Screen the same view took the row's width and
  squeezed the name and the step line to nothing, which is the blank panel. `HermeyTurnElapsed`
  formats the number; a formatted string's width is its digits;
* **the card stays until the owner removes it.** `end(_:dismissalPolicy:)` is the only call that can
  take a card away, and even `.default` clears the Dynamic Island and keeps only the Lock Screen copy.
  So the coordinator has no `end(` at all: a finished turn is an update to `.done`, `staleAfter` is
  the system's own eight-hour ceiling rather than thirty minutes, and a new turn re-points the card
  that is already up. A leftover from a dead process is told the truth (retired to `Done`), not yanked;
* **the card is the system's glass, with words on it from the first frame.** No
  `activityBackgroundTint` — that tint was the gold panel — and the ink is the system's
  `.primary`/`.secondary` so it is legible on glass in either appearance, with amber only on the
  glyph. The step line is drawn for *every* phase, not only once the reply lands.

What a real device has to confirm (it cannot be asserted here): that the extension is embedded and
signed, that the compact pill sits inside the notch's width instead of over the status bar, that the
card reads as glass rather than a filled panel, and that the finished card is still there after the
phone has been locked and unlocked an hour later.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXT = ROOT / "Apps" / "HermesLiveActivity"
ATTRIBUTES = (EXT / "HermeyTurnAttributes.swift").read_text(encoding="utf-8")
WIDGET = (EXT / "HermeyTurnLiveActivity.swift").read_text(encoding="utf-8")
PLIST_PATH = EXT / "Info.plist"
# XcodeGen writes the extension's Info.plist from project.yml on every generate, and .gitignore keeps
# it out of the tree — so it is absent in a fresh worktree and in CI. The assertions that need it fall
# back to project.yml, which is the source it is generated from.
PLIST = PLIST_PATH.read_text(encoding="utf-8") if PLIST_PATH.exists() else ""
PROJECT = (ROOT / "project.yml").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "Apps" / "HermesMobile" / "Views" / "LiveActivityCoordinator.swift").read_text(encoding="utf-8")
APP_MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
# The shell that owns the coordinator. Read only to prove it does nothing else with it.
SHELL = (ROOT / "Apps" / "HermesMobile" / "HermesMobileApp.swift").read_text(encoding="utf-8")


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


def compact(name: str) -> str:
    """The view body of one Dynamic Island compact presentation."""
    return braced(WIDGET, WIDGET.index(f"{name}: {{"))


def piece(declaration: str) -> str:
    """The body of one private view or enum in the widget file."""
    return braced(WIDGET, WIDGET.index(declaration))


def code(source: str) -> str:
    """A Swift source with its `//` comments stripped.

    Every guard here is about what *runs*: the file's comments name the very modifiers the guards
    forbid (`.timer`, `activityBackgroundTint`), because the reason a rule exists belongs next to the
    rule. Stripping comments is what lets both be true.
    """
    kept = []
    for line in source.splitlines():
        marker = line.find("//")
        kept.append(line if marker == -1 else line[:marker])
    return "\n".join(kept)


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
        # A stored duration freezes at whatever the app last sent, so the state carries the date the
        # turn began and the view formats the difference.
        self.assertIn("public var startedAt: Date", ATTRIBUTES)
        label = piece("private struct HermeyTurnElapsedLabel: View")
        self.assertIn("HermeyTurnElapsed.short(from: state.startedAt", label)
        # …and not with `Text(_, style: .timer)`, which is the width bug: a live timer is offered
        # the proposal and reports it back, pinning nothing.
        self.assertNotIn(".timer", code(WIDGET))

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
        # No fill of ours: the gold panel was a pinned canvas. What is allowed now is a whisper of
        # white over the system's material — the owner asked for glass he can see the wallpaper
        # through, and the tint is the only lever a Live Activity has for that.
        self.assertNotIn("activityBackgroundTint(canvas)", code(WIDGET))
        self.assertIn("activityBackgroundTint(Color.white.opacity(HermeyTurnGlass.lift))", code(WIDGET))
        self.assertIn(".activitySystemActionForegroundColor(HermeyTurnAccent.amber)", content)

    def test_the_state_picks_the_glyph_and_the_sentence(self) -> None:
        # Working → an in-progress bubble and a tick when it is over. The words are the state's now
        # (see `TheCardAlwaysSaysWhatItIsDoing`); the literals here are the floor a card from a build
        # with no step field still draws.
        self.assertIn('"ellipsis.bubble"', WIDGET)
        self.assertIn('"checkmark.circle"', WIDGET)
        status = section("// MARK: - Pieces")
        self.assertIn('return state.phase == .done ? "Done" : "Working on your message"', status)

    def test_a_stale_card_stops_claiming_to_work(self) -> None:
        # `staleDate` fires when the app could not update the card (killed mid-turn). The sentence
        # has to step back to what is still true rather than keep animating a turn that may be over.
        self.assertIn("isStale", WIDGET)
        self.assertIn('"Still waiting on \\(botName)"', WIDGET)


class ThePaletteIsTheAccentAndTheSystemsInk(unittest.TestCase):
    def test_the_only_literal_colour_is_the_theme_s_accent(self) -> None:
        # `Theme.carbon`: accent #CC6543. The extension cannot import `HermeyUI` (see above), so the
        # value is restated — one value, and it is an *accent*: the glyph, the keyline, the system
        # action tint. Nothing in this feature paints a background any more.
        self.assertIn("0xCC6543", WIDGET)
        found = set(re.findall(
            r"Color\(\.sRGB, red: (\d+) / 255, green: (\d+) / 255, blue: (\d+) / 255", WIDGET))
        self.assertEqual(found, {("204", "101", "67")})

    def test_the_card_has_no_fill_of_its_own(self) -> None:
        # The pale gold panel was `activityBackgroundTint` — a pinned light canvas painted over the
        # system's glass — and the near-black-on-paper ink that only made sense on top of it. Both
        # are gone: the card is glass, and its words are the system's own ink.
        body = code(WIDGET)
        for gone in ("HermeyTurnInk", "0xFAF9F5", ".background(Color", ".fill(Color.black"):
            self.assertNotIn(gone, body, f"the card still paints {gone}")
        # A tint is allowed; a slab is not. The lift must stay a whisper of white over the material.
        lift = float(WIDGET.split("static let lift: Double = ", 1)[1].split("\n", 1)[0])
        self.assertGreater(lift, 0, "no tint at all reads as a solid dark slab on a dark wallpaper")
        self.assertLessEqual(lift, 0.15, "more than a whisper stops being glass and becomes a panel")

    def test_every_word_on_the_glass_is_the_systems_own_ink(self) -> None:
        tone = piece("private enum HermeyTurnTone")
        self.assertIn("case .card: return .primary", tone)
        self.assertIn("case .card: return .secondary", tone)
        # …while the island, black in both appearances, is pinned white: `primary`/`secondary` on it
        # resolve to the system's dark-on-dark pair.
        self.assertIn("case .island: return Color.white", tone)
        self.assertIn("Color.white.opacity(0.72)", tone)
        # Centre (name + step), trailing (elapsed) and the bottom snippet: every island piece that
        # prints names the island's tone.
        island = WIDGET[WIDGET.index("} dynamicIsland:"):WIDGET.index("// MARK: - Pieces")]
        self.assertEqual(island.count("tone: .island"), 3)

    def test_no_asset_catalogue_or_remote_image_is_involved(self) -> None:
        # Live Activity snapshots get a small memory budget and no async image loading worth the
        # complexity; the card is text and SF Symbols.
        for forbidden in ('Image("', "AsyncImage", "UIImage", "Image(uiImage"):
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
        # `Activity.request` stacks a second island happily. A turn that begins while a card is up —
        # a working one, or the `Done` card the last turn left showing — re-points that card.
        begin = body("private func begin()")
        self.assertIn("if let current = activity,", begin)
        self.assertIn("current.activityState == .active || current.activityState == .stale", begin)
        self.assertIn("push(content, to: current)", begin)
        # A card the owner swiped away is not a card to update: the handle is dropped, and the one
        # `request` in this file makes a fresh one.
        self.assertIn("activity = nil", begin)
        self.assertEqual(COORDINATOR.count("Activity.request("), 1)

    def test_a_card_left_by_another_process_is_adopted_not_stacked(self) -> None:
        # After a relaunch the handle is gone but the card may still be on screen; adopting it is the
        # difference between one island and two.
        begin = body("private func begin()")
        self.assertIn("Activity<HermeyTurnAttributes>.activities.first", begin)
        self.assertIn("$0.attributes.botName == name", begin)
        self.assertIn("push(content, to: lingering)", begin)

    def test_it_finishes_the_card_with_the_reply_and_leaves_it_up(self) -> None:
        finish = body("private func finish()")
        self.assertIn("phase: .done", finish)
        self.assertIn("replySnippet: replySnippet()", finish)
        self.assertIn("step: Self.doneWords", finish)
        self.assertIn("staleDate: nil", finish)
        # Not ended: `end` is what removes a card from the island, and the island keeps saying
        # "Done" until the owner takes it away.
        self.assertNotIn(".end(", finish)
        # The handle survives the turn, so the next one re-points this same card.
        self.assertNotIn("activity = nil", finish)

    def test_termination_retires_rather_than_ends(self) -> None:
        # Activities outlive the process. The sweep at attach names every card of this type and
        # *updates* it to a finished state — it never ends one, so a launch cannot take a card the
        # owner is looking at off his Lock Screen.
        sweep = body("func retireLeftovers()")
        self.assertIn("Activity<HermeyTurnAttributes>.activities", sweep)
        self.assertIn("await leftover.update(content)", sweep)
        self.assertIn("phase: .done", sweep)
        self.assertNotIn(".end(", sweep)
        attach = body("func attach(to model: AppModel)")
        self.assertIn("retireLeftovers()", attach)

    def test_a_new_turn_waits_for_the_sweep(self) -> None:
        # The sweep at attach is asynchronous, so a turn that begins in the same launch waits for
        # it: otherwise a `Done` write could land on top of the new turn's `Working` and the whole
        # turn would read as finished.
        push = body("private func push(")
        self.assertIn("let pending = retirement", push)
        self.assertIn("await pending?.value", push)
        self.assertIn("await card.update(content)", push)
        for transition in ("private func begin()", "private func finish()", "private func progress()"):
            self.assertIn("push(content, to: ", body(transition), transition)

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
        self.assertIn("func retireLeftovers()", stub)
        self.assertIn("not available on this platform", stub)


class TheExtensionIsItsOwnBundle(unittest.TestCase):
    # Asserted against project.yml, which is what XcodeGen generates the plist from — the generated
    # file is gitignored, so a fresh worktree (and CI) has no plist to read.
    def test_it_declares_the_widgetkit_extension_point(self) -> None:
        self.assertIn("com.apple.widgetkit-extension", PROJECT)
        self.assertIn("HermesLiveActivity:", PROJECT)
        self.assertIn("type: app-extension", PROJECT)
        if PLIST:
            self.assertIn("com.apple.widgetkit-extension", PLIST)

    def test_it_shares_no_app_group(self) -> None:
        # Prefer attributes only. A group would mean an entitlement, a provisioning profile that
        # carries it, and a second place for state to live — and on this project's signing it does
        # not provision at all (which is why the share sheet was removed).
        self.assertEqual(list(EXT.glob("*.entitlements")), [])
        self.assertNotIn("application-groups", PROJECT)
        if PLIST:
            self.assertNotIn("application-groups", PLIST)

    def test_its_bundle_id_is_recorded_for_the_project_file(self) -> None:
        # An embedded extension's id must be prefixed by the app's (dev.hermey.app.mobile), or the
        # build fails with "Embedded binary's bundle identifier is not prefixed with the parent app's".
        self.assertIn("dev.hermey.app.mobile.liveActivity", PROJECT)
        self.assertNotIn("dev.hermey.app.LiveActivity", PROJECT)


class TheIslandStaysSmall(unittest.TestCase):
    """Compact slots report their size; the island widens to whatever comes back."""

    def test_no_compact_slot_proposes_a_width(self) -> None:
        # These three slots are the only places that can ask for the pill's width, so none of them
        # may contain something that stretches: a `Spacer` or an infinite frame here is the whole
        # 323 pt pill, and the content that hugs the leading edge of it is what the owner saw.
        for name in ("compactLeading", "compactTrailing", "minimal"):
            content = compact(name)
            for forbidden in ("Spacer", "maxWidth", "GeometryReader",
                              "frame(width:", "frame(minWidth:", "frame(idealWidth:"):
                self.assertNotIn(forbidden, content, f"{name} proposes a width: {forbidden}")

    def test_no_presentation_draws_a_live_timer(self) -> None:
        # The finding behind the 323 pt pill: `Text(_, style: .timer)` cannot be pinned, because it
        # must be able to render any elapsed value — it takes the proposal it is offered, and the
        # island (and the Lock Screen row) obey. `.fixedSize(horizontal:)` does not help a view that
        # has no fixed size to pin. The elapsed number is a formatted string here instead.
        self.assertNotIn(".timer", code(WIDGET))
        self.assertIn("HermeyTurnElapsed.short(from: state.startedAt", WIDGET)
        # …and the formatter is the same one the finished card freezes with.
        elapsed = piece("private enum HermeyTurnElapsed")
        self.assertIn("String(format:", elapsed)
        self.assertIn("finishedAt ?? Date()", piece("private struct HermeyTurnElapsedLabel: View"))

    def test_every_compact_view_pins_its_intrinsic_size(self) -> None:
        # `.fixedSize()` is the modifier that stops a `Text` filling the island's proposal — and it
        # belongs on the *region's* outermost view, not only inside the piece it draws: a `Group`
        # with a branch is not a size, and a slot cannot see through one.
        self.assertIn(".fixedSize()", compact("minimal"))
        self.assertIn(".fixedSize()", compact("compactTrailing"))
        self.assertIn(".fixedSize()", compact("compactLeading"))
        lead = piece("private struct HermeyTurnCompactLead: View")
        self.assertIn(".fixedSize()", lead)
        self.assertNotIn("Spacer", lead)
        label = piece("private struct HermeyTurnElapsedLabel: View")
        self.assertIn(".fixedSize(horizontal: true, vertical: false)", label)
        self.assertIn(".monospacedDigit()", label)

    def test_compact_leading_names_the_bot(self) -> None:
        # A glance has to answer "which bot"; the screenshot answered nothing.
        self.assertIn("HermeyTurnCompactLead(", compact("compactLeading"))
        self.assertIn("botName", compact("compactLeading"))
        lead = piece("private struct HermeyTurnCompactLead: View")
        self.assertIn("HermeyTurnNames.compact(botName)", lead)

    def test_the_name_is_short_before_it_is_drawn(self) -> None:
        # Truncating in code, not with `lineLimit`: a `Text` still reports the whole string's width
        # to the layout before it truncates what it draws, which is how the pill got wide.
        names = piece("private enum HermeyTurnNames")
        self.assertIn("static let compactLimit = 8", names)
        self.assertIn("prefix(compactLimit)", names)
        self.assertIn('"\u2026"', names)
        self.assertIn("whereSeparator: \\.isWhitespace", names)

    def test_compact_trailing_is_the_elapsed_number_and_nothing_else(self) -> None:
        # The trailing slot holds a few monospaced digits and nothing that can grow: no name, no
        # snippet, no stack that could take the proposal.
        content = compact("compactTrailing")
        self.assertIn("HermeyTurnElapsedLabel(state: context.state, tone: .island)", content)
        self.assertNotIn("botName", content)
        self.assertNotIn("replySnippet", content)
        self.assertNotIn("HStack", content)
        self.assertNotIn("VStack", content)

    def test_the_expanded_island_cannot_stretch_either(self) -> None:
        # The expanded island is the system's to size, but a spacer or an infinite frame in it is
        # still a view whose only job is to take room the card does not need.
        island = WIDGET[WIDGET.index("} dynamicIsland:"):WIDGET.index("// MARK: - Pieces")]
        self.assertNotIn("Spacer", island)
        self.assertNotIn("maxWidth", code(island))

    def test_the_expanded_island_balances_its_content(self) -> None:
        # Left: the mark. Centre: the bot and the step. Trailing: the elapsed number. Bottom: the
        # reply, once there is one. Three pieces of content, one at each edge, and nothing that
        # asks the island to be wider than the three of them.
        self.assertIn("HermeyTurnExpandedCenter(state: context.state", region("center"))
        self.assertIn("HermeyTurnElapsedLabel(state: context.state, tone: .island)", region("trailing"))
        for name in ("leading", "center", "trailing"):
            self.assertNotIn("Spacer", region(name))
            self.assertNotIn("maxWidth", region(name))


class TheReplyHasItsOwnField(unittest.TestCase):
    def test_the_state_carries_the_snippet(self) -> None:
        self.assertIn("public var replySnippet: String", ATTRIBUTES)
        self.assertIn("public static let snippetLimit = 120", ATTRIBUTES)

    def test_the_type_enforces_the_cap_and_the_single_line(self) -> None:
        # One place decides what a card may show: the field's own initialiser. A view-side cap would
        # be a second rule that drifts, and the state travels to *two* processes.
        init = ATTRIBUTES[ATTRIBUTES.index("public init(phase: Phase"):ATTRIBUTES.index("// Decoded by hand")]
        self.assertIn('replySnippet: String = ""', init)
        self.assertIn("self.replySnippet = Self.clipped(replySnippet)", init)
        clip = body("public static func clipped", ATTRIBUTES)
        # Splitting on whitespace and re-joining is what strips the newlines a markdown reply is
        # full of, and what folds a code block's indentation.
        self.assertIn("whereSeparator: \\.isWhitespace", clip)
        self.assertIn('joined(separator: " ")', clip)
        self.assertIn("prefix(snippetLimit)", clip)

    def test_an_activity_from_the_previous_build_still_decodes(self) -> None:
        # 0.1.618 requested cards with no `replySnippet` key. A synthesised decoder would throw and
        # drop a card the owner is looking at; a missing key is an empty snippet.
        self.assertIn("decodeIfPresent(String.self, forKey: .replySnippet)", ATTRIBUTES)

    def test_the_card_draws_it_only_when_there_is_one(self) -> None:
        snippet = piece("private struct HermeyTurnSnippet: View")
        self.assertIn("state.replySnippet", snippet)
        self.assertIn("phase == .done", snippet)
        self.assertIn("lineLimit(2)", snippet)
        self.assertIn("truncationMode(.tail)", snippet)
        # Nothing is invented when the string is empty: no placeholder line.
        self.assertNotIn("Working", snippet)

    def test_both_surfaces_show_it(self) -> None:
        self.assertIn("HermeyTurnSnippet(state: context.state, tone: .island)",
                      region("bottom"))
        self.assertIn("HermeyTurnSnippet(state: state, tone: .card)",
                      piece("private struct HermeyTurnLockScreen: View"))


class TheCoordinatorHandsTheReplyOver(unittest.TestCase):
    def test_the_snippet_is_passed_when_the_card_finishes(self) -> None:
        finish = body("private func finish()")
        self.assertIn("replySnippet: replySnippet()", finish)
        # Handed to the same update that carries the `Done` state, and before it: the snippet is
        # built from the stream the model has already cleared, so it has to be read here.
        self.assertLess(finish.index("replySnippet: replySnippet()"),
                        finish.index("push(content, to: activity)"))

    def test_the_reply_is_read_while_it_streams(self) -> None:
        # `finish` runs after the model has emptied `streamingText`, so the words have to be copied
        # as they arrive or the card has nothing to show.
        self.assertIn("model.$streamingText", COORDINATOR)
        self.assertIn("replyTail", COORDINATOR)
        self.assertIn("String(text.suffix(Self.replyTailLimit))", COORDINATOR)

    def test_it_never_invents_a_sentence(self) -> None:
        helper = body("private func replySnippet()")
        self.assertIn('return ""', helper)
        # The only two sources: the streamed tail, and the transcript's last assistant row.
        self.assertIn("if !replyTail.isEmpty { return replyTail }", helper)
        self.assertIn("$0.role == .assistant", helper)
        self.assertNotIn("Replied", helper)

    def test_the_name_is_short_before_it_is_drawn_here_too(self) -> None:
        # The island's own shortening is a display rule; the coordinator still sends the real name.
        self.assertIn("HermeyTurnAttributes(botName: name)", COORDINATOR)


class TheCardIsGlassWithWordsOnIt(unittest.TestCase):
    """The blank gold panel: a fill of ours, and no legible line on it until the reply landed.

    Two things made it blank, and both are pinned here. The card painted
    `activityBackgroundTint(canvas)` — a pinned light paper — and its ink was pinned to match
    (`HermeyTurnInk`, near-black on cream), so the panel was the palette rather than the system's
    glass. And the row's trailing number was a live `Text(_, style: .timer)`, the one view that takes
    the width it is offered: it took the row, and the name and the step line were squeezed out of it
    until the turn ended and a formatted string replaced it.
    """

    def test_the_working_card_draws_the_step_line(self) -> None:
        card = piece("private struct HermeyTurnLockScreen: View")
        self.assertIn(
            "HermeyTurnStatusLine(state: state, botName: botName, isStale: isStale, tone: .card)",
            card)
        # Unconditionally: nothing in the card's body branches on the phase, so the sentence saying
        # what the bot is doing is drawn from the first second of the turn, not only at `Done`.
        self.assertNotIn("phase == .done", card)
        self.assertNotIn("if state.", card)

    def test_the_step_line_keeps_its_height_and_its_width(self) -> None:
        status = piece("private struct HermeyTurnStatusLine: View")
        # Vertical fixed size: the row can never be compressed to a height of nothing.
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", status)
        card = piece("private struct HermeyTurnLockScreen: View")
        # …and the column of words outranks the trailing number for width.
        self.assertIn(".layoutPriority(1)", card)
        self.assertLess(card.index(".layoutPriority(1)"), card.index("Spacer(minLength: 8)"))

    def test_no_light_paper_ink(self) -> None:
        body = code(WIDGET)
        for gone in ("HermeyTurnInk", "0xFAF9F5"):
            self.assertNotIn(gone, body, f"the card still paints {gone}")
        # A whisper of white over the material is allowed — the owner asked to see the wallpaper
        # through the card — but nothing opaque may be painted under the words.
        self.assertNotIn("activityBackgroundTint(canvas)", body)
        # Amber survives only where it is an accent: the mark and the status symbol.
        self.assertIn("foregroundStyle(HermeyTurnAccent.amber)", WIDGET)

    def test_the_expanded_island_says_what_the_bot_is_doing_too(self) -> None:
        center = piece("private struct HermeyTurnExpandedCenter: View")
        self.assertIn(
            "HermeyTurnStatusLine(state: state, botName: botName, isStale: isStale, tone: .island)",
            center)


class ItStaysUntilTheOwnerRemovesIt(unittest.TestCase):
    """`end(_:dismissalPolicy:)` is the only call that takes a card away — and it is not called.

    The old `finish` ended with `.after(Date() + 6)`, which is exactly "it disappears seconds after
    it appears", and `endAll` ended leftovers with `.immediate`, which is a launch taking the card
    out from under him. Even `.default` would clear the Dynamic Island immediately and keep only the
    Lock Screen copy, so the card is never ended at all: the turn's last word is an *update*.
    """

    def test_nothing_in_the_coordinator_ends_a_card(self) -> None:
        body = code(COORDINATOR)
        for forbidden in (".end(", "dismissalPolicy", ".immediate", "doneLinger"):
            self.assertNotIn(forbidden, body, f"the coordinator still ends the card: {forbidden}")

    def test_any_end_call_site_would_have_to_be_default(self) -> None:
        # The shape a future removal must take, if one is ever added: `.default`, never `.immediate`
        # and never a short `.after`. Today there are no call sites, which is the strongest form.
        self.assertEqual(re.findall(r"dismissalPolicy: ([^\n)]+)", code(COORDINATOR)), [])

    def test_the_stale_date_is_the_systems_own_ceiling(self) -> None:
        found = re.search(r"static let staleAfter: TimeInterval = ([0-9 *]+)", COORDINATOR)
        if found is None:
            self.fail("staleAfter is gone, so nothing bounds a dead card")
        expression = found.group(1).strip()
        self.assertGreaterEqual(eval(expression, {"__builtins__": {}}), 8 * 60 * 60)

    def test_a_finished_card_is_never_stale(self) -> None:
        finish = body("private func finish()")
        self.assertIn("ActivityContent(state: state, staleDate: nil)", finish)

    def test_no_scene_or_background_path_touches_the_card(self) -> None:
        # A card must not go away because the phone was locked, the app was backgrounded or the
        # socket reconnected: those are the moments a turn most needs to stay readable.
        body = code(COORDINATOR)
        for forbidden in ("scenePhase", "didEnterBackground", "willResignActive",
                          "didBecomeActive", "onDisappear", "reconnect", "suspend"):
            self.assertNotIn(forbidden, body, f"the card is touched on {forbidden}")

    def test_the_shell_only_ever_attaches_it(self) -> None:
        # The coordinator is the card's whole lifecycle. A second entry point in the shell — a
        # termination callback, a scene change — is a second way for the card to disappear.
        self.assertEqual(re.findall(r"liveActivity\.\w+", SHELL), ["liveActivity.attach"])

    def test_a_turn_that_never_started_never_creates_one(self) -> None:
        self.assertIn("guard ActivityAuthorizationInfo().areActivitiesEnabled else", COORDINATOR)
        self.assertIn("note(\"no card: Live Activities are turned off for Hermey in Settings\")", COORDINATOR)
        self.assertEqual(COORDINATOR.count("Activity.request("), 1)


class TheCardAlwaysSaysWhatItIsDoing(unittest.TestCase):
    """The card that was a pale tint and no words: the state had nothing in it to draw.

    Everything the extension can print has to arrive in the activity the app hands the system —
    the widget is a second process with no bot list, no transcript and no stream, so a sentence
    written in the view is the same sentence for every turn, and a name captured once at `request`
    time is the only thing the card will ever say about *this* bot. The card therefore carries a
    `step` (what the bot is doing, in the app's own words), the coordinator pushes it when the turn
    moves, and both the initialiser and the decoder end at a neutral word — the floor that makes a
    blank capsule impossible, including for an activity requested by an older build.
    """

    def test_the_state_carries_the_step_and_its_cap(self) -> None:
        self.assertIn("public var step: String", ATTRIBUTES)
        self.assertIn("public static let stepLimit = 48", ATTRIBUTES)

    def test_the_state_pushed_at_start_is_never_empty(self) -> None:
        begin = body("private func begin()")
        # Read before the request, and handed to it: the first frame iOS draws is this state, and a
        # turn whose first token is slow would otherwise be a wordless card for its whole run.
        self.assertIn("let startStep = normalisedStep()", begin)
        self.assertLess(begin.index("let startStep"), begin.index("Activity.request("))
        # One state for every path — the request, the re-point of a live card, and the adoption of
        # one left by another process — so no branch can push a wordless frame.
        self.assertEqual(begin.count("step: startStep"), 1)
        self.assertIn("let content = ActivityContent(state: state,", begin)
        # …and the type cannot be handed an empty one: `stepLine` ends at the neutral word.
        init = ATTRIBUTES[ATTRIBUTES.index("public init(phase: Phase"):ATTRIBUTES.index("/// The step, flattened")]
        self.assertIn("self.step = Self.stepLine(step, phase: phase)", init)
        step_line = body("public static func stepLine", ATTRIBUTES)
        self.assertIn("guard !flat.isEmpty else { return Self.neutral(phase) }", step_line)
        self.assertIn("prefix(stepLimit)", step_line)

    def test_the_neutral_word_for_each_phase(self) -> None:
        neutral = body("public static func neutral", ATTRIBUTES)
        self.assertIn('case .working: return "Working"', neutral)
        self.assertIn('case .done: return "Done"', neutral)

    def test_an_older_card_gets_the_same_floor(self) -> None:
        # 0.1.638's activities have no `step` key. A missing key must decode to the neutral word,
        # not to a blank line and not to a thrown decoder that drops the card being looked at.
        decoder = ATTRIBUTES[ATTRIBUTES.index("public init(from decoder: Decoder) throws"):]
        decoder = decoder[:decoder.index("/// What the card calls a bot")]
        self.assertIn("decodeIfPresent(String.self, forKey: .step)", decoder)
        self.assertIn("phase: phase", decoder)
        self.assertIn("case phase, startedAt, finishedAt, replySnippet, step", ATTRIBUTES)

    def test_the_name_line_can_never_be_blank(self) -> None:
        # The name is the other half of "which bot": `Bot.displayName` always resolves, but the card
        # must not depend on that, because a blank name line is indistinguishable from no card.
        self.assertIn('public static let fallbackName = "Hermey"', ATTRIBUTES)
        self.assertIn("self.botName = Self.displayName(botName)", ATTRIBUTES)
        display = body("public static func displayName", ATTRIBUTES)
        self.assertIn("return flat.isEmpty ? fallbackName : flat", display)

    def test_the_lock_screen_prints_the_step(self) -> None:
        # The complaint was the lock screen, so the layout that failed is the one pinned: the card
        # draws the named status line, and the line is the state's step when there is one.
        card = piece("private struct HermeyTurnLockScreen: View")
        self.assertIn("HermeyTurnStatusLine(state: state, botName: botName, isStale: isStale, tone: .card)", card)
        self.assertIn("Text(line)", piece("private struct HermeyTurnStatusLine: View"))
        status = piece("private struct HermeyTurnStatusLine: View")
        self.assertIn("let step = state.step", status)
        self.assertIn("guard step.isEmpty else { return step }", status)

    def test_the_end_state_has_words_with_or_without_a_reply(self) -> None:
        status = piece("private struct HermeyTurnStatusLine: View")
        self.assertIn('return state.phase == .done ? "Done" : "Working on your message"', status)
        finish = body("private func finish()")
        self.assertIn("step: Self.doneWords", finish)
        # The snippet stays the second line, and stays optional: a cancelled turn has no reply to
        # quote, so the card says "Done" and the elapsed time rather than inventing words.
        self.assertIn("replySnippet: replySnippet(),", finish)
        self.assertIn('static let doneWords = "Done"', COORDINATOR)

    def test_progress_is_pushed_while_the_turn_runs(self) -> None:
        # The path the feature was missing: `begin` wrote the state once and nothing refreshed it,
        # so the lock screen held the frame from `request` until the turn ended.
        attach = body("func attach(to model: AppModel)")
        for source in ("model.$liveTools", "model.$streamingText", "model.$reasoningText"):
            self.assertIn(source, attach)
        self.assertIn("self.progress()", attach)
        progress = body("private func progress()")
        self.assertIn("push(content, to: activity)", progress)
        self.assertIn("phase: .working", progress)
        # Normalised before it is compared, so a token that does not change the line is not an
        # update — otherwise a streaming reply costs one activity write per token.
        self.assertIn("let step = normalisedStep()", progress)
        self.assertIn("guard step != lastStep else { return }", progress)

    def test_the_step_is_the_apps_own_vocabulary(self) -> None:
        # Same words the app's working row reads: the tracker's activity, and the tool that is out.
        step = body("private func stepLine()")
        self.assertIn("model.liveTools.last(where: { $0.isRunning })", step)
        self.assertIn("model.activity(forBot: $0)", step)
        self.assertIn("model.streamingText", step)
        for phrase in ("Thinking it through", "Using the computer", "Working on your message"):
            self.assertIn(phrase, step)

    def test_the_widget_draws_the_type_the_coordinator_starts(self) -> None:
        # One attributes type in two processes: the widget's configuration and every `Activity<>`
        # the coordinator holds must name the same struct, and no second `ActivityAttributes`
        # conformance may exist anywhere in the tree to drift from it.
        conformances = [
            path for path in sorted(ROOT.glob("Apps/**/*.swift")) + sorted(ROOT.glob("Sources/**/*.swift"))
            if ": ActivityAttributes" in path.read_text(encoding="utf-8")
        ]
        self.assertEqual([path.name for path in conformances], ["HermeyTurnAttributes.swift"])
        self.assertIn("ActivityConfiguration(for: HermeyTurnAttributes.self)", WIDGET)
        self.assertEqual(set(re.findall(r"Activity<(\w+)>", COORDINATOR)), {"HermeyTurnAttributes"})
        self.assertIn("HermeyTurnAttributes(botName: name)", COORDINATOR)


if __name__ == "__main__":
    unittest.main()
