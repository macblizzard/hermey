"""computer.observe: capture the Mac's screen without blocking the socket or auto-prompting."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ComputerObserve(unittest.TestCase):
    def test_host_has_a_dedicated_observe_route(self) -> None:
        # Retargeted from `hermes_bridge/local_computers.py` (deleted with the Python bridge).
        module = (ROOT / "hermeyd" / "src" / "local_computers.rs").read_text()
        self.assertIn('"/v1/local-computers/{device_id}/observe"', (ROOT / "hermeyd" / "src" / "main.rs").read_text())
        self.assertIn('json!({"type": "observe"})', module)
        self.assertIn('"local_computer.observe"', (ROOT / "hermeyd" / "src" / "audit.rs").read_text())

    def test_cli_saves_the_jpeg_and_prints_metadata(self) -> None:
        cli = (ROOT / "Tools/local_computer.py").read_text()
        self.assertIn('if raw and raw[0] == "observe":', cli)
        self.assertIn('/observe", {})', cli)
        self.assertIn('observation.get("image_base64") or observation.get("imageBase64")', cli)
        self.assertIn('"active_window": observation.get("activeWindow")', cli)
        self.assertIn("hermey-observe-", cli)

    def test_mac_capture_is_scaled_and_permission_safe(self) -> None:
        observer = (ROOT / "Apps/HermesMac/LocalComputer/ComputerObserver.swift").read_text()
        self.assertIn("CGWindowListCreateImage", observer)
        self.assertIn("let maxDimension: CGFloat = 1600", observer)
        self.assertIn("using: .jpeg", observer)
        self.assertIn("ComputerPermissionError.missing(.screenRecording)", observer)
        self.assertIn("CGWindowListCopyWindowInfo", observer)

    def test_receive_loop_dispatches_observe_off_the_loop(self) -> None:
        service = (ROOT / "Apps/HermesMac/LocalComputer/LocalComputerService.swift").read_text()
        self.assertIn('} else if kind == "observe" {', service)
        self.assertIn("await self.commandGate.run", service)
        self.assertIn("await self.handleObserve(frame, on: task)", service)
        self.assertIn("ComputerObserver.shared.observe()", service)
