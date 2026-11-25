"""Two more reports from Mohammad, 2026-11-24, and the rule each one is held to.

* **The row's ⋯ — gone (2026-11-25).** It was added as a hover-only overlay, then reported again:
  the owner wants no ⋯ on a hovered or selected bot row. The glyph and the focus state that kept it
  visible are removed from the row; the hover fill, the row's height, its button and its
  `contextMenu` are exactly what they were, and the context menu is now the row's only menu. (The
  session-row, lock-screen and avatar guards below are unchanged.)
* **The composer's session row.** The session line that floated above the capsule is now *inside*
  the composer, as one row under the field with two halves: a dark rounded pill holding only the
  model (tinted round glyph, the name in semibold, a chevron, all one button that opens the existing
  model picker), and the context count as its own text at the row's trailing edge. The count is
  `fixedSize`, so it keeps its room; the model name truncates at the tail; a `Spacer` between them
  means neither half can squeeze the other. The row is `Equatable` and one line — chrome below the
  text, never a character of it covered.
* **The Lock Screen card's left edge.** Inside the Live Activity card, `HERMEY` and `Working · …` had
  two different left edges, because the status line led with its phase symbol. Both rows now start at
  the same point of the text column, nothing indents a line, the card's vertical padding is one
  symmetric number, and the block is centred against the mark and the timer in all three phases.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
MAC = ROOT / "Apps" / "HermesMac"
PHONE = ROOT / "Apps" / "HermesMobile"

PILL = UI / "ComposerModelPill.swift"
ROW = UI / "ComposerSessionRow.swift"
COMPOSER = UI / "Composer.swift"

MAC_BAR = MAC / "Conversation" / "MacComposerBar.swift"
PHONE_SCREEN = PHONE / "Views" / "ConversationScreen.swift"
MAC_ROOT = MAC / "Workspace" / "WorkspaceRoot.swift"

SIDEBAR = MAC / "Sidebar" / "SidebarBotList.swift"
PHONE_LIST = PHONE / "Views" / "BotListScreen.swift"

LIVE_ACTIVITY = ROOT / "Apps" / "HermesLiveActivity" / "HermeyTurnLiveActivity.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def between(text: str, start: str, end: str) -> str:
    """The source between two markers, exclusive of `end`."""
    assert start in text, f"missing start marker: {start!r}"
    body = text.split(start, 1)[1]
    assert end in body, f"missing end marker: {end!r}"
    return body.split(end, 1)[0]


def without_comments(text: str) -> str:
    """The source with its `//` lines stripped: a guard about code must not read prose."""
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


class TheComposerCarriesItsModelInTheRow(unittest.TestCase):
    """The session row's two halves — model pill leading, context count trailing — in the composer."""

    PILL_SOURCE = read(PILL)
    ROW_SOURCE = read(ROW)
    COMPOSER_SOURCE = read(COMPOSER)
    MAC_SOURCE = read(MAC_BAR)
    PHONE_SOURCE = read(PHONE_SCREEN)

    def pill_label(self) -> str:
        """The button's label: everything the pill draws, minus the button's own modifiers."""
        return between(self.PILL_SOURCE,
                       "Button(action: onOpen) {",
                       ".buttonStyle(PressableButtonStyle())")

    def pill_struct(self) -> str:
        """The pill type alone: `SessionLine` shares the file, and its `TokenCount` is not the pill's."""
        return self.PILL_SOURCE.split("public struct ComposerModelPill", 1)[1]

    def row_body(self) -> str:
        """The row's `body`: both halves, in the order the row draws them."""
        return between(self.ROW_SOURCE,
                       "public var body: some View {",
                       "\n    }\n}")

    def count_view(self) -> str:
        """The row's trailing half: the count it draws after the pill."""
        return between(self.ROW_SOURCE,
                       "if let tokens =",
                       "\n        }\n    }")

    def glyph_view(self) -> str:
        return between(self.PILL_SOURCE,
                       "private var glyph: some View {",
                       "private var chevron: some View {")

    def chevron_view(self) -> str:
        return between(self.PILL_SOURCE,
                       "private var chevron: some View {",
                       "\n\n}")

    def model_name_view(self) -> str:
        return between(self.PILL_SOURCE,
                       "private func modelName(_ name: String) -> some View {",
                       "/// A small round tinted glyph")

    def test_it_is_one_button_and_the_chevron_is_inside_it(self) -> None:
        self.assertEqual(self.PILL_SOURCE.count("Button(action: onOpen)"), 1)
        # No bare `Button {` and no second control: the chevron is part of the same label, so a tap
        # anywhere on the pill (glyph, name, chevron) opens the same picker.
        self.assertNotIn("Button {", self.PILL_SOURCE)
        label = self.pill_label()
        self.assertIn("\n                    chevron\n", label)
        self.assertIn('Image(systemName: "chevron.down")', self.chevron_view())
        self.assertNotIn("Button", label)
        self.assertNotIn("Button", self.chevron_view())
        # The row draws exactly one pill, and the pill is the row's leading half.
        self.assertEqual(self.ROW_SOURCE.count("ComposerModelPill(provider: provider"), 1)
        self.assertLess(self.row_body().index("ComposerModelPill("),
                        self.row_body().index("Spacer(minLength: 8)"))

    def test_it_is_chrome_not_a_link(self) -> None:
        label = self.pill_label()
        # A dark rounded fill of the app's own token, lightened under the pointer (and under
        # keyboard focus, which is the pill's own answer to the system ring); nothing stroked, no
        # underline, no accent-coloured text that would read as a link.
        self.assertIn("Capsule().fill(isEnabled && (isHovered || isFocused) ? Tokens.controlHover", label)
        self.assertIn(": Tokens.control))", label)
        self.assertNotIn("strokeBorder", self.PILL_SOURCE)
        self.assertNotIn("underline(", self.PILL_SOURCE)
        # The shared press feedback every other control uses.
        self.assertIn(".buttonStyle(PressableButtonStyle())", self.PILL_SOURCE)
        # Hover only where there is a pointer — the app's own cross-platform helper.
        self.assertIn(".onHoverCompat { isHovered = $0 }", self.PILL_SOURCE)

    def test_the_pill_is_as_tall_as_its_row(self) -> None:
        label = self.pill_label()
        self.assertIn(".frame(maxHeight: .infinity)", label,
                      "the pill must take the composer row's control height")
        self.assertNotIn(".fixedSize(horizontal: false, vertical: true)", label,
                         "a vertical fixedSize pins the pill to its text height")

    def test_the_sample_s_anatomy_inside_the_pill(self) -> None:
        label = self.pill_label()
        # The pill is the model alone: a small circular tinted glyph, then the model in semibold,
        # then the chevron — a gap, not a divider. The count is the row's other half, not this one's.
        self.assertIn("Circle().fill(Tokens.accentSoft)", self.glyph_view())
        self.assertIn('Image(systemName: "cpu")', self.glyph_view())
        self.assertIn("TypeScale.font(TypeScale.label, weight: .semibold)",
                      self.model_name_view())
        self.assertIn("Tokens.textPrimary", self.model_name_view())
        self.assertIn('Image(systemName: "chevron.down")', self.chevron_view())
        self.assertNotIn("Divider", self.PILL_SOURCE)
        self.assertNotIn('Text("·")', self.PILL_SOURCE)
        # Glyph, name, chevron: three parts, in that order, inside the pill's single HStack.
        order = ["glyph", "modelName(name)", "\n                    chevron\n"]
        positions = [label.index(token) for token in order]
        self.assertEqual(positions, sorted(positions))
        self.assertIn(".padding(.horizontal, 12)", label)
        # No token text survives in the pill type: the count moved to the row.
        pill = without_comments(self.pill_struct())
        for count in ("SessionLine.context", "Text(tokens)", "context(tokens)"):
            self.assertNotIn(count, pill)

    def test_the_count_keeps_its_room_and_the_model_truncates(self) -> None:
        # The count used to ride inside the pill, where it could squeeze the model name. It is now
        # the row's trailing half: `fixedSize` holds its width, and the model is what gives way.
        self.assertNotIn("ViewThatFits", without_comments(self.pill_struct()),
                         "a fallback that drops the count comes back the moment this returns")
        self.assertNotIn("Text(tokens)", self.pill_label())
        # The name truncates where it is drawn, in `modelName(_:)`.
        self.assertIn(".truncationMode(.tail)", read(PILL),
                      "the model truncates rather than widening the pill")
        count = self.count_view()
        self.assertIn("SessionLine.context(used: used, limit: limit)", self.ROW_SOURCE,
                      "the count comes from the one formatter both apps already share")
        self.assertIn("Text(tokens)", count)
        self.assertIn(".fixedSize(horizontal: true, vertical: false)", count,
                      "the count must not be squeezed or truncated")
        self.assertNotIn(".truncationMode", count,
                         "the count is not the half that gives way")
        # A spacer between the halves, not one half's width: neither can squeeze the other.
        body = self.row_body()
        self.assertIn("HStack(spacing: 8)", body)
        self.assertLess(body.index("ComposerModelPill("), body.index("Spacer(minLength: 8)"))
        self.assertLess(body.index("Spacer(minLength: 8)"), body.index("Text(tokens)"))

    def test_the_pill_is_not_in_the_field_row(self) -> None:
        # It used to sit between the paperclip and the text, which read as part of the field and put
        # a lozenge on the placeholder's own line. Nothing about the pill belongs in that row.
        row = between(self.COMPOSER_SOURCE,
                      "HStack(alignment: .bottom, spacing: 8) {",
                      "// One tap clears everything typed.")
        self.assertIn("rowCentred(attachControl)", row)
        self.assertNotIn("sessionRow", row,
                         "the session row is back on the field's line")
        self.assertNotIn("sessionPill", row)
        self.assertNotIn("rowCentred(sessionRow", row)

    def test_the_pill_sits_on_its_own_row_under_the_text_on_both_platforms(self) -> None:
        # One band, no per-platform split: under the field row, inside the same rounded container,
        # before the card's own `hint` — so it can never cover a character being typed.
        use = between(self.COMPOSER_SOURCE,
                      "            .padding(.bottom, hint == nil ? 8 : 2)\n",
                      "if let hint, !hint.isEmpty {")
        self.assertIn("sessionPillBand", use)
        self.assertNotIn("#if os(iOS)", use, "the band is one rule, not a phone-only branch")
        band = between(self.COMPOSER_SOURCE,
                       "private var sessionPillBand: some View {",
                       "private var trimmed: String {")
        self.assertIn("if let sessionRow {", band)
        self.assertIn("sessionRow\n                .equatable()", band,
                      "the row is what the composer lays out, not a pill the apps assemble")
        self.assertIn(".frame(height: controlSide)", band)
        # Its own row, aligned with the text rather than the card's edge — not an overlay.
        self.assertIn(".frame(maxWidth: .infinity, alignment: .leading)", band)
        self.assertIn(".padding(.leading, 8)", band,
                      "the row must start where the typed text starts, including its inset")
        self.assertNotIn("overlay", band)
        self.assertNotIn("ComposerModelPill", band,
                         "the band draws the row; the row is what draws the pill")
        self.assertLess(self.COMPOSER_SOURCE.index("            HStack(alignment: .bottom, spacing: 8) {"),
                        self.COMPOSER_SOURCE.index("\n            sessionPillBand\n"))
        self.assertLess(self.COMPOSER_SOURCE.index("\n            sessionPillBand\n"),
                        self.COMPOSER_SOURCE.index("\n        .background {"))

    def test_the_field_keeps_its_height_and_padding(self) -> None:
        body = between(self.COMPOSER_SOURCE,
                       "HStack(alignment: .bottom, spacing: 8) {",
                       "if let hint, !hint.isEmpty {")
        self.assertIn("field\n                    .frame(minHeight: rowHeight)", body)
        # The field row's own padding is untouched by the pill: it is still the same 8/6/8 the card
        # has always used.
        self.assertIn(".padding(.horizontal, 8)\n            .padding(.top, 6)\n"
                      "            .padding(.bottom, hint == nil ? 8 : 2)", body)

    def test_typing_cannot_re_lay_the_pill_out(self) -> None:
        self.assertIn("public struct ComposerModelPill: View, Equatable", self.PILL_SOURCE)
        self.assertIn("public struct ComposerSessionRow: View, Equatable", self.ROW_SOURCE)
        # The closures are not compared: they are rebuilt every parent pass, and comparing them
        # would make `.equatable()` pointless. The pill compares the model it draws; the row
        # compares the model and the count its two halves draw.
        comparator = between(self.PILL_SOURCE,
                             "public static func == (lhs: ComposerModelPill",
                             "/// The tinted round glyph")
        for field in ("provider", "model", "isEnabled"):
            self.assertIn(f"lhs.{field} == rhs.{field}", comparator)
        self.assertNotIn("onOpen", comparator)
        row_comparator = between(self.ROW_SOURCE,
                                 "public static func == (lhs: ComposerSessionRow",
                                 "public var body: some View {")
        for field in ("provider", "model", "used", "limit", "isEnabled"):
            self.assertIn(f"lhs.{field} == rhs.{field}", row_comparator)
        self.assertNotIn("onOpen", row_comparator)
        # Applied once, in the composer, where the row is drawn — so both apps inherit it rather
        # than each remembering.
        band = between(self.COMPOSER_SOURCE,
                       "private var sessionPillBand: some View {",
                       "private var trimmed: String {")
        self.assertIn(".equatable()", band)
        for source in (self.PILL_SOURCE, self.ROW_SOURCE):
            self.assertNotIn("model.draft", source)
            self.assertNotIn("GeometryReader", source)

    def test_both_apps_draw_it_and_open_the_picker_they_already_have(self) -> None:
        for name, source in (("the Mac", self.MAC_SOURCE), ("the phone", self.PHONE_SOURCE)):
            # One row per composer, built with the same five values (the action is each app's own).
            self.assertEqual(source.count("sessionRow: ComposerSessionRow("), 1, name)
            call = between(source, "sessionRow: ComposerSessionRow(", "onOpen:")
            for value in ("provider: model.modelProvider",
                          "model: model.modelLabel",
                          "used: model.contextUsed",
                          "limit: model.contextMax",
                          "isEnabled:"):
                self.assertIn(value, call, name)
            # Neither app assembles the pill itself: the row is the only door to it.
            self.assertNotIn("ComposerModelPill(", source, name)

        # The Mac: the row calls `store.openModel`, which is the one door the bot panel's Model
        # row uses, and that flag presents `MacModelSheet` at the window's root. No second picker.
        self.assertIn("guard let bot = model.selectedBot else { return }", self.MAC_SOURCE)
        self.assertIn("store.openModel(bot)", self.MAC_SOURCE)
        self.assertIn("onOpen: openModelPicker", self.MAC_SOURCE)
        root = read(MAC_ROOT)
        self.assertIn("if let bot = store.modelBot { return .model(bot) }", root)
        self.assertIn("MacModelSheet(model: store.model,", root)

        # The phone: the same sheet the drawer's Model row opens, for the bot the screen is about.
        self.assertIn("onOpen: { showModel = true }", self.PHONE_SOURCE)
        phone = self.PHONE_SOURCE
        self.assertIn(".sheet(isPresented: $showModel) {", phone)
        self.assertIn("BotModelSheet(bot: bot, model: model)", phone)

    def test_the_pill_has_no_count_left_in_it(self) -> None:
        # The two halves cannot silently merge back: `used`/`limit` live on `ComposerSessionRow`,
        # which draws the count, and the init through which the row builds the pill passes neither.
        pill = without_comments(self.pill_struct())
        for field in ("used", "limit", "contextUsed", "contextMax"):
            self.assertIsNone(re.search(rf"\b{field}\b", pill),
                              "the pill type must not carry the context count again")
        row_init = between(self.ROW_SOURCE,
                           "public init(provider: String?",
                           "self.provider = provider")
        for field in ("used: Int?", "limit: Int?"):
            self.assertIn(field, row_init, "the row is where the count's inputs belong")
        pill_call = between(self.ROW_SOURCE,
                            "ComposerModelPill(provider: provider",
                            "onOpen: onOpen)")
        for field in ("used:", "limit:"):
            self.assertNotIn(field, pill_call,
                             "the row must not hand the pill the count it draws itself")

    def test_the_name_on_the_pill_is_the_host_s_number(self) -> None:
        # The pill reads the same two published values the header does, and the picker writes
        # through the same route, so a pick updates the label without a second source.
        app_model = read(ROOT / "Sources" / "HermesAppKit" / "AppModel.swift")
        self.assertIn("public private(set) var modelLabel: String?", app_model)
        self.assertIn("public private(set) var modelProvider: String?", app_model)
        self.assertIn("if case .applied = change, botID == selectedBotID {", app_model)
        self.assertIn("await loadModelLabel()", app_model)


class TheBotRowHasNoOverflowButton(unittest.TestCase):
    """Mac: no ⋯ on a hovered or selected row. The context menu is the row's menu.

    The glyph was a second door onto the same `BotRowMenu` the row's `contextMenu` draws, revealed
    on hover, selection, keyboard focus or the search highlight. The owner asked for it to go
    (2026-11-25) without losing the menu, so both halves are pinned here: no glyph button is built
    anywhere in the row view, and the hover state, the context menu, the row's height and its
    keyboard stop are unchanged. The phone never had the glyph — long press and the two swipe
    actions are its doors — and that stays asserted too.
    """

    MAC_SOURCE = read(SIDEBAR)
    PHONE_SOURCE = read(PHONE_LIST)

    def mac_row(self) -> str:
        return between(self.MAC_SOURCE,
                       "private func row(for bot: Bot, isHovered: Bool = false,",
                       "/// A hidden bot is not gone")

    def test_no_glyph_button_is_built_in_the_row(self) -> None:
        row = self.mac_row()
        # The button, its visibility flag and the focus state that kept it on screen are all gone —
        # not merely hidden, because a control that is only `opacity(0)` still takes its corner and
        # still sits in the tab order.
        self.assertNotIn("overflowButton", self.MAC_SOURCE)
        self.assertNotIn('Image(systemName: "ellipsis")', self.MAC_SOURCE)
        self.assertNotIn("showsOverflow", self.MAC_SOURCE)
        self.assertNotIn("focusedOverflow", self.MAC_SOURCE)
        # No menu is built on the row at all: the only one is its `contextMenu` (which is what the
        # one `Menu {` in this text is — `contextMenu {`).
        self.assertEqual(row.count("Menu {"), 1, "only the context menu may open a menu on the row")
        self.assertIn(".contextMenu {", row)

    def test_the_row_still_carries_its_context_menu(self) -> None:
        row = self.mac_row()
        self.assertIn(".contextMenu {\n            BotRowMenu(menu: rowMenu(for: bot))", row)
        # One description of the verbs, handed the same value it always was — right-click reaches
        # every entry the ⋯ used to list, because both were always this builder.
        self.assertIn("private func rowMenu(for bot: Bot) -> BotMenu {", self.MAC_SOURCE)
        menu = read(MAC / "Sidebar" / "BotRowMenu.swift")
        for verb in ("Bot Settings", "Pin to top", "All sessions…", "Previous conversations",
                     "Hide bot", "New category…"):
            self.assertIn(verb, menu, "the context menu lost an entry the ⋯ used to offer")

    def test_the_hover_state_itself_is_kept(self) -> None:
        row = self.mac_row()
        # The fill is what says a row is live; only the ⋯ goes.
        self.assertIn("isHovered || holdsKeyboardFocus ? Tokens.controlHover", row)
        self.assertIn("(isHovered || holdsKeyboardFocus) && !isSelected ? 1 : 0", row)
        self.assertIn("wakesOnHover: isHovered", row)
        # Keyboard focus still lights the row — there is no system focus ring on it.
        self.assertIn("let holdsKeyboardFocus = focusedRow == bot.id", row)
        self.assertIn(".focused($focusedRow, equals: bot.id)", row)

    def test_the_row_keeps_its_shape_and_its_button(self) -> None:
        row = self.mac_row()
        self.assertIn("return Button {", row)
        self.assertIn(".buttonStyle(.plain)", row)
        self.assertIn(".contentShape(Rectangle())", row)
        # The height is the metrics' — the ⋯ never reserved a gutter, and nothing replaced it.
        self.assertIn(".frame(height: metrics.rowHeight)", row)
        self.assertIn(".padding(.horizontal, metrics.rowPadding)", row)
        self.assertIn(".padding(.vertical, metrics.rowPadding)", row)
        # And the unread dot has its trailing corner back to itself.
        self.assertIn("if model.hasUnread(bot.id) {\n                    UnreadBeacon(diameter: 7)\n                }",
                      row)

    def test_the_phone_keeps_what_it_has(self) -> None:
        # No hover on a phone, and no ⋯ on its rows either: the long-press menu and the two swipe
        # actions are the row's doors, so nothing is hidden behind a pointer that never comes.
        phone_row = between(self.PHONE_SOURCE,
                            "private func row(for bot: Bot) -> some View {",
                            "/// A description written on the host is the useful line")
        self.assertNotIn('Image(systemName: "ellipsis")', phone_row)
        self.assertNotIn("overflowButton", phone_row)
        self.assertNotIn(".overlay(alignment: .trailing)", phone_row)
        # The trailing edge is still the beacon's, and the menus are still the row's own.
        self.assertIn("UnreadBeacon(diameter: 8)", phone_row)
        self.assertIn(".contextMenu {", phone_row)
        self.assertEqual(phone_row.count(".swipeActions("), 2)
        self.assertIn(".accessibilityHint(\"Opens the conversation with this bot\")", phone_row)


class TheLockScreenCardHasOneLeftEdge(unittest.TestCase):
    """`HERMEY` and `Working · …` start at the same point, and the block is centred in the card."""

    SOURCE = read(LIVE_ACTIVITY)

    def card(self) -> str:
        return between(self.SOURCE,
                       "private struct HermeyTurnLockScreen: View {",
                       "    /// The snippet is read after the sentence rather than as a separate element")

    def status_line(self) -> str:
        return between(self.SOURCE,
                       "private struct HermeyTurnStatusLine: View {",
                       "    private var symbol: String {")

    def test_the_two_text_rows_share_one_leading_edge(self) -> None:
        card = self.card()
        # Nothing indents a single row: no leading padding, no tracking/kerning that could nudge the
        # brand word's first glyph off the column's edge…
        self.assertNotIn(".kerning(", card)
        self.assertNotIn(".tracking(", card)
        self.assertNotIn(".padding(.leading", card)
        # …and the status line no longer leads with its symbol, which is what pushed "Working" right.
        self.assertIn("showsSymbol: false", card)
        self.assertNotIn("HermeyTurnStatusLine(state: state, botName: botName, isStale: isStale, tone: .card)",
                         card)

    def test_the_symbol_is_gated_so_the_island_keeps_it(self) -> None:
        status = self.status_line()
        self.assertIn("var showsSymbol: Bool = true", status)
        self.assertIn("if showsSymbol {", status)
        # The expanded island passes neither flag, so its row is unchanged.
        island = between(self.SOURCE,
                         "private struct HermeyTurnExpandedCenter: View {",
                         "/// The state in words:")
        self.assertIn("leadsWithWord: false", island)
        self.assertNotIn("showsSymbol", island)

    def test_the_vertical_padding_is_symmetric(self) -> None:
        card = self.card()
        # One number, used for both sides, and no per-edge padding anywhere in the card.
        self.assertEqual(card.count(".padding(.vertical, HermeyTurnGlass.cardVertical)"), 1)
        self.assertNotIn(".padding(.top", card)
        self.assertNotIn(".padding(.bottom", card)
        # `cardVertical` itself is one value, so the two sides cannot drift apart.
        glass = between(self.SOURCE,
                        "private enum HermeyTurnGlass {",
                        "    /// The island's leading/trailing regions")
        self.assertIn("static let cardVertical: CGFloat = 8", glass)
        self.assertNotIn("cardVerticalTop", glass)

    def test_the_block_is_centred_against_the_mark_and_the_timer(self) -> None:
        card = self.card()
        # The row centres vertically, and the text column reports its own height rather than being
        # stretched to the card's — which is how a block ends up riding low inside it.
        self.assertIn("HStack(alignment: .center, spacing: 10)", card)
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", card)
        self.assertIn("Spacer(minLength: 8)", card)
        self.assertLess(card.index("HermeyTurnMark(phase: state.phase, size: 22)"),
                        card.index("HermeyTurnElapsedLabel(state: state, tone: .card)"))

    def test_every_phase_and_the_stale_card_are_aligned_the_same_way(self) -> None:
        card = self.card()
        # Nothing in the card branches on the phase: the alignment is the layout's, not a per-state
        # patch, so working / needs you / done and the stale card all draw the same two rows.
        self.assertNotIn("switch state.phase", card)
        self.assertNotIn("if state.phase", card)
        self.assertNotIn("state.phase ==", card)
        # The three phases and the stale sentence still exist — in the one place they always did.
        symbol = between(self.SOURCE,
                         "    private var symbol: String {",
                         "    /// The word, then the step")
        for phase in (".working", ".needsYou", ".done"):
            self.assertIn(f"case {phase}:", symbol)
        self.assertIn('if isStale { return "Still waiting on \\(botName)" }', self.SOURCE)

    def test_one_line_per_row_with_tail_truncation(self) -> None:
        card = self.card()
        self.assertEqual(card.count(".lineLimit(1)"), 2)   # the brand word and the bot's name
        self.assertEqual(card.count(".truncationMode(.tail)"), 2)
        self.assertIn(".truncationMode(.tail)", self.status_line())


class AHoveredRowWakesItsFace(unittest.TestCase):
    """Pointer on the row: the face greets, then floats — one row, never a busy performance."""

    WAKE = read(UI / "BotAvatarWake.swift")
    AVATAR = read(UI / "BotAvatarView.swift")
    SIDEBAR = read(SIDEBAR)
    PHONE = read(PHONE_LIST)

    def awake_rule(self) -> str:
        return between(self.AVATAR, "private var isAwake: Bool {", "    /// The generated avatar")

    def row(self) -> str:
        return between(self.SIDEBAR,
                       "private func row(for bot: Bot, isHovered: Bool = false,",
                       "/// A hidden bot is not gone")

    def test_the_row_hands_its_hover_to_the_avatar(self) -> None:
        row = self.row()
        self.assertIn("wakesOnHover: isHovered", row)
        # The resting rule is the one it always was: only a *busy* row animates at rest, and the
        # face is drawn at the row's fixed size, so nothing about the row moves as it greets.
        self.assertIn("animates: store.activity(for: bot.id) != .idle", row)
        self.assertIn("size: metrics.avatar", row)
        self.assertEqual(row.count("wakesOnHover:"), 1)

    def test_the_rest_rule_is_relaxed_only_while_hovered(self) -> None:
        rule = self.awake_rule()
        self.assertIn("wakesOnHover: wakesOnHover", rule)
        # Deliberately not part of it: the resting floor and flags are lifted by the hover itself,
        # never edited, so a row that is not hovered behaves exactly as it does today.
        for resting in ("animates", "animatingFrom", "size:", "minimumSize"):
            self.assertNotIn(resting, rule, f"the wake rule consults {resting!r}")
        # Every calm case still says no.
        self.assertIn("reduceMotion: reduceMotion || systemReduceMotion", rule)
        self.assertIn("appAllowsMotion: appAllowsMotion", rule)
        self.assertIn("isActiveScene: scenePhase == .active", rule)
        # And a face with `animates: false` still holds its rest pose: `moves` is unchanged.
        shape = between(self.AVATAR, "private var shapeBody: some View {", "// Built once per body")
        self.assertIn("animates: animates && appAllowsMotion", shape)
        self.assertIn("minimumSize: animatingFrom", shape)

    def test_reduce_motion_suppresses_the_hop(self) -> None:
        allows = between(self.WAKE, "public static func allows(", "/// The frame at an instant.")
        self.assertIn("wakesOnHover && !reduceMotion && appAllowsMotion && isActiveScene", allows)
        # The greeting is only ever sampled through `isAwake`, which is that function.
        for branch in (between(self.AVATAR, "private var shapeBody: some View {",
                               "// Built once per body"),
                       between(self.AVATAR, "private func drawnBody(", "/// The face this view draws:")):
            self.assertIn("let awake = isAwake", branch)

    def test_the_wake_never_borrows_the_busy_performance(self) -> None:
        wake = without_comments(self.WAKE)
        self.assertNotIn("performedFrame", wake)
        self.assertNotIn("BotAvatarPerformance", wake)
        self.assertNotIn(".working", wake)
        # The hello settles into the reference's own idle float, which is reused, not re-authored.
        self.assertIn("BotAvatarMotion.bodyPose(activity: .idle, at: time, traits: traits)", wake)
        self.assertIn("BotAvatarMotion.eyePose(traits: traits, at: time)", wake)
        self.assertIn("return settled", wake)

    def test_the_hop_is_small_and_never_lays_out_the_row(self) -> None:
        # Fractions of the face's own side, like every other pose here — so they move the drawing,
        # not the layout: a translate/rotate/scale cannot change the row's height or hit target.
        self.assertIn("translateY: -0.10 * arc", self.WAKE)
        self.assertIn("rotate: gaze * 3.0 * arc", self.WAKE)
        # The eyes lead the hop and then come home.
        self.assertIn("offsetX: gaze * 0.20 * min(1, t * 4)", self.WAKE)
        self.assertIn("guard elapsed < greetingDuration else { return settled }", self.WAKE)
        # Applied as transforms over a fixed frame, exactly as the shape face already does it.
        self.assertIn(".frame(width: size, height: size)", self.AVATAR)

    def test_the_cost_is_one_row_at_the_busy_beat(self) -> None:
        self.assertIn("public static let frameInterval: Double = BotAvatarMotion.frameInterval", self.WAKE)
        # The woken timeline is the only place the beat is raised, and never past 30 Hz.
        timeline = self.AVATAR.count("minimumInterval: awake ? BotAvatarWake.frameInterval")
        self.assertEqual(timeline, 2, "both branches must use the woken beat")
        self.assertIn("paused: !moves && !awake", self.AVATAR)
        self.assertNotIn("1.0 / 60", self.AVATAR)
        self.assertNotIn("1.0 / 60", self.WAKE)
        # Nothing else in the Mac app wakes a face: one hovered row, one animating face.
        self.assertNotIn("wakesOnHover: true", self.SIDEBAR)

    def test_the_phone_has_no_pointer_so_it_passes_nothing(self) -> None:
        self.assertNotIn("wakesOnHover", self.PHONE)


if __name__ == "__main__":
    unittest.main()