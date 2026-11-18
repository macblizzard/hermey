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

    def test_bot_admin_no_longer_stalls_the_state_lock_or_drops_partial_writes(self) -> None:
        module = (ROOT / "Bridge" / "hermes_bridge" / "bot_admin.py").read_text()
        self.assertIn("REQUEST_TIMEOUT = 10", module)
        self.assertIn("_PROFILE_OPERATION_LOCKS", module)
        self.assertIn("with _profile_operation_lock(profile):", module)
        self.assertIn("outcome[\"partial\"] = True", module)
        self.assertIn("ARCHIVE_KEEP = 20", module)
        self.assertIn("def _prune_archives() -> None:", module)

    def test_file_links_reject_path_traversal(self) -> None:
        links = (ROOT / "Sources" / "HermeyUI" / "HermesFileLinkCard.swift").read_text()
        self.assertIn("Self.isSafeFilename(raw)", links)
        self.assertIn("guard !name.isEmpty, name != \".\", name != \"..\" else { return false }", links)
        self.assertIn("!name.contains(\"/\")", links)

    def test_compaction_guard_is_set_before_the_first_await(self) -> None:
        app = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text()
        start = app.index("public func compressNow() async")
        end = app.index("private func finishCompaction()", start)
        body = app[start:end]
        self.assertIn("isCompressing = true", body)
        self.assertIn("_ = await endlessSession(for: bot)", body)
        self.assertLess(body.index("isCompressing = true"),
                        body.index("_ = await endlessSession(for: bot)"))

    def test_approval_answers_report_send_failures(self) -> None:
        app = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text()
        self.assertIn('lastSendError = "could not send the answer:', app)
        self.assertIn('lastSendError = "could not send the answers:', app)
        self.assertIn('lastSendError = "could not withdraw the request:', app)

    def test_visible_transcript_is_cached_until_the_transcript_changes(self) -> None:
        app = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text()
        self.assertIn("private var visibleTranscriptCache:", app)
        self.assertIn("didSet { visibleTranscriptCache = nil }", app)
        self.assertIn("cached.showToolCalls == showToolCalls", app)

    def test_act_validates_against_every_online_display(self) -> None:
        actions = (ROOT / "Apps" / "HermesMac" / "LocalComputer" / "ComputerActions.swift").read_text()
        self.assertIn("private static func activeDisplayUnion() -> CGRect", actions)
        self.assertIn("CGGetOnlineDisplayList", actions)
        self.assertIn("bounds.contains(CGPoint(x: x, y: y))", actions)

    def test_every_local_frame_passes_through_one_serial_gate(self) -> None:
        service = (ROOT / "Apps" / "HermesMac" / "LocalComputer" / "LocalComputerService.swift").read_text()
        self.assertIn("private actor CommandGate", service)
        self.assertIn("private let commandGate = CommandGate()", service)
        self.assertIn("await self.commandGate.run", service)

    def test_the_cli_reports_missing_observation_metadata_instead_of_crashing(self) -> None:
        cli = (ROOT / "Tools" / "local_computer.py").read_text()
        self.assertIn('width = observation.get("width")', cli)
        self.assertIn('height = observation.get("height")', cli)
        self.assertIn('json.JSONDecodeError, KeyError) as exc:', cli)
