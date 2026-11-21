"""Build A: GUI actions, app focus and serialization ship together."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class BuildAGUI(unittest.TestCase):
    def test_host_act_route_is_audited_and_bounded(self) -> None:
        # Retargeted from `hermes_bridge/local_computers.py` (deleted with the Python bridge).
        module = (ROOT / "hermeyd" / "src" / "local_computers.rs").read_text()
        self.assertIn("/v1/local-computers/{device_id}/act", (ROOT / "hermeyd" / "src" / "main.rs").read_text())
        self.assertIn('json!({"type": "act", "actions": body.actions, "bot": body.bot})', module)
        self.assertIn("body.actions.len() > 24", module)
        self.assertIn("1 to 24 actions per batch", module)
        self.assertIn('"local_computer.act"', (ROOT / "hermeyd" / "src" / "audit.rs").read_text())

    def test_cli_accepts_a_json_action_batch(self) -> None:
        cli = (ROOT / "Tools/local_computer.py").read_text()
        self.assertIn('if raw and raw[0] == "act":', cli)
        self.assertIn('{"actions": actions, "bot": bot}', cli)
        self.assertIn("1 <= len(actions) <= 24", cli)
        self.assertIn("save_observation(result, save)", cli)

    def test_mac_action_engine_covers_the_rakazo_verbs(self) -> None:
        actions = (ROOT / "Apps/HermesMac/LocalComputer/ComputerActions.swift").read_text()
        for verb in ("click", "move", "down", "up", "type", "key", "scroll", "wait", "focus", "open_path"):
            self.assertIn(f'case "{verb}":', actions)
        self.assertIn("guard raw.count <= 24", actions)
        self.assertIn("guard AXIsProcessTrusted() else { throw ActError.permission }", actions)
        self.assertIn('"CGSSessionScreenIsLocked"', actions)
        self.assertIn("eventSourceUserData", actions)
        self.assertIn("lastObservationAt", actions)

    def test_gui_is_serialized(self) -> None:
        actions = (ROOT / "Apps/HermesMac/LocalComputer/ComputerActions.swift").read_text()
        self.assertIn("actor ComputerGate", actions)
        self.assertIn("await Self.gate.acquire()", actions)
        self.assertIn("await Self.gate.release()", actions)
        service = (ROOT / "Apps/HermesMac/LocalComputer/LocalComputerService.swift").read_text()
        self.assertIn('} else if kind == "act" {', service)
        self.assertIn("ComputerActions.shared.perform(actions, bot: bot)", service)
