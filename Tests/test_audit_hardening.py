"""Guards for the 2026-11-18 audit fixes: the bugs found must not come back."""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AuditHardening(unittest.TestCase):
    def test_history_limit_travels_to_the_host(self) -> None:
        actor = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text()
        self.assertIn('"limit": .int(Int64(limit)),', actor)

    def test_recent_transcripts_are_bounded_and_byte_free(self) -> None:
        app = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text()
        self.assertIn("private var recentTranscriptOrder: [SessionID] = []", app)
        self.assertIn("recentTranscriptOrder.count > 8", app)
        self.assertIn("imageData: nil", app)

    def test_local_computer_service_is_app_scoped_and_cancel_closed_sockets(self) -> None:
        service = (ROOT / "Apps" / "HermesMac" / "LocalComputer" / "LocalComputerService.swift").read_text()
        self.assertIn("static let shared = LocalComputerService()", service)
        self.assertIn("LocalComputerCloseError", service)
        self.assertIn("task.closeCode.rawValue", service)
        self.assertIn("task.cancel(with: .goingAway, reason: nil)", service)
        view = (ROOT / "Apps" / "HermesMac" / "Views" / "LocalComputerSettingsView.swift").read_text()
        self.assertIn("@ObservedObject private var service = LocalComputerService.shared", view)

    def test_gui_scroll_cannot_trap_the_app(self) -> None:
        actions = (ROOT / "Apps" / "HermesMac" / "LocalComputer" / "ComputerActions.swift").read_text()
        self.assertIn("let delta = min(max(action.amount ?? 3, -10_000), 10_000)", actions)
        self.assertIn('let dy = action.direction == "up" ? -delta : (action.direction == "down" ? delta : 0)', actions)

    def test_workspace_file_tool_resolves_symlinks_before_trusting_a_path(self) -> None:
        files = (ROOT / "Apps" / "HermesMac" / "LocalComputer" / "ComputerFiles.swift").read_text()
        self.assertIn("url.resolvingSymlinksInPath()", files)
        self.assertIn("attributesOfItem(atPath: url.path)", files)

    def test_browser_downloads_sanitise_server_names(self) -> None:
        browser = (ROOT / "Apps" / "HermesMac" / "LocalComputer" / "ComputerBrowser.swift").read_text()
        self.assertIn("URL(fileURLWithPath: suggestedFilename).lastPathComponent", browser)
        self.assertIn("while FileManager.default.fileExists(atPath: target.path)", browser)

    def test_remote_ws_pairings_are_refused(self) -> None:
        pairing = (ROOT / "Apps" / "HermesMac" / "Pairing" / "PairingAddress.swift").read_text()
        self.assertIn('if scheme == "ws", !["127.0.0.1", "localhost", "[::1]"].contains(host.lowercased())', pairing)

    def test_bridge_registration_is_socket_scoped(self) -> None:
        bridge = (ROOT / "Bridge" / "hermes_bridge" / "local_computers.py").read_text()
        self.assertIn("def unregister(self, device_id: str, socket: WebSocket) -> None:", bridge)
        self.assertIn("if computer and computer.socket is socket:", bridge)
        self.assertIn('{"type": "file", "op": op, "path": path}', bridge)
        self.assertIn('{"type": "browser", "op": op}', bridge)

    def test_secret_scan_checks_tracked_names_and_artifacts(self) -> None:
        scan = (ROOT / "Tools" / "ci" / "secret_scan.sh").read_text()
        self.assertIn("tracked_paths=$(git ls-files", scan)
        self.assertIn("artifacts=$(git ls-files | grep -E", scan)
        ignore = (ROOT / ".gitignore").read_text()
        self.assertIn("/https:", ignore)
        tracked = subprocess.check_output(["git", "ls-files"], cwd=ROOT, text=True).splitlines()
        self.assertFalse(any(path.startswith("https:") for path in tracked))

    def test_release_tools_are_compiled_in_ci(self) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertIn("python3 -m compileall -q Tools/release", ci)
