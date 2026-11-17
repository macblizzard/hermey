"""Build A: GUI actions, app focus and serialization ship together."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class BuildAGUI(unittest.TestCase):
    def test_bridge_act_route_is_audited_and_bounded(self) -> None:
        module = (ROOT / "Bridge/hermes_bridge/local_computers.py").read_text()
        self.assertIn('@router.post("/{device_id}/act")', module)
        self.assertIn('{"type": "act", "actions": actions, "bot": bot}', module)
        self.assertIn("1 <= len(actions) <= 24", module)
        self.assertIn('"local_computer.act"', (ROOT / "Bridge/hermes_bridge/audit.py").read_text())

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
        self.assertIn("kCGSSessionScreenIsLocked", actions)
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
