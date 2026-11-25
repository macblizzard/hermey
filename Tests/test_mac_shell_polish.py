"""The shell's small shapes: a floating pill, an icon row, a faded list, a quiet composer.

Each guard here is one decision that a later edit could quietly undo — a reserved strip creeping
back above the transcript, a search box growing back into the row, a hint line returning under the
field — so each is pinned by its shape rather than by a pixel count.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"

PANE = (MAC / "Conversation" / "ConversationPane.swift").read_text(encoding="utf-8")
HEADER = (MAC / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")
TRANSCRIPT = (MAC / "Conversation" / "TranscriptScroll.swift").read_text(encoding="utf-8")
SIDEBAR = (MAC / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
COMPOSER_BAR = (MAC / "Conversation" / "MacComposerBar.swift").read_text(encoding="utf-8")
COMPOSER = (ROOT / "Sources" / "HermeyUI" / "Composer.swift").read_text(encoding="utf-8")
ROOMS = (ROOT / "Sources" / "HermeyUI" / "GroupChatViews.swift").read_text(encoding="utf-8")


class ThePillFloats(unittest.TestCase):
    def test_the_transcript_reserves_nothing_above_it(self) -> None:
        # A reserved strip outside the scroll view means content can never pass behind the pill,
        # which is the whole point of the shape.
        self.assertNotIn(".padding(.top, Geometry.chatHeader)", PANE)
        self.assertIn("ConversationHeader(model: model, store: store)", PANE)

    def test_the_rows_carry_the_inset_instead(self) -> None:
        # Inside the scroll view, so the inset scrolls away and later rows pass underneath.
        self.assertIn(".padding(.top, Geometry.chatHeaderPill + 20)", TRANSCRIPT)
        self.assertIn(".padding(.top, Geometry.chatHeaderPill + 10)", TRANSCRIPT)

    def test_the_pill_sits_against_the_window_edge(self) -> None:
        # Six of air and the capsule; no extra top padding, so the pill's centre is 26 pt down and
        # level with the sidebar's first row.
        # On the traffic lights' line: the capsule plus two points, top-aligned in the pane.
        self.assertIn(".frame(width: width, height: Geometry.chatHeaderPill + 2)", HEADER)
        self.assertIn("alignment: .top", HEADER)
        self.assertNotIn(".padding(.top, 2)", HEADER)


class TheSidebarRowIsIcons(unittest.TestCase):
    def test_search_is_a_button_not_a_box(self) -> None:
        self.assertIn("private var isSearching", SIDEBAR)
        self.assertIn('HermeyIconButton("magnifyingglass"', SIDEBAR)
        # The field is its own row, above the floor bar, and the top row never grows one: opened in
        # place it took the traffic lights' line and blended into the window's chrome (reported
        # 2026-11-14). The magnifier that opens it lives on the bar below, and stays there while the
        # field is open — the bar's grouping never moves.
        header = SIDEBAR.split("private var header: some View {", 1)[1].split(
            "private var notificationsButton", 1)[0]
        bar = SIDEBAR.split("private var bottomBar: some View {", 1)[1].split(
            "// MARK: Waiting", 1)[0]
        self.assertNotIn("MacSidebarSearchField", header)
        self.assertIn("MacSidebarSearchField", SIDEBAR)
        self.assertIn('HermeyIconButton("magnifyingglass"', bar,
                      "the button that opens search stays in the bar while search is open")
        self.assertIn("sidebar.searchRow", SIDEBAR)

    def test_the_panels_toggle_lives_in_the_panel(self) -> None:
        self.assertIn('HermeyIconButton("sidebar.left"', SIDEBAR)
        self.assertIn("store.toggleSidebar()", SIDEBAR)
        # The header's copy is gone: while the panel is hidden the door is drawn on the window's
        # floor, on the panel's own bar line (`SidebarFloorToggle`), because the header copy was
        # the same control jumping to the top of the window when the panel collapsed.
        self.assertNotIn("isSidebarHidden", HEADER)
        self.assertNotIn('"sidebar.leading"', HEADER)

    def test_the_plus_replaces_the_three_dots(self) -> None:
        self.assertIn("private var addMenu", SIDEBAR)
        self.assertIn('Image(systemName: "plus")', SIDEBAR)
        # Our verbs, unchanged: add, group chat, manage, hidden, read.
        for verb in ("Add bot…", "Start group chat…", "Manage bots…",
                     "Show hidden bots", "Mark all as read"):
            self.assertIn(verb, SIDEBAR)
        # The ⋯ menu it replaced is gone from the panel's row.
        self.assertNotIn('Image(systemName: "ellipsis")', SIDEBAR)


class TheListFadesAtBothEnds(unittest.TestCase):
    def test_the_fade_is_fixed_height_and_the_bottom_end_is_mirrored(self) -> None:
        self.assertIn(".mask(listFade)", SIDEBAR)
        fade = SIDEBAR.split("private var listFade", 1)[1].split("\n    }", 1)[0]
        self.assertIn("LinearGradient(colors: [.clear, .black]", fade)
        # Fixed, not a fraction: a fraction eats a short list and hides a row of a long one.
        self.assertIn("frame(height: Self.dissolveHeight)", fade)
        self.assertIn("private static let dissolveHeight: CGFloat = 26", SIDEBAR)
        # The bottom end is not a second mask leg any more: it is the floor bar's own scrim, drawn
        # in the panel's fill over the list, so the bar's edge is the same dissolve as the top one
        # rather than a hard cut.
        scrim = SIDEBAR.split("private var bottomDissolve", 1)[1].split("\n    }", 1)[0]
        self.assertIn("LinearGradient(colors: [Tokens.sidebar, Tokens.sidebar.opacity(0)]", scrim)
        self.assertIn("startPoint: .bottom", scrim)
        self.assertIn("endPoint: .top", scrim)
        self.assertIn("bottomDissolve\n                    .frame(height: Self.dissolveHeight)", SIDEBAR)


class TheComposerIsQuiet(unittest.TestCase):
    def test_no_placeholder(self) -> None:
        self.assertIn('placeholder: "Message \\(composerTitle)"', COMPOSER_BAR,
                      "the empty field names the bot it writes to, the same words iOS shows")

    def test_the_hint_is_state_only(self) -> None:
        self.assertIn("private var hint: String?", COMPOSER_BAR)
        hint = COMPOSER_BAR.split("private var hint: String?", 1)[1].split("\n    }", 1)[0]
        self.assertIn("return nil", hint)
        # The keyboard reference is what went; the recording states are what stayed.
        self.assertNotIn("newline", hint)
        self.assertIn("voice.isRecording", hint)

    def test_attach_is_a_ring_not_a_bare_glyph(self) -> None:
        # the plus is a circle with a border and a fill that brightens on hover; an unstroked
        # glyph in a floating capsule read as punctuation rather than a button.
        self.assertIn("ComposerRingButton(glyph: \"plus\"", COMPOSER)
        self.assertIn("Circle().strokeBorder(isHovering ? Tokens.borderFocus : Tokens.borderStrong",
                      COMPOSER)
        self.assertIn(".onHover { isHovering = $0 }", COMPOSER)

    def test_the_controls_ride_the_last_line(self) -> None:
        # Controls sit at the foot of the card, on the line the caret is on, so a long message grows
        # above them instead of leaving them behind on line one.
        self.assertIn("private func rowCentred<V: View>(_ view: V) -> some View", COMPOSER)
        self.assertIn("HStack(alignment: .bottom, spacing: 8)", COMPOSER)
        # And nothing that can grow: an unbounded frame in the row made the card fill the screen.
        self.assertNotIn("maxHeight: .infinity", COMPOSER)
        self.assertNotIn("alignment: .top)", COMPOSER)

    def test_attach_is_a_plus(self) -> None:
        self.assertIn('glyph: "plus"', COMPOSER)
        self.assertNotIn('"paperclip"', COMPOSER)

    def test_no_hint_line_by_default(self) -> None:
        self.assertIn("public static let defaultHint: String? = nil", COMPOSER)


class TheGroupComposerIsQuietToo(unittest.TestCase):
    """A room's composer carries no instructions — and the direct-message one is untouched.

    The room passed `⏎ send · ⇧⏎ newline · @ to pick a bot` under the field on the Mac, and its
    placeholder said "@ a bot to pick who answers". Both were removed on 2026-11-25 ("remove hints
    like send, new line, etc. from group chat compose box"). The DM composer keeps what it had:
    `Composer.defaultHint` is still nil and the Mac's bar still passes only its voice state, so the
    two are pinned apart here rather than one assertion covering both by accident.
    """

    def composer_body(self) -> str:
        """The room's builder, from its `Composer(` call — comments above it excluded."""
        return ROOMS.split("private var composer: some View {", 1)[1].split(
            "/// The files waiting to go", 1)[0]

    def group_call(self) -> str:
        return self.composer_body().split("Composer(text: $draft,", 1)[1].split("onAttach:", 1)[0]

    def test_the_room_builds_no_hint_string(self) -> None:
        # No hint line, and none of the keyboard glyphs that carried one, anywhere in the room view.
        for gone in ("⏎", "⇧", "composerHint"):
            self.assertNotIn(gone, ROOMS, f"the group room still carries {gone!r}")
        # The call passes the name of the room and nothing else: no `hint:` argument at all, so the
        # composer's own default (nil) applies.
        self.assertNotIn("hint:", self.group_call())

    def test_the_placeholder_does_not_teach(self) -> None:
        call = self.group_call()
        self.assertIn('placeholder: "Message the group"', call)
        placeholder = call.split("isSending:", 1)[0]
        for instruction in ("@ a bot", "pick who answers", "send", "new line", "newline"):
            self.assertNotIn(instruction, placeholder,
                             f"the group placeholder still explains {instruction!r}")

    def test_the_direct_message_composer_keeps_what_it_had(self) -> None:
        # An empty bot composer names the bot it writes to — no instructions, as before.
        self.assertIn('placeholder: "Message \\(composerTitle)"', COMPOSER_BAR)
        # Its hint is state only: recording, permission, transcribing — never a keyboard reference.
        hint = COMPOSER_BAR.split("private var hint: String?", 1)[1].split("\n    }", 1)[0]
        self.assertIn("voice.isRecording", hint)
        self.assertIn("return nil", hint)
        self.assertNotIn("newline", hint)
        # And the shared default stays nil, so a caller that passes nothing gets no line.
        self.assertIn("public static let defaultHint: String? = nil", COMPOSER)


if __name__ == "__main__":
    unittest.main()


class TheMacAsksAtLaunch(unittest.TestCase):
    """A cold start checks for updates, on both shells.

    Sparkle's `SUEnableAutomaticChecks` with `SUScheduledCheckInterval: 86400` is a "once a day at
    most" policy, so a Mac restarted after a release could sit on the old build until tomorrow. The
    launch check is explicit, silent, and never blocks: Sparkle draws its own dismissible prompt.
    """

    def setUp(self) -> None:
        self.source = (MAC / "HermesMacApp.swift").read_text(encoding="utf-8")

    def test_the_app_asks_the_feed_at_every_launch(self) -> None:
        self.assertIn("updater.updater.checkForUpdatesInBackground()", self.source)
        self.assertIn("checkForUpdatesAtLaunch()", self.source)

    def test_the_launch_check_runs_after_dialling_the_host(self) -> None:
        task = self.source.split("await store.connectOnLaunchIfPaired()", 1)[1]
        self.assertIn("checkForUpdatesAtLaunch()", task.split("}", 1)[0],
                      "the feed must not delay the first connection")

    def test_nothing_installs_itself(self) -> None:
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn("SUAutomaticallyUpdate: false", project,
                      "an update may ask; it may not install behind the user")

