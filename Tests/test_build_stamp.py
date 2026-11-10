"""Guards for the two files that advertise a build: the README and the Pages landing page.

A version written by hand rots the moment the next build ships — these tests hold the shape that
makes the release tools able to keep it current (the markers), and fail on the specific rot that
already happened: a download URL pinned to one release's asset name.
"""

from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools" / "release"))
import build_stamp  # noqa: E402


class StampTests(unittest.TestCase):
    def test_replace_rewrites_only_the_marked_block(self):
        text = f"head\n{build_stamp.BEGIN}\nold\n{build_stamp.END}\ntail\n"
        stamped = build_stamp.replace(text, "\nnew\n")
        self.assertEqual(stamped, f"head\n{build_stamp.BEGIN}\nnew\n{build_stamp.END}\ntail\n")

    def test_a_file_without_markers_is_left_alone(self):
        self.assertIsNone(build_stamp.replace("no markers here", "x"))
        self.assertIsNone(build_stamp.current("no markers here"))

    def test_matches_is_exact(self):
        text = f"{build_stamp.BEGIN}body{build_stamp.END}"
        self.assertTrue(build_stamp.matches(text, "body"))
        self.assertFalse(build_stamp.matches(text, "body "))
        self.assertFalse(build_stamp.matches(text, "other"))

    def test_readme_body_names_the_build(self):
        body = build_stamp.readme_body("0.1.66", "66")
        self.assertIn("0.1.66", body)
        self.assertIn("66", body)
        self.assertEqual(build_stamp.replace(f"{build_stamp.BEGIN}x{build_stamp.END}",
                                             build_stamp.readme_body("0.1.66", "66")),
                         f"{build_stamp.BEGIN}{body}{build_stamp.END}")

    def test_index_body_names_the_file_it_serves(self):
        body = build_stamp.index_body("0.1.66", "66", "Hermey-0.1.66-b66.ipa")
        self.assertIn("0.1.66", body)
        self.assertIn("Hermey-0.1.66-b66.ipa", body)


class RepoDocTests(unittest.TestCase):
    def test_readme_has_a_stamped_build_line(self):
        readme = (ROOT / "README.md").read_text()
        self.assertIsNotNone(build_stamp.current(readme),
                             "README.md lost its build markers; the release tools can no longer "
                             "keep the visible build line current")
        self.assertIn("Latest published build", build_stamp.current(readme))

    def test_no_doc_pins_a_versioned_asset(self):
        # `releases/download/v0.1.66/...` 404s the moment the next build ships; every doc link must
        # go through `releases/latest` (or the SHA-addressed source manifest).
        offenders = []
        for path in [ROOT / "README.md", ROOT / "llms.txt", *sorted((ROOT / "docs").glob("*.md"))]:
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if re.search(r"releases/download/v\d", line):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertEqual(offenders, [])

    def test_install_url_is_the_release_asset_every_doc_promises(self):
        # That URL only works because `publish_altstore.py` uploads `setup/install.sh` to the
        # release; this asserts the docs and the tool still agree about the name.
        publish = (ROOT / "Tools" / "release" / "publish_altstore.py").read_text()
        self.assertIn('"setup" / "install.sh"', publish)
        self.assertIn("releases/latest/download/install.sh", (ROOT / "README.md").read_text())


if __name__ == "__main__":
    unittest.main()
