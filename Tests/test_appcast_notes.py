"""Sparkle's update dialog says what changed, from the changelog, not "Build X (Y)".

The failure this pins: `Mo updates Hermey and the notes area reads only "Build 0.1.60x (60x)."`
The GitHub release page had the notes; the appcast did not, because `publish_altstore.py` built
`<description>`, both `localizedDescription`s and `mac.json` from `args.notes`, which nothing ever
passed. The changelog had the text the whole time.

A previous attempt at this put the helper *inside* `main()`, which is invisible to an importer and
left the publisher exiting 0 without doing its work — so the checks below do not just read the
source: they run `main()` end to end against stub `gh`/`git` calls and inspect what it would have
published.
"""

import contextlib
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASE = ROOT / "Tools" / "release"
ALTSTORE = (RELEASE / "publish_altstore.py").read_text(encoding="utf-8")
CHANGELOG = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
sys.path.insert(0, str(RELEASE))
import publish_altstore  # noqa: E402
import publish_dist  # noqa: E402

#: A section that exists in CHANGELOG.md, with a bullet that is stable history rather than the
#: still-moving `[Unreleased]` block.
KNOWN_VERSION = "0.1.13"
KNOWN_LINE = "Unread counts"
IPA_ENTRY = {"CFBundleShortVersionString": KNOWN_VERSION, "CFBundleVersion": "1313",
             "CFBundleIdentifier": "dev.hermey.app", "MinimumOSVersion": "17.0"}


class TheNotesComeFromTheChangelog(unittest.TestCase):
    def test_the_helper_is_module_level_and_before_main(self) -> None:
        # `def changelog_notes` nested inside `main()` is the bug that shipped: `import` sees nothing,
        # and a helper defined at 4-space indentation runs only if `main()` reaches it.
        self.assertEqual(publish_altstore.changelog_notes.__qualname__, "changelog_notes")
        self.assertIn("\ndef changelog_notes(version: str) -> str:", ALTSTORE)
        self.assertLess(ALTSTORE.index("\ndef changelog_notes("), ALTSTORE.index("\ndef main("))

    def test_a_known_version_answers_with_its_own_section(self) -> None:
        notes = publish_altstore.changelog_notes(KNOWN_VERSION)
        self.assertTrue(notes.strip(), "a released version must have notes")
        self.assertIn(KNOWN_LINE, notes)
        # The heading line is a date, not news: it must not be the first thing the dialog draws.
        self.assertFalse(notes.lstrip().startswith("—"), notes[:40])
        self.assertNotIn(f"## [{KNOWN_VERSION}]", notes)

    def test_an_unknown_version_falls_back_to_unreleased(self) -> None:
        notes = publish_altstore.changelog_notes("0.0.0-not-a-release")
        self.assertIn("### Added", notes)
        # ...and it is clipped, because `[Unreleased]` between releases is a document, not a dialog.
        self.assertLessEqual(len(notes), publish_altstore.MAX_NOTE_CHARS + 4)

    def test_a_changelog_that_is_not_there_is_not_an_exception(self) -> None:
        with mock.patch.object(publish_altstore, "CHANGELOG",
                               pathlib.Path(tempfile.gettempdir()) / "no-such-changelog.md"):
            self.assertEqual(publish_altstore.changelog_notes(KNOWN_VERSION), "")

    def test_the_notes_are_resolved_once_and_nothing_reads_args_notes_again(self) -> None:
        # One resolution, then every destination takes that value. Two of them reading `args.notes`
        # directly is how the body and the appcast drifted apart in the first place.
        self.assertIn('notes = (args.notes or changelog_notes(version)', ALTSTORE)
        code = [line for line in ALTSTORE.splitlines() if not line.lstrip().startswith("#")]
        reads = sum(line.count("args.notes") for line in code)
        self.assertLessEqual(reads, 2,
                             "args.notes may only appear in the one resolution (and its log line)")


class TheAppcastCarriesThem(unittest.TestCase):
    """The dialog's text is `publish_dist.appcast_document`'s `<description>`, built from the notes."""

    def setUp(self) -> None:
        self.entry = {
            "version": KNOWN_VERSION, "buildVersion": "1313",
            "date": "2026-11-09T12:00:00Z",
            "localizedDescription": publish_altstore.changelog_notes(KNOWN_VERSION),
            "downloadURL": "https://example.test/Hermey.ipa", "size": 1234,
            "minOSVersion": "17.0", "sha256": "0" * 64,
        }
        self.appcast = publish_dist.appcast_document(
            self.entry, self.entry["downloadURL"], self.entry["size"], "signature",
            self.entry["localizedDescription"], "https://example.test/releases")

    def description(self) -> str:
        # The channel description ("Hermey for macOS") is first; the item's is the second.
        return self.appcast.split("<description>")[2].split("</description>")[0]

    def test_the_description_is_the_changelog_and_not_the_placeholder(self) -> None:
        description = self.description()
        self.assertIn(KNOWN_LINE, description)
        self.assertNotIn(f"Build {KNOWN_VERSION}", description)
        self.assertTrue(description.strip())

    def test_line_breaks_survive_as_html(self) -> None:
        # One bullet per line is the shape Sparkle draws; a raw newline would collapse into a space.
        self.assertIn("<br/>", self.description())


class ThePublisherStillRuns(unittest.TestCase):
    """`main()` end to end, with `gh` and `git` stubbed: a publisher that returns 0 and publishes
    nothing is the failure mode this fix has to prove it did not reintroduce."""

    def run_publisher(self, already_released: bool) -> tuple[int, list[list[str]], dict]:
        calls: list[list[str]] = []
        captured: dict = {}

        def fake_run(cmd, **kwargs):
            calls.append(list(cmd))
            if cmd[:2] == ["git", "clone"]:
                pathlib.Path(cmd[-1]).mkdir(parents=True, exist_ok=True)
            if cmd[:2] == ["git", "-C"] and "status" in cmd:
                return ""
            return ""

        def fake_pages(repo, tag, work, version, build, ipa_name):
            # The manifest `main()` wrote, as the page publisher would have carried it.
            captured["altstore"] = json.loads((work / "altstore.json").read_text(encoding="utf-8"))

        with tempfile.TemporaryDirectory() as scratch:
            ipa = pathlib.Path(scratch) / "Hermey.ipa"
            ipa.write_bytes(b"not a real ipa: the reader is stubbed")
            argv = ["publish_altstore.py", "--ipa", str(ipa), "--repo", "owner/name",
                    "--skip-release-verify"]
            with mock.patch.object(publish_altstore, "run", fake_run), \
                    mock.patch.object(publish_altstore, "read_ipa", lambda _p: dict(IPA_ENTRY)), \
                    mock.patch.object(publish_altstore, "release_has",
                                      lambda repo, tag, asset: already_released), \
                    mock.patch.object(publish_altstore, "publish_pages", fake_pages), \
                    mock.patch.object(sys, "argv", argv), \
                    contextlib.redirect_stdout(io.StringIO()):
                code = publish_altstore.main()
        return code, calls, captured

    def test_it_exits_zero_and_actually_calls_gh(self) -> None:
        for already_released in (True, False):
            code, calls, captured = self.run_publisher(already_released)
            self.assertEqual(code, 0)
            self.assertIn("altstore", captured, "main() never wrote a manifest")
            verbs = [" ".join(call[:3]) for call in calls if call and call[0] == "gh"]
            expected = "gh release edit" if already_released else "gh release create"
            self.assertIn(expected, verbs)

    def test_the_release_body_carries_the_changelog(self) -> None:
        for already_released in (True, False):
            _code, calls, _captured = self.run_publisher(already_released)
            body = [call for call in calls
                    if call[:3] == ["gh", "release", "edit" if already_released else "create"]]
            self.assertTrue(body)
            notes = body[-1][body[-1].index("--notes") + 1]
            self.assertIn(KNOWN_LINE, notes)
            self.assertNotIn("Build 0.1.13", notes)

    def test_both_manifests_and_the_appcast_agree_with_the_body(self) -> None:
        _code, _calls, captured = self.run_publisher(already_released=True)
        entry = captured["altstore"]["apps"][0]["versions"][0]
        self.assertIn(KNOWN_LINE, entry["localizedDescription"])
        appcast = publish_dist.appcast_document(
            entry, entry["downloadURL"], entry["size"], "signature",
            entry["localizedDescription"], "https://example.test/releases")
        self.assertIn(KNOWN_LINE, appcast.split("<description>")[2].split("</description>")[0])

    def test_the_cli_still_parses(self) -> None:
        result = subprocess.run([sys.executable, str(RELEASE / "publish_altstore.py"), "--help"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--notes", result.stdout)


class TheWrapperDoesNotInventNotes(unittest.TestCase):
    """The publish script is where `args.notes` came from: it defaulted to a placeholder, so the
    publisher's own changelog fallback could never run."""

    WRAPPER = (RELEASE / "publish_github.sh").read_text(encoding="utf-8")

    def test_it_passes_no_notes_unless_the_owner_set_them(self) -> None:
        # Comments may explain the old placeholder; a live line carrying it is the bug.
        code = "\n".join(line for line in self.WRAPPER.splitlines()
                         if not line.lstrip().startswith("#"))
        self.assertNotIn("Build from CI run", code,
                         "a placeholder `--notes` outranks the changelog and empties the dialog")
        self.assertIn('NOTES_ARGS=(--notes "$NOTES")', code)
        self.assertIn('if [ -n "${NOTES:-}" ]; then', code)
        self.assertNotIn("${NOTES:-Build", code, "--notes must be an override, never a default")

    def test_the_wrapper_still_parses(self) -> None:
        result = subprocess.run(["bash", "-n", str(RELEASE / "publish_github.sh")],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
