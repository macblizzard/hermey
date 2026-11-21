"""The CLI hermeyd installs into every bot must be the CLI this repo ships.

They drifted once already: `Tools/local_computer.py` gained local-bearer support (hermeyd's 8788 +
`<state>/local.token`) while the copy bundled inside hermeyd stayed on the old unauthenticated program. A
bot installed from that bundle would get a CLI that cannot talk to the service that installed it — a silent
401 rather than a broken build.
"""

from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO_CLI = ROOT / "Tools" / "local_computer.py"
BUNDLED_CLI = ROOT / "hermeyd" / "assets" / "agent-skills" / "bin" / "local_computer.py"


class BundledCliMatchesRepoCopy(unittest.TestCase):
    def test_the_bundled_cli_is_byte_identical_to_the_repo_copy(self):
        self.assertTrue(BUNDLED_CLI.exists(), "hermeyd no longer bundles the local-computer CLI")
        self.assertEqual(
            REPO_CLI.read_bytes(),
            BUNDLED_CLI.read_bytes(),
            "Tools/local_computer.py and the copy bundled in hermeyd have drifted — copy the repo "
            "version over the bundled one so installed bots get the same program",
        )

    def test_the_bundled_cli_knows_the_local_bearer(self):
        text = BUNDLED_CLI.read_text(encoding="utf-8")
        for needle in ("HERMEYD_LOCAL_TOKEN", "HERMEYD_LOCAL_TOKEN_FILE", "8788"):
            self.assertIn(needle, text, f"the bundled CLI lost {needle} — it cannot authenticate")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
