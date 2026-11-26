"""The bot list's ＋ lights up under the pointer, every time, and takes every press.

Reported 2026-11-25, twice. The first report — "the + button on desktop doesnt have a mouseover
effect, and sometimes click doesnt take" — was answered with two changes:

* the ＋ was the one control in the row built by hand, and the one with **no hover treatment at
  all**, while the bell beside it gets `hoverFill` from `HermeyIconButton`;
* the title-bar band behind the row was a single full-width `TitlebarDragArea()`, an AppKit `NSView`
  whose `mouseDown` takes the press and runs the window's drag loop. A band drawn *under* a control
  is a band that can eat that control's click.

The click fix held. The hover did not: "the hover on sidebar + doesnt seem to have fixed" arrived
after 0.1.661 shipped. Two faults, and both are asserted here as absent:

* **the event never arrived.** It was wired `.onHoverCompat {...}` on the `Menu` itself, which is
  `onHover` on macOS. A `Menu` with `.borderlessButton` is an `NSPopUpButton`, and a pop-up button's
  cell runs its own highlight; the crossings SwiftUI translates on the host around that cell were
  not being delivered to the modified view. Hover is an `NSTrackingArea` **we** install now, in an
  `NSView` of our own (`HoverReporter`), which no cell can decline to forward;
* **the change was too small to see.** `control` → `controlHover` on Midnight is `#232323` →
  `#2B2B2B`: a 3% step next to a bell that hovers `clear` → `controlHover`. The glyph and the
  hairline move too now.

The SwiftUI sources are read as text here because none of this is something a Linux test can call:
there is no Swift toolchain in this checkout, and what a tracking area does is AppKit's.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

MAC = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
IOS = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
CONTROLS = (ROOT / "Sources" / "HermeyUI" / "Controls.swift").read_text(encoding="utf-8")
COMPONENTS = (ROOT / "Sources" / "HermeyUI" / "Components.swift").read_text(encoding="utf-8")
DRAG = (ROOT / "Apps" / "HermesMac" / "Support" / "TitlebarDragArea.swift").read_text(encoding="utf-8")
REPORTER = (ROOT / "Apps" / "HermesMac" / "Support" / "HoverReporter.swift").read_text(encoding="utf-8")

# The band's height, written the same way the row's is: the traffic-light strip, a 30 pt icon row,
# and `barInset` above and below it.
BAND_HEIGHT = "WorkspaceShell.titlebarStrip + 30 + Self.barInset * 2"


def block(source: str, opening: str, closing: str) -> str:
    """The text between one declaration and the next marker, exclusive."""
    assert opening in source, f"{opening!r} is gone"
    tail = source.split(opening, 1)[1]
    assert closing in tail, f"{closing!r} did not follow {opening!r}"
    return tail.split(closing, 1)[0]


class TheHoverComesFromAppKitNotFromTheMenu(unittest.TestCase):
    """A borderless `Menu` is a control whose cell can swallow SwiftUI's hover. Ours cannot."""

    def setUp(self) -> None:
        self.plus = block(MAC, "private var addMenu: some View {", "    /// The top of the list's dissolve")

    def test_the_plus_no_longer_asks_swiftui_for_hover(self) -> None:
        # The exact wiring that shipped in 0.1.661 and did not light the button. `onHoverCompat` is
        # `onHover` on macOS, and a pop-up button's own cell is what the pointer lands in.
        self.assertNotIn(".onHoverCompat", self.plus,
                         "the ＋ went back to SwiftUI's onHover: that is the wiring that did nothing")

    def test_the_plus_is_watched_by_our_own_reporter(self) -> None:
        self.assertIn(".background(HoverReporter { isAddMenuHovered = $0 })", self.plus)
        # A background, not an overlay: the reporter must sit behind the control so the control
        # keeps the press in front of it.
        self.assertNotIn(".overlay(HoverReporter", self.plus)

    def test_the_reporter_installs_a_tracking_area_of_its_own(self) -> None:
        self.assertIn("struct HoverReporter: NSViewRepresentable", REPORTER)
        self.assertIn("NSTrackingArea(", REPORTER)
        self.assertIn("addTrackingArea(area)", REPORTER)
        # Removed before it is re-installed: tracking areas do not replace each other, and two of
        # them on one view is two `exit`s for every leave.
        self.assertIn("removeTrackingArea(", REPORTER)
        # The three options that make it a hover and not a promise: both directions, only while
        # the window is key, and a rect AppKit keeps current through every resize.
        for option in (".mouseEnteredAndExited", ".activeInKeyWindow", ".inVisibleRect"):
            self.assertIn(option, REPORTER, f"the tracking area is missing {option}")

    def test_a_crossing_is_not_the_only_way_to_learn_the_truth(self) -> None:
        # A tracking area fires on a *crossing*. Rebuilt under a resting pointer (the sidebar
        # redraws on every bot state change) there is none, so the pointer is read directly.
        self.assertIn("mouseLocationOutsideOfEventStream", REPORTER)
        install = block(REPORTER, "override func updateTrackingAreas() {", "override func mouseEntered")
        self.assertIn("schedulePointerSync()", install,
                      "the area is installed without reading where the pointer already is")

    def test_the_reporter_is_never_a_click_target(self) -> None:
        # The measured keep-out above the row exists because an AppKit view under a control eats
        # its press. This one sits under a control by design, so it must refuse every hit.
        self.assertRegex(REPORTER, r"override func hitTest\(_ point: NSPoint\) -> NSView\? \{ nil \}")


class TheHoverIsVisibleAtAGlance(unittest.TestCase):
    """Fill, glyph and hairline all step, so a glance catches it on a dark chrome."""

    def setUp(self) -> None:
        self.plus = block(MAC, "private var addMenu: some View {", "    /// The top of the list's dissolve")
        self.label = block(self.plus, "} label: {", ".menuStyle(.borderlessButton)")

    def test_the_fill_steps(self) -> None:
        self.assertIn(".fill(isAddMenuHovered ? Tokens.controlHover : Tokens.control)", self.label)
        self.assertNotIn(".fill(Tokens.surface)", self.label,
                         "the ＋ went back to a flat fill: it has no hover state then")

    def test_the_glyph_steps_from_a_dimmed_rest_to_full_ink(self) -> None:
        # A fill step alone is what was reported as no hover. The glyph was `textPrimary` at rest
        # and stayed there, so the brightest thing in the button never moved.
        self.assertIn(".foregroundStyle(isAddMenuHovered ? Tokens.textPrimary : Tokens.textSecondary)",
                      self.label)
        self.assertNotIn(".foregroundStyle(Tokens.textPrimary)\n", self.label,
                         "the glyph is full ink at rest again: only the fill can change")

    def test_the_hairline_steps(self) -> None:
        self.assertIn(".strokeBorder(isAddMenuHovered ? Tokens.borderStrong : Tokens.border, lineWidth: 1)",
                      self.label)

    def test_all_three_move_together(self) -> None:
        # One state, three channels: a channel left on a plain token is a channel that stays put.
        self.assertEqual(self.label.count("isAddMenuHovered ?"), 3,
                         "the hover must change exactly the fill, the glyph and the border")


class TheHoverIsWiredBothWays(unittest.TestCase):
    """Enter and exit both reach SwiftUI, so a fast pass cannot leave it bright."""

    def setUp(self) -> None:
        self.plus = block(MAC, "private var addMenu: some View {", "    /// The top of the list's dissolve")

    def test_enter_reports_true_and_exit_reports_false(self) -> None:
        entered = block(REPORTER, "override func mouseEntered(with event: NSEvent) {", "}")
        exited = block(REPORTER, "override func mouseExited(with event: NSEvent) {", "}")
        self.assertIn("report(true)", entered)
        self.assertIn("report(false)", exited)

    def test_the_reporter_calls_back_in_both_directions(self) -> None:
        # One closure, one bool, passed straight through — never an `if inside { ... }` that drops
        # the way back out.
        report = block(REPORTER, "private func report(_ inside: Bool) {", "private func removeWindowObservers")
        self.assertIn("onChange?(inside)", report)
        self.assertNotIn("if inside", report)

    def test_the_swiftui_side_assigns_straight_through(self) -> None:
        self.assertIn("isAddMenuHovered = $0", self.plus)
        self.assertNotIn("if $0", self.plus)

    def test_a_window_that_stops_being_key_clears_it(self) -> None:
        # `.activeInKeyWindow` stops tracking when the window is not key and sends no `exit`.
        self.assertIn("NSWindow.didResignKeyNotification", REPORTER)
        self.assertIn("NSWindow.didBecomeKeyNotification", REPORTER)


class ThePlusAndTheBellAreTheSameFamily(unittest.TestCase):
    """The neighbouring reference, and the one case the reporter cannot see: the menu it opens."""

    def setUp(self) -> None:
        self.plus = block(MAC, "private var addMenu: some View {", "    /// The top of the list's dissolve")
        self.bell = block(MAC, "private var notificationsButton: some View {", "    // MARK: Floor")

    def test_the_bell_brightens_its_fill(self) -> None:
        self.assertIn('HermeyIconButton("bell"', self.bell)
        self.assertIn(".hoverFill(rest: .clear, hover: Tokens.controlHover", CONTROLS)
        self.assertIn(".onHoverCompat { hovering = $0 }", COMPONENTS,
                      "hover is one implementation (`HoverFill`), not a second copy per control")

    def test_an_open_menu_neither_holds_it_bright_nor_leaves_it_dim(self) -> None:
        # A menu runs its own event loop in its own window, so the `false` that would put the fill
        # back can be suspended while it is up. Both ends of the tracking clear it.
        self.assertIn("NSMenu.didBeginTrackingNotification", self.plus)
        self.assertIn("NSMenu.didEndTrackingNotification", self.plus)
        for name in ("didBeginTrackingNotification", "didEndTrackingNotification"):
            call = block(self.plus, f"NSMenu.{name})) {{ _ in", "}")
            self.assertIn("isAddMenuHovered = false", call, f"{name} does not put the ＋ back to rest")


class TheTitleBarBandCannotReachAControl(unittest.TestCase):
    """The band is a title bar everywhere the row is empty — and nothing where a control is."""

    def setUp(self) -> None:
        self.header = block(MAC, "private var header: some View {", "    /// Everything waiting")
        self.band = block(self.header, ".background(alignment: .top) {", ".onPreferenceChange")
        self.verbs = block(self.header, "// The verbs as one measured box.", "Color.clear.preference")

    def test_the_catcher_is_still_a_title_bar(self) -> None:
        # Not deleted: #237 asked for the whole top band to zoom the window on a double-click, and
        # the AppKit view is what makes that exist. It keeps the row's full height.
        self.assertIn("TitlebarDragArea()", self.band)
        self.assertIn(f".frame(height: {BAND_HEIGHT})", self.band)
        self.assertIn("window.performDrag(with: event)", DRAG)

    def test_the_band_stops_at_the_verbs(self) -> None:
        # [the row's empty width][the verbs' width]. The second half is `Color.clear` — not a view
        # that declines the press, but no drag view at all, so there is nothing to lose a race with.
        self.assertIn("Color.clear", self.band,
                      "the band runs under the verbs again: a drag view there eats their clicks")
        # The hole starts at the verbs' leading edge, which is `barInset` in from the band's right
        # edge — sized to the glyphs alone it would still cover the bell's outer 10 pt.
        self.assertIn(".frame(width: verbsWidth + Self.barInset)", self.band,
                      "the hole in the band does not reach the verbs' leading edge")
        drag = self.band.index("TitlebarDragArea()")
        keep_out = self.band.index("Color.clear")
        width = self.band.index(".frame(width: verbsWidth + Self.barInset)")
        self.assertLess(drag, keep_out)
        self.assertLess(keep_out, width)

    def test_no_control_is_drawn_inside_the_catcher(self) -> None:
        # The band is one `HStack(spacing: 0)` of a drag area and a hole. A control inside it would
        # be a control whose press the drag view's `mouseDown` can take first.
        for control in ("notificationsButton", "addMenu", "HermeyIconButton", "Menu {"):
            self.assertNotIn(control, self.band, f"{control} is inside the title-bar band")

    def test_the_keep_out_is_measured_not_typed(self) -> None:
        # 62 pt of arithmetic would rot the day a third verb lands in the row; the width comes off
        # the verbs' own frame, so the hole follows whatever is in it.
        self.assertIn("Color.clear.preference(key: VerbsWidthKey.self, value: proxy.size.width)",
                      self.header)
        self.assertIn("if abs(width - verbsWidth) > 0.5 { verbsWidth = width }", self.header)
        self.assertNotIn("frame(width: 62)", self.band)

    def test_the_row_is_still_exactly_the_two_verbs(self) -> None:
        # Every child of the measured box had to be reviewed for hover and for dead corners. A new
        # one has to be reviewed too: adding it fails here first.
        inner = self.verbs.split("HStack(spacing: 2) {", 1)[1].split("}", 1)[0]
        children = [line.strip() for line in inner.strip().splitlines() if line.strip()]
        self.assertEqual(children, ["notificationsButton", "addMenu"])


class TheClickBoxIsTheDrawnBox(unittest.TestCase):
    """A press anywhere on the 30 pt square is the ＋'s — edges and corners included."""

    def setUp(self) -> None:
        self.plus = block(MAC, "private var addMenu: some View {", "    /// The top of the list's dissolve")

    def test_the_hit_shape_is_a_rectangle_over_the_square(self) -> None:
        # Rectangle, not Circle: a circular content shape on a square leaves its four corners dead,
        # and the corner is where a hand lands when it is aiming at the glyph.
        label = block(self.plus, "} label: {", ".menuStyle(.borderlessButton)")
        frame = label.index(".frame(width: BarIconScale.of(24), height: BarIconScale.of(24))")
        shape = label.index(".contentShape(Rectangle())")
        self.assertLess(frame, shape, "the hit shape must cover the whole framed box, not the glyph")
        self.assertNotIn("contentShape(Circle()", self.plus)
        # The visual is that same box: a rounded square of the same size and radius.
        self.assertIn("RoundedRectangle(cornerRadius: BarIconScale.of(7), style: .continuous)", label)

    def test_the_control_declares_its_own_box_too(self) -> None:
        # The label's shape decides what SwiftUI hit-tests; the modifier on the menu says the box
        # out loud instead of leaving it to an AppKit cell's idea of where its glyph is.
        after = self.plus.split(".menuStyle(.borderlessButton)", 1)[1]
        self.assertIn(".contentShape(Rectangle())", after.split(".help(", 1)[0])

    def test_the_bell_is_the_same_box(self) -> None:
        # The reference: 30 pt frame, hover fill, then a rectangular content shape — in that order.
        icon = CONTROLS.split("public struct HermeyIconButton", 1)[1]
        body = block(icon, "public var body: some View {", "/// An inline text action")
        frame = body.index(".frame(width: side, height: side)")
        hover = body.index(".hoverFill(rest: .clear, hover: Tokens.controlHover")
        shape = body.index(".contentShape(Rectangle())")
        self.assertLess(frame, hover)
        self.assertLess(hover, shape)


class EveryControlInTheRowHovers(unittest.TestCase):
    """The row has no hover-blind control left in it."""

    def setUp(self) -> None:
        self.bell = block(MAC, "private var notificationsButton: some View {", "    // MARK: Floor")
        self.plus = block(MAC, "private var addMenu: some View {", "    /// The top of the list's dissolve")

    def test_both_verbs_have_a_hover(self) -> None:
        for name, source in (("notificationsButton", self.bell), ("addMenu", self.plus)):
            with self.subTest(control=name):
                # Either the shared glyph button (which carries `hoverFill` itself) or the
                # tracking-area reporter. Nothing in this row is allowed to have neither.
                self.assertTrue("HermeyIconButton(" in source or "HoverReporter" in source,
                                f"{name} has no hover treatment")

    def test_the_hover_is_on_the_control_and_covers_the_click_box(self) -> None:
        # On the menu rather than inside its label, so the brightened box and the clickable box are
        # the same 30 pt square — and behind it, so the press still lands on the menu.
        label_end = self.plus.index(".menuStyle(.borderlessButton)")
        self.assertNotIn("HoverReporter", self.plus[:label_end])
        self.assertIn(".background(HoverReporter", self.plus[label_end:])


class ThePhoneIsUntouched(unittest.TestCase):
    """The Mac panel's own view; nothing here is shared with the phone's list."""

    def test_the_phone_has_none_of_this(self) -> None:
        for identifier in ("isAddMenuHovered", "VerbsWidthKey", "didBeginTrackingNotification",
                           "HoverReporter", "NSTrackingArea"):
            self.assertNotIn(identifier, IOS, f"{identifier} leaked into the phone's list")

    def test_the_phones_plus_keeps_its_toolbar_behaviour(self) -> None:
        # A toolbar menu on iOS: the bar draws the chrome and the system gives the press feedback.
        add = block(IOS, 'Image(systemName: "plus")', ".accessibilityIdentifier(\"botList.add\")")
        self.assertIn(".frame(width: 36, height: 36)", add)
        self.assertIn(".buttonStyle(.plain)", add)
        self.assertNotIn("onHover", add, "there is no pointer on the phone")


if __name__ == "__main__":
    unittest.main()

class TheHoverCannotBeStarved(unittest.TestCase):
    """The menu cell in front must not be able to hide the pointer from us.

    The first fix used a tracking area on our own NSView, which still depends on crossings
    AppKit chooses to send *to that view*. A borderless NSPopUpButton reports no mouseover
    after it shipped, so the sample now comes from the window's own event stream as well —
    the belt to the area's braces. Both must exist: the area keeps it cheap, the monitor
    makes it true.
    """

    def reporter(self):
        return REPORTER

    def test_the_pointer_is_sampled_from_the_windows_own_stream(self):
        src = self.reporter()
        self.assertIn("addLocalMonitorForEvents", src,
                      "the hover fell back to tracking areas alone: a menu cell can starve those")
        self.assertIn(".mouseMoved", src, "the monitor does not watch pointer moves")
        self.assertIn("mouseLocationOutsideOfEventStream", src,
                      "the monitor does not read the pointer's real position")

    def test_the_monitor_is_removed_with_the_view(self):
        src = self.reporter()
        self.assertIn("removeMonitor", src, "a local monitor outlives the view that installed it")
        self.assertGreaterEqual(src.count("removeMonitor"), 2,
                                "the monitor is only released on one path")

    def test_the_sample_is_deduped(self):
        src = self.reporter()
        self.assertIn("guard reported != inside", src,
                      "every pointer move would write state, and the sidebar repaints constantly")


class TheComposerStillOffersBothDoors(unittest.TestCase):
    """Mohammad asked for the two-entry attach menu back after the single panel shipped.

    One panel could not reach the Photos library, and the library is where his pictures are.
    """

    def test_the_menu_has_a_photos_entry_and_a_files_entry(self):
        menu = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MacAttachmentMenu.swift")
        self.assertTrue(menu.exists(), "the two-entry attach menu is gone again")
        src = menu.read_text(encoding="utf-8")
        self.assertIn("Photos", src)
        self.assertIn("Files", src)

    def test_the_single_panel_is_gone(self):
        picker = ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerPicker.swift"
        self.assertFalse(picker.exists(), "the single-panel picker is back; the menu is what he asked for")
