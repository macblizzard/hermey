"""Guards for Build C: the parity features must stay wired after this batch ships."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class BuildCParity(unittest.TestCase):
    def test_takeover_primitve_is_present_and_pauses_between_actions(self) -> None:
        takeover = (ROOT / "Apps" / "HermesMac" / "LocalComputer" / "ComputerTakeover.swift").read_text()
        self.assertIn("final class ComputerTakeover", takeover)
        self.assertIn("CGEvent.tapCreate", takeover)
        self.assertIn("ComputerEventTag.herm", takeover)
        self.assertIn("func waitWhilePaused() async", takeover)

        actions = (ROOT / "Apps" / "HermesMac" / "LocalComputer" / "ComputerActions.swift").read_text()
        self.assertIn("await ComputerTakeover.shared.waitWhilePaused()", actions)
        self.assertIn("ComputerEventTag.herm", actions)

    def test_the_menu_bar_and_settings_surface_the_takeover(self) -> None:
        app = (ROOT / "Apps" / "HermesMac" / "HermesMacApp.swift").read_text()
        self.assertIn("MenuBarExtra", app)
        menu = (ROOT / "Apps" / "HermesMac" / "Views" / "ComputerControlMenu.swift").read_text()
        self.assertIn("Bot control paused by your input", menu)
        self.assertIn("Resume bot control", menu)

        settings = (ROOT / "Apps" / "HermesMac" / "Views" / "LocalComputerSettingsView.swift").read_text()
        self.assertIn("Section(\"Activity\")", settings)
        self.assertIn("service.recentActivity", settings)
        self.assertIn("service.isCommandRunning", settings)

    def test_the_service_records_activity_and_streams_progress(self) -> None:
        service = (ROOT / "Apps" / "HermesMac" / "LocalComputer" / "LocalComputerService.swift").read_text()
        self.assertIn("struct ComputerActivityItem", service)
        self.assertIn("@Published private(set) var recentActivity", service)
        self.assertIn("@Published private(set) var isCommandRunning", service)
        self.assertIn("ProgressReporter(task: task, id: callID)", service)
        self.assertIn("kind == \"resume\"", service)
        reporter = (ROOT / "Apps" / "HermesMac" / "LocalComputer" / "ProgressReporter.swift").read_text()
        self.assertIn("\"type\": \"progress\"", reporter)

    def test_the_host_streams_progress_and_hands_control_back(self) -> None:
        # Retargeted from `hermes_bridge/local_computers.py` (deleted with the Python bridge).
        bridge = (ROOT / "hermeyd" / "src" / "local_computers.rs").read_text()
        self.assertIn('"/v1/local-computers/{device_id}/execute-stream"', (ROOT / "hermeyd" / "src" / "main.rs").read_text())
        self.assertIn('HeaderValue::from_static("application/x-ndjson")', bridge)
        self.assertIn('"/v1/local-computers/{device_id}/resume"', (ROOT / "hermeyd" / "src" / "main.rs").read_text())
        self.assertIn("mod progress {", bridge)
        self.assertIn("let mut saw_progress = false;", bridge)

    def test_ask_user_uses_the_bot_message_route(self) -> None:
        # Retargeted from `hermes_bridge/bot_message.py` (deleted with the Python bridge).
        message = (ROOT / "hermeyd" / "src" / "bot_message.rs").read_text()
        self.assertIn('"/v1/bots/{profile}/ask"', (ROOT / "hermeyd" / "src" / "main.rs").read_text())
        self.assertIn("fn owner_reply(", message)
        self.assertIn("async fn wait_for_owner_reply(", message)
        self.assertIn('"bot_ask"', message)

    def test_the_cli_exposes_the_new_verbs(self) -> None:
        cli = (ROOT / "Tools" / "local_computer.py").read_text()
        self.assertIn("def do_ask", cli)
        self.assertIn("def do_resume", cli)
        self.assertIn("def do_execute_stream", cli)
        self.assertIn('raw[0] == "ask"', cli)
        self.assertIn('raw[0] == "resume"', cli)
        self.assertIn('args.stream', cli)

    def test_the_parity_plan_records_build_c_progress(self) -> None:
        plan = (ROOT / "docs" / "LOCAL_COMPUTER_PARITY.md").read_text()
        self.assertIn("## Phase 8 — Takeover and ask_user — done", plan)
        self.assertIn("## Phase 9 — Activity feed and live progress — done", plan)
        self.assertIn("## Phase 11 — Connectivity discipline (no LaunchAgent) — done", plan)
        # The plan's closing status moved when bc01c04 marked every phase shipped; the old sentence
        # ("phases 8, 9 and 11 are implemented and tested") no longer exists and left CI red.
        self.assertIn("Status: all three builds are shipped and verified", plan)
        self.assertIn("Every phase is implemented, tested and verified", plan)
