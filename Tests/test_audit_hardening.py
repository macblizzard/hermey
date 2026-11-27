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

    def test_remote_ws_pairings_are_upgraded_to_wss(self) -> None:
        # Retargeted 2026-11-27: a plaintext pairing to a host that is not this machine is now
        # *upgraded* rather than refused, and the predicate lives in `LoopbackHost` (which knows
        # that URLComponents returns `::1`, not `[::1]`). The property this test has always meant is
        # the same one: a device token never travels in cleartext off this box.
        pairing = (ROOT / "Apps" / "HermesMac" / "Pairing" / "PairingAddress.swift").read_text()
        self.assertIn('if scheme == "ws", !LoopbackHost.isLoopback(host) {', pairing)
        self.assertIn('components.scheme = "wss"', pairing)

    def test_host_registration_is_per_device_and_revoke_is_socket_scoped(self) -> None:
        # Retargeted from `hermes_bridge/local_computers.py` (deleted with the Python bridge):
        # hermeyd's Registry keys one live Mac per device id and drops its sender on revoke, which
        # is what closes the socket (4403) instead of leaving a half-removed entry behind.
        module = (ROOT / "hermeyd" / "src" / "local_computers.rs").read_text()
        self.assertIn("computers: Mutex<HashMap<String, Computer>>", module)
        self.assertIn("self.computers.lock().unwrap().remove(device_id).is_some()", module)
        self.assertIn('close_with(&mut socket, CLOSE_REVOKED, "this computer was revoked")', module)
        self.assertIn('json!({"type": "file", "op": op, "path": path})', module)
        self.assertIn('json!({"type": "browser", "op": op})', module)

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

    def test_bot_admin_archives_before_it_deletes_and_caps_the_archives(self) -> None:
        # Retargeted from `hermes_bridge/bot_admin.py`: the Python state lock and its `partial`
        # outcome have no equivalent here (hermeyd never holds a shared file lock — the archive is
        # built in a temp file and renamed), but the property the test was for — an archive that
        # did not land refuses the delete, and archives cannot pile up — is kept.
        module = (ROOT / "hermeyd" / "src" / "bot_admin.rs").read_text()
        self.assertIn("const ARCHIVE_KEEP: usize = 20", module)
        self.assertIn("fn prune_archives(archive_dir: &std::path::Path)", module)
        before_remove = module.split("remove_dir_all", 1)[0]
        self.assertIn("archive failed", before_remove,
                      "the archive must fail before the point of no return")
        purge = module.split("pub async fn purge", 1)[1]
        self.assertLess(purge.index("std::fs::rename(&tmp, &archive)"),
                        purge.index("remove_dir_all"))

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
        # `select: true` is the B2 classification (Compress acts on the conversation on screen).
        self.assertIn("_ = await endlessSession(for: bot, select: true)", body)
        self.assertLess(body.index("isCompressing = true"),
                        body.index("_ = await endlessSession(for: bot, select: true)"))

    def test_approval_answers_report_send_failures(self) -> None:
        app = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text()
        self.assertIn('lastSendError = "could not send the answer:', app)
        self.assertIn('lastSendError = "could not send the answers:', app)
        self.assertIn('lastSendError = "could not withdraw the request:', app)

    def test_visible_transcript_is_cached_until_the_transcript_changes(self) -> None:
        # Shape updated 2026-11-25 (scroll freeze): the cache is no longer a tuple invalidated by
        # `visibleTranscriptCache = nil`. A page landing *above* the reader invalidated it several
        # times a second and each invalidation re-ran three whole-array filters over 6,400 rows, so
        # the cache now splices the page on (`TranscriptVisibilityCache`) and is kept in step from
        # one place, `transcriptDidChange`. The three things this test has always meant are still
        # asserted: there is a cache, every transcript change goes through it, and the visibility
        # flags are part of its key.
        app = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text()
        self.assertIn("private var visibleTranscriptCache = TranscriptVisibilityCache()", app)
        self.assertIn("didSet { transcriptDidChange(from: oldValue) }", app)
        rows = (ROOT / "Sources" / "HermesKit" / "IncrementalTranscriptRows.swift").read_text()
        self.assertIn("showToolCalls != self.showToolCalls", rows)
        self.assertIn("showReasoning != self.showReasoning", rows)

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
