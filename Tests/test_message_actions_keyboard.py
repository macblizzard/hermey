"""No `⋯` under a message — the right-click menu is the row's menu, and ⌘⇧M is the keyboard's door.

Asked for 2026-11-26: *"please remove the 3dot button below each message, since we already have
right click menu, we dont need the 3dot button"*.

What is pinned here, and why each half matters:

* **The glyph is gone, not hidden.** A control at `opacity(0)` still reserves its corner in the
  action line and still sits in the tab order, so the test refuses the naming as well as the
  drawing: no `actionGlyph("menu"`, no `"ellipsis"` in the Mac row, no `menuGlyphFocused`.
* **The door it was is not gone with it.** The `⋯` was the one tab stop on the row and the only
  way to the menu without a pointer. Its replacement is the Conversation menu's *Message Actions…*
  (⌘⇧M), which raises the same `NSMenu` for the row the keyboard is on — so no `MessageMenuItem`
  (Select Text, Read Aloud, Add Reaction, Share, Copy Message, Edit and resend, Delete) lost its
  keyboard route. The transcript must know which row that is (`focusedRow`), every row must be a
  tab stop, and the command must actually post and the transcript actually answer.
* **The pointer's doors are untouched.** The AppKit overlay still takes right-click and ctrl-click
  from the window's event stream (`hitTest` nil, `.rightMouseDown`, `.control`), and the phone's
  long press still raises its action card — the phone never had a `⋯`, which is why only the Mac
  loses one.
* **Nothing else in the row moved.** The clamp ("Show full message"), the emoji reactions, the
  hover state, the time and the row's own overlay are all asserted still present.
* **Group rooms get the same rule.** Their transcript rows have no `⋯` either; the two `Menu`s in
  `GroupChatViews` are the room header's verbs (find, refresh, delete the chat), which are not a
  message's actions and have no right-click equivalent.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"
PHONE = ROOT / "Apps" / "HermesMobile"
UI = ROOT / "Sources" / "HermeyUI"

ROW = MAC / "Conversation" / "TranscriptRowView.swift"
MENU = MAC / "Conversation" / "MessageContextMenu.swift"
SCROLL = MAC / "Conversation" / "TranscriptScroll.swift"
APP = MAC / "HermesMacApp.swift"
PHONE_TRANSCRIPT = PHONE / "Views" / "MobileTranscript.swift"
MENU_ITEMS = UI / "MessageMenuRow.swift"
GROUP = UI / "GroupChatViews.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def without_comments(text: str) -> str:
    """The source with its `//` lines stripped: a guard about code must not read prose."""
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def between(text: str, start: str, end: str) -> str:
    assert start in text, f"missing start marker: {start!r}"
    body = text.split(start, 1)[1]
    assert end in body, f"missing end marker: {end!r}"
    return body.split(end, 1)[0]


class TheThreeDotIsGoneFromTheMacRow(unittest.TestCase):
    """The glyph is not built anywhere in a row, and the plumbing that only it used is gone too."""

    SOURCE = read(ROW)
    CODE = without_comments(read(ROW))

    def test_no_ellipsis_glyph_is_built(self) -> None:
        self.assertNotIn('Image(systemName: "ellipsis")', self.CODE)
        self.assertNotIn('systemImage: "ellipsis"', self.CODE)
        # Named, because a control renamed to keep drawing would pass a grep for one spelling only.
        self.assertNotIn("actionGlyph(\"menu\"", self.CODE)
        self.assertNotIn("All message actions", self.CODE)

    def test_the_focus_state_that_kept_it_alive_is_gone(self) -> None:
        # `opacity(0)` would still take the corner and the tab stop; the whole naming has to go.
        self.assertNotIn("menuGlyphFocused", self.CODE)
        self.assertNotIn("keyboardStop", self.CODE)

    def test_the_remaining_glyphs_are_the_pointer_shortcuts_and_no_tab_stops(self) -> None:
        # React, speak, copy and reply stay: they are verbs a reader presses with the pointer while
        # reading, and none of them is a tab stop (each is in the menu the keyboard opens).
        for glyph in ('actionGlyph("react"', 'actionGlyph("speak"', 'actionGlyph("copy"',
                      'actionGlyph("reply"'):
            self.assertEqual(self.CODE.count(glyph), 1, f"{glyph} must keep its one use")
        action_line = without_comments(between(self.SOURCE,
                                               "private var messageActions: some View {",
                                               "/// One glyph of the action line."))
        self.assertNotIn("ellipsis", action_line)
        self.assertIn(".focusable(false)", self.CODE)

    def test_the_menu_itself_is_still_the_row_s_own(self) -> None:
        # The overlay is the right-click menu, handed the row's own rows and its own anchor.
        self.assertIn(".overlay { MessageContextMenu(items: menuItems, anchor: menuAnchor) }",
                      self.CODE)
        # And the anchor is registered so the menu bar can name this row (see the next class).
        self.assertIn("MessageMenuDirectory.shared.register(menuAnchor, for: entry.id)", self.CODE)
        self.assertIn("MessageMenuDirectory.shared.unregister(entry.id)", self.CODE)

    def test_nothing_else_in_the_row_moved(self) -> None:
        # The clamp's own control, the reactions, the hover, the time and the tint: all still here.
        self.assertIn("ClampedBody(", self.CODE)
        self.assertIn("messageTime", self.CODE)
        self.assertIn("messageActions", self.CODE)
        self.assertIn("reactionPicker", self.CODE)
        self.assertIn("QuickReactionRow(", self.CODE)
        self.assertIn("showingReactions", self.CODE)
        self.assertIn("isHovered", self.CODE)
        self.assertIn("userBubbleTint", self.CODE)
        self.assertIn("TranscriptClamp.Body(", self.CODE)


class TheKeyboardKeepsEveryVerb(unittest.TestCase):
    """⌘⇧M raises the focused row's menu, so nothing the `⋯` offered is keyboard-unreachable."""

    APP = read(APP)
    SCROLL_SOURCE = read(SCROLL)
    MENU = read(MENU)
    ITEMS = read(MENU_ITEMS)
    CODE = without_comments(read(SCROLL))

    def test_the_command_exists_with_its_shortcut(self) -> None:
        app = without_comments(self.APP)
        self.assertIn('Button("Message Actions…")', app)
        self.assertIn("MessageMenuDirectory.requestActions()", app)
        self.assertIn('.keyboardShortcut("m", modifiers: [.command, .shift])', app)
        # In the Conversation menu, next to the other keys a reader would look for.
        menu = between(app, 'CommandMenu("Conversation")', "Menu(\"Switch Bot\")")
        self.assertIn('Button("Message Actions…")', menu)
        self.assertIn('Button("Find in Conversation…")', menu)
        # Never `.disabled`: a disabled menu item swallows its key equivalent for the rest of the run.
        self.assertNotIn('.keyboardShortcut("m", modifiers: [.command, .shift])\n            .disabled',
                         menu)

    def test_the_command_and_the_transcript_agree_on_one_notification(self) -> None:
        self.assertIn("Notification.Name(\"hermey.message.actions\")", self.MENU)
        self.assertIn("static let messageActionsRequested = Notification.Name(", self.MENU)
        self.assertIn("NotificationCenter.default.post(name: .messageActionsRequested, object: nil)",
                      self.MENU)
        self.assertIn(
            ".onReceive(NotificationCenter.default.publisher(for: .messageActionsRequested))",
            self.CODE)
        self.assertIn("raiseMessageActions()", self.CODE)

    def test_it_targets_the_focused_row_and_falls_back_to_the_newest(self) -> None:
        # A row is a tab stop, and its focus is what names it.
        self.assertIn("@FocusState private var focusedRow: String?", self.CODE)
        self.assertIn(".focused($focusedRow, equals: entry.id)", self.CODE)
        self.assertIn(".focusable()", self.CODE)
        # The command acts on that row, or on the newest message when no row holds focus.
        self.assertIn(
            "MessageMenuDirectory.shared.present(for: focusedRow ?? model.visibleTranscript.last?.id)",
            self.CODE)
        # Focus is drawn, because the app turns the system ring off: a keyboard stop you cannot see
        # is a keyboard stop nobody finds.
        self.assertIn(".hermeyFocusQuiet()", self.CODE)
        self.assertIn("focusedRow == entry.id ? Tokens.borderStrong : .clear", self.CODE)
        self.assertIn(".allowsHitTesting(false)", self.CODE)

    def test_the_directory_presents_the_same_app_kit_menu(self) -> None:
        menu = without_comments(self.MENU)
        self.assertIn("final class MessageMenuDirectory", menu)
        self.assertIn("func register(_ anchor: MessageMenuAnchor, for row: String)", menu)
        self.assertIn("func present(for row: String?) -> Bool", menu)
        self.assertIn("host.presentBelow()", menu)

    def test_every_verb_the_menu_offers_is_still_a_keyboard_row(self) -> None:
        # The verbs are built from the shared `MessageMenuItem` constructors, and the Mac's menu is
        # the one ⌘⇧M opens — so this list is exactly what the keyboard can reach.
        for verb in (".selectText {", ".readAloud(isSpeaking:", ".addReaction {", ".share(",
                     ".copyMessage {", ".editAndResend {", ".deleteMessage {"):
            self.assertIn(verb, read(ROW), f"the row stopped offering {verb}")
        for constructor in ("selectText", "readAloud", "addReaction", "copyMessage", "reply",
                            "copyCodeBlock", "editAndResend", "deleteMessage"):
            self.assertIn(f"static func {constructor}(", self.ITEMS)


class ThePointerAndThePhoneStillReachTheirMenus(unittest.TestCase):
    """Right-click on the Mac and long press on the phone are the doors that remain."""

    MENU = read(MENU)
    PHONE = read(PHONE_TRANSCRIPT)

    def test_the_app_kit_menu_takes_the_whole_row_and_stays_out_of_the_way(self) -> None:
        menu = without_comments(self.MENU)
        # Never a hit target: selection, links, thumbnails and the hover glyphs keep their presses.
        self.assertIn("override func hitTest(_ point: NSPoint) -> NSView? { nil }", menu)
        # Right-click and ctrl-click, from the window's own event stream.
        self.assertIn("NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown])",
                      menu)
        self.assertIn("case .rightMouseDown:", menu)
        self.assertIn("case .leftMouseDown where event.modifierFlags.contains(.control):", menu)
        # A click inside the row's bounds is the row's; one outside is nobody's.
        self.assertIn("return bounds.contains(convert(event.locationInWindow, from: nil))", menu)
        # And the menu is built from the shared rows, with a glyph on every one.
        self.assertIn("NSMenuItem(title: item.title,", menu)
        self.assertIn("nsItem.image = Self.glyph(item.symbol, description: item.title)", menu)

    def test_the_phone_keeps_long_press_and_carries_every_verb(self) -> None:
        phone = without_comments(self.PHONE)
        # The phone never had a `⋯` on a message: long press on the bubble, the card underneath.
        self.assertEqual(phone.count(".onLongPressGesture(minimumDuration: 0.35) { raiseActions() }"), 2)
        for role in ("userBubble", "assistant"):
            self.assertIn(role, phone)
        self.assertIn("private func raiseActions() {", phone)
        self.assertIn("showingActions = true", phone)
        # Tool and system rows keep their menu.
        self.assertIn("content.contextMenu { menu }", phone)
        # Every verb of the card, including the ones a Mac menu spells the same way.
        for verb in ('actionRow("Copy"', 'actionRow("Reply"', 'actionRow("Select"',
                     'actionRow("Edit and resend"', 'actionRow("Delete"'):
            self.assertIn(verb, phone, f"the long-press card lost {verb}")
        self.assertIn("QuickReactionRow(selected: reaction)", phone)
        # Nothing was added to the phone's rows to replace a button it never had.
        self.assertNotIn('Image(systemName: "ellipsis")', phone)

    def test_the_group_room_rows_have_no_overflow_button_either(self) -> None:
        group = without_comments(read(GROUP))
        rows = group
        # The two `Menu {`s that remain are the room header's verbs, and they say so.
        self.assertIn('Label("Search", systemImage: "magnifyingglass")', rows)
        self.assertIn('Label("Refresh", systemImage: "arrow.clockwise")', rows)
        self.assertIn('Button("Delete group chat…", role: .destructive)', rows)
        # No transcript row in the room draws a `⋯` button of its own.
        for line in rows.splitlines():
            if "ellipsis" in line:
                self.assertIn("Image(systemName: \"ellipsis\")", line)
        self.assertNotIn("overflowButton", rows)
        self.assertNotIn("messageActions", rows)


if __name__ == "__main__":
    unittest.main()
