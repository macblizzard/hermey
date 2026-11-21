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
        self.assertIn("session.webSocketTask(with: url)", service)
        code = "\n".join(line for line in service.splitlines()
                          if not line.lstrip().startswith("//"))
        self.assertNotIn("NWListener", code)
        self.assertNotIn("SSH", code)

    def test_stays_up_by_itself(self) -> None:
        service = (ROOT / "Apps/HermesMac/LocalComputer/LocalComputerService.swift").read_text()
        self.assertIn("config.timeoutIntervalForRequest = 3_600", service)
        # The heartbeat is an async task measuring a *sent* ping, not a run-loop Timer reading a pong
        # clock. A backgrounded app has its timers throttled, so the old version saw a stale `lastPong`
        # it had never asked for and tore down a healthy socket on wake.
        self.assertIn(
            "private func startHeartbeat(for task: URLSessionWebSocketTask) -> Task<Void, Never>", service)
        self.assertIn("if let sent = self.pingSentAt, Date().timeIntervalSince(sent) > 45", service)
        self.assertNotIn("Timer(timeInterval: 15", service)
        self.assertIn("lastPong = Date()", service)
        self.assertNotIn("withThrowingTaskGroup", service)
        self.assertIn("backoff = min(backoff * 2, 30_000_000_000)", service)
        self.assertIn("let code = (error as? LocalComputerCloseError)?.code", service)
        # Only a revoke ends the loop. A rejected single-use ticket (4401) mints another and retries;
        # treating it as final is what left the owner flipping the switch.
        self.assertIn("if code == 4403 {", service)
        self.assertNotIn("if code == 4403 || code == 4401 {", service)
        # A machine that slept comes back with a socket that answers nothing, so wake and activation
        # both re-verify it.
        self.assertIn("NSWorkspace.didWakeNotification", service)
        self.assertIn("func recoverIfNeeded()", service)

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
        self.assertIn('http://127.0.0.1:8788', cli)          # hermeyd, not the retired bridge's 8787
        self.assertIn('HERMES_BRIDGE_URL', cli)             # a bridge host still works, by override
        self.assertIn('Authorization', cli)                 # the route needs a bearer
        self.assertIn('HERMEYD_LOCAL_TOKEN_FILE', cli)      # …read from the service, never hardcoded
        self.assertIn('"/v1/local-computers"', cli)
        self.assertIn('args.command[1:] if args.command and args.command[0] == "--"', cli)
        self.assertIn('base64.b64decode(result.get("stdout", ""))', cli)

    def test_permission_panes_and_prompt_are_real(self) -> None:
        perms = (ROOT / "Apps/HermesMac/LocalComputer/ComputerPermissions.swift").read_text()
        for pane in ("Privacy_Accessibility", "Privacy_ScreenCapture",
                     "Privacy_ListenEvent", "Privacy_Automation"):
            self.assertIn(pane, perms)
        self.assertIn("x-apple.systempreferences:com.apple.preference.security?", perms)
        self.assertIn("AXIsProcessTrustedWithOptions", perms)
        self.assertIn("kAXTrustedCheckOptionPrompt.takeUnretainedValue()", perms)
        self.assertIn("SCShareableContent.getWithCompletionHandler", perms)
        self.assertIn("CGEvent.tapCreate", perms)

    def test_permission_errors_name_the_missing_grant(self) -> None:
        perms = (ROOT / "Apps/HermesMac/LocalComputer/ComputerPermissions.swift").read_text()
        self.assertIn("enum ComputerPermissionError: LocalizedError", perms)
        self.assertIn('case missing(ComputerPermission)', perms)
        self.assertIn('Enable it in Settings → Computer', perms)

    def test_settings_panel_shows_every_grant(self) -> None:
        view = (ROOT / "Apps/HermesMac/Views/LocalComputerSettingsView.swift").read_text()
        self.assertIn("@StateObject private var permissions = ComputerPermissions()", view)
        self.assertIn('Text("Permissions")', view)
        self.assertIn("ForEach(ComputerPermission.allCases)", view)
        self.assertIn('Button(permission == .accessibility ? "Request Access" : "Open Settings")', view)
        self.assertIn('permissions.check(permission)', view)

    def test_permission_probes_require_an_explicit_button(self) -> None:
        perms = (ROOT / "Apps/HermesMac/LocalComputer/ComputerPermissions.swift").read_text()
        self.assertNotIn("init() {\n        refreshSafe()", perms)
        self.assertIn("starts completely passive", perms)
        self.assertNotIn("Task { await checkScreenRecording() }\n    }", perms)
        self.assertIn("func check(_ permission: ComputerPermission)", perms)
        self.assertIn("case .screenRecording:\n            states[.screenRecording]", perms)
        view = (ROOT / "Apps/HermesMac/Views/LocalComputerSettingsView.swift").read_text()
        self.assertIn('Button("Check") { permissions.check(permission) }', view)
        self.assertNotIn("onChange(of: scenePhase)", view)
        self.assertNotIn("permissions.refresh()", view)

    def test_receive_loop_never_blocks_on_a_command(self) -> None:
        service = (ROOT / "Apps/HermesMac/LocalComputer/LocalComputerService.swift").read_text()
        self.assertIn("Task { @MainActor [weak self] in", service)
        self.assertIn("await self.commandGate.run", service)
        self.assertIn("await self.handleExecute(frame, on: task)", service)
        self.assertNotIn("await handleExecute(frame, on: task)", service)
        self.assertIn("ClientLog.shared.record", service)
