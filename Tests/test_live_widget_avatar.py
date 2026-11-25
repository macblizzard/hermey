"""The bot's own face on the Live Activity: one renderer, eight states, one clock.

The owner: "animated bot avatar on iOS live widget". The card had never drawn the bot — it drew an SF
Symbol — so this is not a restyle of a drawing that was already there: it is the app's avatar, in a
second process.

Everything here is Swift that cannot run on this machine (ActivityKit and WidgetKit are iOS; a widget
is its own process and has no simulator here), so the contract is pinned from source the way
`test_live_activity.py` pins the rest of the feature:

* **one renderer.** The extension compiles `Sources/HermeyUI/OpenBotAvatar` in (`project.yml`) — the
  same files `HermeyUI` builds — and the card's view calls `OpenBotAvatarRenderer.draw` and
  `OpenBotAvatarState.pose`. Nothing in the extension may contain an eye, a blink, a gaze, a squint
  or a `sin`: a second motion language is how the Lock Screen comes to blink on a different clock
  from the chat header;
* **one cadence.** The frame interval is `OpenBotAvatarView.frameInterval`, asked for by name. A
  literal `0.1` in the widget would be a second animation that drifts from the first, and a number
  nobody would remember to change twice;
* **one resolution path.** The face is a stored document, resolved through `BotAvatarLibrary` from the
  activity's attributes. It may not be a bitmap: `PushIcon`/`MobileFaceCache` render PNGs for banners,
  and a PNG in the card would be the old shape at the old size, frozen;
* **one vocabulary.** The state word is `BotStateWord`'s; the extension may not spell one of the eight
  itself, and the state it draws comes from `ContentState.botState`, not from a second mapping of
  phases invented in the view;
* **one cost.** The definition is decoded once per distinct face, not once per frame and not once per
  update, and a frame is a pose plus a fill.

What a device has to confirm (none of it assertable from source): that the extension is embedded and
signed with the avatar's sources compiled in, that the card actually advances frames while the Lock
Screen is on, how many of the requested 10 Hz frames iOS composites, that Always-On pauses it, and
that the face is legible at card size over the wallpaper.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXT = ROOT / "Apps" / "HermesLiveActivity"
AVATAR = ROOT / "Sources" / "HermeyUI" / "OpenBotAvatar"

FACE = (EXT / "HermeyTurnFace.swift").read_text(encoding="utf-8")
WIDGET = (EXT / "HermeyTurnLiveActivity.swift").read_text(encoding="utf-8")
ATTRIBUTES = (EXT / "HermeyTurnAttributes.swift").read_text(encoding="utf-8")
VIEW = (AVATAR / "OpenBotAvatarView.swift").read_text(encoding="utf-8")
STATE = (AVATAR / "OpenBotAvatarState.swift").read_text(encoding="utf-8")
RENDERER = (AVATAR / "OpenBotAvatarRenderer.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "Apps" / "HermesMobile" / "Views" / "LiveActivityCoordinator.swift").read_text(encoding="utf-8")
SHELL = (ROOT / "Apps" / "HermesMobile" / "HermesMobileApp.swift").read_text(encoding="utf-8")
WORDS = (ROOT / "Sources" / "HermesKit" / "BotStateWord.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "project.yml").read_text(encoding="utf-8")

STATES = ["idle", "thinking", "reading", "working", "computer", "waiting", "blocked", "done"]


def code(source: str) -> str:
    """A Swift source with its `//` comments stripped: prose may name what the code may not do."""
    kept = []
    for line in source.splitlines():
        marker = line.find("//")
        kept.append(line if marker == -1 else line[:marker])
    return "\n".join(kept)


def braced(source: str, start: int) -> str:
    """The contents of the first brace-balanced block at or after `start`."""
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    raise AssertionError("block is not closed")


def piece(source: str, declaration: str) -> str:
    return braced(source, source.index(declaration))


class TheWidgetDrawsWithTheAppsRenderer(unittest.TestCase):
    """No second implementation: the extension compiles the drawing in and calls it."""

    def test_the_renderer_and_the_pose_are_the_apps_own(self) -> None:
        drawn = code(FACE)
        self.assertIn("OpenBotAvatarRenderer.draw(face.model", drawn)
        self.assertIn("state.pose(mood: mood, time: time, seed: face.seed, reducedMotion: still)", drawn)
        self.assertIn("OpenBotAvatarModel.model(for: resolved.definition)", drawn)
        # The volume, the silhouette and the eye shape are not re-derived here.
        for forbidden in ("addPath(", "silhouette", "OpenBotAvatarVolume(", "Polygon("):
            self.assertNotIn(forbidden, drawn, f"the widget re-derives the body: {forbidden}")

    def test_no_eye_or_blink_maths_lives_in_the_extension(self) -> None:
        # The four channels a second avatar implementation grows first: its own clock, its own blink,
        # its own look, its own squint.
        drawn = code(FACE)
        for forbidden in ("sin(", "cos(", "noise(", "blink(", "wander(", "dart(", "squint",
                          "gazeX", "gazeY", "truncatingRemainder"):
            self.assertNotIn(forbidden, drawn, f"the widget pens its own {forbidden}")
        # …and the whole extension, not just the file that draws: the card's own file must not have
        # started drawing an eye either.
        self.assertNotIn("eye", code(WIDGET).lower().replace("eyes are", ""))

    def test_the_canvas_only_transforms_what_the_model_built(self) -> None:
        # The renderer's cost note: paths are built once per definition, a frame only fills them.
        self.assertIn("Every path this draws is built once", RENDERER)
        self.assertIn("public static func model(for definition: BotAvatarDefinition)", RENDERER)

    def test_the_extension_compiles_the_drawing_rather_than_linking_the_package(self) -> None:
        # The same rule as `BotStateWord.swift`: one file, two processes, no module in common.
        self.assertIn("- path: Sources/HermeyUI/OpenBotAvatar", PROJECT)
        self.assertIn('excludes:\n          - "OpenBotAvatarEditor.swift"', PROJECT)
        for required in ("BotAvatarIdentity.swift", "BotAvatarShape.swift",
                         "BotAvatarPalette.swift", "BotAvatarLibrary.swift"):
            self.assertIn(f"- path: Sources/HermeyUI/{required}", PROJECT)
        # …and no drawing file imports the app's stack outright: the one `HermesKit` import there is
        # is the activity bridge, behind `canImport`, and it is the only one.
        bridged = []
        for path in sorted(AVATAR.glob("*.swift")):
            source = path.read_text(encoding="utf-8")
            if "import HermesKit" in source:
                bridged.append(path.name)
                self.assertIn("#if canImport(HermesKit)\nimport HermesKit\n#endif", source,
                              f"{path.name} imports HermesKit outside a guard")
            self.assertNotIn("\nimport HermesAppKit\n", source, f"{path.name} links the app")
        self.assertEqual(bridged, ["OpenBotAvatarView.swift"])


class TheMotionComesFromOnePlace(unittest.TestCase):
    """Ten frames a second, from the constant the app animates at, and no other number."""

    def test_the_cadence_is_the_apps_own_constant(self) -> None:
        self.assertIn("TimelineView(.animation(minimumInterval: OpenBotAvatarView.frameInterval, paused: still))",
                      FACE)
        # The constant is declared once, in the view the app draws.
        self.assertIn("public static let frameInterval = 0.1", VIEW)
        self.assertEqual(VIEW.count("static let frameInterval"), 1)
        # Every avatar surface asks for it by name; none restates the number.
        for path in (EXT / "HermeyTurnFace.swift",):
            source = code(path.read_text(encoding="utf-8"))
            self.assertNotIn("minimumInterval: 0.1", source, f"{path.name} restates the cadence")

    def test_the_clock_is_the_one_the_app_feeds_the_pose(self) -> None:
        # The same quantity as `OpenBotAvatarView` (the reference date), so the card's face is at the
        # same point of the same wave as the roster's rather than on a clock of its own.
        self.assertIn("context.date.timeIntervalSinceReferenceDate", VIEW)
        self.assertIn("date.timeIntervalSinceReferenceDate", FACE)
        self.assertEqual(code(FACE).count("Date()"), 0, "the widget reads a clock of its own")

    def test_the_pose_is_the_eight_state_function(self) -> None:
        self.assertIn("public func pose(mood: BotAvatarMood,", STATE)
        # The widget asks it for a state, and the state is one of the eight — not a phase.
        self.assertIn("let state: OpenBotAvatarState", FACE)
        self.assertIn("OpenBotAvatarState(rawValue: turn.botState)", FACE)
        for name in STATES:
            self.assertIn(f"    case {name}\n", STATE, f"{name} is missing from the states")

    def test_always_on_and_a_stale_card_hold_the_stance(self) -> None:
        # The system stops compositing animations on an Always-On Lock Screen; asking for frames
        # there is a battery bug, not a feature. A stale card is the same: the app could not update
        # it, so it holds what is still true.
        self.assertIn("isLuminanceReduced", FACE)
        self.assertIn("private var still: Bool { isStale || luminanceReduced }", FACE)
        self.assertIn("paused: still", FACE)
        self.assertIn("let time = still ? 0 : date.timeIntervalSinceReferenceDate", FACE)


class TheFaceIsResolvedNotSnapshotted(unittest.TestCase):
    """A stored definition, through the library — never a bitmap of the old shape."""

    def test_the_definition_arrives_in_the_activity(self) -> None:
        self.assertIn("public var face: Face?", ATTRIBUTES)
        self.assertIn("public var definition: String?", ATTRIBUTES)
        # Static, not per update: a turn belongs to one bot, so the face is written at `request`.
        self.assertIn("let attributes = HermeyTurnAttributes(botName: name, face: faceForSelectedBot())",
                      COORDINATOR)
        self.assertIn("document.definitionJSON()", COORDINATOR)
        self.assertIn("document.material.rawValue", COORDINATOR)

    def test_it_is_resolved_through_the_library(self) -> None:
        prepared = piece(FACE, "static func prepare(_ face:")
        self.assertIn("BotAvatarDocument(json: definition", prepared)
        self.assertIn("BotAvatarLibrary(avatars: [botID: document])", prepared)
        self.assertIn("guard let resolved = library[botID]", prepared)
        # The document's own initialiser is the host's validator — one rule for both processes.
        self.assertIn("public init?(json definitionJSON: String", VIEW)

    def test_it_is_not_a_bitmap(self) -> None:
        # `PushIcon` and `MobileFaceCache` render PNGs for notification banners. A card that drew one
        # would be the shape face at one size with no state and no motion.
        drawn = code(FACE) + code(WIDGET)
        for forbidden in ("PushIcon", "MobileFaceCache", "ImageRenderer", "UIImage", "Image(uiImage",
                          "png", "Image(\""):
            self.assertNotIn(forbidden, drawn, f"the card draws a picture: {forbidden}")

    def test_the_decode_happens_once_per_face_not_per_frame(self) -> None:
        store = piece(FACE, "enum HermeyTurnFaceStore")
        self.assertIn("if let hit = cache[key]", store)
        self.assertIn("cache[key] = prepared", store)
        # The cache is bounded, and it is cleared rather than grown.
        self.assertIn("private static let cacheLimit = 8", store)
        self.assertIn("if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }", store)
        # …and the *frame* path does no decoding at all: the model is what it was handed.
        face = piece(FACE, "struct HermeyTurnFace: View")
        for forbidden in ("BotAvatarDocument(", "BotAvatarLibrary(", "JSONDecoder", "decode("):
            self.assertNotIn(forbidden, face, f"a frame decodes: {forbidden}")

    def test_a_bot_without_a_face_keeps_the_old_card(self) -> None:
        # No definition, or one this build refuses: the phase's own symbol, at the size the card has
        # always drawn it. Nothing invents a face.
        avatar = piece(WIDGET, "private struct HermeyTurnAvatar: View")
        self.assertIn("if let prepared = HermeyTurnFaceStore.prepare(face)", avatar)
        self.assertIn("HermeyTurnMark(phase: state.phase, size: size * 0.65)", avatar)
        self.assertIn("static func prepare(_ face: HermeyTurnAttributes.Face?) -> HermeyTurnPreparedFace?",
                      FACE)
        self.assertIn("guard let face, face.isDrawn, let definition = face.definition else { return nil }",
                      FACE)


class TheCardWearsTheBotsState(unittest.TestCase):
    """The eight words, from the one vocabulary, carried to the card and worn by the face."""

    def test_the_state_travels_and_is_normalised(self) -> None:
        self.assertIn("public var botState: String", ATTRIBUTES)
        normaliser = piece(ATTRIBUTES, "public static func state(from raw:")
        self.assertIn("if let raw, BotStateWord(rawValue: raw) != nil { return raw }", normaliser)
        for phase, word in ((".working", "working"), (".needsYou", "waiting"), (".done", "done")):
            self.assertIn(f"case {phase}: return BotStateWord.{word}.rawValue", normaliser)

    def test_the_eight_words_are_the_one_table(self) -> None:
        # Nothing in the extension spells a label; it asks `BotStateWord` (compiled in, see project.yml).
        self.assertEqual(re.findall(r"^    case (\w+)$", WORDS, re.M), STATES)
        rendered = code(FACE) + code(WIDGET)
        labels = ["Idle", "Thinking", "Reading", "Working", "Using the computer",
                  "Waiting for you", "Blocked", "Done"]
        for label in labels:
            self.assertNotIn(f'"{label}"', rendered, f"the extension spells {label!r} itself")
        self.assertIn("- path: Sources/HermesKit/BotStateWord.swift", PROJECT)

    def test_the_coordinator_sends_the_state_the_tracker_reports(self) -> None:
        helper = piece(COORDINATOR, "private func botStateLine()")
        self.assertIn("model.activity(forBot: id).rawValue", helper)
        # Every state the card is handed carries it — the start, the progress, and both endings.
        for marker in ("botState: botStateLine())", "botState: state)",
                        "botState: BotAvatarActivity.done.rawValue"):
            self.assertIn(marker, COORDINATOR, marker)

    def test_a_state_change_under_an_unchanged_line_is_still_an_update(self) -> None:
        # "Running read_file" is the same sentence whether the bot is thinking or working, but the
        # pose differs — so the state is part of what decides a push.
        progress = piece(COORDINATOR, "private func progress()")
        self.assertIn("let state = botStateLine()", progress)
        self.assertIn("state != lastState", progress)

    def test_an_old_card_still_draws_its_face(self) -> None:
        # A card requested by the previous build carries no `botState` and no `face`: the decoder
        # falls back to the phase's state, and a missing face is the phase's symbol.
        decoder = ATTRIBUTES[ATTRIBUTES.index("public init(from decoder: Decoder) throws"):]
        decoder = decoder[:decoder.index("/// What the card calls a bot")]
        self.assertIn("forKey: .botState", decoder)
        self.assertIn("Self.state(from: try container.decodeIfPresent(String.self, forKey: .botState)",
                      ATTRIBUTES)
        self.assertIn("public var face: Face?", ATTRIBUTES)
        self.assertIn("if let known = OpenBotAvatarState(rawValue: turn.botState)", FACE)


class TheCardsContentAndTheActivitySurvive(unittest.TestCase):
    """The face is added to the card; the words, the width and the lifetime are untouched."""

    def test_the_card_still_draws_the_words_it_had(self) -> None:
        card = piece(WIDGET, "private struct HermeyTurnLockScreen: View")
        self.assertIn("HermeyTurnAvatar(state: state, face: face, isStale: isStale)", card)
        self.assertIn("Text(botName)", card)
        self.assertIn("HermeyTurnStatusLine(state: state,", card)
        self.assertIn("HermeyTurnSnippet(state: state, tone: .card)", card)
        self.assertIn("HermeyTurnElapsedLabel(state: state, tone: .card)", card)

    def test_the_compact_pill_is_unchanged(self) -> None:
        # A face at 13 pt is under `OpenBotAvatarView.animatingFrom` (24) and its width would widen
        # the island, so the pill keeps the mark it had and the card carries the avatar.
        for closure in ("compactLeading: {", "compactTrailing: {", "minimal: {"):
            content = braced(WIDGET, WIDGET.index(closure))
            self.assertNotIn("HermeyTurnAvatar", content, f"{closure} grew a face")
        self.assertIn("HermeyTurnMark(phase: context.state.phase, size: 15)", WIDGET)

    def test_the_animation_still_cannot_be_ended_by_the_app(self) -> None:
        # The card lives until the owner removes it; a view that animates is not a view that ends.
        self.assertNotIn(".end(", code(COORDINATOR))
        self.assertIn("paused: still", FACE)
        # …and the paused branch is a *still frame of the same pose*, not a different drawing.
        pose = piece(FACE, "private func pose(at date: Date)")
        self.assertIn("reducedMotion: still", pose)

    def test_the_shell_hands_the_faces_over_at_attach(self) -> None:
        # One entry point into the coordinator's life, as before: the faces ride the attach.
        self.assertIn("liveActivity.attach(to: app.model) { id in app.botAvatars[id] }", SHELL)
        self.assertEqual(re.findall(r"liveActivity\.\w+", SHELL), ["liveActivity.attach"])


if __name__ == "__main__":
    unittest.main()
