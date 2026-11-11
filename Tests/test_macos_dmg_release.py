"""The Mac app ships as a disk image.

A .dmg needs no notarization to be made, published or opened — notarization is a Gatekeeper
*ticket*, and an unsigned app inside a disk image argues with Gatekeeper exactly as much as the same
app inside a .zip. What a disk image buys is the install gesture: the window opens with Hermey beside
an Applications shortcut, and installing is one drag.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
PUBLISH = (ROOT / "Tools" / "release" / "publish_altstore.py").read_text(encoding="utf-8")
DOCS = (ROOT / "docs" / "APPS.md").read_text(encoding="utf-8")


class TheJobBuildsIt(unittest.TestCase):
    def test_hdiutil_makes_a_compressed_image(self) -> None:
        self.assertIn("hdiutil create", CI)
        self.assertIn("-format UDZO", CI, "an uncompressed image is 30 MB of nothing")

    def test_the_window_holds_the_install_shortcut(self) -> None:
        self.assertIn("ln -s /Applications dist/dmg-root/Applications", CI,
                      "without the shortcut there is nothing to drag the app onto")
        self.assertIn("cp -R \"$APP\" dist/dmg-root/Hermey.app", CI)

    def test_the_image_is_verified_before_it_is_published(self) -> None:
        self.assertIn("hdiutil verify dist/Hermey-macOS-unsigned.dmg", CI,
                      "a truncated image mounts as 'no mountable file systems' for the user, not for us")

    def test_only_the_image_is_published(self) -> None:
        block = CI.split("name: Hermey-macOS-unsigned", 1)[1].split("if-no-files-found", 1)[0]
        self.assertIn("dist/Hermey-macOS-unsigned.dmg", block)
        self.assertNotIn(".zip", block, "the zip was a wrapper around the same .app; one artifact is enough")
        self.assertNotIn("ditto -c -k", CI, "the zip step is gone, not merely unlisted")


class TheReleaseCarriesIt(unittest.TestCase):
    def test_the_publisher_takes_a_dmg(self) -> None:
        self.assertIn('parser.add_argument("--mac-dmg"', PUBLISH)

    def test_the_publisher_knows_one_mac_artifact(self) -> None:
        self.assertIn("--mac-dmg", PUBLISH)
        self.assertNotIn("--mac-zip", PUBLISH, "two Mac artifacts was the old contract; one is the new")
        self.assertNotIn("mac_zip", PUBLISH)

    def test_the_mirror_gets_a_stable_name(self) -> None:
        self.assertIn('args.mirror_to / "Hermey-macOS-unsigned.dmg"', PUBLISH,
                      "the site links the stable name, not the versioned one")


class TheDocsSaySo(unittest.TestCase):
    def test_the_mac_instructions_lead_with_the_image(self) -> None:
        self.assertIn("Hermey-macOS-unsigned.dmg", DOCS)

    def test_the_quarantine_command_is_written_out(self) -> None:
        # An unsigned app that will not open is the first thing a Mac user hits; the command that
        # fixes it is one line, and it belongs in the instructions rather than in a support thread.
        self.assertIn("xattr -dr com.apple.quarantine /Applications/Hermey.app", DOCS)
        self.assertIn("right-click", DOCS.lower(), "the GUI route is offered too, for people who prefer it")


if __name__ == "__main__":
    unittest.main()
