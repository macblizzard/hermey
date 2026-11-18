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

    def test_the_bridge_streams_progress_and_hands_control_back(self) -> None:
        bridge = (ROOT / "Bridge" / "hermes_bridge" / "local_computers.py").read_text()
        self.assertIn("execute-stream", bridge)
        self.assertIn("media_type=\"application/x-ndjson\"", bridge)
        self.assertIn('@router.post("/{device_id}/resume")', bridge)
        self.assertIn("progress_queue", bridge)
        self.assertIn("if saw_progress:", bridge)

    def test_ask_user_uses_the_bot_message_route(self) -> None:
        message = (ROOT / "Bridge" / "hermes_bridge" / "bot_message.py").read_text()
        self.assertIn("'/{profile}/ask'", message)
        self.assertIn("def _owner_reply", message)
        self.assertIn("def _wait_for_owner_reply", message)
        self.assertIn("'bot_ask'", message)

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
