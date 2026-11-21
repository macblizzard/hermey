"""Every capability a new install must have arrives as a bundled skill.

Standing decision, 2026-11-19: a feature that a bot cannot discover does not exist for the user. When
a host needs a bot to know something for a Hermey app feature to work — the Mac bridge, the desktop a
bot draws on — the instruction ships **inside the host service** and is rendered on every start, so
a fresh install has it without anybody copying files.

The Python bridge used to own this. Since the bridge was removed, the templates live in
`hermeyd/assets/agent-skills/` and are embedded into the binary by `hermeyd/src/skills.rs`; the
installer half is covered by that module's own Rust tests (`cargo test` in `hermeyd/`).

This file pins the mechanism rather than one skill's wording:

* every directory under `agent-skills/` is a skill, and every one of them is embedded;
* each template is loadable by Hermes (frontmatter first line, name matching its directory, a
  description the index can print) and marked as ours so a template update may replace it;
* the desktop skill stays about the host's screen, never the owner's Mac.
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "hermeyd" / "assets" / "agent-skills"
SKILLS_RS = (ROOT / "hermeyd" / "src" / "skills.rs").read_text(encoding="utf-8")


class TheBundleIsComplete(unittest.TestCase):
    def test_bot_desktop_ships_with_the_host(self) -> None:
        self.assertTrue((BUNDLE / "bot-desktop" / "SKILL.md").is_file())

    def test_the_mac_skill_is_still_there(self) -> None:
        self.assertTrue((BUNDLE / "mac-local-computer" / "SKILL.md").is_file())

    def test_every_bundled_directory_is_declared(self) -> None:
        """A skill nobody embeds is a file, not a feature.

        Retargeted from `hermes_bridge/agent_skills.py::BUNDLED_SKILLS` (deleted with the Python
        bridge): the declaration is now the `include_str!` beside each skill's name.
        """
        on_disk = {p.parent.name for p in BUNDLE.glob("*/SKILL.md")}
        for name in on_disk:
            self.assertIn(f'../assets/agent-skills/{name}/SKILL.md', SKILLS_RS,
                          f"{name} is on disk but skills.rs never embeds it")

    def test_the_embedded_bundle_is_the_one_in_the_tree(self) -> None:
        """The old `package_data` test, in Rust terms: `include_str!` is the packaging."""
        self.assertIn('include_bytes!("../assets/agent-skills/bin/local_computer.py")', SKILLS_RS)


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


class TheyAreSeparateCapabilities(unittest.TestCase):
    """Owner, 2026-11-19: "computer use / local Mac access and bot desktop are different skills".

    One is about the owner's Mac, reachable through the host service with a CLI per command; the
    other is about the host's own screen, which exists whether or not a Mac is ever paired. Bundling
    them together would be a mistake in either direction: a host with no Mac still needs a desktop,
    and a desktop instruction is useless where a bot needs to run `xcodebuild`.

    The installer half ("a CLI failure still installs the desktop skill", `needs_cli`) moved to
    `hermeyd/src/skills.rs`, which has its own tests — `without_the_cli_only_the_skill_that_needs_it`
    `_is_held_back` and `scripts_land_executable_beside_the_cli_and_render_their_path`.
    """

    def test_the_desktop_skill_does_not_talk_about_the_mac(self) -> None:
        text = (BUNDLE / "bot-desktop" / "SKILL.md").read_text(encoding="utf-8").lower()
        for term in ("macbook", "local_computer", "xcode", "hermey app"):
            self.assertNotIn(term, text, f"the desktop skill is not the Mac skill: {term}")
