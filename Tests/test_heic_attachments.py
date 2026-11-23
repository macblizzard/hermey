"""An iPhone photo must be attachable.

The host's `image.attach_bytes` sniffs the extension and refuses anything outside Hermes's own
`_IMAGE_EXTENSIONS` (png, jpg, jpeg, gif, webp, bmp — its fallback list names exactly those). A camera
roll is HEIC by default, so every photo taken on the phone came back as

    send with attachments failed: unsupported image extension: .heic

after the picture had been chosen and previewed. These checks keep the conversion in place: it is
cheaper and more honest to re-encode on the client than to teach the host about a format it does not
need to know.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRANSCODING = (ROOT / "Sources" / "HermesKit" / "ImageTranscoding.swift").read_text(encoding="utf-8")
APP_MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")

HOST_REFUSED = ["heic", "heif"]


class TheTranscoder(unittest.TestCase):
    def test_it_names_the_extensions_the_host_refuses(self) -> None:
        for ext in HOST_REFUSED:
            self.assertIn(f'"{ext}"', TRANSCODING)

    def test_it_writes_jpeg(self) -> None:
        self.assertIn("UTType.jpeg.identifier", TRANSCODING)
        self.assertIn("CGImageDestinationCreateWithData", TRANSCODING)
        self.assertIn("CGImageDestinationFinalize", TRANSCODING)
        # A quality setting, so a 12 MP photo stays inside the 8 MB attachment budget.
        self.assertIn("kCGImageDestinationLossyCompressionQuality", TRANSCODING)

    def test_the_name_becomes_a_jpg(self) -> None:
        self.assertIn('jpegExtension = "jpg"', TRANSCODING)
        self.assertIn("deletingPathExtension", TRANSCODING)

    def test_an_undecodable_file_is_passed_through_untouched(self) -> None:
        # Every failure path returns the original name/data with converted=false: an attachment must
        # never be lost to a failed transcode, and the host's own error is the honest one to show.
        # Four refusals — not convertible, unreadable source, no destination, finalise failed — each
        # returning the original bytes, plus the not-an-image early return in `jpegIfNeeded`.
        self.assertGreaterEqual(TRANSCODING.count("converted: false"), 4)

    def test_only_images_are_converted_by_the_model(self) -> None:
        body = APP_MODEL[APP_MODEL.index("func addPendingAttachment"):]
        body = body[: body.index("\n    }")]
        self.assertIn("isImage", body)
        self.assertIn("ImageTranscoding.jpegIfNeeded", body)
        # Conversion happens before the size guard, so the limit applies to what is actually sent.
        self.assertLess(body.index("ImageTranscoding.jpegIfNeeded"),
                        body.index("maxAttachmentBytes"))


if __name__ == "__main__":
    unittest.main()
