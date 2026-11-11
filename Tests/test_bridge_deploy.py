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
        self.assertIn('systemctl restart "$UNIT"', body)
        self.assertIn('HERMES_BRIDGE_UNIT:-hermes-native-bridge', body)

    def test_it_refuses_a_venv_without_python(self) -> None:
        body = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("no python in $VENV", body, "fail loudly instead of installing into the wrong place")

    def test_it_reports_what_it_deployed(self) -> None:
        body = SCRIPT.read_text(encoding="utf-8")
        for module in ("workspace", "policy", "proxy"):
            self.assertIn(f'"{module}"', body)


if __name__ == "__main__":
    unittest.main()
