"""The local-computer prototype keeps its promises: off by default, outbound only, revocable."""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class LocalComputerPrototype(unittest.TestCase):
    def test_mac_toggle_is_off_by_default_and_persisted(self) -> None:
        service = (ROOT / "Apps/HermesMac/LocalComputer/LocalComputerService.swift").read_text()
        self.assertIn('private let enabledKey = "hermey.localComputer.enabled"', service)
        self.assertIn("private var enabled = false", service)
        self.assertIn("defaults.bool(forKey: enabledKey)", service)
        self.assertIn("defaults.set(value, forKey: enabledKey)", service)

    def test_mac_dials_out_instead_of_listening(self) -> None:
        address = (ROOT / "Apps/HermesMac/Pairing/PairingAddress.swift").read_text()
        self.assertIn('components.path = "/v1/local-computers/ws"', address)
        service = (ROOT / "Apps/HermesMac/LocalComputer/LocalComputerService.swift").read_text()
        self.assertIn("URLSession.shared.webSocketTask(with: url)", service)
        code = "\n".join(line for line in service.splitlines()
                          if not line.lstrip().startswith("//"))
        self.assertNotIn("NWListener", code)
        self.assertNotIn("SSH", code)

    def test_stays_up_by_itself(self) -> None:
        service = (ROOT / "Apps/HermesMac/LocalComputer/LocalComputerService.swift").read_text()
        self.assertIn('try await Task.sleep(nanoseconds: 20_000_000_000)', service)  # heartbeat
        self.assertIn('try await task.send(.string(#"{"type":"ping"}"#))', service)
        self.assertIn("backoff = min(backoff * 2, 30_000_000_000)", service)
        self.assertIn("code == 4403 ? .refused : .reconnecting", service)

    def test_commands_are_argv_not_shell_and_output_is_capped(self) -> None:
        service = (ROOT / "Apps/HermesMac/LocalComputer/LocalComputerService.swift").read_text()
        self.assertIn('process.executableURL = URL(fileURLWithPath: "/usr/bin/env")', service)
        self.assertIn("process.arguments = argv", service)
        self.assertIn("static let maxOutput = 4_000_000", service)
        self.assertIn('environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin', service)

    def test_settings_panel_has_the_computers_section(self) -> None:
        view = (ROOT / "Apps/HermesMac/Views/LocalComputerSettingsView.swift").read_text()
        self.assertIn('Text("Computers")', view)
        self.assertIn('Toggle("Let bots use this computer"', view)
        self.assertIn('Text(service.status == .connected ? "Connected"', view)
        self.assertIn("Button(role: .destructive)", view)
        settings = (ROOT / "Apps/HermesMac/Views/MacSettingsView.swift").read_text()
        self.assertIn("LocalComputerSettingsView(store: store)", settings)

    def test_bridge_requires_a_paired_device_and_persists_revocation(self) -> None:
        module = (ROOT / "Bridge/hermes_bridge/local_computers.py").read_text()
        self.assertIn("require_device(runtime, authorization)", module)
        self.assertIn('"revoked-local-computers.json"', module)
        self.assertIn("await websocket.accept()", module)
        self.assertIn('runtime.tickets.redeem(ticket)', module)

    def test_bots_have_a_host_side_cli(self) -> None:
        cli = (ROOT / "Tools/local_computer.py").read_text()
        self.assertIn('http://127.0.0.1:8787', cli)
        self.assertIn('"/v1/local-computers"', cli)
        self.assertIn('args.command[1:] if args.command and args.command[0] == "--"', cli)
        self.assertIn('base64.b64decode(result.get("stdout", ""))', cli)
