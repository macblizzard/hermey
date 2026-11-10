"""Nothing may appear over the workspace unless the person asked for it.

A blank panel showed up over the sidebar on first launch and closed with Esc. No surface in the app
presents itself, so the app now *says* what it has open a second after launch, and the one overlay
that can legitimately be empty refuses to draw when it has nothing to offer.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROOT_VIEW = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
STORE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")


class LaunchSurfaces(unittest.TestCase):
    def test_launch_names_every_window_and_flag(self) -> None:
        self.assertIn("auditLaunchSurfaces()", ROOT_VIEW)
        audit = ROOT_VIEW.split("private func auditLaunchSurfaces()", 1)[1]
        self.assertIn("NSApplication.shared.windows", audit)
        for flag in ("isPalettePresented", "isPairSheetPresented", "botSettingsBot",
                     "isComputerPanelPresented", "isResetConfirmationPresented",
                     "isAddBotPresented", "isManageBotsPresented",
                     "isStartGroupChatPresented", "isGroupChatsPresented"):
            self.assertIn(flag, audit, f"{flag} can raise a surface, so the audit must report it")
        self.assertIn('category: "launch"', audit)

    def test_every_overlay_starts_closed(self) -> None:
        # A surface that starts true is a surface nobody asked for.
        for flag in ("isPalettePresented", "isPairSheetPresented", "isAddBotPresented",
                     "isManageBotsPresented", "isStartGroupChatPresented", "isGroupChatsPresented",
                     "isResetConfirmationPresented"):
            self.assertIn(f"@Published var {flag} = false", STORE,
                          f"{flag} must default to false")

    def test_the_palette_never_draws_empty(self) -> None:
        self.assertIn("if store.isPalettePresented && !store.commands.isEmpty", ROOT_VIEW,
                      "a palette with no verbs is a blank box")


if __name__ == "__main__":
    unittest.main()
