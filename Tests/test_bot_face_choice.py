"""The user's icon override: one string, end to end.

The stored value is the reference's own — `#RRGGBB::shape_N`, what the web app keeps in
`bots.color` — so a choice made on one surface means the same face on every other one. This file
pins the parts a compiler cannot: that the value keeps its field, that both readers (the Swift
`BotFaceChoice` and the Python bridge) agree on its grammar, and that a choice made by the *previous*
build migrates instead of vanishing.

The behavioural half is `Tests/HermeyUITests/BotFaceChoiceTests.swift` (encode/decode, migration,
normalisation).
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
GALLERY = (UI / "BotIconGallery.swift").read_text(encoding="utf-8")
IDENTITY = (UI / "BotAvatarIdentity.swift").read_text(encoding="utf-8")
SHAPES = (UI / "BotAvatarShape.swift").read_text(encoding="utf-8")
PALETTE = (UI / "BotAvatarPalette.swift").read_text(encoding="utf-8")
BRIDGE = (ROOT / "Bridge" / "hermes_bridge" / "bot_icons.py").read_text(encoding="utf-8")
IOS_SERVICE = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotIconPicker.swift").read_text(encoding="utf-8")
MAC_SERVICE = (ROOT / "Apps" / "HermesMac" / "Views" / "MacBotIconPicker.swift").read_text(encoding="utf-8")
APP_ENV = (ROOT / "Apps" / "HermesMobile" / "App" / "AppEnvironment.swift").read_text(encoding="utf-8")
SWIFT_TESTS = (ROOT / "Tests" / "HermeyUITests" / "BotFaceChoiceTests.swift").read_text(encoding="utf-8")

sys.path.insert(0, str(ROOT / "Bridge"))
try:  # the bridge's own module is the authority on the wire grammar
    from hermes_bridge import bot_icons as bridge_icons  # type: ignore
    HAVE_BRIDGE = True
except Exception:  # pragma: no cover - fastapi/pydantic absent
    bridge_icons = None
    HAVE_BRIDGE = False

SHAPE_ORDER = ["hex", "wedge", "squircle", "tablet", "pebble", "blob", "teardrop", "cloud"]

LEGACY_SHAPES = ["ember", "nova", "cobalt", "orbit", "moss", "dusk", "beacon", "pixel",
                 "rover", "prism", "lump", "mushroom", "blob", "capsule", "droplet", "scallop"]
LEGACY_COLORS = ["orange", "amber", "lime", "mint", "teal", "cyan", "blue", "indigo",
                 "purple", "pink", "ruby", "slate"]


def swift_palette_hexes() -> list[str]:
    start = PALETTE.index("colors: [BotAvatarColorDef] = [")
    body = PALETTE[start:PALETTE.index("\n    ]", start)]
    return re.findall(r'hex: "(#[0-9A-Fa-f]{6})"', body)


def swift_legacy_colors() -> dict[str, str]:
    start = GALLERY.index("static let legacyColors: [String: String] = [")
    body = GALLERY[start:GALLERY.index("\n    ]", start)]
    return dict(re.findall(r'"([a-z]+)": "(#[0-9A-F]{6})"', body))


def swift_legacy_order() -> list[str]:
    start = GALLERY.index("static let legacyShapeOrder: [String] = [")
    body = GALLERY[start:GALLERY.index("\n    ]", start)]
    return re.findall(r'"([a-z]+)"', body)


class TheFieldIsUnchanged(unittest.TestCase):
    def test_it_is_still_bot_faces(self) -> None:
        # "The same stored field": the host's per-bot map and the app's dictionary keep their shape,
        # only the value changed. A migration that renamed the field would lose every choice on
        # every device that had not updated.
        self.assertIn("@Published private(set) var botFaces: [String: BotFaceChoice]", APP_ENV)
        self.assertIn("-> [String: BotFaceChoice] {", MAC_SERVICE)
        self.assertIn("-> [String: BotFaceChoice] {", IOS_SERVICE)
        self.assertIn("private static func botFaceCacheKey", APP_ENV)
        self.assertIn("hermey.botFaces.\\(", APP_ENV)
        self.assertIn("@router.get('')", BRIDGE)
        self.assertIn("@router.put('/{bot_id}')", BRIDGE)

    def test_the_value_is_the_reference_string(self) -> None:
        self.assertIn("public struct BotFaceChoice: Hashable, Codable, Sendable, RawRepresentable", GALLERY)
        self.assertIn("::shape_", GALLERY)
        self.assertIn("BotAvatarShape.normalized(index: shapeIndex)", GALLERY)
        # It is read back through the module's one parser, not a second one written for the picker.
        self.assertIn("public var stored: BotAvatarStoredValue { BotAvatarIdentity.parse(raw) }", GALLERY)
        self.assertIn("public static func parse(_ raw: String) -> BotAvatarStoredValue {", IDENTITY)

    def test_the_picker_offers_the_eight_bodies_and_the_palette(self) -> None:
        picker = GALLERY[GALLERY.index("public struct BotFacePicker"):]
        self.assertIn("ForEach(BotAvatarShape.shipped.indices, id: \\.self)", picker)
        self.assertIn("BotAvatarPalette.colors", picker)
        self.assertIn("count: 8", picker)
        # A live preview drawn by the same view every other surface uses.
        self.assertIn("BotAvatarView(identity: identity, color: draft.raw, activity: .idle, size: 76)", picker)


class TheGrammarAgreesOnBothSides(unittest.TestCase):
    def test_the_shipped_order_is_the_index_order(self) -> None:
        self.assertIn("case hex, wedge, squircle, tablet, pebble, blob, teardrop, cloud", SHAPES)
        self.assertEqual(swift_legacy_order(), LEGACY_SHAPES,
                         "the old order decides which body a legacy index lands on")

    def test_every_palette_hex_is_canonical(self) -> None:
        hexes = swift_palette_hexes()
        self.assertEqual(len(hexes), 11)
        for value in hexes:
            self.assertRegex(value, r"^#[0-9A-F]{6}$")
        # The default the parser falls back to is a real entry, not a guess.
        self.assertIn("#A97EFE", hexes)

    def test_the_old_colours_all_land_on_the_palette(self) -> None:
        mapping = swift_legacy_colors()
        self.assertEqual(sorted(mapping), sorted(LEGACY_COLORS),
                         "every old swatch must migrate; a missing one loses a chosen colour")
        palette = set(swift_palette_hexes())
        for old, new in mapping.items():
            self.assertIn(new, palette, f"{old} maps to {new}, which is not in the palette")

    def test_the_bridge_accepts_exactly_the_strings_the_picker_writes(self) -> None:
        self.assertIn("AVATAR = re.compile", BRIDGE)
        self.assertIn("avatar: Optional[str] = None", BRIDGE)
        self.assertIn("def split_avatar(", BRIDGE)
        if HAVE_BRIDGE:
            assert bridge_icons is not None
            # `#RRGGBB::shape_N` and `#RRGGBB` are the two the app writes; anything else is refused
            # rather than stored as a value nothing can draw.
            for value in ("#A97EFE::shape_0", "#A97EFE::shape_7", "#FF781C", "#abc"):
                self.assertRegex(value, bridge_icons.AVATAR.pattern)
            for value in ("A97EFE", "#A97EFE::shape_", "data:image/png;base64,AA", "#GGGGGG"):
                self.assertIsNone(bridge_icons.AVATAR.match(value), value)

    def test_the_bridge_stores_a_body_and_a_colour_for_an_old_reader(self) -> None:
        # A device that has not been updated reads `shape`/`color` as required strings and skips a
        # row it does not recognise. Missing keys would fail its whole decode — every face gone,
        # not one.
        if not HAVE_BRIDGE:
            self.skipTest("bridge dependencies not installed")
        assert bridge_icons is not None
        colour, shape = bridge_icons.split_avatar("#A97EFE::shape_3")
        self.assertEqual(colour, "#A97EFE")
        self.assertEqual(shape, "shape_3", "the body, which an old reader skips rather than mis-draws")
        self.assertEqual(bridge_icons.split_avatar("#A97EFE"), ("#A97EFE", None))


class ItRoundTrips(unittest.TestCase):
    def test_write_then_read_is_the_same_choice(self) -> None:
        # The exact arithmetic the Swift does: normalise, append the index, parse it back.
        def make(hex_value: str, index: int) -> str:
            digits = hex_value.lstrip("#")
            if len(digits) == 3:
                digits = "".join(c * 2 for c in digits)
            return f"#{digits.upper()}::shape_{index % 8}"

        def parse(raw: str) -> tuple[str, int | None]:
            head, sep, tail = raw.partition("::shape_")
            return head, (int(tail) % 8 if sep else None)

        for index in range(8):
            for hex_value in swift_palette_hexes():
                stored = make(hex_value, index)
                self.assertEqual(parse(stored), (hex_value, index))
                self.assertIn(hex_value, swift_palette_hexes())

    def test_a_bare_colour_leaves_the_body_to_the_id(self) -> None:
        # `#FF781C` is valid and means "this colour, the body the id draws" — which is what the web
        # writes when only a colour was chosen.
        self.assertIn("public static func make(colorHex: String) -> BotFaceChoice", GALLERY)
        self.assertIn("public var shapeIndex: Int? {", GALLERY)
        self.assertIn("if case .shape(_, let index) = stored { return index }", GALLERY)
        self.assertIn("let index = explicitShapeIndex ?? BotAvatarHash.shapeIndex(for: seedIdentity)", IDENTITY)

    def test_the_migration_is_total_over_the_old_sets(self) -> None:
        self.assertIn("public static func migrated(legacyShape shape: String?, legacyColor color: String?) -> BotFaceChoice?",
                      GALLERY)
        self.assertIn("public static func migrated(legacyToken token: String) -> BotFaceChoice?", GALLERY)
        self.assertIn("public static func migrated(legacyIcon name: String) -> BotFaceChoice?", GALLERY)
        # A shape this build does not know still keeps the user's colour.
        self.assertIn("return make(colorHex: hex)\n    }", GALLERY)

    def test_the_decoder_takes_both_payloads(self) -> None:
        self.assertIn("public init(from decoder: Decoder) throws {", GALLERY)
        self.assertIn("if let container = try? decoder.singleValueContainer(),", GALLERY)
        self.assertIn("let container = try decoder.container(keyedBy: LegacyKeys.self)", GALLERY)
        self.assertIn("private enum LegacyKeys: String, CodingKey {", GALLERY)

    def test_every_service_reads_avatar_first_and_writes_only_it(self) -> None:
        for service, name in ((IOS_SERVICE, "iOS"), (MAC_SERVICE, "Mac")):
            self.assertIn("let avatar: String?", service, name)
            self.assertIn("if let avatar = face.avatar, let choice = BotFaceChoice(rawValue: avatar)", service, name)
            self.assertIn("BotFaceChoice.migrated(legacyShape: face.shape, legacyColor: face.color)", service, name)
            self.assertIn("BotFaceChoice.migrated(legacyIcon: icon)", service, name)
            self.assertIn("Change(avatar: face?.raw)", service, name)
            self.assertIn("case avatar", service, name)

    def test_the_device_cache_migrates_what_it_wrote_before(self) -> None:
        # `shape|color` and a bare icon id are both readable; the next write is the new string.
        self.assertIn("BotFaceChoice.migrated(legacyToken: encoded)", APP_ENV)
        self.assertIn("BotFaceChoice.migrated(legacyIcon: encoded)", APP_ENV)
        self.assertIn("let raw = faces.mapValues(\\.raw)", APP_ENV)

    def test_the_swift_tests_cover_the_round_trip(self) -> None:
        for name in ("testAChoiceIsTheReferenceString",
                     "testItEncodesAsOneString",
                     "testItStillDecodesTheOldPairPayload",
                     "testEveryOldShapeAndColourMigrates",
                     "testAnIconOnlyRowMigratesToTheColourItWasDrawnIn"):
            self.assertIn(f"func {name}(", SWIFT_TESTS, name)


if __name__ == "__main__":
    unittest.main()
