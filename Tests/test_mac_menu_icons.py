"""The Mac's message menu, drawn by AppKit, and the rules that keep it that way.

The owner asked twice for icons in a message's right-click menu. `MessageMenuRow` has built every
row with a `Label(title, systemImage:)` since 2026-11-24, and the phone shows them; the Mac's
`contextMenu` did not. What can be proved from the source is what SwiftUI's macOS menu does with the
rows: it builds its items from the button's *title*. There is no `.labelStyle`, no tint and no
`NSMenu` anywhere in the tree a style could reach into — the menu is made after our view code has
finished. So the Mac builds its own `NSMenu`, where `NSMenuItem.image` is the documented glyph, and
these tests hold the two halves together:

* one description of the rows (`MessageMenuItem`), rendered as `MessageMenuRow` on the phone and as
  `NSMenuItem`s on the Mac — a row still cannot be built without a symbol;
* the Mac's rows are that description and nothing else: no Mac file spells a verb title;
* every `NSMenuItem` is given its image from the row's symbol, in the one place items are made;
* the right-click reaches AppKit from the window's event stream, and the keyboard reaches the same
  menu through the row's `⋯`;
* the phone is untouched and still has exactly the rows it had.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
MAC = ROOT / "Apps" / "HermesMac"
PHONE = ROOT / "Apps" / "HermesMobile"

SPEC = UI / "MessageMenuRow.swift"
PRESENTER = MAC / "Conversation" / "MessageContextMenu.swift"
MAC_ROW = MAC / "Conversation" / "TranscriptRowView.swift"
MOBILE = PHONE / "Views" / "MobileTranscript.swift"
ROOMS = UI / "GroupChatViews.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def between(text: str, start: str, end: str) -> str:
    """The source between two markers, exclusive of `end`."""
    assert start in text, f"missing start marker: {start!r}"
    body = text.split(start, 1)[1]
    assert end in body, f"missing end marker: {end!r}"
    return body.split(end, 1)[0]


def call_arguments(text: str, marker: str) -> list[str]:
    """The argument text of every `marker(...)` call, parentheses balanced."""
    found: list[str] = []
    for match in re.finditer(re.escape(marker) + r"\(", text):
        depth = 0
        start = match.end()
        for index in range(match.end() - 1, len(text)):
            char = text[index]
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    found.append(text[start:index])
                    break
    return found


class TheMacMenuIsAnNSMenu(unittest.TestCase):
    """A real `NSMenu` with `NSMenuItem.image`, not a `Label` inside a SwiftUI `contextMenu`."""

    PRESENTER = read(PRESENTER)
    ROW = read(MAC_ROW)

    def test_the_mac_row_no_longer_asks_swiftui_for_a_context_menu(self) -> None:
        # The menu SwiftUI builds is the menu that dropped the images; it is not used at all now.
        self.assertNotIn(".contextMenu {", self.ROW)
        self.assertNotIn("content.contextMenu", self.ROW)
        self.assertIn(".overlay { MessageContextMenu(items: menuItems, anchor: menuAnchor) }",
                      self.ROW)

    def test_the_overlay_never_takes_a_press(self) -> None:
        # Selection, links, thumbnails and the hover glyphs underneath keep every press; the menu
        # is raised from the window's event stream instead.
        self.assertIn("override func hitTest(_ point: NSPoint) -> NSView? { nil }", self.PRESENTER)

    def test_the_right_click_reaches_appkit_through_the_window_stream(self) -> None:
        self.assertIn("NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown])",
                      self.PRESENTER)
        # Consumed, so a second — iconless — menu cannot appear behind ours.
        monitor = between(self.PRESENTER, "guard let self, self.isMenuClick",
                          "private func isMenuClick")
        self.assertIn("return nil", monitor)
        self.assertIn("menu.popUp(positioning: nil, at: point, in: self)", self.PRESENTER)
        # Control-click, which macOS may deliver either way.
        self.assertIn("case .leftMouseDown where event.modifierFlags.contains(.control):",
                      self.PRESENTER)

    def test_every_item_is_an_nsmenuitem_carrying_an_image(self) -> None:
        # One place makes items, and the image is set there, from the row's symbol.
        self.assertEqual(self.PRESENTER.count("NSMenuItem(title:"), 1)
        factory = between(self.PRESENTER, "private func makeItem(", "\n    }")
        self.assertIn("NSMenuItem(title: item.title", factory)
        self.assertIn("nsItem.image = Self.glyph(item.symbol, description: item.title)", factory)
        self.assertLess(factory.index("NSMenuItem(title:"), factory.index("nsItem.image ="))
        # The glyph comes from the row's symbol, at menu size, and is a template so the menu's own
        # appearance draws it.
        glyph = between(self.PRESENTER, "private static func glyph(", "return image")
        self.assertIn("NSImage(systemSymbolName: symbol,", glyph)
        self.assertIn("accessibilityDescription: description)", glyph)
        self.assertIn("image.size = NSSize(width: 16, height: 16)", glyph)
        self.assertIn("image.isTemplate = false", glyph,
                      "a template glyph is re-tinted by the menu and can vanish into it")

    def test_no_item_can_be_built_without_an_image(self) -> None:
        # A literal title in an `NSMenuItem` would be a second, hand-made row — and the shape that
        # let a row ship without a glyph. Titles come from the spec, images from their symbols.
        for path in MAC.rglob("*.swift"):
            source = read(path)
            if "NSMenuItem(" not in source:
                continue
            self.assertEqual(source.count("NSMenuItem(title:"), source.count("NSMenuItem("),
                             f"{path} makes an NSMenuItem without a title/image pair")
            self.assertNotIn('NSMenuItem(title: "', source,
                             f"{path} spells a menu row's title itself")

    def test_the_share_row_uses_the_system_sharing_picker(self) -> None:
        self.assertIn("NSSharingServicePicker(items: [text])", self.PRESENTER)
        self.assertIn("case .share(let text):", read(PRESENTER))


class TheRowsComeFromTheSharedSpec(unittest.TestCase):
    """One description of the rows, shared by the phone's `MessageMenuRow` and the Mac's `NSMenu`."""

    SPEC = read(SPEC)
    ROW = read(MAC_ROW)

    def menu_rows(self) -> str:
        return between(self.ROW, "private var menuItems: [MessageMenuItem] {",
                       "@ViewBuilder private var content: some View {")

    def test_a_row_cannot_be_built_without_a_symbol(self) -> None:
        # No default on `symbol:`, on either the spec's generic constructor or the row's.
        self.assertIn("public static func action(_ title: String, symbol: String,", self.SPEC)
        self.assertNotIn("symbol: String =", self.SPEC)
        # The SwiftUI drawing of a row still passes the glyph to a `Label`.
        self.assertIn("Label(item.title, systemImage: item.symbol)", self.SPEC)

    def test_every_verb_the_two_menus_have_is_described_once(self) -> None:
        for verb, symbol in (('"Select Text"', "text.cursor"),
                             ('"Add Reaction…"', "face.smiling"),
                             ('"Copy Message"', "doc.on.doc"),
                             ('"Share"', "square.and.arrow.up"),
                             ('"Reply"', "arrowshape.turn.up.left"),
                             ('"Copy code block"', "chevron.left.forwardslash.chevron.right")):
            self.assertIn(verb, self.SPEC, f"the spec must describe {verb}")
            self.assertIn(f'"{symbol}"', self.SPEC, f"{verb} must carry {symbol}")

    def test_the_mac_spells_no_verb_of_its_own(self) -> None:
        rows = self.menu_rows()
        for title in ("Select Text", "Read Aloud", "Stop Reading", "Add Reaction",
                      "Copy Message", "Share", "Reply", "Copy code block"):
            self.assertNotIn(f'"{title}', rows, f"the Mac must not spell “{title}” itself")
        # …and it reaches the rows by name, through the shared constructors.
        for factory in (".selectText {", ".readAloud(isSpeaking:", ".addReaction {",
                        ".share(entry.text)", ".copyMessage {"):
            self.assertIn(factory, rows)

    def test_the_mac_keeps_its_rows_their_order_and_their_conditions(self) -> None:
        rows = self.menu_rows()
        order = [".selectText {", ".readAloud(isSpeaking:", ".addReaction {",
                 ".share(entry.text)", ".copyMessage {"]
        positions = [rows.index(row) for row in order]
        self.assertEqual(positions, sorted(positions), "the rows' order is part of the menu")
        # The speaker's row swaps title *and* glyph with the turn; the reaction row exists only
        # when the message can carry one — and it still opens the popover rather than reacting.
        self.assertIn('isSpeaking ? "Stop Reading" : "Read Aloud"', self.SPEC)
        self.assertIn('symbol: isSpeaking ? "speaker.slash" : "speaker.wave.2"', self.SPEC)
        self.assertIn("if reactionMessage != nil {", rows)
        self.assertLess(rows.index("if reactionMessage != nil {"), rows.index(".addReaction {"))
        self.assertIn(".addReaction { showingReactions = true }", rows)
        # Select Text still goes to the transcript's sheet, through the row's own callback.
        self.assertIn(".selectText { onSelectText(entry.text) }", rows)
        # The three role-gated rows stay gated, and Share/Copy stay on every role.
        self.assertIn("if entry.role == .user || entry.role == .assistant {", rows)
        self.assertLess(rows.index("if entry.role == .user || entry.role == .assistant {"),
                        rows.index(".share(entry.text)"))
        self.assertIn("setString(entry.text, forType: .string)", rows)

    def test_the_row_type_still_draws_the_phone_menu(self) -> None:
        self.assertIn("public struct MessageMenuRow: View", self.SPEC)
        self.assertIn("public init(_ item: MessageMenuItem)", self.SPEC)
        self.assertIn("ShareLink(item: text)", self.SPEC)


class ThePhoneStillHasExactlyItsOwnRows(unittest.TestCase):
    """`Apps/HermesMobile` is not part of this change; its menu must be byte-for-byte its own."""

    MOBILE = read(MOBILE)

    def menu(self) -> str:
        return between(self.MOBILE, "private var menu: some View {", "// MARK: Action card")

    def test_it_still_draws_the_shared_row_type(self) -> None:
        menu = self.menu()
        self.assertIn("MessageMenuRow.action(", menu)
        self.assertIn("MessageMenuRow.share(entry.text)", menu)
        self.assertNotIn("MessageMenuItem(", menu)

    def test_it_has_exactly_the_rows_it_had(self) -> None:
        menu = self.menu()
        verbs = call_arguments(menu, "MessageMenuRow.action")
        rows = []
        for verb in verbs:
            title = re.search(r'^\s*"([^"]+)"', verb)
            symbol = re.search(r'symbol: "([^"]+)"', verb)
            self.assertIsNotNone(title, f"a row without a title: {verb!r}")
            self.assertIsNotNone(symbol, f"a row without a glyph: {verb!r}")
            rows.append((title.group(1), symbol.group(1)))
        self.assertEqual(rows,
                         [("Select Text", "text.cursor"),
                          ("Read Aloud", "speaker.wave.2"),
                          ("Reply", "arrowshape.turn.up.left"),
                          ("Copy message", "doc.on.doc"),
                          ("Copy code block", "chevron.left.forwardslash.chevron.right")])
        # Share sits between Reply and Copy message, and the code-block row is last and conditional.
        self.assertLess(menu.index('MessageMenuRow.action("Reply"'),
                        menu.index("MessageMenuRow.share(entry.text)"))
        self.assertLess(menu.index("MessageMenuRow.share(entry.text)"),
                        menu.index('MessageMenuRow.action("Copy message"'))
        self.assertIn("if let code = Self.firstCodeBlock(in: entry.text) {", menu)
        self.assertLess(menu.index("if let code = Self.firstCodeBlock(in: entry.text) {"),
                        menu.index('MessageMenuRow.action("Copy code block"'))

    def test_the_room_transcript_is_untouched_too(self) -> None:
        room = between(read(ROOMS), ".contextMenu {", "// Under every message")
        self.assertIn("MessageMenuRow.action(\"Copy Message\"", room)
        self.assertIn("MessageMenuRow.share(message.text)", room)


class TheKeyboardCanReachTheMenu(unittest.TestCase):
    """A right-click is not the only door: *Message Actions…* (⌘⇧M) raises the same `NSMenu`.

    The row's `⋯` was that door until 2026-11-26, when the owner asked for it to go: the right-click
    menu *is* the row's menu. The keyboard's door is the menu bar's command now, and it reaches the
    very same AppKit menu — the row registers its anchor by message id, and the command raises the
    menu of the row the keyboard is on. So the two halves this class has always held together are
    unchanged: the keyboard gets the whole menu, and both doors open one menu.
    """

    ROW = read(MAC_ROW)
    PRESENTER = read(PRESENTER)
    SCROLL = read(MAC / "Conversation" / "TranscriptScroll.swift")
    APP = read(MAC / "HermesMacApp.swift")

    def test_the_command_replaces_the_glyph(self) -> None:
        actions = between(self.ROW, "private var messageActions: some View {",
                          "private func actionGlyph(")
        # No glyph, and nothing left of the focus state that kept it on screen.
        self.assertNotIn('systemImage: "ellipsis"', actions)
        self.assertNotIn("menuAnchor.present()", actions)
        self.assertNotIn("menuGlyphFocused", self.ROW)
        self.assertNotIn("keyboardStop", self.ROW)
        # The keyboard's door, in the menu bar, with the key the row's own comment promised.
        self.assertIn('Button("Message Actions…")', self.APP)
        # The key lives in the registry (Settings → Shortcuts edits it), not in the menu source.
        self.assertIn('.hermeyShortcut("message.actions", using: shortcuts)', self.APP)
        registry = read(ROOT / "Sources" / "HermesKit" / "ShortcutRegistry.swift")
        self.assertIn('id: "message.actions"', registry)
        self.assertIn("MessageMenuDirectory.requestActions()", self.APP)
        # And the transcript answers it for the row the keyboard is on.
        self.assertIn("NotificationCenter.default.publisher(for: .messageActionsRequested)",
                      self.SCROLL)
        self.assertIn("MessageMenuDirectory.shared.present(for:", self.SCROLL)
        self.assertIn("@FocusState private var focusedRow: String?", self.SCROLL)

    def test_it_raises_the_same_menu_below_the_row(self) -> None:
        self.assertIn("func presentBelow()", self.PRESENTER)
        self.assertIn("host.presentBelow()", self.PRESENTER)
        self.assertIn("func present(for row: String?) -> Bool", self.PRESENTER)
        # The anchor is handed the very view that owns the rows, so both doors show one menu.
        self.assertIn("anchor?.host = view", self.PRESENTER)
        self.assertEqual(self.PRESENTER.count("MessageMenuRouter(items: items, host: self"), 1)

    def test_the_pointer_path_and_the_keyboard_path_share_one_builder(self) -> None:
        # `present(at:)` (right-click) and `presentBelow()` (⌘⇧M) both funnel into `show(point:)`,
        # which is the only caller of the router — so the two menus cannot hold different rows.
        show = between(self.PRESENTER, "private func show(point: NSPoint) {", "\n    }")
        self.assertIn("MessageMenuRouter(items: items", show)
        for caller in ("private func present(at point: NSPoint) {", "func presentBelow() {"):
            body = between(self.PRESENTER, caller, "\n    }")
            self.assertIn("show(point:", body)


if __name__ == "__main__":
    unittest.main()

class TheGlyphsAreVisible(unittest.TestCase):
    """A menu icon nobody can see is the fault this file exists to prevent, twice over.

    The first Mac menu had no images at all (SwiftUI dropped them). The second had them as template
    images, and a screenshot showed every glyph tinted into the dark menu — reported as "no icons".
    """

    SRC = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MessageContextMenu.swift").read_text(encoding="utf-8")

    def test_the_glyph_is_coloured_for_the_dark_menu(self):
        self.assertIn("paletteColors", self.SRC,
                      "the symbol has no explicit ink: a template is re-tinted by whoever draws it")
        self.assertIn("isTemplate = false", self.SRC,
                      "the glyph is still a template, so its colour is out of our hands")

    def test_the_menu_draws_in_the_apps_own_appearance(self):
        self.assertIn("menu.appearance = NSApp.effectiveAppearance", self.SRC,
                      "menu and glyph ink could disagree again")
