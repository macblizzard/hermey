"""The shared computer's full screen, on both platforms.

The pane had a "full screen" verb from the start, but on the Mac it only grew inside the window and
on the phone there was no verb at all — the picture was never as big as the screen. This guards the
three things that make it real: the Mac moves its own window, the phone drops its chrome, and the
picture can be zoomed and panned while clicks still land on the right framebuffer pixel.
"""
from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAGES = [ROOT / "Apps" / "HermesMac" / "Resources" / "botcomputer.html",
         ROOT / "Apps" / "HermesMobile" / "Resources" / "botcomputer.html"]
PANE = ROOT / "Sources" / "HermeyUI" / "BotComputerPane.swift"
WINDOW = ROOT / "Apps" / "HermesMac" / "Support" / "WindowFullScreen.swift"
SHELL = ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift"
PHONE = ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift"


class BotComputerFullScreen(unittest.TestCase):
    def test_both_pages_still_identical(self) -> None:
        texts = [p.read_text(encoding="utf-8") for p in PAGES]
        self.assertEqual(texts[0], texts[1],
                         "the two bundles ship the same page; a one-sided fix is a bug on the other")

    def test_the_module_still_parses(self) -> None:
        for page in PAGES:
            found = re.search(r'<script type="module">(.*?)</script>',
                              page.read_text(encoding="utf-8"), re.S)
            self.assertIsNotNone(found)
            with tempfile.NamedTemporaryFile("w", suffix=".mjs", delete=False) as handle:
                handle.write(found.group(1) if found else "")
                path = handle.name
            result = subprocess.run(["node", "--check", path], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_zoom_range_is_one_definition(self) -> None:
        for page in PAGES:
            text = page.read_text(encoding="utf-8")
            self.assertIn("const MIN_SCALE = 1;", text)
            self.assertIn("const MAX_SCALE = 5;", text)
            self.assertNotIn("MAX_SCALE = 4", text)
            controls = (ROOT / "Sources" / "HermeyUI" / "BotComputerWebView.swift").read_text(encoding="utf-8")
            self.assertIn("public static let maxScale: Double = 5", controls)
            self.assertIn("public static let minScale: Double = 1", controls)

    def test_mac_input_zooms_and_pans(self) -> None:
        for page in PAGES:
            text = page.read_text(encoding="utf-8")
            # Capture phase on the canvas's ancestor: the only place a handler runs before noVNC's.
            self.assertIn("}, { passive: false, capture: true });", text)
            self.assertIn("if (event.ctrlKey || event.metaKey) {", text)
            self.assertIn("zoomAround(Math.exp(-event.deltaY * 0.012)", text)
            self.assertIn("screen.addEventListener('gesturechange'", text)
            # A scroll pans only while zoomed; at 1x it must keep reaching the remote desktop.
            wheel = text.split("screen.addEventListener('wheel'", 1)[1].split("}, { passive: false", 1)[0]
            self.assertIn("if (scale > 1.01) {", wheel)
            # Option-drag, and the preventDefault that keeps it from arriving as a remote press.
            pan = text.split("screen.addEventListener('pointerdown'", 1)[1].split("}, { capture: true }", 1)[0]
            self.assertIn("event.pointerType !== 'mouse'", pan)
            self.assertIn("!event.altKey", pan)
            self.assertIn("event.preventDefault();", pan)

    def test_the_pane_owns_zoom_and_full_screen(self) -> None:
        pane = PANE.read_text(encoding="utf-8")
        self.assertIn("@StateObject private var viewer = BotComputerViewerControls()", pane)
        self.assertIn("controls: viewer", pane)
        self.assertIn("@State private var localFullScreen = false", pane)
        self.assertIn("onToggleFullScreen == nil ? localFullScreen : isFullScreen", pane)
        # Escape, and a visible way out that is not Escape.
        self.assertIn(".onKeyPress(.escape)", pane)
        self.assertIn('Image(systemName: "arrow.down.right.and.arrow.up.left")', pane)
        self.assertIn(".accessibilityLabel(\"Leave full screen\")", pane)
        # The phone's own edge-to-edge: no header, no status bar, no safe-area inset.
        self.assertIn(".ignoresSafeArea(.container, edges: fullScreenActive ? .all : Edge.Set())", pane)
        self.assertIn(".statusBarHidden(fullScreenActive)", pane)
        # The header is collapsed, never removed: the web view under it must keep its identity or
        # every toggle would reload the page and drop the socket.
        self.assertIn(".frame(height: fullScreenActive ? 0 : nil)", pane)

    def test_the_mac_moves_the_window(self) -> None:
        self.assertTrue(WINDOW.exists(), "WindowFullScreenDriver is what makes it the window's full screen")
        window = WINDOW.read_text(encoding="utf-8")
        self.assertIn("window.toggleFullScreen(nil)", window)
        self.assertIn("NSWindow.didExitFullScreenNotification", window)
        # Leaving the system's way must put the pane back, not leave the flag and window disagreeing.
        self.assertIn("if self.desired {", window)
        shell = SHELL.read_text(encoding="utf-8")
        self.assertIn("WindowFullScreenDriver(isFullScreen: store.isComputerFullScreen", shell)
        self.assertIn("onExit: { store.isComputerFullScreen = false }", shell)

    def test_the_phone_gets_the_verb_without_a_shell_change(self) -> None:
        phone = PHONE.read_text(encoding="utf-8")
        call = phone.split("BotComputerPane(profile:", 1)[1].split(")", 1)[0]
        # No callback: the pane's own state is the flag on the phone, and the button is always drawn.
        self.assertNotIn("onToggleFullScreen", call)

    def test_the_lease_still_moves_in_place(self) -> None:
        pane = PANE.read_text(encoding="utf-8")
        # Take-over keeps the socket it won the lease on, and a replaced viewer cannot report into
        # the pane that replaced it.
        self.assertIn("guard socket == socketURL else { return }", pane)
        self.assertEqual(pane.count("private func takeOver()"), 1)
        self.assertEqual(pane.count("private func handBack()"), 1)
        take = pane.split("private func takeOver()", 1)[1].split("private func handBack()", 1)[0]
        self.assertIn("client.lease(profile: profile, acquire: true, viewerID: viewerID)", take)
        self.assertIn("holdsControl = held", take)
        self.assertNotIn("openScreen()", take, "taking over must not rebuild the viewer")


if __name__ == "__main__":
    unittest.main()
