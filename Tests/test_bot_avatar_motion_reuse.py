"""The drawn avatar performs the motions the shape face already has — one motion language, not two.

Reported by Mohammad, 2026-11-24:

> and what about the motions? I cont see any motion on the bot avatar now, would it be possible to
> use the same motions that we already have?

The generated avatar (`OpenBotAvatarView`) arrived with its own, much calmer motion: it breathes and
sways at 10 Hz, and nothing else. The shape-and-palette face it replaced has had `BotAvatarMotion`
(the reference's acting) plus `BotAvatarPerformance` (the jump, the flip, the darts, the squint)
since 0.1.6xx. The fix is a hand-over, not a port: `BotAvatarView`'s drawn branch asks
`BotAvatarMotion.performedFrame` for the same frame the shape path draws, on the same clock, and
applies its body as the outer transform; the frame's eyes go down through one optional parameter so
the drawn eyes blink and dart on the existing schedule.

What this file pins, all of it readable out of the Swift:

* the drawn branch calls `BotAvatarMotion.performedFrame` — and no drawn-avatar file invents a
  jump, a flip, a saccade or a second motion type;
* the body transform is the shape path's own three modifiers plus its brightness, in its order;
* the eye override is **one optional input** with a nil default, and nil leaves today's behaviour
  (the avatar's own `Self.blink` clock) exactly as it was — there is no second blink clock;
* the pet draws `OpenBotAvatarView` directly, so the shared performance cannot double-apply with the
  pet's own hop, and its badge overlay and hit box are untouched;
* every calm case — Reduce Motion, `animates: false`, the app's motion switch, a background scene, a
  size below `animatingFrom` — short-circuits to `.rest`.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
AVATAR = UI / "OpenBotAvatar"
BOT_AVATAR_VIEW = UI / "BotAvatarView.swift"
MOTION = UI / "BotAvatarMotion.swift"
PERFORMANCE = UI / "BotAvatarPerformance.swift"
STATE = AVATAR / "OpenBotAvatarState.swift"
VIEW = AVATAR / "OpenBotAvatarView.swift"
OVERRIDE = AVATAR / "OpenBotAvatarEyeOverride.swift"
PET = ROOT / "Apps" / "HermesMac" / "Pets" / "PetView.swift"
PET_BADGE = ROOT / "Apps" / "HermesMac" / "Pets" / "PetBadge.swift"
PET_PANEL = ROOT / "Apps" / "HermesMac" / "Pets" / "DesktopPetPanel.swift"
MAC_SETTINGS_SHEET = ROOT / "Apps" / "HermesMac" / "Views" / "MacBotSettingsSheet.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code(path: Path) -> str:
    """The file with its comments removed: prose naming a symbol is not the symbol."""
    return "\n".join(line.split("//")[0] for line in read(path).splitlines())


def swift_declaration(text: str, marker: str) -> str:
    """The brace-balanced body of the first declaration containing `marker`.

    A line-wise grep is how a modifier ten lines below a call site gets missed; the whole body is
    the unit that has to be right here, so the helper walks the braces rather than splitting lines.
    """
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
    raise AssertionError(f"{marker!r} has no balanced body")


class TheDrawnBranchReusesOneMotionLanguage(unittest.TestCase):
    def setUp(self) -> None:
        self.source = read(BOT_AVATAR_VIEW)
        self.drawn = swift_declaration(self.source, "private func drawnBody(")
        self.shape = swift_declaration(self.source, "private func content(")
        # The frame chooser itself: a result builder cannot hold an `if` that assigns, so both
        # branches ask one helper instead of repeating the ladder.
        self.helper = swift_declaration(self.source, "private func motionFrame(")

    def test_the_drawn_branch_asks_for_the_shared_frame(self) -> None:
        self.assertIn("motionFrame(at: time, traits: traits, moves: moves, awake: awake)", self.drawn,
                      "the drawn branch no longer asks the one frame chooser for its frame")
        self.assertEqual(self.helper.count("BotAvatarMotion.performedFrame("), 1,
                         "the frame chooser no longer asks the shape face's motion for its frame")
        for argument in ("activity: activity",
                         "traits: traits",
                         "at: time",
                         "side: Double(size)"):
            self.assertIn(argument, self.helper, f"the drawn frame is missing {argument!r}")
        # `time` is the timeline's own date, hoisted so the wake frame can share it.
        self.assertIn("let time = context.date.timeIntervalSinceReferenceDate", self.drawn)

    def test_both_branches_call_the_same_function(self) -> None:
        # One call site, two callers: the shape body and the drawn body both ask `motionFrame`, and
        # `motionFrame` is the only thing that asks the motion for a frame.
        self.assertEqual(self.source.count("BotAvatarMotion.performedFrame("), 1,
                         "a second motion source has appeared")
        self.assertEqual(self.source.count("motionFrame(at: time, traits: traits, moves: moves, awake: awake)"), 2,
                         "one of the two branches stopped asking the shared frame chooser")

    def test_the_body_is_applied_the_way_the_shape_path_applies_it(self) -> None:
        # The shape path first, so the drawn one is checked against what it is copying.
        for shape_expression in (".scaleEffect(x: body.scaleX, y: body.scaleY)",
                                 ".rotationEffect(.degrees(body.rotate))",
                                 ".offset(x: body.translateX * size, y: body.translateY * size)",
                                 ".brightness(body.brightness)"):
            self.assertIn(shape_expression, self.shape,
                          f"the shape path no longer applies {shape_expression!r}")
        for drawn_expression in (".scaleEffect(x: frame.body.scaleX, y: frame.body.scaleY)",
                                 ".rotationEffect(.degrees(frame.body.rotate))",
                                 ".offset(x: frame.body.translateX * size, y: frame.body.translateY * size)",
                                 ".brightness(frame.body.brightness)"):
            self.assertIn(drawn_expression, self.drawn,
                          f"the drawn avatar does not apply {drawn_expression!r}")

    def test_the_clock_is_the_shape_paths_clock(self) -> None:
        shape = swift_declaration(self.source, "private var shapeBody:")
        self.assertIn("BotAvatarMotion.frameInterval(for: activity)", shape)
        self.assertIn("BotAvatarMotion.frameInterval(for: activity)", self.drawn,
                      "the drawn branch runs on its own interval instead of the face's")
        self.assertIn("paused: !moves", self.drawn)
        # No hard-coded cadence in the drawn branch: the interval comes from the motion model.
        self.assertNotIn("0.1", self.drawn)
        # And the drawn avatar's own 10 Hz breathing constant is still there, untouched.
        self.assertIn("frameInterval = 0.1", read(VIEW))

    def test_no_drawn_avatar_file_invents_a_motion(self) -> None:
        # The performance vocabulary lives in one place; a `struct OpenBotAvatarMotion` (or a jump
        # track) inside the renderer would be the second language this change exists to avoid.
        for path in sorted(AVATAR.rglob("*.swift")):
            text = code(path)
            with self.subTest(file=path.name):
                self.assertIsNone(re.search(r"\b(struct|enum|class)\s+\w*Motion\b", text),
                                  f"{path.name} declares a motion type")
                for word in ("jumpY", "flipTuck", "saccadeTravel", "stuntTravel"):
                    self.assertNotIn(word, text, f"{path.name} re-implements {word}")

    def test_the_shared_view_declares_no_new_view_types(self) -> None:
        declared = set(re.findall(r"\b(?:public )?struct (\w+)", read(BOT_AVATAR_VIEW)))
        self.assertEqual(declared, {"BotAvatarView", "BotAvatarRing"},
                         "a new type appeared beside the two faces")


class TheEyesAreHandedOverNotSecondClocked(unittest.TestCase):
    def setUp(self) -> None:
        self.view = read(VIEW)
        self.state = read(STATE)
        self.override = read(OVERRIDE)

    def test_the_override_is_one_optional_input(self) -> None:
        self.assertIn("public var eyeOverride: OpenBotAvatarEyeOverride?", self.view)
        self.assertIn("eyeOverride: OpenBotAvatarEyeOverride? = nil", self.view)
        # One parameter, passed straight into the pose: no second parallel option beside it.
        self.assertIn("eyeOverride: eyeOverride", self.view)
        self.assertEqual(self.view.count("OpenBotAvatarEyeOverride?"), 2,
                         "the drawn view took more than one optional eye input")

    def test_the_state_applies_it_last_and_only_when_given(self) -> None:
        self.assertIn("eyeOverride: OpenBotAvatarEyeOverride? = nil", self.state)
        pose = swift_declaration(self.state, "public func pose(mood:")
        guard = pose[pose.index("if let eyeOverride {"):]
        for channel in ("pose.blink = eyeOverride.blink",
                        "pose.gazeX = eyeOverride.gazeX",
                        "pose.gazeY = eyeOverride.gazeY",
                        "pose.squint = eyeOverride.squint"):
            self.assertIn(channel, guard, f"the override no longer feeds {channel!r}")

    def test_nil_keeps_the_drawn_avatars_own_blink_clock(self) -> None:
        # The idle clock is still there, unsuppressed, for every caller that passes nothing.
        self.assertIn("pose.blink = reducedMotion ? 0 : Self.blink(seed: seed, time: t)", self.state)
        self.assertIn("static func blink(seed: UInt32, time: Double) -> Double", self.state)
        self.assertIsNone(re.search(r"static func blink\(seed.*eyeOverride", self.state),
                          "the drawn blink clock grew an override parameter")

    def test_the_override_reads_the_frame_and_has_no_clock(self) -> None:
        self.assertIn("public init(eyes: BotAvatarEyePose)", self.override)
        self.assertIn("1 - eyes.scaleY", self.override)
        self.assertIn("eyes.offsetX * Self.gazeGainX", self.override)
        self.assertIn("eyes.offsetY * Self.gazeGainY", self.override)
        # Both gains come off the renderer's own declared travel, not a taste constant.
        self.assertIn("OpenBotAvatarGeometry.gazeX", self.override)
        self.assertIn("OpenBotAvatarGeometry.gazeY", self.override)
        for forbidden in ("func blink(", "Date(", "Task.sleep", "TimelineView", "sin("):
            self.assertNotIn(forbidden, self.override,
                             f"the eye override runs a clock of its own ({forbidden})")

    def test_the_override_is_built_only_from_the_shared_frame(self) -> None:
        sites = [path for path in ROOT.rglob("*.swift")
                 if "/.build/" not in str(path) and ".git" not in str(path)
                 and "OpenBotAvatarEyeOverride(eyes:" in read(path)]
        self.assertEqual([path.name for path in sites], ["BotAvatarView.swift"],
                         "a surface builds its own eye pose instead of the shared frame's")
        drawn = swift_declaration(read(BOT_AVATAR_VIEW), "private func drawnBody(")
        self.assertIn("eyeOverride: (moves || awake) ? OpenBotAvatarEyeOverride(eyes: frame.eyes) : nil", drawn,
                      "the override is applied even when the face is holding still")

    def test_the_rest_pose_channels_of_the_drawn_face_are_untouched(self) -> None:
        # The eye override supersedes blink, gaze and squint; the channels it does not own are still
        # set where they were — the mood's arc, the face's lean, and the ribbons a turn sweeps.
        for channel in ("pose.arch = 1", "pose.tilt = 0.32", "pose.ribbons = min(1"):
            self.assertIn(channel, self.state, f"the eye override work dropped {channel!r}")


class ThePetKeepsItsOwnLayer(unittest.TestCase):
    def setUp(self) -> None:
        self.pet = read(PET)

    def test_the_pet_draws_the_drawn_view_directly(self) -> None:
        self.assertIn("OpenBotAvatarView(definition: avatar.definition,", self.pet)
        # Not through `BotAvatarView`: that is the view that now performs the shared hop and flip,
        # and a pet has its own. (`OpenBotAvatarView(` contains the shorter name, hence the
        # lookbehind rather than a plain substring.)
        self.assertIsNone(re.search(r"(?<![A-Za-z])BotAvatarView\(", code(PET)),
                          "the pet went through the shared face and now performs motion twice")
        self.assertNotIn("performedFrame", code(PET))
        self.assertNotIn("eyeOverride", code(PET),
                         "the pet's avatar took the shared eye schedule as well as its own lid")

    def test_the_badge_rides_the_box_the_hit_test_is_told(self) -> None:
        badge = self.pet.index(".overlay(alignment: .topTrailing)")
        frame = self.pet.index(".frame(width: side, height: side)")
        motion = self.pet.index(".scaleEffect(motion.scale)")
        self.assertLess(frame, badge, "the badge is no longer anchored to the pet's own box")
        self.assertLess(badge, motion, "the badge stopped travelling with the pet's motion")
        self.assertIn("PetUnreadBadge(count: pet.unread)", self.pet)

    def test_the_hit_box_is_the_same_box(self) -> None:
        # The badge the hit test knows about is `PetBadge.rect`; nothing here moved it.
        self.assertIn("PetBadge.contains(iconPoint, iconSide: iconMask.side)", read(PET_PANEL))
        badge = read(PET_BADGE)
        self.assertIn("static func contains(", badge)
        self.assertIn("rect(", badge)


class EveryCalmCaseHoldsTheRestPose(unittest.TestCase):
    def setUp(self) -> None:
        self.drawn = swift_declaration(read(BOT_AVATAR_VIEW), "private func drawnBody(")

    def test_every_gate_is_the_shape_paths(self) -> None:
        for gate in ("BotAvatarMotion.allows(",
                     "reduceMotion: reduceMotion || systemReduceMotion",
                     "animates: animates && appAllowsMotion",
                     "&& scenePhase == .active",
                     "minimumSize: animatingFrom",
                     "paused: !moves && !awake"):
            self.assertIn(gate, self.drawn, f"the drawn branch lost the {gate!r} gate")

    def test_no_motion_means_the_rest_frame(self) -> None:
        helper = swift_declaration(read(BOT_AVATAR_VIEW), "private func motionFrame(")
        self.assertIn("return .rest", helper)
        self.assertIn("eyeOverride: (moves || awake) ? OpenBotAvatarEyeOverride(eyes: frame.eyes) : nil",
                      self.drawn)

    def test_the_app_switch_reaches_the_drawn_breath_too(self) -> None:
        # The drawn branch used to pass `animates: animates`, so Settings → Appearance could not
        # stop a generated face at all.
        self.assertIn("animates: (animates || awake) && appAllowsMotion,", self.drawn)

    def test_the_floor_and_its_callers_are_unchanged(self) -> None:
        self.assertIn("animatingFrom: Double = BotAvatarMotion.minimumAnimatingSize",
                      read(BOT_AVATAR_VIEW))
        # A 26 pt face in a settings sheet is still static by its caller's own word, so the drawn
        # branch cannot start performing there.
        sheet = read(MAC_SETTINGS_SHEET)
        self.assertIn("size: 26,", sheet)
        self.assertIn("animates: false", sheet)


if __name__ == "__main__":
    unittest.main()
