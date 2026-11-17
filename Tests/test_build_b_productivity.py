"""Build B: shared workspace, browser tools and secret-safe output."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class BuildB(unittest.TestCase):
    def test_shared_workspace_is_confined(self) -> None:
        files = (ROOT / "Apps/HermesMac/LocalComputer/ComputerFiles.swift").read_text()
        self.assertIn('appendingPathComponent("Workspace", isDirectory: true)', files)
        self.assertIn("url.path.hasPrefix(rootPath + \"/\")", files)
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

    def test_bridge_routes_exist(self) -> None:
        module = (ROOT / "Bridge/hermes_bridge/local_computers.py").read_text()
        self.assertIn('@router.post("/{device_id}/file")', module)
        self.assertIn('@router.post("/{device_id}/browser")', module)
        self.assertIn("local_computer.file", (ROOT / "Bridge/hermes_bridge/audit.py").read_text())
        self.assertIn("local_computer.browser", (ROOT / "Bridge/hermes_bridge/audit.py").read_text())

    def test_cli_exposes_files_and_browser(self) -> None:
        cli = (ROOT / "Tools/local_computer.py").read_text()
        self.assertIn('if raw and raw[0] == "files":', cli)
        self.assertIn('if raw and raw[0] == "browser":', cli)
        self.assertIn('choices=("list", "read", "write", "mkdir")', cli)
        self.assertIn('choices=("navigate", "snapshot", "act", "downloads")', cli)

    def test_secret_redaction_is_wired(self) -> None:
        module = (ROOT / "Bridge/hermes_bridge/local_computers.py").read_text()
        self.assertIn("def redact_text", module)
        self.assertIn("def redact_result", module)
        self.assertIn("return redact_result(result)", module)
        for pattern in ("sk-", "gh[pousr]_", "AKIA", "Bearer"):
            self.assertIn(pattern, module)
