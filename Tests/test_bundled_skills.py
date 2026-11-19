"""Every capability a new install must have arrives as a bundled skill.

Standing decision, 2026-11-19: a feature that a bot cannot discover does not exist for the user. When
a host needs a bot to know something for a Hermey app feature to work — the Mac bridge, the desktop a
bot draws on — the instruction ships **inside the bridge package** and is rendered on every start, so
a fresh install has it without anybody copying files.

This file pins the mechanism rather than one skill's wording:

* every directory under `agent_skills/` is a skill, and every one of them is installed;
* each template is loadable by Hermes (frontmatter first line, name matching its directory, a
  description the index can print) and marked as ours so a template update may replace it;
* a bot's own edit is never destroyed, and a user's own skill of that name is never touched;
* `status()` reports each skill, so the app can tell "installed" from "today's rules".
"""

import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "Bridge" / "hermes_bridge" / "agent_skills"

sys.path.insert(0, str(ROOT / "Bridge"))
try:
    from hermes_bridge import agent_skills  # noqa: E402
except ImportError as error:  # noqa: BLE001 - the hygiene job runs this suite on a bare interpreter
    agent_skills = None
    IMPORT_ERROR = error
else:
    IMPORT_ERROR = None


class TheBundleIsComplete(unittest.TestCase):
    def test_bot_desktop_ships_with_the_bridge(self) -> None:
        self.assertTrue((BUNDLE / "bot-desktop" / "SKILL.md").is_file())

    def test_the_mac_skill_is_still_there(self) -> None:
        self.assertTrue((BUNDLE / "mac-local-computer" / "SKILL.md").is_file())

    def test_every_bundled_directory_is_declared(self) -> None:
        """A skill nobody installs is a file, not a feature."""
        if agent_skills is None:
            self.skipTest(f"bridge deps not installed: {IMPORT_ERROR}")
        declared = set(agent_skills.BUNDLED_SKILLS)
        on_disk = {p.parent.name for p in BUNDLE.glob("*/SKILL.md")}
        self.assertEqual(declared, on_disk, f"declared {declared} but on disk {on_disk}")

    def test_the_package_data_carries_them_into_the_wheel(self) -> None:
        """`setup/install.sh` pip-installs a built package; an unlisted file never arrives."""
        pyproject = (ROOT / "Bridge" / "pyproject.toml").read_text()
        self.assertIn('"agent_skills/*/*.md"', pyproject)


class EveryTemplateIsLoadable(unittest.TestCase):
    def test_frontmatter_and_name_match_the_directory(self) -> None:
        for skill in sorted(BUNDLE.glob("*/SKILL.md")):
            with self.subTest(skill=skill.parent.name):
                text = skill.read_text(encoding="utf-8")
                self.assertTrue(text.startswith("---\n"), "Hermes reads frontmatter from line one")
                self.assertIn(f"name: {skill.parent.name}", text)

    def test_the_description_fits_the_index(self) -> None:
        for skill in sorted(BUNDLE.glob("*/SKILL.md")):
            with self.subTest(skill=skill.parent.name):
                text = skill.read_text(encoding="utf-8")
                line = next(l for l in text.splitlines() if l.startswith("description:"))
                description = line.split(":", 1)[1].strip().strip('"')
                self.assertLessEqual(len(description), 60, description)

    def test_ours_to_update(self) -> None:
        """Without the marker an update is refused as `foreign` and users keep old instructions."""
        for skill in sorted(BUNDLE.glob("*/SKILL.md")):
            with self.subTest(skill=skill.parent.name):
                self.assertIn("managed_by: hermey-bridge", skill.read_text(encoding="utf-8"))


class TheDesktopSkillSaysTheThingsThatWentWrong(unittest.TestCase):
    """Written from two real failures: a bot used the owner's own display and reported success."""

    def setUp(self) -> None:
        self.text = (BUNDLE / "bot-desktop" / "SKILL.md").read_text(encoding="utf-8")

    def test_it_points_at_the_canonical_display_file(self) -> None:
        self.assertIn("bot-desktop/display", self.text)

    def test_it_forbids_other_displays(self) -> None:
        self.assertIn("Never use a display that is not the one in", self.text)

    def test_it_says_a_launcher_exit_code_is_not_proof(self) -> None:
        self.assertIn("exits 0", self.text)
        self.assertIn("Prove the window landed", self.text)

    def test_it_warns_that_the_browser_profile_is_shared(self) -> None:
        self.assertIn("shared", self.text.lower())
        self.assertIn("browser-profile", self.text)


if __name__ == "__main__":
    unittest.main()
