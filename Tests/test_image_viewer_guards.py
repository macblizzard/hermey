"""A picture in a bubble must open.

Clicking an attached image used to do nothing in either app, and a picture the host produced had no
surface at all. `ImageViewer` is the one viewer both paths open; these guards keep the wiring in place
and keep the viewer honest about the bytes it holds.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEWER = (ROOT / "Sources" / "OpenBotUI" / "ImageViewer.swift").read_text(encoding="utf-8")
MAC_ROW = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift").read_text(encoding="utf-8")
IOS_ROW = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text(encoding="utf-8")


class ImageViewerGuards(unittest.TestCase):
    def test_the_viewer_does_not_re_encode_what_it_shows(self) -> None:
        self.assertIn("public let data: Data", VIEWER)
        self.assertNotIn("jpegData(", VIEWER)
        self.assertNotIn("pngRepresentation", VIEWER)
        self.assertNotIn("UIImage(cgImage:", VIEWER.replace("UIImage(data: data)", ""),
                         "drawing the preview must not build a second encoding")

    def test_the_viewer_can_save_and_copy(self) -> None:
        self.assertIn("NSSavePanel", VIEWER)
        self.assertIn("ShareLink", VIEWER)
        self.assertIn("UIPasteboard.general.image", VIEWER)
        self.assertIn("NSPasteboard.general", VIEWER)

    def test_a_picture_you_sent_has_no_save(self) -> None:
        # "i guess i dont need to download image that im sending to u"
        self.assertIn("public let canExport: Bool", VIEWER)
        self.assertIn("if canExport {", VIEWER)
        for name, text in (("TranscriptRowView", MAC_ROW), ("MobileTranscript", IOS_ROW)):
            self.assertIn("canExport: false", text, f"{name} shows a picture the person already owns")

    def test_zoom_is_a_control_and_a_gesture(self) -> None:
        self.assertIn("MagnificationGesture", VIEWER)
        self.assertIn("Button(\"Fit\")", VIEWER)
        self.assertIn("minus.magnifyingglass", VIEWER)
        self.assertIn("plus.magnifyingglass", VIEWER)

    def test_the_mac_thumbnail_opens_the_viewer(self) -> None:
        self.assertIn("ImageViewer(data: item.data, title: item.name, canExport: false)", MAC_ROW)
        self.assertIn("viewingImage = ViewedImage(", MAC_ROW)
        self.assertIn(".sheet(item: $viewingImage)", MAC_ROW)

    def test_the_phone_thumbnail_opens_the_viewer(self) -> None:
        self.assertIn("ImageViewer(data: item.data, title: item.name, canExport: false)", IOS_ROW)
        self.assertIn("viewingImage = ViewedAttachment(", IOS_ROW)
        self.assertIn(".fullScreenCover(item: $viewingImage)", IOS_ROW)


if __name__ == "__main__":
    unittest.main()
