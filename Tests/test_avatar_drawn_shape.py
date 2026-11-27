"""What the avatar editor *draws*, not what it captions.

Reported by Mohammad, 2026-11-26, with two iPhone screenshots:

* Book picked — the caption under the preview read ``Book 50 · 48 · spacing 14.0 · ×0.85`` and the
  preview was the same green cat-head the bot already wore;
* Mug picked — the caption read ``Mug 46 · 54 · spacing 13.0 · ×0.90``, the picture was **the same
  cat-head**, and so was the little head beside the name at the top of the sheet.

So the draft reached the label and never reached the drawing. The caption is the draft's own name
and eyes; the body came from a texture that had been built once and kept.

The mechanism, and the reason this file exists: the glass body is drawn by a Metal pass whose
*fragment* is masked by a texture of the silhouette. That texture lives in
`BotAvatarGlassDrawer` and was rebuilt only when the drawable's pixel size changed — the body's own
outline was not part of the decision, so the first silhouette a view was handed stayed on screen for
the life of that view while the eyes (drawn by the two `Canvas` passes over it) moved on. First shape
wins, label keeps changing: exactly the pair of screenshots.

Three things are pinned here, all of them on the drawn value:

* the model a frame draws is picked by a key that contains the body path (`OpenBotAvatarModel`), and
  the glass mask is keyed by that same body (`OpenBotAvatarModel.bodyKey`) — so a new preset cannot
  reuse the last one's drawing;
* adopting a preset changes the path the renderer would use, for all twelve presets, and the drawer's
  own rule rebuilds the mask every time it happens (and would *not* have, under the old rule — that
  assertion is what keeps this file from being vacuous);
* the preview and the header are handed the *draft*, so the body they draw is the draft's body.

The pose is deliberately not in the key: it changes every frame, and a mask per frame is two chamfer
passes per frame. A state chip must not rebuild the mask either — the state moves the eyes and the
shader's uniforms, not the silhouette.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
AVATAR = UI / "OpenBotAvatar"

RENDERER = AVATAR / "OpenBotAvatarRenderer.swift"
VIEW = AVATAR / "OpenBotAvatarView.swift"
STATE = AVATAR / "OpenBotAvatarState.swift"
EDITOR = AVATAR / "OpenBotAvatarEditor.swift"
PRESETS = AVATAR / "OpenBotAvatarPresets.swift"
BOT_AVATAR_VIEW = UI / "BotAvatarView.swift"

GLASS_VIEW = AVATAR / "Glass" / "BotAvatarGlassView.swift"
GLASS_LAYER = AVATAR / "Glass" / "BotAvatarGlassLayer.swift"

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


# MARK: - The preset table, as the renderer would see it


def presets() -> list[dict]:
    """Every preset's id, name, body path and eyes, read from the table itself.

    The table is the only place a preset is defined (`adopt` copies one whole), so reading it is
    reading what the editor puts in the draft.
    """
    text = read(PRESETS)
    rows = []
    for block in re.finditer(r"BotAvatarDefinition\((.*?)\)\)", text, re.S):
        body = block.group(1)
        ident = re.search(r'id: "([a-z0-9-]+)"', body)
        name = re.search(r'name: "([^"]+)"', body)
        path = re.search(r'path: "([^"]+)"', body)
        # The block stops just before the `))` that closes the definition, so the eyes' own closing
        # paren is not in it.
        eyes = re.search(r"eyes: \.init\(x: ([0-9.]+), y: ([0-9.]+), "
                         r"spacing: ([0-9.]+), scale: ([0-9.]+)", body)
        if not (ident and name and path and eyes):
            continue
        rows.append({
            "id": ident.group(1),
            "name": name.group(1),
            "path": path.group(1),
            "eyes": [float(eyes.group(index)) for index in (1, 2, 3, 4)],
        })
    return rows


def swift_number(value: float) -> str:
    """How Swift's `\\(Double)` prints the number: `50.0`, `0.85`."""
    return f"{value:.1f}" if float(value).is_integer() else f"{value}"


def model_key(preset: dict) -> str:
    """The `OpenBotAvatarModel` cache key, built from the renderer's own template.

    The template is read out of the Swift source rather than copied, so a key that stops naming the
    body fails here instead of passing on a stale duplicate.
    """
    template = re.search(r'let key = "([^"]+)"', read(RENDERER)).group(1)
    values = {
        "id": preset["id"],
        "name": preset["name"],
        "body.path": preset["path"],
        "eyes.x": swift_number(preset["eyes"][0]),
        "eyes.y": swift_number(preset["eyes"][1]),
        "eyes.spacing": swift_number(preset["eyes"][2]),
        "eyes.scale": swift_number(preset["eyes"][3]),
    }

    def substitute(match: re.Match) -> str:
        field = match.group(1)
        if field not in values:
            raise AssertionError(f"the model's key reads `{field}`, which this test does not know")
        return values[field]

    return re.sub(r"\\\(definition\.([a-zA-Z.]+)\)", substitute, template)


def mask_rebuilds(drawn_key: str | None, key: str, texture_pixels: tuple | None,
                  pixels: tuple) -> bool:
    """The drawer's own rule, in Python.

    `BotAvatarGlassDrawer.draw` rebuilds the silhouette texture when there is none, when the *body*
    the view is drawing is not the body the texture was built from, or when the drawable's pixel size
    changed. `TheMaskIsKeyedByTheBody` asserts the Swift says the same thing, so this mirror cannot
    drift from it silently.
    """
    return (texture_pixels is None
            or drawn_key != key
            or texture_pixels != pixels)


class Drawer:
    """A `BotAvatarGlassDrawer`, reduced to the state its cache rule reads."""

    def __init__(self, pixels=(600, 600)):
        self.pixels = pixels
        self.key: str | None = None
        self.drawn_key: str | None = None

    def adopt(self, key: str) -> bool:
        """Hand it a frame for `key`; answers whether the mask was rebuilt."""
        self.key = key
        rebuilt = mask_rebuilds(self.drawn_key, self.key,
                                None if self.drawn_key is None else self.pixels, self.pixels)
        if rebuilt:
            self.drawn_key = self.key
        return rebuilt

    def resize(self, pixels) -> None:
        """`mtkView(_:drawableSizeWillChange:)` throws the texture away."""
        self.pixels = pixels
        self.drawn_key = None


# MARK: - The cache carries the body


class TheMaskIsKeyedByTheBody(unittest.TestCase):
    """A drawing of one silhouette is not a drawing of another, whatever else is equal."""

    def setUp(self) -> None:
        self.renderer = code(RENDERER)
        self.layer = code(GLASS_LAYER)
        self.glass_view = code(GLASS_VIEW)

    def test_the_body_key_is_the_path_and_nothing_else(self) -> None:
        key = swift_declaration(self.renderer, "public var bodyKey")
        self.assertIn("definition.body.path", key)
        # Colour, material, size and state change how a body is drawn, never what shape it is — and
        # one of them in the key would rebuild the mask for a state chip or a colour swatch.
        for absent in ("color", "material", "size", "state", "mood"):
            self.assertNotIn(absent, key, f"`{absent}` must not decide the body")

    def test_the_model_the_frame_draws_is_keyed_by_the_body(self) -> None:
        # The volume, the silhouette and the ribbons are all built from the keyed model; a model
        # reused across bodies is the same bug one layer up.
        template = re.search(r'let key = "([^"]+)"', self.renderer).group(1)
        self.assertIn("\\(definition.body.path)", template)

    def test_the_drawer_rebuilds_its_mask_for_a_new_body(self) -> None:
        draw = self.layer.split("func draw(in view: MTKView)")[1].split("static func makeMask")[0]
        self.assertIn("|| maskKeyDrawn != maskKey", draw)
        # The texture is only re-made when that decision said so (and the key recorded with it), or a
        # frame would rebuild two chamfer passes per tick.
        self.assertIn("maskKeyDrawn = texture == nil ? nil : maskKey", draw)
        # A resize still empties the cache: the texture is the drawable's own resolution.
        resize = self.layer.split("drawableSizeWillChange")[1].split("func draw(")[0]
        self.assertIn("texture = nil", resize)
        self.assertIn("maskKeyDrawn = nil", resize)

    def test_the_pose_is_not_in_the_key(self) -> None:
        # `path` carries the pose and moves every frame. Comparing it would rebuild the mask at the
        # avatar's own frame rate, which is the cost this cache exists to avoid.
        draw = self.layer.split("func draw(in view: MTKView)")[1].split("static func makeMask")[0]
        rebuild = draw.split("let pixels = view.drawableSize")[1].split("guard let texture")[0]
        self.assertNotIn("path !=", rebuild)
        self.assertNotIn("path ==", rebuild)
        # The body reaches the drawer beside the path, not instead of it.
        update = swift_declaration(self.layer, "func update(_ view: MTKView?")
        self.assertIn("path: Path, maskKey: String", update)
        self.assertIn("self.maskKey = maskKey", update)

    def test_both_platforms_carry_it_through_the_representable(self) -> None:
        canvas = swift_declaration(self.layer, "struct BotAvatarGlassCanvas")
        self.assertIn("var maskKey: String", canvas)
        self.assertEqual(self.layer.count("path: path, maskKey: maskKey)"), 2,
                         "the UIKit and AppKit representables must both pass the body down")
        self.assertIn("var maskKey: String", swift_declaration(self.glass_view, "struct BotAvatarGlassView"))
        self.assertIn("maskKey: maskKey", self.glass_view)

    def test_the_frame_hands_the_drawer_the_body_it_is_drawing(self) -> None:
        metal = code(VIEW).split("case .metal:")[1]
        # The body's own path, and the part of the pose that moves its outline: a key of the body
        # alone froze the mask at whichever pose first drew. Both are there, so neither can be
        # dropped for the other.
        self.assertIn('maskKey: model.bodyKey + "|" + pose.silhouetteKey)', metal)
        self.assertIn("public var silhouetteKey: String", code(STATE))

    def test_a_colour_or_material_change_alone_keeps_the_mask(self) -> None:
        drawer = Drawer()
        body = presets()[3]["path"]
        self.assertTrue(drawer.adopt(body))
        # Same body, same pixels: colour, material, size and state are not in the key, so the mask
        # is reused (the drawing that is cheap to make again is the eyes and the uniforms).
        self.assertFalse(drawer.adopt(body))


class EveryPresetDrawsItsOwnBody(unittest.TestCase):
    """Twelve presets, twelve bodies — through the path the renderer would really use."""

    def setUp(self) -> None:
        self.presets = presets()
        self.assertEqual(len(self.presets), 12, self.presets)

    def test_every_preset_has_its_own_model_key(self) -> None:
        keys = [model_key(preset) for preset in self.presets]
        self.assertEqual(len(set(keys)), 12,
                         "two presets would resolve to one model, and draw as one shape")

    def test_the_model_key_names_the_body_it_draws(self) -> None:
        for preset in self.presets:
            self.assertIn(preset["path"], model_key(preset),
                          f"{preset['id']}'s model key does not name its own silhouette")

    def test_adopting_a_preset_changes_the_key_the_renderer_would_use(self) -> None:
        # Walking the table in the order the strip offers it: the key the view would hand the
        # renderer must be a different one after every tap.
        keys = [model_key(preset) for preset in self.presets]
        for previous, current in zip(keys, keys[1:]):
            self.assertNotEqual(previous, current)

    def test_the_drawer_rebuilds_the_mask_for_every_preset(self) -> None:
        drawer = Drawer()
        for preset in self.presets:
            self.assertTrue(drawer.adopt(model_key(preset)),
                            f"{preset['id']} would be drawn through the previous body's mask")
            self.assertEqual(drawer.drawn_key, model_key(preset))

    def test_the_size_only_rule_would_have_frozen_the_first_body(self) -> None:
        # The rule this replaced, kept as the reason the guard above is not vacuous: under it, the
        # first preset in the drawer wins for the life of the view, whatever the caption says.
        def old_rule(drawn_key, key, texture_pixels, pixels):
            return texture_pixels is None or texture_pixels != pixels

        first = model_key(self.presets[0])
        drawn, pixels = first, (600, 600)
        rebuilt = old_rule(drawn, model_key(self.presets[1]), pixels, pixels)
        self.assertFalse(rebuilt, "the old rule must be the bug, or this file proves nothing")

    def test_the_states_share_one_body(self) -> None:
        # The pills move the eyes, the pose and the tint; at a held pose the silhouette is the same
        # body, so the mask is built once and repeated frames stay free. (A state that *moves* the
        # body — a celebration's turn and hop — is in the key, and rebuilds; see
        # `Tests/test_avatar_face_motion_and_marks.py`.)
        drawer = Drawer()
        key = model_key(self.presets[7])
        self.assertTrue(drawer.adopt(key))
        for _ in range(9):
            self.assertFalse(drawer.adopt(key), "a held pose must not rebuild the silhouette mask")
        # …and the state still reaches the drawing, through the pose and the two Canvas passes.
        view = code(VIEW)
        self.assertIn("frame(model: model, pose: pose", view)
        self.assertIn("state.pose(mood: mood", view)

    def test_a_resize_rebuilds_once_and_then_holds(self) -> None:
        drawer = Drawer()
        key = model_key(self.presets[2])
        drawer.adopt(key)
        drawer.resize((1200, 1200))
        self.assertTrue(drawer.adopt(key))
        self.assertFalse(drawer.adopt(key))


# MARK: - The preview and the header draw the draft


class ThePreviewDrawsTheDraftBody(unittest.TestCase):
    """The picture above the caption is the draft's box, on both shells.

    It was never the caption's job to be right on its own: a caption that follows the draft over a
    body that does not is the exact pair of screenshots this fixes.
    """

    def test_the_preview_is_handed_the_draft(self) -> None:
        editor = code(EDITOR)
        preview = editor.split("private var facePreview")[1].split("private var previewTitle")[0]
        self.assertIn("OpenBotAvatarView(definition: draft,", preview)
        self.assertIn("color: colorHex,", preview)
        self.assertIn("material: material,", preview)
        # Not the stored document: a preview you cannot change is not a preview.
        self.assertNotIn("stored", preview)
        self.assertNotIn("document:", preview)

    def test_the_preview_is_drawn_at_the_size_the_material_row_asked_about(self) -> None:
        editor = code(EDITOR)
        preview = editor.split("private var facePreview")[1].split("private var previewTitle")[0]
        self.assertIn("size: 200,", preview)
        self.assertIn("static let previewSide: Double = 200", editor)
        # The material row's answer about glass is about this size, not a guess at one.
        self.assertIn("side: Self.previewSide", editor)

    def test_the_header_is_handed_the_same_draft(self) -> None:
        for sheet in (code(MAC_SHEET), code(PHONE_SCREEN)):
            header = swift_declaration(sheet, "private var headerAvatar:")
            self.assertIn("case .custom(let document):", header)
            self.assertIn("document: document", header)
            self.assertIn("onFaceChange: { liveFace = $0 }", sheet)
            self.assertIn("switch tab == .avatar ? liveFace : nil {", header)

    def test_both_heads_resolve_to_the_same_drawing(self) -> None:
        # `BotAvatarView.face` is the one resolution, and the drawn branch hands its definition to
        # `OpenBotAvatarView` — so the header and the 200 pt preview reach the same mask key.
        view = code(BOT_AVATAR_VIEW)
        face = swift_declaration(view, "private var face: BotAvatarDocument?")
        self.assertIn("if let document { return document }", face)
        self.assertIn("return BotAvatarDocument(definition: definition, color: avatarColor)", face)
        self.assertIn("return avatarLibrary[identity]", face)
        drawn = swift_declaration(view, "private func drawnBody(")
        self.assertIn("OpenBotAvatarView(definition: face.definition,", drawn)


if __name__ == "__main__":
    unittest.main()
