"""The reference motion model must live *inside* `BotAvatarMotion`, not beside it.

A rewrite of that file once left every new declaration at file scope, after the enum's closing
brace: `BotAvatarMotion.frame` did not exist and `easeInOut` was out of scope, so nothing built —
while the Python suite stayed green because it only greps for strings. This measures nesting.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Sources" / "HermeyUI" / "BotAvatarMotion.swift").read_text()


def depths(text: str) -> dict[str, int]:
    """Brace depth at the line that declares each interesting symbol."""
    found: dict[str, int] = {}
    depth = 0
    for line in text.split("\n"):
        code = re.sub(r"//.*", "", line)
        # Depth *before* this line opens anything: a declaration one level in sits at depth 1, and
        # a declaration at file scope sits at 0 — which is the distinction this test is about.
        for key in ("enum BotAvatarMotion {", "static func frame(activity",
                    "struct Frame: Equatable", "static func sample(",
                    "static func eyePose(activity", "extension BotAvatarPose {"):
            if key in line:
                found.setdefault(key, depth)
        depth += code.count("{") - code.count("}")
    return found


class TheModelIsNested(unittest.TestCase):
    def test_the_frame_model_is_inside_the_enum(self) -> None:
        found = depths(SOURCE)
        self.assertIn("enum BotAvatarMotion {", found)
        enum_depth = found["enum BotAvatarMotion {"]  # 0: the enum is a top-level declaration
        for key in ("static func frame(activity", "struct Frame: Equatable",
                    "static func sample(", "static func eyePose(activity"):
            self.assertIn(key, found, f"{key} is missing altogether")
            self.assertGreater(found[key], enum_depth,
                               f"{key} sits beside the enum, not inside it")

    def test_the_pose_extension_stays_outside(self) -> None:
        found = depths(SOURCE)
        self.assertEqual(found.get("extension BotAvatarPose {"), 0,
                         "an extension at file scope is right; a nested one is not")

    def test_braces_balance(self) -> None:
        code = re.sub(r"//.*", "", SOURCE)
        self.assertEqual(code.count("{"), code.count("}"))
