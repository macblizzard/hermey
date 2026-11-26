"""The settings panel's face: one definition, and the header says what the tab is editing.

Reported by Mohammad, 2026-11-26, with two screenshots:

> on bot settings panel, the bot avatar does not show up beside the bot name on top left. and also
> on bot settings avatar panel, changing between the 12 avatar shapes keeps the same avatar shape
> only changes the eyes, but clicking on random properly sets a random face and color and material.

and, on the second shot (Hourglass chosen, the big preview correctly an hourglass):

> even though the hourglass is selected but still it shows the cat face

What that pair of screenshots establishes, and what this file pins:

* the **preset table works**: twelve presets, twelve distinct silhouettes, each one adopted as a
  whole `BotAvatarDefinition` (shape id *and* geometry *and* eyes) — never as an eyes-only patch.
  The guard below fails if a preset path is ever written as a partial update, and it fails if two
  presets stop being distinguishable by their own path;
* all twelve are reachable: the strip iterates `OpenBotAvatarPresets.all` over a six-column grid, so
  it wraps into two rows rather than hiding six behind an edge;
* the **header beside the name** is the surface that was wrong. It resolved the *stored* face only
  and, for a bot whose only face is a drawn document, it depended on `environment.botAvatars`
  reaching a presented sheet — which is where it drew nothing at all. It now draws the face the tab
  is *editing* (the editor reports its draft through `onFaceChange`) and, before the tab opens, the
  sheet's own copy of the stored document;
* that resolution is **one point**, in `BotAvatarView.face`: an explicit document, else an explicit
  definition, else the environment — so a surface that was handed a face cannot be overridden by a
  stale map, and a surface that was handed nothing still draws what the host stores.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
AVATAR = UI / "OpenBotAvatar"

BOT_AVATAR_VIEW = UI / "BotAvatarView.swift"
EDITOR = AVATAR / "OpenBotAvatarEditor.swift"
PRESETS = AVATAR / "OpenBotAvatarPresets.swift"
RANDOM = AVATAR / "OpenBotAvatarRandom.swift"

MAC_SHEET = ROOT / "Apps" / "HermesMac" / "Views" / "MacBotSettingsSheet.swift"
PHONE_SCREEN = ROOT / "Apps" / "HermesMobile" / "Views" / "BotModelSettingsScreen.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code(path: Path) -> str:
    """The file with its comments removed: prose naming a symbol is not the symbol."""
    return "\n".join(line.split("//")[0] for line in read(path).splitlines())


def swift_declaration(text: str, marker: str) -> str:
    """The brace-balanced body of the first declaration containing `marker`."""
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise AssertionError(f"unbalanced braces after {marker!r}")


class EveryPresetWritesItsWholeShape(unittest.TestCase):
    """A preset is a definition, not a pair of eyes.

    The owner's "it only changes the eyes" is the symptom of an apply path that writes part of a
    definition; the guard on `adopt` is written to fail on exactly that.
    """

    def setUp(self) -> None:
        self.presets = read(PRESETS)
        self.editor = code(EDITOR)

    def test_the_table_has_twelve_presets_with_twelve_distinct_paths(self) -> None:
        ids = re.findall(r'id: "([a-z0-9-]+)"', self.presets)
        paths = re.findall(r'path: "([^"]+)"', self.presets)
        self.assertEqual(len(ids), 12, f"expected twelve presets, found {ids}")
        self.assertEqual(len(set(ids)), 12, f"two presets share an id: {ids}")
        # The definition's own identity *is* its body path: two presets with one path are one shape
        # with two names, which is what "the shape never changes" would look like if it were real.
        self.assertEqual(len(set(paths)), 12, "two presets draw the same silhouette")

    def test_all_lands_in_the_editor_in_table_order(self) -> None:
        table = re.search(r"public static let all: \[BotAvatarDefinition\] = \[(.*?)\]",
                          self.presets, re.S)
        self.assertIsNotNone(table, "the preset table is gone")
        assert table is not None
        written = [name.strip() for name in table.group(1).split(",") if name.strip()]
        self.assertEqual(written, ["blob", "box", "mug", "sprout", "cat", "egg",
                                   "bottle", "star", "droplet", "hourglass", "book", "mushroom"])
        # Softened once, at the table: the editor stores and draws the same text.
        self.assertIn(".map(OpenBotAvatarSoften.softened)", self.presets)

    def test_a_preset_is_adopted_whole(self) -> None:
        adopt = swift_declaration(self.editor, "private func adopt(")
        # The whole definition — body, eyes, id, name — in one assignment. A path that wrote
        # `draft.eyes = preset.eyes` (or any other field on its own) would pass a preview check and
        # leave the silhouette alone, which is the reported defect.
        self.assertIn("draft = preset", adopt)
        self.assertNotRegex(self.editor, r"draft\.(eyes|body|id|name)\s*=",
                            "a preset must never be applied field by field")

    def test_random_writes_the_same_three_fields(self) -> None:
        randomise = swift_declaration(self.editor, "private func randomise(")
        self.assertIn("material = pick.material", randomise)
        self.assertIn("colorHex = pick.colorHex", randomise)
        # The shape goes through the same `adopt`, so a random face and a preset cannot diverge.
        self.assertIn("adopt(pick.definition)", randomise)

    def test_save_stores_the_whole_definition(self) -> None:
        commit = swift_declaration(self.editor, "private func commit(")
        self.assertIn("BotAvatarDocument(definition: draft,", commit)
        self.assertIn("color: colorHex", commit)
        self.assertIn("material: material", commit)

    def test_all_twelve_are_on_screen(self) -> None:
        presets = swift_declaration(self.editor, "private var presets:")
        # The strip iterates the whole table, in a six-column grid: two rows, not a clipped one.
        self.assertIn("ForEach(OpenBotAvatarPresets.all, id: \\.id)", presets)
        self.assertIn("count: 6)", presets)
        # No fixed height and no horizontal scroll that could put the second six past an edge.
        self.assertNotIn("ScrollView(.horizontal", presets)
        self.assertNotIn("frame(height:", presets)


class TheCaptionSaysWhatIsDrawn(unittest.TestCase):
    """The line under the preview ("Hourglass 50 · 33 · spacing 16.0") is the drawn shape's own
    name and eyes, so a preview can never be captioned as another shape."""

    def setUp(self) -> None:
        self.editor = read(EDITOR)

    def test_the_title_is_the_drafts_name(self) -> None:
        title = self.editor.split("private var previewTitle")[1].split("/// What pressing Save")[0]
        self.assertIn("return draft.name", title)
        # Not the stored definition: the caption describes what the view above it is drawing.
        self.assertNotIn("stored", title)

    def test_the_caption_is_the_drafts_own_eyes(self) -> None:
        self.assertIn('Text("\\(Int(draft.eyes.x.rounded()))', self.editor)
        self.assertIn("draft.eyes.spacing", self.editor)

    def test_the_preview_draws_the_same_draft(self) -> None:
        preview = self.editor.split("private var facePreview")[1].split("private var previewTitle")[0]
        self.assertIn("OpenBotAvatarView(definition: draft,", preview)


class TheHeaderDrawsTheFaceBeingEdited(unittest.TestCase):
    """Both settings surfaces draw the draft, not last week's stored face."""

    def setUp(self) -> None:
        self.editor = code(EDITOR)
        self.mac = code(MAC_SHEET)
        self.phone = code(PHONE_SCREEN)

    def test_the_editor_reports_its_draft(self) -> None:
        self.assertIn("public var onFaceChange: ((BotAvatarSelection) -> Void)?", self.editor)
        self.assertIn(".onAppear { reportFaceOnScreen() }", self.editor)
        self.assertIn(".onChange(of: faceOnScreen)", self.editor)
        report = swift_declaration(self.editor, "private func reportFaceOnScreen(")
        self.assertIn("onFaceChange(selection)", report)

    def test_the_mac_header_draws_it(self) -> None:
        header = swift_declaration(self.mac, "private var headerAvatar:")
        self.assertIn("case .custom(let document):", header)
        self.assertIn("document: document", header)
        # A Classic pick draws the shape face even for a bot that still has a drawing stored.
        self.assertIn("ignoresStoredAvatar: true", header)
        # Nothing drawn yet: the sheet's own copy of the host's document, never the environment's.
        self.assertIn("document: store.botAvatars[bot.id]", header)
        self.assertIn("BotAvatarSize.settingsHeader", header)
        self.assertIn("animates: false", header)
        # The draft is the bot's face only while the tab that draws it is open.
        self.assertIn("switch tab == .avatar ? liveFace : nil {", header)
        # The header is wired to the editor's report.
        self.assertIn("onFaceChange: { liveFace = $0 }", self.mac)
        self.assertIn("headerAvatar", swift_declaration(self.mac, "private var titleBar:"))
        self.assertIn("@State private var liveFace: BotAvatarSelection?", self.mac)

    def test_the_phone_header_draws_it(self) -> None:
        header = swift_declaration(self.phone, "private var headerAvatar:")
        self.assertIn("case .custom(let document):", header)
        self.assertIn("document: document", header)
        self.assertIn("ignoresStoredAvatar: true", header)
        self.assertIn("document: avatar", header)
        self.assertIn("switch tab == .avatar ? liveFace : nil {", header)
        self.assertIn("BotAvatarSize.settingsHeader", header)
        self.assertIn("animates: false", header)
        self.assertIn("onFaceChange: { liveFace = $0 }", self.phone)
        principal = self.phone[self.phone.index("ToolbarItem(placement: .principal)"):]
        self.assertIn("headerAvatar", principal[:400])
        self.assertIn("@State private var liveFace: BotAvatarSelection?", self.phone)

    def test_both_platforms_draw_at_one_size(self) -> None:
        sizes = read(BOT_AVATAR_VIEW)
        self.assertIn("public static let settingsHeader: CGFloat = 26", sizes)
        # Neither shell writes a bare number beside the constant.
        for source in (self.mac, self.phone):
            self.assertNotRegex(source, r"size: (24|26|28),",
                                "the header's side belongs to BotAvatarSize.settingsHeader")


class OneResolutionPoint(unittest.TestCase):
    """`BotAvatarView.face`: document, then definition, then the environment."""

    def test_the_order_is_document_first(self) -> None:
        view = code(BOT_AVATAR_VIEW)
        face = swift_declaration(view, "private var face: BotAvatarDocument?")
        document = face.index("if let document { return document }")
        definition = face.index("if let definition {")
        environment = face.index("return avatarLibrary[identity]")
        self.assertLess(document, definition)
        self.assertLess(definition, environment)
        # The classic row's opt-out still wins over the environment, or the editor's Classic
        # swatches would draw the drawing the person is leaving.
        self.assertLess(face.index("if ignoresStoredAvatar { return nil }"), environment)

    def test_the_document_carries_the_material(self) -> None:
        # `definition:`/`avatarColor:` stay for a preview, but they cannot carry a material; the
        # document is the only route that draws a glass face as glass.
        view = code(BOT_AVATAR_VIEW)
        self.assertIn("public var document: BotAvatarDocument?", view)
        self.assertIn("if let document { return document }", view)


if __name__ == "__main__":
    unittest.main()
