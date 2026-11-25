"""The bot list's ＋ brightens under the pointer and takes every press, first time.

Reported 2026-11-25: "the + button on desktop doesnt have a mouseover effect, and sometimes click
doesnt take". Two separate faults in one control, and the SwiftUI sources are read as text here
because neither is something a Linux test can call:

* the ＋ was the one control in the row built by hand, and it was the one control with **no hover
  treatment at all** — the bell beside it gets `hoverFill` from `HermeyIconButton`;
* the title-bar band behind the row was a single full-width `TitlebarDragArea()`, and that view is
  an AppKit `NSView` whose `mouseDown` takes the press and runs the window's drag loop. A band
  drawn *under* a control is a band that can eat that control's click — the ＋ opened on some
  presses and not others, whichever of the two won the hit test at that pixel.

The band is still a title bar (the owner asked for that: "I cant double click anywhere on the
sidebar top"); it now stops where the verbs begin.
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

# The band's height, written the same way the row's is: the traffic-light strip, a 30 pt icon row,
# and `barInset` above and below it.
BAND_HEIGHT = "WorkspaceShell.titlebarStrip + 30 + Self.barInset * 2"


def block(source: str, opening: str, closing: str) -> str:
    """The text between one declaration and the next marker, exclusive."""
    assert opening in source, f"{opening!r} is gone"
    tail = source.split(opening, 1)[1]
    assert closing in tail, f"{closing!r} did not follow {opening!r}"
    return tail.split(closing, 1)[0]


class ThePlusWearsTheChromesOwnHover(unittest.TestCase):
    """Pointing at it brightens it by the same step as the bell beside it."""

    def setUp(self) -> None:
        self.header = block(MAC, "private var header: some View {", "    /// Everything waiting")
        self.plus = block(MAC, "private var addMenu: some View {", "    /// The top of the list's dissolve")
        self.bell = block(MAC, "private var notificationsButton: some View {", "    // MARK: Floor")

    def test_the_fill_is_the_control_pair_every_other_control_uses(self) -> None:
        # `control` at rest, `controlHover` under the pointer — the exact pair `hoverFill` applies,
        # so the two verbs brighten by the same amount rather than by a hand-picked shade.
        self.assertIn(".fill(isAddMenuHovered ? Tokens.controlHover : Tokens.control)", self.plus)
        self.assertNotIn(".fill(Tokens.surface)", self.plus,
                         "the ＋ went back to a flat fill: it has no hover state then")

    def test_the_bell_brightens_the_same_way(self) -> None:
        # The reference the ＋ has to match: the shared glyph button's hover fill, on the same token.
        self.assertIn('HermeyIconButton("bell"', self.bell)
        self.assertIn(".hoverFill(rest: .clear, hover: Tokens.controlHover", CONTROLS)
        self.assertIn(".onHoverCompat { hovering = $0 }", COMPONENTS,
                      "hover is one implementation (`HoverFill`), not a second copy per control")

    def test_a_fast_pointer_leaving_puts_it_back(self) -> None:
        # Assigned straight through: `if hovering { isHovering = true }` would stay bright forever
        # after the first pass, which a fast exit makes invisible until it is not.
        self.assertIn(".onHoverCompat { isAddMenuHovered = $0 }", self.plus)
        self.assertNotIn("if $0", self.plus)

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
                # Either the shared glyph button (which carries `hoverFill` itself) or an explicit
                # `onHoverCompat`. Nothing in this row is allowed to have neither.
                self.assertTrue("HermeyIconButton(" in source or ".onHoverCompat" in source,
                                f"{name} has no hover treatment")

    def test_the_hover_is_on_the_control_and_covers_the_click_box(self) -> None:
        # On the menu rather than inside its label, so the brightened box and the clickable box are
        # the same 30 pt square.
        label_end = self.plus.index(".menuStyle(.borderlessButton)")
        self.assertNotIn(".onHoverCompat", self.plus[:label_end])
        self.assertIn(".onHoverCompat", self.plus[label_end:])


class ThePhoneIsUntouched(unittest.TestCase):
    """The Mac panel's own view; nothing here is shared with the phone's list."""

    def test_the_phone_has_none_of_this(self) -> None:
        for identifier in ("isAddMenuHovered", "VerbsWidthKey", "didBeginTrackingNotification"):
            self.assertNotIn(identifier, IOS, f"{identifier} leaked into the phone's list")

    def test_the_phones_plus_keeps_its_toolbar_behaviour(self) -> None:
        # A toolbar menu on iOS: the bar draws the chrome and the system gives the press feedback.
        add = block(IOS, 'Image(systemName: "plus")', ".accessibilityIdentifier(\"botList.add\")")
        self.assertIn(".frame(width: 36, height: 36)", add)
        self.assertIn(".buttonStyle(.plain)", add)
        self.assertNotIn("onHover", add, "there is no pointer on the phone")


if __name__ == "__main__":
    unittest.main()
