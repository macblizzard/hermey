"""A fresh install must arrive with the desktop its bots drive.

Reported 2026-11-19: a new host got a bridge and a Hermey app, but a bot asked to "use the desktop"
found no desktop — or worse, found *another* X server (the owner's own `:10`) and silently worked
where nobody could see it. The packages existed as an in-app "Install" card that runs `apt-get`
through a sudo password card, which is the right fallback for a host the agent cannot provision, and
the wrong only-path for `setup/install.sh`, which already runs as root.

The rules pinned here:

* the step asks the **agent** for its package list (`tools/bot_desktop/runtime.py`) rather than
  keeping a copy here — one source of truth for apt, dnf and pacman;
* it is idempotent: a host that already has the binaries is left alone;
* it never fails the install: a package mirror problem must not stop a bridge that is otherwise fine,
  and the app can retry from a bot's screen;
* it can be skipped by name, for hosts that deliberately do not want a desktop.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALL = (ROOT / "setup" / "install.sh").read_text()


def _desktop_section() -> str:
    start = INSTALL.index("# ---------------------------------------------------------------- bot desktop")
    end = INSTALL.index("# ---------------------------------------------------------------- units")
    return INSTALL[start:end]


class TheInstallerPreparesIt(unittest.TestCase):
    def test_there_is_a_step_at_all(self) -> None:
        self.assertIn("Preparing the bot desktop", INSTALL)

    def test_it_asks_the_agent_for_the_package_list(self) -> None:
        section = _desktop_section()
        self.assertIn("tools/bot_desktop/runtime.py", section)
        self.assertIn("r.REQUIRED_BINARIES", section)
        self.assertIn("r.install_command()", section)

    def test_it_does_not_keep_its_own_copy_of_the_packages(self) -> None:
        """A copied list drifts: the agent's is per-distro and grows with support for new ones."""
        section = _desktop_section()
        for package in ("tigervnc-standalone-server", "xfce4-panel", "xfwm4", "dbus-x11"):
            self.assertNotIn(package, section, f"{package} belongs in the agent's runtime.py")

    def test_it_is_idempotent(self) -> None:
        section = _desktop_section()
        self.assertIn('command -v "$b"', section, "it must check for the binaries, not assume")
        self.assertIn("already installed", section)

    def test_it_needs_root_and_says_what_to_run_otherwise(self) -> None:
        section = _desktop_section()
        self.assertIn('[ "$(id -u)" = 0 ]', section)
        self.assertIn("not running as root", section)

    def test_a_failed_install_never_fails_the_bridge_install(self) -> None:
        section = _desktop_section()
        self.assertNotRegex(section, r"\bdie\b", "a package mirror must not fail the whole install")
        self.assertIn("did not finish", section)

    def test_it_can_be_skipped(self) -> None:
        self.assertIn("--no-desktop)", INSTALL)
        self.assertIn("DO_DESKTOP=no", INSTALL)
        self.assertRegex(INSTALL, r"DO_DESKTOP=\$\{HERMEY_DESKTOP:-auto\}")

    def test_the_flag_is_documented_in_usage(self) -> None:
        self.assertIn("--no-desktop     do not prepare the desktop", INSTALL)


if __name__ == "__main__":
    unittest.main()
