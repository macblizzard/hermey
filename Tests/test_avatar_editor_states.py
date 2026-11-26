"""The avatar editor's state strip, its honest material row, and its one example state — from source.

Since open-bot-avatar 0.5.1 the renderer can be told a state by name *or* by a definition of the
host's own, and glass is drawn two ways (a Metal pass on an app surface, the painted material
everywhere else). Neither is worth anything if the editor cannot show it, so the editor grew:

* a **strip** of the eight activity states plus one example definition, tapping which moves the
  preview above and nothing else;
* a **material row** that asks `BotAvatarGlassRoute` what this device will really draw instead of
  promising a 3D surface to a process that cannot draw one;
* one demonstration `AvatarStateDefinition`, visible in the product rather than only in the source.

None of that is exercisable from this suite — the editor is SwiftUI — so what is checked here is
every fact those three can silently get wrong:

* the strip offers the eight activity words *and* the example, and nothing else;
* the example is a real `AvatarStateDefinition` with an id and a pose built from `StateContext`;
* a chip feeds the preview's `state:` and does not remount it (a remount would rebuild the model it
  draws and kill the easing the renderer exists to perform);
* the material row asks the one decision (through `drawn`, which is `decide`) and its copy claims
  nothing the route has not answered — no "3D" anywhere;
* the strip writes no store, no bot and no activity: the only assignment a chip makes is the view's
  own `@State`;
* every chip carries a label and the selected trait;
* the strip wraps rather than scrolling, its columns come from the width rather than the selection,
  and the size the material row asks about is the size the preview is drawn at;
* the example lives in the editor file — the one avatar file the Live Activity excludes — so the
  widget process does not compile a demonstration state it can never show.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
AVATAR = UI / "OpenBotAvatar"

EDITOR = AVATAR / "OpenBotAvatarEditor.swift"
ROUTE = AVATAR / "OpenBotAvatarGlassRoute.swift"
VIEW = AVATAR / "OpenBotAvatarView.swift"
STATE = AVATAR / "OpenBotAvatarState.swift"
STATE_DEFINITION = AVATAR / "OpenBotAvatarStateDefinition.swift"
PROJECT = ROOT / "project.yml"

#: The eight, in the order the strip shows them and the order the task named them.
THE_EIGHT = ["idle", "thinking", "reading", "working",
             "computer", "waiting", "blocked", "done"]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code(text: str) -> str:
    """The text with its comments removed, so an example written in a doc comment is not a literal."""
    return "\n".join(line.split("///")[0].split("//")[0] for line in text.splitlines())


def block(source: str, opening: str, closing: str = "\n    }") -> str:
    """One member's body: from `opening` to the first `closing` after it."""
    start = source.index(opening)
    return source[start:source.index(closing, start)]


def editor_chips() -> str:
    return block(code(read(EDITOR)), "private var stateStrip: some View {")


def editor_chip() -> str:
    """`stateChip(_:title:)`, comments stripped."""
    source = code(read(EDITOR))
    start = source.index("private func stateChip(")
    return source[start:source.index("\n    }", start)]


def editor_preview() -> str:
    """The drawn preview: the `OpenBotAvatarView` call in `facePreview`."""
    source = code(read(EDITOR))
    return source.split("OpenBotAvatarView(definition: draft,")[1].split("label:")[0]


class TheStripOffersTheEightAndOneExample(unittest.TestCase):
    """Nine chips: the eight activity words, then the demonstration state."""

    def test_the_eight_are_the_contract_s_eight(self):
        # Read off the enum rather than trusted: the strip iterates `allCases`, so a ninth case
        # would appear in the product with no editor change and no test failing.
        source = code(read(STATE))
        start = source.index("public enum OpenBotAvatarState:")
        enum = source[start:source.index("\n}", start)]
        cases = re.findall(r"^    case (\w+)$", enum, re.MULTILINE)
        self.assertEqual(cases, THE_EIGHT)

    def test_the_strip_draws_all_cases_plus_exactly_one_example(self):
        strip = editor_chips()
        self.assertIn("ForEach(OpenBotAvatarState.allCases, id: \\.self)", strip,
                      "the eight must come from the enum, not from a list written here")
        # Two chips are made: one inside the ForEach (the eight, by case) and one example.
        self.assertEqual(len(re.findall(r"stateChip\(", strip)), 2, strip)
        self.assertEqual(re.findall(r'title: "([^"]+)"', strip), ["Example"])
        # The example is the ninth chip, after the eight — not a row of its own.
        self.assertGreater(strip.index('title: "Example"'),
                           strip.index("ForEach(OpenBotAvatarState.allCases"))

    def test_the_strip_is_shown_only_where_a_state_is_drawn(self):
        # A Classic face is one body and one palette, held at rest: chips there would be controls
        # that change nothing, which is how a person concludes the tab is broken.
        source = code(read(EDITOR))
        self.assertIn("if family == .custom {\n                stateStrip\n            }", source)


class TheExampleIsARealDefinition(unittest.TestCase):
    """The ninth chip draws the API 0.5.1 added, not a stand-in."""

    def test_it_is_an_avatar_state_definition_with_an_id(self):
        source = code(read(EDITOR))
        self.assertIn('public static let definition = AvatarStateDefinition(id: "example")', source)
        # Built once, at the type, not per body evaluation: a definition per frame would be a new
        # closure each time the strip is drawn.
        self.assertNotIn("AvatarStateDefinition(id:", editor_chips())

    def test_the_pose_starts_from_the_calm_one_and_adds_one_thing(self):
        definition = block(code(read(EDITOR)), "public static let definition = AvatarStateDefinition")
        self.assertIn("ctx.rest(1)", definition, "a state of one's own starts from the calm pose")
        self.assertRegex(definition, r"pose\.roll = -?\d+(\.\d+)? \* ctx\.wave\(")
        self.assertRegex(definition, r"pose\.gazeX = ")
        self.assertIn("return pose", definition)
        # `wave` takes a period **and** a phase; the doc example's one-argument call would not build.
        for call in re.findall(r"ctx\.wave\(([^)]*)\)", definition):
            self.assertEqual(len(call.split(",")), 2, f"ctx.wave({call}) is not the two-argument sine")

    def test_the_example_is_named_example(self):
        # A chip labelled "Example" over an id of something else would teach the wrong thing: the id
        # is what names a state everywhere (two definitions with one id are the same state).
        definition = block(code(read(EDITOR)), "public static let definition = AvatarStateDefinition")
        self.assertIn('id: "example"', definition)

    def test_it_survives_being_handed_to_the_view_like_any_state(self):
        # The same `state:` parameter the eight use — that is what makes it a demonstration rather
        # than a second rendering path.
        self.assertIn("OpenBotAvatarStateChoice(OpenBotAvatarExampleState.definition)", editor_chips())
        view = code(read(VIEW))
        self.assertIn("public var state: OpenBotAvatarStateChoice", view)
        self.assertIn("case .defined(let definition)", code(read(STATE_DEFINITION)))

    def test_the_example_is_not_compiled_into_the_widget(self):
        # The Live Activity compiles `Sources/HermeyUI/OpenBotAvatar` and excludes one file. A new
        # file holding the example would ship a state the card can never show.
        carriers = [path.name for path in AVATAR.glob("*.swift")
                    if "OpenBotAvatarExampleState" in read(path)]
        self.assertEqual(carriers, ["OpenBotAvatarEditor.swift"])
        self.assertIn('excludes:\n          - "OpenBotAvatarEditor.swift"', read(PROJECT))


class AChipFeedsThePreviewAndNothingElse(unittest.TestCase):
    """The strip is a window on the renderer, not a remote control for a bot."""

    def test_the_choice_is_the_preview_s_own_state(self):
        chip = editor_chip()
        action = chip.split("Button {", 1)[1].split("} label:", 1)[0]
        # The button's whole effect: one assignment to this view's `@State`.
        self.assertEqual(re.findall(r"previewChoice = \w+", action), ["previewChoice = choice"])
        self.assertNotIn("save(", action)
        self.assertNotIn("await", action)
        source = code(read(EDITOR))
        self.assertIn("@State private var previewChoice: OpenBotAvatarStateChoice", source)

    def test_the_preview_draws_what_the_strip_chose(self):
        self.assertIn("state: previewChoice,", editor_preview())
        # …as the same parameter a bot's real state travels through, not a second one.
        self.assertNotIn("previewState,", editor_preview())

    def test_nothing_is_keyed_on_the_state(self):
        # `.id(previewChoice)` — or any id in that call — would remount the view on every tap:
        # a fresh animator (so the change would cut instead of ease) and, on a definition change,
        # a fresh model.
        preview = editor_preview()
        self.assertNotIn(".id(", preview)
        self.assertNotIn("OpenBotAvatarModel", preview)
        self.assertNotIn("decode(", preview)

    def test_the_editor_writes_no_bot_state_anywhere(self):
        source = code(read(EDITOR))
        # No activity setter, no tracker, no store: the editor's only write channel is `save`, which
        # takes a `BotAvatarSelection` — a face — and nothing else.
        for token in ("setActivity", "activity(", "BotActivityTracker", "recordActivity",
                      "botAvatars[", "store.", ".activity ="):
            self.assertNotIn(token, source, f"the editor reaches for {token}")
        self.assertNotRegex(source, r"\n\s*previewState = ",
                            "the seed is read, never written back")
        # …and the strip's region holds no call to the save channel at all.
        strip = block(source, "private var stateStrip: some View {") + editor_chip()
        self.assertNotIn("save(", strip)

    def test_the_state_lives_in_the_view_and_not_in_the_draft(self):
        # Switching state must not dirty the Save button: a state is a preview, not part of the face.
        dirty = block(code(read(EDITOR)), "private var dirty: Bool {")
        self.assertNotIn("previewChoice", dirty)


class TheMaterialRowTellsTheTruth(unittest.TestCase):
    """Glass on this device, as this device will draw it."""

    def test_the_row_asks_the_route(self):
        note = block(code(read(EDITOR)), "private var glassSurfaceNote: String {")
        self.assertIn("BotAvatarGlassRoute.drawn(material: material,", note)
        self.assertIn("side: Self.previewSide,", note)
        self.assertIn("reduceTransparency: reduceTransparency", note)
        # …through the environment the preview itself reads, so the two cannot disagree.
        self.assertIn("@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency",
                      code(read(EDITOR)))

    def test_the_row_asks_the_one_decision_and_does_not_make_its_own(self):
        # `drawn` is `decide` under a name for a caller with no view; the editor never re-implements
        # the four guards and never calls `decide` itself (that would be a second call site).
        self.assertNotIn("BotAvatarGlassRoute.decide(", code(read(EDITOR)))
        self.assertNotIn("BotAvatarGlassShader", code(read(EDITOR)),
                         "the editor reads neither the floor nor the process probe for itself")
        drawn = block(code(read(ROUTE)), "public static func drawn(")
        self.assertEqual(re.findall(r"decide\(", drawn), ["decide("],
                         "the wrapper must be one delegation to the one decision")

    def test_each_answer_has_its_own_sentence(self):
        note = block(code(read(EDITOR)), "private var glassSurfaceNote: String {")
        # One branch per route, and only the two routes there are.
        self.assertEqual(re.findall(r"case \.(\w+):", note), ["metal", "canvas"])
        metal = note.split("case .metal:")[1].split("case .canvas:")[0]
        canvas = note.split("case .canvas:")[1]
        self.assertIn('"Drawn as a lit, refracting surface on this device."', metal)
        self.assertIn('"Drawn as a painted surface on this device.', canvas)
        self.assertNotIn("refract", canvas, "the painter does not refract")
        # Reduce Transparency is a reason a person can act on, so it is named.
        self.assertIn("Reduce Transparency is on", canvas)

    def test_the_row_never_promises_more_than_the_platform_can_do(self):
        source = code(read(EDITOR))
        for claim in ("3D", "3-D", "three-dimensional", "raytraced", "raymarched", "always drawn by"):
            self.assertNotIn(claim, source, f"the editor claims {claim}")

    def test_the_note_is_asked_about_the_size_the_preview_draws(self):
        # `previewSide` and the `size:` the view is drawn at are two spellings of one number; if they
        # drift, the row answers about a body that is not on screen.
        side = re.search(r"static let previewSide: Double = (\d+)", code(read(EDITOR)))
        self.assertIsNotNone(side)
        drawn_at = re.search(r"size: (\d+)", editor_preview())
        self.assertIsNotNone(drawn_at)
        self.assertEqual(side.group(1), drawn_at.group(1))

    def test_the_note_appears_only_under_glass(self):
        # Solid, Matte and Metal have one drawing each; a sentence about the shader under them would
        # be about someone else's material.
        row = block(code(read(EDITOR)), "private var materialRow: some View {")
        self.assertIn("if material == .glass {", row)
        self.assertLess(row.index("if material == .glass {"), row.index("Text(glassSurfaceNote)"))


class TheStripCannotSlowTheSheet(unittest.TestCase):
    """Nine chips, no scroll view, no reflow, no second colour or font."""

    def test_it_wraps_instead_of_scrolling(self):
        strip = block(code(read(EDITOR)), "private var stateStrip: some View {")
        self.assertNotIn("ScrollView", strip)
        self.assertIn("LazyVGrid(columns: [GridItem(.adaptive(minimum:", strip)

    def test_a_chip_s_width_comes_from_its_column_not_its_selection(self):
        chip = editor_chip()
        # The only things `chosen` may steer are colours and the accessibility trait.
        for line in chip.splitlines():
            if "chosen ?" not in line:
                continue
            self.assertTrue(any(token in line for token in
                                ("foregroundStyle", "fill(", "strokeBorder", "accessibilityAddTraits")),
                            f"selection changes more than colour here: {line.strip()}")
        # …so the font, the padding and the height are the same chosen or not.
        for fixed in (".padding(.horizontal, 8)", ".frame(height: 26)"):
            self.assertIn(fixed, chip)

    def test_the_chips_use_the_house_tokens_and_no_new_ones(self):
        chip = editor_chip()
        self.assertIn("TypeScale.font(TypeScale.sm", chip)
        used = set(re.findall(r"Tokens\.(\w+)", chip))
        self.assertTrue(used <= {"accent", "textSecondary", "controlActive", "border", "radiusControl"}, used)
        self.assertNotRegex(chip, r"#[0-9A-Fa-f]{3,6}", "a hex literal is a second palette")


class EveryChipIsAnnounced(unittest.TestCase):
    """A chip is a button with a name and a selected trait."""

    def test_it_has_a_label_and_a_selected_trait(self):
        chip = editor_chip()
        self.assertIn(".accessibilityLabel(Text(title))", chip)
        self.assertIn(".accessibilityAddTraits(chosen ? [.isSelected] : [])", chip)
        # The label is the chip's own word, so "Blocked" is read and not "chip 7".
        self.assertIn("Text(title)", chip)

    def test_the_selection_is_computed_from_the_id(self):
        # Two states with one id are the same state — the renderer's own rule — so the strip must not
        # compare cases, which would leave the example chip unselectable.
        self.assertIn("let chosen = previewChoice.id == choice.id", editor_chip())


if __name__ == "__main__":
    unittest.main()
