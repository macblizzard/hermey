"""The extension has to be on disk after an install, not after a support ticket.

Three promises, each pinned below:

* it is written on startup, from the copy that ships in the package;
* the copy in the package is identical to the one in ``browser-extension/`` (the authoring copy), so a
  change cannot land in one place and quietly miss the other;
* a browser that refuses ``--load-extension`` is reported as such instead of being assumed fine.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

from hermes_bridge import browser_extension

ROOT = pathlib.Path(__file__).resolve().parents[2]
AUTHORING = ROOT / "browser-extension"


class TestItIsPrebuiltWithThePackage(unittest.TestCase):
    def test_the_package_copy_matches_the_authoring_copy(self) -> None:
        for name in browser_extension.EXTENSION_FILES:
            packaged = browser_extension.source_dir() / name
            authored = AUTHORING / name
            self.assertTrue(packaged.is_file(), f"{name} missing from the package")
            self.assertEqual(packaged.read_bytes(), authored.read_bytes(),
                             f"{name} differs between browser-extension/ and the package copy")

    def test_it_is_listed_as_package_data(self) -> None:
        pyproject = (ROOT / "Bridge" / "pyproject.toml").read_text(encoding="utf-8")
        self.assertIn("browser_extension/*", pyproject)


class TestInstallation(unittest.TestCase):
    def test_it_writes_every_file_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            first = browser_extension.install(pathlib.Path(tmp) / "ext")
            second = browser_extension.install(pathlib.Path(tmp) / "ext")
            self.assertEqual(first, second)
            for name in browser_extension.EXTENSION_FILES:
                self.assertTrue((first / name).is_file(), name)

    def test_an_updated_file_replaces_an_old_one(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = browser_extension.install(pathlib.Path(tmp) / "ext")
            (target / "background.js").write_bytes(b"stale")
            browser_extension.install(pathlib.Path(tmp) / "ext")
            self.assertEqual((target / "background.js").read_bytes(),
                             (browser_extension.source_dir() / "background.js").read_bytes())

    def test_a_read_only_system_path_falls_back(self) -> None:
        """A host running the bridge as a normal user still gets the extension somewhere usable."""
        with tempfile.TemporaryDirectory() as tmp:
            blocked = pathlib.Path(tmp) / "blocked"
            blocked.write_text("not a directory")
            written = browser_extension.install(blocked)
            self.assertTrue((written / "manifest.json").is_file())

    def test_status_reports_current(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {"HERMES_EXTENSION_HOME": tmp}):
                browser_extension.install()
                report = browser_extension.status()
                self.assertTrue(report["present"])
                self.assertTrue(report["up_to_date"])


class TestTheBrowserIsChecked(unittest.TestCase):
    def test_stable_chrome_is_reported_as_unable_to_load(self) -> None:
        fake = lambda *a, **k: subprocess.CompletedProcess(a, 0, "Google Chrome 158.0.8127.36\n", "")
        with mock.patch("subprocess.run", fake):
            report = browser_extension.describe_browser("/usr/bin/google-chrome-stable")
        self.assertIs(report["loads_extensions"], False)
        self.assertIn("never filled", report["note"])

    def test_chrome_for_testing_is_accepted(self) -> None:
        fake = lambda *a, **k: subprocess.CompletedProcess(a, 0, "Google Chrome for Testing 148.0.7778.96\n", "")
        with mock.patch("subprocess.run", fake):
            report = browser_extension.describe_browser("/opt/hermes-chromium-148/chrome")
        self.assertIs(report["loads_extensions"], True)
        self.assertEqual(report["note"], "")

    def test_an_unknown_browser_is_not_assumed_fine(self) -> None:
        fake = lambda *a, **k: subprocess.CompletedProcess(a, 0, "Vivaldi 7.0\n", "")
        with mock.patch("subprocess.run", fake):
            self.assertIsNone(browser_extension.describe_browser("/usr/bin/vivaldi")["loads_extensions"])


class TestTheManifestIsSelfSufficient(unittest.TestCase):
    def test_it_asks_for_the_alarms_permission(self) -> None:
        """Without it the keepalive is undefined, the worker sleeps, and the socket never returns."""
        manifest = json.loads((browser_extension.source_dir() / "manifest.json").read_text())
        self.assertIn("alarms", manifest["permissions"])

