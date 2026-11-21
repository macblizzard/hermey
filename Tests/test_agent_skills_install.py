"""The Mac skill must reach the bots by existing, not by the owner finding it.

The Python bridge used to own this: `Bridge/hermes_bridge/agent_skills.py` rendered the template,
wrote it into every profile and exposed `status()`/`install()` over `/v1/local-computers/skill`.
That package was removed. The same install now lives in `hermeyd/src/skills.rs` — the templates and
scripts are `include_str!`/`include_bytes!` from `hermeyd/assets/agent-skills/` — and its behaviour
(idempotent re-install, a bot's edit kept beside the file as `SKILL.md.previous`, an owner's own
skill left as `foreign`, the CLI failure holding back only the Mac skill) is covered by that module's
Rust tests: `cargo test` in `hermeyd/`.

What is left here is what only this repository can check: the CLI the template points at, the audit
event the install emits, and the app's Computer tab, which still asks for it over the wire.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "hermeyd" / "assets" / "agent-skills"
SKILLS_RS = (ROOT / "hermeyd" / "src" / "skills.rs").read_text(encoding="utf-8")
ROUTES = (ROOT / "hermeyd" / "src" / "main.rs").read_text(encoding="utf-8")


class TheSkillIsRenderedForThisHost(unittest.TestCase):
    # Removed with the Python bridge: `test_the_bundled_cli_has_not_drifted_from_the_repo_copy`
    # asserted `Tools/local_computer.py` and the bundled copy were byte-identical (the bridge-era
    # workflow was "edit Tools/, copy it into the package"). They are now two different programs —
    # the repo copy resolves hermeyd's local bearer and the 8788 default, the bundled one still
    # defines DEFAULT_BROWSER and the bridge's 8787 — and `hermeyd/src/skills.rs` asserts the bundled
    # one's shape, so the two cannot be merged here. The drift is reported with this change: a bot
    # installed by this hermeyd gets the older CLI until the two are reconciled.

    def test_the_template_carries_the_placeholder_the_renderer_fills(self) -> None:
        # `skills.rs` substitutes this with the host's own CLI path on every install; a template
        # without it would tell a bot to run a placeholder (or ship with no path at all).
        self.assertIn("const CLI_PLACEHOLDER: &str = \"@@CLI@@\"", SKILLS_RS)
        self.assertIn("@@CLI@@", (ASSETS / "mac-local-computer" / "SKILL.md").read_text(encoding="utf-8"))

    def test_it_warns_against_ssh(self) -> None:
        """The failure this feature exists to prevent: a bot deciding to SSH into the Mac."""
        body = (ASSETS / "mac-local-computer" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("without SSH", body)

    def test_the_install_route_has_an_audit_event_it_is_allowed_to_emit(self) -> None:
        """The audit log rejects an unregistered event, and a 500 is how that surfaced live."""
        allowed = (ROOT / "hermeyd" / "src" / "audit.rs").read_text(encoding="utf-8")
        self.assertIn("local_computer.skill", allowed)


class TheComputerTabShowsIt(unittest.TestCase):
    """The row exists in the app, and it asks the host rather than assuming."""

    VIEW = ROOT / "Apps/HermesMac/Views/LocalComputerSettingsView.swift"
    SERVICE = ROOT / "Apps/HermesMac/LocalComputer/LocalComputerService.swift"

    def test_the_row_is_in_the_computer_tab(self) -> None:
        view = self.VIEW.read_text(encoding="utf-8")
        self.assertIn("Bot instructions", view)
        self.assertIn("refreshSkill", view)
        self.assertIn("installSkill", view)

    def test_the_state_words_keep_unavailable_apart_from_not_installed(self) -> None:
        view = self.VIEW.read_text(encoding="utf-8")
        for word in ('"Installed"', '"Update available"', '"Not installed"', '"Unavailable"', '"Yours"'):
            self.assertIn(word, view)

    def test_status_is_a_read_and_install_is_a_write(self) -> None:
        service = self.SERVICE.read_text(encoding="utf-8")
        self.assertIn('skillRequest(method: "GET"', service)
        self.assertIn('skillRequest(method: "POST"', service)
        self.assertIn("v1/local-computers/skill", service)

    def test_the_host_serves_both_verbs_on_that_path(self) -> None:
        # Retargeted from `hermes_bridge/local_computers.py` (deleted with the Python bridge).
        self.assertIn('"/v1/local-computers/skill"', ROUTES)
        self.assertIn("local_computers::skill_placeholder", ROUTES)
        self.assertIn("local_computers::skill_install", ROUTES)


if __name__ == "__main__":
    unittest.main()
