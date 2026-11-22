"""The share sheet is gone, and stays gone until it can actually work.

It was removed because a third-party signing certificate cannot provision an arbitrary App Group — the
container is nil at runtime, so the extension had nowhere to hand a payload. Removing it left two dangling
`ShareWiring` calls behind, which the Mac build caught (`cannot find ShareWiring in scope`) but no
source-level test did. This file is that test: no half-removals.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    *(ROOT / "Apps").rglob("*.swift"),
    *(ROOT / "Sources").rglob("*.swift"),
    *(ROOT / "Apps").rglob("Info.plist"),
]
GONE = ("ShareWiring", "ShareInboxReceiver", "HermeyShareExtension", "ShareBotSnapshot", "ShareInboxStorage")


class NoDanglingShareReferences(unittest.TestCase):
    def test_no_source_mentions_the_removed_share_code(self) -> None:
        offenders = []
        for path in SOURCES:
            text = path.read_text(encoding="utf-8", errors="replace")
            for name in GONE:
                if name in text:
                    offenders.append(f"{path.relative_to(ROOT)}: {name}")
        self.assertEqual(offenders, [], "half-removed share code: " + ", ".join(offenders))

    def test_the_directories_are_gone(self) -> None:
        for gone in ("Apps/HermeyShareExtension", "Apps/HermesShare"):
            self.assertFalse((ROOT / gone).exists(), f"{gone} should not exist")

    def test_the_project_declares_no_share_target(self) -> None:
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertNotIn("ShareExtension", project)
        self.assertNotIn("Apps/HermesShare", project)

    def test_no_app_group_entitlement_is_left_behind(self) -> None:
        # The app group existed only for the share sheet; a leftover entitlement would fail signing on a
        # certificate that cannot provision it.
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertNotIn("application-groups", project)
        self.assertEqual(list((ROOT / "Apps").glob("*.entitlements")), [])
        self.assertEqual(list((ROOT / "Apps").rglob("HermesMobile.entitlements")), [])

    def test_the_live_activity_extension_is_still_declared(self) -> None:
        # The removal must not take the widget with it.
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn("HermesLiveActivity:", project)
        self.assertIn("com.apple.widgetkit-extension", project)


if __name__ == "__main__":
    unittest.main()
