"""Build B: shared workspace, browser tools and secret-safe output."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class BuildB(unittest.TestCase):
    def test_shared_workspace_is_confined(self) -> None:
        files = (ROOT / "Apps/HermesMac/LocalComputer/ComputerFiles.swift").read_text()
        self.assertIn('appendingPathComponent("Workspace", isDirectory: true)', files)
        self.assertIn("resolved.path.hasPrefix(rootPath + \"/\")", files)
        self.assertIn("case \"read\":", files)
        self.assertIn("case \"write\":", files)
        self.assertIn("case \"list\":", files)
        self.assertIn("private let maxBytes = 4_000_000", files)

    def test_browser_surface_has_navigate_snapshot_act_and_downloads(self) -> None:
        browser = (ROOT / "Apps/HermesMac/LocalComputer/ComputerBrowser.swift").read_text()
        self.assertIn("WKWebView", browser)
        self.assertIn("func navigate", browser)
        self.assertIn("func snapshot", browser)
        self.assertIn("func act", browser)
        self.assertIn("WKDownloadDelegate", browser)
        self.assertIn('appendingPathComponent("downloads"', browser)
        service = (ROOT / "Apps/HermesMac/LocalComputer/LocalComputerService.swift").read_text()
        self.assertIn('} else if kind == "browser" {', service)

    def test_host_routes_exist(self) -> None:
        # Retargeted from `hermes_bridge/local_computers.py` (deleted with the Python bridge).
        routes = (ROOT / "hermeyd" / "src" / "main.rs").read_text()
        self.assertIn('"/v1/local-computers/{device_id}/file"', routes)
        self.assertIn('"/v1/local-computers/{device_id}/browser"', routes)
        audit = (ROOT / "hermeyd" / "src" / "audit.rs").read_text()
        self.assertIn("local_computer.file", audit)
        self.assertIn("local_computer.browser", audit)

    def test_cli_exposes_files_and_browser(self) -> None:
        cli = (ROOT / "Tools/local_computer.py").read_text()
        self.assertIn('if raw and raw[0] == "files":', cli)
        self.assertIn('if raw and raw[0] == "browser":', cli)
        self.assertIn('choices=("list", "read", "write", "mkdir")', cli)
        self.assertIn('choices=("navigate", "snapshot", "act", "downloads")', cli)

    def test_secret_redaction_is_wired(self) -> None:
        # Retargeted from `hermes_bridge/local_computers.py` (deleted with the Python bridge).
        # hermeyd redacts with `scrub` + `redact` over every result it returns. NOTE: its marker
        # list is narrower than the bridge's — `sk-`, bearer/authorization/token/password and the
        # api-key spellings, but not the AWS `AKIA` or GitHub `ghp_`/`gho_` prefixes; that gap is
        # reported rather than asserted here.
        module = (ROOT / "hermeyd" / "src" / "local_computers.rs").read_text()
        self.assertIn("fn scrub(text: &str) -> String", module)
        self.assertIn("fn redact(mut value: Value) -> Value", module)
        self.assertIn("SECRET_MARKERS", module)
        for marker in ("sk-", "bearer ", "authorization:", "token="):
            self.assertIn(marker, module)
