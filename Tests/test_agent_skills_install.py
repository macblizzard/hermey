"""The Mac skill must reach the bots by existing, not by the owner finding it.

These tests drive the real installer against a throwaway Hermes home: what it writes, where, what it
refuses to touch, and that the CLI it points at is the CLI this repo ships.
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Bridge"))

from hermes_bridge import agent_skills  # noqa: E402


class Scratch(unittest.TestCase):
    """A fake Hermes install home with a couple of profiles."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name) / ".hermes"
        self.profiles = self.home / "profiles"
        for name in ("cody", "jason"):
            (self.profiles / name).mkdir(parents=True)
        (self.home / "skills").mkdir(parents=True)
        self._env = {key: os.environ.get(key)
                     for key in ("HERMES_PROFILES_ROOT", "HERMES_SKILLS_DIR",
                                 "HERMES_BRIDGE_HOST", "HERMES_BRIDGE_PORT")}
        os.environ["HERMES_PROFILES_ROOT"] = str(self.profiles)
        os.environ.pop("HERMES_SKILLS_DIR", None)
        self.state = Path(self._tmp.name) / "state"

    def tearDown(self) -> None:
        for key, value in self._env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self._tmp.cleanup()

    def install(self) -> dict:
        """install() with the CLI landing in this test's state dir, not the host's."""

        original = agent_skills.install_cli
        agent_skills.install_cli = lambda destination=None: original(self.state / "bin" / "local_computer.py")
        try:
            return agent_skills.install()
        finally:
            agent_skills.install_cli = original


class TheSkillIsRenderedForThisHost(Scratch):
    def test_no_placeholder_survives(self) -> None:
        body = agent_skills.render(Path("/opt/hermey/bin/local_computer.py"))
        self.assertNotIn("@@", body, "a bot would be told to run a placeholder")
        self.assertIn("/opt/hermey/bin/local_computer.py", body)

    def test_it_names_the_bridge_the_cli_defaults_to(self) -> None:
        os.environ["HERMES_BRIDGE_PORT"] = "9999"
        body = agent_skills.render(Path("/x/local_computer.py"))
        self.assertIn("http://127.0.0.1:9999", body)

    def test_the_frontmatter_is_loadable_and_ours(self) -> None:
        text = agent_skills.TEMPLATE.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("---\n"), "Hermes reads frontmatter from the first line")
        self.assertIn(f"name: {agent_skills.SKILL_NAME}", text)
        self.assertIn(agent_skills.MANAGED_MARKER, text)
        description = next(line for line in text.splitlines() if line.startswith("description:"))
        # Hermes caps a skill description at 60 characters; longer is silently truncated.
        self.assertLessEqual(len(description.split(":", 1)[1].strip()), 60)

    def test_it_warns_against_ssh(self) -> None:
        """The failure this feature exists to prevent: a bot deciding to SSH into the Mac."""
        body = agent_skills.render(Path("/x/local_computer.py"))
        self.assertIn("without SSH", body)


class ItLandsEverywhereItMust(Scratch):
    def test_a_stock_host_gets_it_in_the_default_and_every_profile(self) -> None:
        result = self.install()
        self.assertTrue(result["installed"], result)
        for root in (self.home / "skills", self.profiles / "cody" / "skills",
                     self.profiles / "jason" / "skills"):
            self.assertTrue((root / agent_skills.SKILL_NAME / "SKILL.md").is_file(), root)

    def test_the_cli_is_materialised_executable_and_matches_the_repo(self) -> None:
        result = self.install()
        cli = Path(result["cli"])
        self.assertTrue(cli.is_file())
        self.assertTrue(os.stat(cli).st_mode & 0o100, "a bot cannot run a non-executable file")
        shipped = (ROOT / "Bridge/hermes_bridge/agent_skills/bin/local_computer.py").read_bytes()
        self.assertEqual(cli.read_bytes(), shipped)

    def test_the_bundled_cli_has_not_drifted_from_the_repo_copy(self) -> None:
        """Two copies is one too many: this is what keeps them the same file."""
        self.assertEqual((ROOT / "Tools/local_computer.py").read_bytes(),
                         (ROOT / "Bridge/hermes_bridge/agent_skills/bin/local_computer.py").read_bytes(),
                         "edit Tools/local_computer.py, then copy it into the package")

    def test_the_skill_is_readable_by_the_agents_that_load_it(self) -> None:
        self.install()
        path = self.home / "skills" / agent_skills.SKILL_NAME / "SKILL.md"
        mode = os.stat(path).st_mode
        self.assertTrue(mode & 0o044, "mkstemp's 0600 leaves other agent users unable to read it")

    def test_a_skill_written_by_an_older_install_gets_its_mode_fixed(self) -> None:
        """The file is already right, so nothing rewrites it — the mode must still be repaired."""
        self.install()
        path = self.home / "skills" / agent_skills.SKILL_NAME / "SKILL.md"
        path.chmod(0o600)
        self.install()
        self.assertTrue(os.stat(path).st_mode & 0o044)

    def test_the_install_route_has_an_audit_event_it_is_allowed_to_emit(self) -> None:
        """The audit log rejects an unregistered event, and a 500 is how that surfaced live."""
        allowed = (ROOT / "Bridge/hermes_bridge/audit.py").read_text(encoding="utf-8")
        self.assertIn("local_computer.skill", allowed)

    def test_a_configured_shared_dir_is_the_only_target(self) -> None:
        shared = Path(self._tmp.name) / "shared-skills"
        shared.mkdir()
        (self.home / "config.yaml").write_text(
            "skills:\n  external_dirs:\n    - %s\n  template_vars: true\n" % shared, encoding="utf-8")
        result = self.install()
        self.assertEqual(result["installed"], [str(shared)])
        self.assertTrue((shared / agent_skills.SKILL_NAME / "SKILL.md").is_file())
        self.assertFalse((self.profiles / "cody" / "skills" / agent_skills.SKILL_NAME).exists(),
                         "20 copies of one skill is 20 files to keep in step")

    def test_an_unwritable_shared_dir_falls_back_to_the_profiles(self) -> None:
        """The sandbox keeps the Hermes home read-only on some hosts; the skill still ships."""
        blocked = Path(self._tmp.name) / "blocked"
        blocked.write_text("not a directory", encoding="utf-8")  # mkdir now fails
        os.environ["HERMES_SKILLS_DIR"] = str(blocked)
        try:
            result = self.install()
        finally:
            os.environ.pop("HERMES_SKILLS_DIR", None)
        self.assertTrue(result["installed"], result)
        self.assertTrue(any("cody" in path for path in result["installed"]))
        self.assertTrue(any(entry["outcome"].startswith("failed") for entry in result["attempted"]))


class ItIsSafeToRunAgain(Scratch):
    def test_a_second_run_rewrites_nothing(self) -> None:
        self.install()
        path = self.profiles / "cody" / "skills" / agent_skills.SKILL_NAME / "SKILL.md"
        first = path.stat().st_mtime_ns
        result = self.install()
        self.assertEqual(path.stat().st_mtime_ns, first)
        outcomes = {entry["outcome"] for entry in result["attempted"]}
        self.assertEqual(outcomes, {"current"})

    def test_an_updated_template_replaces_our_old_copy(self) -> None:
        self.install()
        path = self.profiles / "cody" / "skills" / agent_skills.SKILL_NAME / "SKILL.md"
        stale = path.read_text(encoding="utf-8").replace("version: 1.0.0", "version: 0.9.0")
        path.write_text(stale, encoding="utf-8")
        self.install()
        self.assertIn("version: 1.0.0", path.read_text(encoding="utf-8"))

    def test_a_hand_edit_to_our_file_survives_beside_it(self) -> None:
        """A bot that edited the installed skill must not lose its words to the next restart."""
        self.install()
        path = self.home / "skills" / agent_skills.SKILL_NAME / "SKILL.md"
        theirs = path.read_text(encoding="utf-8") + "\nNOTE FROM A BOT: the Mac is on Wi-Fi only.\n"
        path.write_text(theirs, encoding="utf-8")
        self.install()
        self.assertIn("NOTE FROM A BOT", (path.parent / "SKILL.md.previous").read_text(encoding="utf-8"))
        self.assertNotIn("NOTE FROM A BOT", path.read_text(encoding="utf-8"),
                         "the generated file stays the template; the edit lives beside it")

    def test_the_owners_own_skill_of_that_name_is_never_overwritten(self) -> None:
        owned = self.profiles / "cody" / "skills" / agent_skills.SKILL_NAME
        owned.mkdir(parents=True)
        theirs = "---\nname: mac-local-computer\ndescription: mine\n---\n\nmy own notes\n"
        (owned / "SKILL.md").write_text(theirs, encoding="utf-8")
        result = self.install()
        self.assertEqual((owned / "SKILL.md").read_text(encoding="utf-8"), theirs)
        self.assertNotIn(str(owned.parent), result["installed"])
        self.assertIn({"dir": str(owned.parent), "outcome": "foreign"}, result["attempted"])


if __name__ == "__main__":
    unittest.main()
