"""A bot's bubble is drawn in the colour its face is drawn in — and a face is either family, never both.

Reported by Mohammad, 2026-11-25, in two sentences:

> previously we had the accent color of our chat bubble to be based on the bot avatar color, now that
> have a different bot style, the chat bubble colors doesn't match that. if that cannot be done, then
> maybe better to add another option inside avatar section for default avatars ...

Both halves are one mistake seen twice: a bot's *colour* was derived at each surface from `bots.color`
alone, so a bot whose drawn avatar was green kept the blue bubble its old shape face had picked; and
the Avatar tab could only ever make a drawn face, so the fixed faces the app ships became
unreachable once a bot had one.

The contract this file pins:

* **one resolution.** `BotAvatarTint.resolve` is the only place a bot's colour is decided, it reads
  the drawn avatar's stored colour first, and the two views that used to spell the rule out no
  longer do;
* **the ink is measured, not assumed.** `BotAvatarBubble` derives its fill and border from the tint
  and picks its ink by WCAG contrast against *that fill*; the numbers below are recomputed from the
  Swift's own constants, so a change to a mix is a failing test rather than a slightly dimmer bubble;
* **the user's bubble is untouched** — 0.16 fill, 0.45 border, `textPrimary` in a conversation and
  the app accent in a room;
* **the bot's own bubbles take its colour** — a bot-to-bot message on both apps, and a bot's message
  in a room;
* **Classic faces come from the tables** (`BotAvatarPalette`, `BotAvatarShape`), are stored as the
  string the old picker wrote, and saving one clears the drawn avatar — while a preset or Random
  clears the Classic face;
* **the rakazo notice is untouched** and no new artwork was derived from it.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
APPS = ROOT / "Apps"
TESTED_AT = ROOT / "Tests"

TINT = UI / "BotAvatarTint.swift"
CLASSICS = UI / "BotAvatarClassics.swift"
PALETTE = UI / "BotAvatarPalette.swift"
SHAPES = UI / "BotAvatarShape.swift"
BOT_AVATAR_VIEW = UI / "BotAvatarView.swift"
ROOMS = UI / "GroupChatViews.swift"
EDITOR = UI / "OpenBotAvatar" / "OpenBotAvatarEditor.swift"
TOKENS = UI / "Tokens.swift"

MAC_TRANSCRIPT = APPS / "HermesMac" / "Conversation" / "TranscriptRowView.swift"
MAC_PANE = APPS / "HermesMac" / "Conversation" / "ConversationPane.swift"
MAC_SHEET = APPS / "HermesMac" / "Views" / "MacBotSettingsSheet.swift"
MAC_SERVICE = APPS / "HermesMac" / "Views" / "MacBotIconPicker.swift"
MAC_STORE = APPS / "HermesMac" / "Workspace" / "WorkspaceStore.swift"
IOS_TRANSCRIPT = APPS / "HermesMobile" / "Views" / "MobileTranscript.swift"
IOS_SCREEN = APPS / "HermesMobile" / "Views" / "ConversationScreen.swift"
IOS_SETTINGS = APPS / "HermesMobile" / "Views" / "BotModelSettingsScreen.swift"
IOS_SERVICE = APPS / "HermesMobile" / "Views" / "BotIconPicker.swift"
IOS_STORE = APPS / "HermesMobile" / "App" / "AppEnvironment.swift"
RUST_ROUTES = ROOT / "hermeyd" / "src" / "bridge_routes.rs"
NOTICES = ROOT / "THIRD-PARTY-NOTICES.md"

#: The two pages the bubble has to read on, by the hexes their palettes are built from.
MIDNIGHT_CANVAS = "#0A0A0A"
PARCHMENT_CANVAS = "#FAF9F5"

#: A body text floor with room to spare: WCAG AA asks 4.5:1 for text this size, and a bubble is read
#: at chat metrics on a phone. The measured floor over the palette is 9.3 dark / 14.7 light.
TEXT_FLOOR = 7.0
#: An edge only has to be an edge; the fill itself carries the identity.
EDGE_FLOOR = 2.0


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def prose(text: str) -> str:
    """A file's doc comments as running text, so a sentence that wraps is still one string."""
    return " ".join(text.replace("///", " ").replace("//", " ").split())


def code(text: str) -> str:
    """The text with its comments removed, so an example in a doc comment is not a literal."""
    return "\n".join(line.split("///")[0].split("//")[0] for line in text.splitlines())


def swift_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*.swift") if "/.build/" not in str(p))


# ---------------------------------------------------------------------------
# The palette and the colour maths, re-derived here rather than trusted.


def palette_hexes() -> list[str]:
    source = read(PALETTE)
    start = source.index("colors: [BotAvatarColorDef] = [")
    body = source[start:source.index("\n    ]", start)]
    return re.findall(r'hex: "(#[0-9A-F]{6})"', body)


def palette_ids() -> list[str]:
    source = read(PALETTE)
    start = source.index("colors: [BotAvatarColorDef] = [")
    body = source[start:source.index("\n    ]", start)]
    return re.findall(r'BotAvatarColorDef\(id: "([a-z]+)"', body)


def shape_kinds() -> list[str]:
    enum = read(SHAPES).split("public enum Kind: String, CaseIterable, Sendable {")[1]
    return re.findall(r"case (\w+(?:, \w+)*)", enum)[0].split(", ")


def _channels(hex_value: str) -> tuple[int, int, int]:
    digits = hex_value.lstrip("#")
    return tuple(int(digits[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def _hex(channels) -> str:
    return "#%02X%02X%02X" % tuple(int(round(c)) for c in channels)


def mix(a: str, b: str, amount: float) -> str:
    left, right = _channels(a), _channels(b)
    return _hex([left[i] + (right[i] - left[i]) * amount for i in range(3)])


def luminance(hex_value: str) -> float:
    linear = []
    for value in _channels(hex_value):
        channel = value / 255
        linear.append(channel / 12.92 if channel <= 0.03928 else ((channel + 0.055) / 1.055) ** 2.4)
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(a: str, b: str) -> float:
    high, low = sorted((luminance(a), luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def swift_constant(name: str) -> float:
    """A `static let <name>: Double = 0.72` from the bubble's own source."""
    match = re.search(re.escape(name) + r": Double = ([\d.]+)", read(TINT))
    if match is None:
        raise AssertionError(f"BotAvatarTint no longer declares {name}")
    return float(match.group(1))


def swift_ink(pole: str) -> str:
    match = re.search(re.escape(pole) + r' = "(#[0-9A-F]{6})"', read(TINT))
    if match is None:
        raise AssertionError(f"BotAvatarTint no longer declares {pole}")
    return match.group(1)


def bubble_colours(tint: str, light_page: bool) -> tuple[str, str, str]:
    """The rule `BotAvatarBubble.init` applies, with the Swift's own constants."""
    fill_mix = swift_constant("lightFillMix" if light_page else "darkFillMix")
    border_mix = swift_constant("lightBorderMix" if light_page else "darkBorderMix")
    pole = "#FFFFFF" if light_page else "#000000"
    other = "#000000" if light_page else "#FFFFFF"
    fill = mix(tint, pole, fill_mix)
    border = mix(tint, other, border_mix)
    ink = ink_for(fill)
    return fill, border, ink


def ink_for(fill: str) -> str:
    on_dark, on_light = swift_ink("inkOnDark"), swift_ink("inkOnLight")
    return on_light if contrast(fill, on_light) >= contrast(fill, on_dark) else on_dark


# ---------------------------------------------------------------------------


class TheTintIsResolvedOnce(unittest.TestCase):
    """A bot's colour is decided in one function, and every surface asks it."""

    def test_the_rule_lives_in_one_place(self) -> None:
        tint = read(TINT)
        self.assertIn("public struct BotAvatarTint", tint)
        self.assertIn("public static func resolve(botID: String", tint)
        # One declaration in the whole tree: a second copy is how the two sides drifted before.
        declarations = [p for p in swift_files(UI) + swift_files(APPS)
                        if "func resolve(botID: String" in read(p)]
        self.assertEqual([TINT], declarations)

    def test_the_three_rules_are_in_order(self) -> None:
        tint = read(TINT)
        rule = tint.split("public static func resolve(botID: String")[1].split("\n    }")[0]
        document = rule.index("if let document {")
        stored = rule.index("document.color")
        shape = rule.index("face?.identity(for: botID)")
        derived = rule.index("BotAvatarIdentity.resolve(identity: botID)")
        self.assertLess(document, stored, "the drawn avatar's colour is not read first")
        self.assertLess(stored, shape, "the shape face must fall back behind the drawn avatar")
        self.assertLess(shape, derived)
        # A stored value that is not a hex falls back to the house colour its renderer paints, not
        # to the shape face: the avatar and the bubble would otherwise disagree again.
        self.assertIn("return BotAvatarTint(hex: houseHex)", rule)
        self.assertIn("BotAvatarPalette.isHexColor(stored)", rule)

    def test_the_two_views_stopped_spelling_it_out(self) -> None:
        # The expression that caused the report, written out at each call site.
        for path in (MAC_PANE, IOS_SCREEN):
            with self.subTest(surface=path.name):
                source = read(path)
                self.assertIn("BotAvatarTint.resolve(", source)
                self.assertNotIn("?.identity(for: ", source,
                                 "a surface still derives a bot's colour itself")

    def test_the_document_is_what_the_surfaces_pass(self) -> None:
        # The half the old expression never knew about.
        self.assertIn("document: store.botAvatars[id])", read(MAC_PANE))
        self.assertIn("document: app.botAvatars[bot.id])", read(IOS_SCREEN))

    def test_a_surface_can_ask_the_library_instead(self) -> None:
        # Rooms carry `BotAvatarLibrary` in the environment, not the two maps.
        self.assertIn("avatars: BotAvatarLibrary", read(TINT))
        self.assertIn("BotAvatarTint.resolve(botID: speaker,", read(ROOMS))
        self.assertIn("avatars: avatarLibrary)", read(ROOMS))


class TheBubbleIsDerivedFromTheTint(unittest.TestCase):
    """Fill, border and ink are computed from one colour — and the ink is measured."""

    def test_the_fill_and_the_border_move_opposite_ways(self) -> None:
        tint = read(TINT)
        self.assertIn("public struct BotAvatarBubble", tint)
        # A dark page deepens the fill and lightens the border; a light page does the reverse.
        self.assertIn("lightPage ? BotAvatarBubble.lightFillMix : BotAvatarBubble.darkFillMix", tint)
        self.assertIn("lightPage ? BotAvatarBubble.lightBorderMix : BotAvatarBubble.darkBorderMix", tint)
        self.assertIn("toward: lightPage ? \"#FFFFFF\" : \"#000000\"", tint)
        self.assertIn("toward: lightPage ? \"#000000\" : \"#FFFFFF\"", tint)

    def test_the_ink_is_a_contrast_measurement_not_a_constant(self) -> None:
        tint = code(read(TINT))
        self.assertIn("public static func ink(forFill fill: String) -> String", tint)
        self.assertIn("BotAvatarPalette.contrastRatio(fill, inkOnLight)", tint)
        self.assertIn("BotAvatarPalette.contrastRatio(fill, inkOnDark)", tint)
        # …and it is not a hard-coded pair of colours picked by theme.
        self.assertNotIn("lightPage ? .white", tint)
        self.assertNotIn("Color.white, forKey", tint)

    def test_every_palette_colour_reads_on_both_pages(self) -> None:
        for hex_value in palette_hexes():
            for light_page in (False, True):
                fill, border, ink = bubble_colours(hex_value, light_page)
                page = PARCHMENT_CANVAS if light_page else MIDNIGHT_CANVAS
                with self.subTest(colour=hex_value, page=page):
                    self.assertGreaterEqual(
                        contrast(fill, ink), TEXT_FLOOR,
                        f"{hex_value} on {page}: {ink} on {fill} is under the floor")
                    self.assertEqual(ink, ink_for(fill),
                                     "the ink is not the better of the two ends of the scale")
                    self.assertGreaterEqual(contrast(border, fill), EDGE_FLOOR,
                                            "the border would not read against its own fill")

    def test_the_documented_floors_are_the_measured_ones(self) -> None:
        # The doc comment quotes two numbers; they have to be the ones the table actually gives.
        floors = {}
        for light_page, key in ((False, "midnight"), (True, "parchment")):
            floors[key] = min(contrast(bubble_colours(h, light_page)[0],
                                      bubble_colours(h, light_page)[2])
                              for h in palette_hexes())
        tint = prose(read(TINT))
        self.assertIn(f"{floors['midnight']:.1f}:1 on Midnight", tint)
        self.assertIn(f"{floors['parchment']:.1f}:1 on Parchment", tint)
        self.assertGreaterEqual(floors["midnight"], TEXT_FLOOR)
        self.assertGreaterEqual(floors["parchment"], TEXT_FLOOR)

    def test_the_page_polarity_comes_from_the_palette(self) -> None:
        # Not from `colorScheme`: a themed light page has to be recognised as light whatever the
        # window's appearance is.
        self.assertIn("public static var isLightPage: Bool { ThemeRuntime.active.isLight }",
                      read(TOKENS))
        for path in (ROOMS, MAC_TRANSCRIPT, IOS_TRANSCRIPT):
            with self.subTest(surface=path.name):
                self.assertIn("lightPage: Tokens.isLightPage", read(path))


class TheBotsOwnBubblesTakeItsColour(unittest.TestCase):
    """On both apps and in rooms, a bot's own message is painted in its own colour."""

    def test_a_rooms_bot_bubble_uses_the_tint(self) -> None:
        rooms = read(ROOMS)
        self.assertIn("botBubble(markdown(message.text), tint: botBubbleTint(for: message.speaker))",
                      rooms)
        self.assertIn("Text(message.text)", rooms)
        bubble = rooms.split("private func botBubble<Content: View>")[1]
        bubble = bubble[:bubble.index("\n    }")]
        for part in (".fill(tint.fill)", ".strokeBorder(tint.border", ".foregroundStyle(tint.ink)"):
            self.assertIn(part, bubble, f"the bot's room bubble does not use {part}")
        self.assertIn("lightPage: Tokens.isLightPage", rooms)

    def test_both_transcripts_paint_a_bot_to_bot_bubble_in_the_senders_colour(self) -> None:
        for path, sender in ((MAC_TRANSCRIPT, "sender.flatMap { faces[$0] }"),
                             (IOS_TRANSCRIPT, "sender.flatMap { app.botFaces[$0] }")):
            with self.subTest(surface=path.name):
                source = read(path)
                self.assertIn("let sender = label.senderProfile", source)
                self.assertIn(sender, source, "the sender's own face is not consulted")
                self.assertIn("let bubble = tint.bubble(lightPage: Tokens.isLightPage)", source)
                self.assertIn(".foregroundStyle(bubble.ink)", source)
                self.assertIn(".fill(bubble.fill)", source)
                self.assertIn(".strokeBorder(bubble.border", source)

    def test_the_mac_row_can_see_the_faces_it_needs(self) -> None:
        # `faces` is threaded from the transcript (which already had it) rather than looked up: a row
        # inside a lazy stack must not reach for a store.
        self.assertIn("var faces: [String: BotFaceChoice] = [:]", read(MAC_TRANSCRIPT))
        scroll = read(APPS / "HermesMac" / "Conversation" / "TranscriptScroll.swift")
        self.assertEqual(scroll.count("faces: faces,"), 2,
                         "a row is built without the face map, so its bubble cannot know the colour")
        self.assertIn("@Environment(\\.botAvatars) private var avatarLibrary", read(MAC_TRANSCRIPT))
        self.assertIn("@Environment(\\.botAvatars) private var avatarLibrary", read(ROOMS))


class TheUsersBubbleIsUnchanged(unittest.TestCase):
    """The one bubble that was never the bot's keeps today's look, exactly."""

    def test_a_conversations_own_bubble_is_the_same_two_opacities(self) -> None:
        for path, name in ((MAC_TRANSCRIPT, "userBubbleTint"), (IOS_TRANSCRIPT, "botTint")):
            with self.subTest(surface=path.name):
                source = read(path)
                self.assertIn(f"{name}.opacity(0.16)", source)
                self.assertIn(f"{name}.opacity(0.45)", source)
                self.assertIn("Tokens.textPrimary", source)

    def test_a_rooms_own_bubble_is_the_app_accent(self) -> None:
        rooms = read(ROOMS)
        mine = rooms.split("private func messageBubble(_ text: String) -> some View {")[1]
        mine = mine[:mine.index("\n    }")]
        self.assertIn(".fill(Tokens.accentSoft)", mine)
        self.assertIn(".foregroundStyle(Tokens.accentText)", mine)
        self.assertIn(".strokeBorder(Tokens.borderStrong", mine)
        # …and it takes no tint at all, so no bot's colour can reach it.
        self.assertNotIn("tint", mine)


class ClassicFacesComeFromTheTables(unittest.TestCase):
    """The Classic family is the app's own bodies and palette, not new art."""

    def test_the_table_is_the_eight_shipped_bodies_in_a_palette(self) -> None:
        source = read(CLASSICS)
        rows = re.findall(r'BotAvatarClassicFace\(colorID: "([a-z]+)", kind: \.(\w+)\)', source)
        self.assertEqual(len(rows), 8, "a Classic row lost a face")
        kinds = shape_kinds()
        self.assertEqual(sorted(kind for _, kind in rows), sorted(kinds),
                         "the classics are not the eight shipped bodies")
        for color_id, _ in rows:
            with self.subTest(face=color_id):
                self.assertIn(color_id, palette_ids(),
                              f"{color_id} is not a palette entry, so the face has no colour")

    def test_every_face_is_the_string_the_old_picker_wrote(self) -> None:
        source = read(CLASSICS)
        self.assertIn("public var choice: BotFaceChoice "
                      "{ BotFaceChoice.make(colorHex: hex, shapeIndex: shapeIndex) }", source)
        self.assertIn("public var shapeIndex: Int { BotAvatarShape.index(of: kind) }", source)
        self.assertIn("BotAvatarPalette.color(id: colorID) ?? BotAvatarPalette.defaultColor", source)

    def test_no_hex_or_path_is_written_in_the_classics(self) -> None:
        source = code(read(CLASSICS))
        self.assertNotRegex(source, r"#[0-9A-Fa-f]{3,6}\b",
                            "a hex literal is a second palette")
        self.assertNotRegex(source, r"M\d", "the classics file draws its own artwork")

    def test_the_notice_for_the_derived_faces_is_untouched(self) -> None:
        notice = read(NOTICES)
        self.assertIn("rakazo", notice.lower())
        self.assertIn("Apache-2.0", notice)

    def test_the_editor_draws_the_table_in_one_scrolling_row(self) -> None:
        editor = read(EDITOR)
        self.assertIn("ForEach(BotAvatarClassics.all)", editor)
        self.assertIn('SectionCaption("CLASSIC")', editor)
        classics = editor.split("private var classics: some View")[1]
        self.assertIn("ScrollView(.horizontal, showsIndicators: false)", classics,
                      "the row must scroll rather than wrap or open a screen")
        # Each swatch is the shared view drawing that face's own string, and it must not be
        # outranked by the avatar this bot already has.
        self.assertIn("color: classic.choice.raw,", classics)
        self.assertIn("ignoresStoredAvatar: true", classics)


class OneFamilyAtATime(unittest.TestCase):
    """Saving one half clears the other, in one request."""

    def test_the_selection_is_one_case_or_the_other(self) -> None:
        source = read(CLASSICS)
        self.assertIn("public enum BotAvatarSelection: Hashable, Sendable {", source)
        self.assertIn("case classic(BotFaceChoice)", source)
        self.assertIn("case custom(BotAvatarDocument)", source)
        self.assertIn("public var document: BotAvatarDocument?", source)
        self.assertIn("public var face: BotFaceChoice?", source)

    def test_both_services_send_both_halves(self) -> None:
        for path in (MAC_SERVICE, IOS_SERVICE):
            with self.subTest(service=path.name):
                source = read(path)
                self.assertIn("func saveAvatar(botID: String, document: BotAvatarDocument?, face: BotFaceChoice?)",
                              source)
                self.assertIn('"avatar": face?.raw ?? NSNull()', source)
                self.assertIn('"material": document?.material.rawValue ?? NSNull()', source)

    def test_both_stores_pass_the_whole_selection(self) -> None:
        for path in (MAC_STORE, IOS_STORE):
            with self.subTest(store=path.name):
                source = read(path)
                self.assertIn("func saveBotAvatar(botID: String, selection: BotAvatarSelection?)", source)
                self.assertIn("selection?.document", source)
                self.assertIn("selection?.face", source)

    def test_the_host_clears_the_other_half(self) -> None:
        # One PUT carries both fields and each is independent, so a classic pick with a null
        # definition and a drawn pick with a null avatar are both a single write.
        routes = read(RUST_ROUTES)
        self.assertIn('if has("avatar") {', routes)
        self.assertIn('if has("definition") {', routes)
        clear = routes.split("Some(Value::Null) | None => {")[1]
        self.assertIn('object.remove("definition");', clear)
        self.assertIn('object.remove("material");', clear)

    def test_the_editor_commits_exactly_one_family(self) -> None:
        editor = read(EDITOR)
        commit = editor.split("private func commit() {")[1].split("\n    }")[0]
        self.assertIn("BotAvatarSelection.classic(choice)", commit)
        self.assertIn("BotAvatarSelection.custom(BotAvatarDocument(", commit)
        self.assertIn("switch family {", commit)

    def test_a_preset_or_random_leaves_the_classic_family(self) -> None:
        editor = read(EDITOR)
        adopt = editor.split("private func adopt(")[1].split("\n    }")[0]
        self.assertIn("family = .custom", adopt, "a preset does not clear the classic family")
        randomise = editor.split("private func randomise() {")[1].split("\n    }")[0]
        self.assertIn("adopt(pick.definition)", randomise,
                      "Random must go through the same door as a preset")
        applied = editor.split("private func applyJSON() {")[1].split("\n    }")[0]
        self.assertIn("family = .custom", applied,
                      "an imported definition is a drawn avatar too")

    def test_a_bot_with_a_drawn_avatar_can_always_come_back(self) -> None:
        # The face a drawn avatar was saved over is still in the host's document. If the dirty check
        # compared only the face, picking that same classic face again would leave Save disabled.
        dirty = read(EDITOR).split("private var dirty: Bool {")[1].split("\n    }")[0]
        classic = dirty.split("case .classic:")[1].split("case .custom:")[0]
        self.assertIn("if stored != nil { return true }", classic)
        self.assertIn("return classicChoice != face", classic)

    def test_a_classic_pick_enters_the_classic_family(self) -> None:
        editor = read(EDITOR)
        choose = editor.split("private func chooseClassic(")[1].split("\n    }")[0]
        self.assertIn("classicChoice = classic.choice", choose)
        self.assertIn("family = .classic", choose)

    def test_reset_clears_both(self) -> None:
        editor = read(EDITOR)
        reset = editor.split("private func reset() {")[1].split("\n    }")[0]
        self.assertIn("try await save(nil)", reset)


class TheEditorSaysWhichFamilyItIsOn(unittest.TestCase):
    def test_the_family_is_seeded_from_the_hosts_two_answers(self) -> None:
        editor = read(EDITOR)
        self.assertIn("BotAvatarSelection.stored(document: stored, face: face)?.family", editor)
        selection = read(CLASSICS)
        stored = selection.split("public static func stored(document:")[1].split("\n    }")[0]
        # A stored definition wins: it is the branch every surface draws first.
        self.assertLess(stored.index("if let document { return .custom(document) }"),
                        stored.index("if let face { return .classic(face) }"))

    def test_the_row_and_the_preview_say_it_in_words(self) -> None:
        editor = read(EDITOR)
        self.assertIn("private var familyNote: String", editor)
        self.assertIn("wears a Classic face", editor)
        self.assertIn("wears its own drawn avatar", editor)
        self.assertIn("private var previewTitle: String", editor)
        self.assertIn("case .classic:", editor.split("private var facePreview")[1])

    def test_the_preview_draws_the_family_being_chosen(self) -> None:
        editor = read(EDITOR)
        preview = editor.split("private var facePreview: some View")[1].split("private var previewTitle")[0]
        self.assertIn("case .classic:", preview)
        self.assertIn("ignoresStoredAvatar: true", preview)
        self.assertIn("case .custom:", preview)
        self.assertIn("OpenBotAvatarView(definition: draft,", preview)

    def test_only_the_editing_surfaces_ignore_a_stored_avatar(self) -> None:
        # The one bypass of the environment resolution, and it is a comparison the person is making:
        # the editor's Classic row, and the settings header that now mirrors the draft beside the
        # title (a Classic pick has to read as a Classic pick up there too, even for a bot that still
        # has a drawing stored). No roster row, panel or transcript surface may take it.
        self.assertIn("if ignoresStoredAvatar { return nil }", read(BOT_AVATAR_VIEW))
        callers = [p for p in swift_files(UI) + swift_files(APPS)
                   if "ignoresStoredAvatar: true" in read(p)]
        self.assertEqual(sorted(callers, key=str), sorted([EDITOR, MAC_SHEET, IOS_SETTINGS], key=str),
                         "a surface other than the editing ones draws the face the host does not have")


class BothAppsOfferTheClassicFamily(unittest.TestCase):
    def test_the_editor_is_the_one_view_both_shells_draw(self) -> None:
        # Each shell hands the editor the face the host stores and a channel that saves one family:
        # the Mac writes the selection through its store, the phone through `AppEnvironment`.
        for path, face_needle, save_needle in (
            (MAC_SHEET, "face: store.botFaces[bot.id]", "selection: selection"),
            (IOS_SETTINGS, "face: icon", "save: save"),
        ):
            with self.subTest(surface=path.name):
                source = read(path)
                self.assertIn("OpenBotAvatarEditor(", source)
                self.assertIn(face_needle, source, "the editor is handed no classic face")
                self.assertIn(save_needle, source, "the editor is handed no family-saving channel")

    def test_the_editors_save_channel_speaks_both_families(self) -> None:
        editor = read(EDITOR)
        self.assertIn("public let save: (BotAvatarSelection?) async throws -> Void", editor)
        self.assertIn("public let face: BotFaceChoice?", editor)

    def test_the_room_and_the_transcripts_are_shared_code(self) -> None:
        # Rooms live in the design system, so "both apps show it" is one row, not two.
        self.assertIn("public struct RoomChatView: View", read(ROOMS))
        self.assertIn("BotAvatarTint", read(ROOMS))
        for path in (MAC_TRANSCRIPT, IOS_TRANSCRIPT):
            self.assertIn("BotAvatarTint.resolve(", read(path))


if __name__ == "__main__":
    unittest.main()
