"""The bridge is deployed from this repo, not by copying files into site-packages.

That is the whole lesson of the incident this guards: the unit pointed at one tree, the running process
came from another, and a third copy existed in `/opt/hermes-apps`. A deploy that is one command keeps
the running code traceable to a commit.
"""
from __future__ import annotations

import os
import stat
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Tools" / "release" / "deploy_bridge.sh"


class TheDeployIsOneCommand(unittest.TestCase):
    def test_it_exists_and_is_executable(self) -> None:
        self.assertTrue(SCRIPT.is_file())
        self.assertTrue(os.stat(SCRIPT).st_mode & stat.S_IXUSR, "a deploy script nobody can run is documentation")

    def test_it_installs_the_repo_not_a_copy(self) -> None:
        body = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('pip" install -q --force-reinstall --no-deps "$REPO_ROOT/Bridge"', body,
                      "the package must come from the checkout, or the running code is untraceable")

    def test_it_restarts_the_unit_it_names(self) -> None:
        body = SCRIPT.read_text(encoding="utf-8")
        # Stop, wait for the loopback port to be free, start: a plain `restart` races itself when the
        # old process still holds the socket, and the new one dies with EADDRINUSE.
        self.assertIn('systemctl stop "$UNIT"', body)
        self.assertIn('systemctl start "$UNIT"', body)
        self.assertIn('HERMES_BRIDGE_UNIT:-hermey-bridge', body)

    def test_it_follows_the_unit_that_is_actually_running(self) -> None:
        """A host first installed under the predecessor's name serves from that unit.

        Both units bind the same loopback port, so restarting the installer's name while the older one
        runs is an EADDRINUSE crash loop that leaves the live bridge on the old code (found 2026-11-15).
        """
        body = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('systemctl is-active --quiet "$UNIT"', body)
        self.assertIn("for candidate in hermes-native-bridge hermey-bridge", body)

    def test_the_default_unit_is_the_one_the_installer_creates(self) -> None:
        """A deploy must restart the unit the bridge actually runs as.

        The guard used to pin `hermes-native-bridge`, the retired predecessor unit: the script then
        installed the new package and restarted something nothing was serving from, so it printed a
        green deploy while the live bridge kept running the old code.
        """
        body = SCRIPT.read_text(encoding="utf-8")
        installer = (ROOT / "setup" / "install.sh").read_text(encoding="utf-8")
        self.assertIn('UNIT_PREFIX=${HERMEY_UNIT_PREFIX:-hermey}', installer)
        self.assertIn('$UNIT_PREFIX-bridge', installer, "the installer's unit name moved; follow it")
        self.assertIn('UNIT="${HERMES_BRIDGE_UNIT:-hermey-bridge}"', body)
        unit_line = [line for line in body.splitlines() if line.startswith("UNIT=")]
        self.assertEqual(len(unit_line), 1, "one place decides the unit")
        # The fallback is deliberate and separate: it follows a *running* predecessor rather than
        # deploying to a name nothing serves from.
        self.assertIn("if [[ -z \"${HERMES_BRIDGE_UNIT:-}\" ]] && ! systemctl is-active --quiet \"$UNIT\"",
                      body)

    def test_it_refuses_a_venv_without_python(self) -> None:
        body = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("no python in $VENV", body, "fail loudly instead of installing into the wrong place")

    def test_it_reports_what_it_deployed(self) -> None:
        body = SCRIPT.read_text(encoding="utf-8")
        for module in ("workspace", "policy", "proxy"):
            self.assertIn(f'"{module}"', body)


if __name__ == "__main__":
    unittest.main()
