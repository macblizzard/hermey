"""Release notes are written for the update prompt, and both prompts get them."""

import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = ROOT / "Tools" / "release" / "release_notes.py"
DIST = (ROOT / "Tools" / "release" / "publish_dist.py").read_text()
CHECKER = (ROOT / "Sources" / "HermesAppKit" / "Updates" / "UpdateChecker.swift").read_text()
PROMPT = (ROOT / "Apps" / "HermesMobile" / "Views" / "UpdatePrompt.swift").read_text()
sys.path.insert(0, str(ROOT / "Tools" / "release"))
import release_notes  # noqa: E402


class TheNotesSayWhatChanged(unittest.TestCase):
    def test_feature_and_fix_subjects_become_bullets(self) -> None:
        self.assertEqual(release_notes.clean("feat(faces): working moves"), "Working moves")
        self.assertEqual(release_notes.clean("fix: the cache was not trusted"), "The cache was not trusted")

    def test_machinery_is_dropped(self) -> None:
        for subject in ("chore: bump", "test: add case", "ci: split job",
                        "fix(tests): the import", "feat(release): publish tooling",
                        "docs: readme", "publish 0.1.496 (496)"):
            self.assertIsNone(release_notes.clean(subject), subject)

    def test_a_plain_subject_is_kept(self) -> None:
        self.assertEqual(release_notes.clean("Add Sparkle"), "Add Sparkle")

    def test_it_runs_against_this_repository(self) -> None:
        output = subprocess.run([sys.executable, str(TOOL)], capture_output=True, text=True,
                                cwd=ROOT, check=True).stdout
        # The checkout this runs in may be shallow (CI), in which case there is no history to read
        # and the tool says so instead of emitting nothing.
        self.assertTrue(output.strip(), "a release must carry some notes")


class BothPromptsCarryThem(unittest.TestCase):
    def test_the_appcast_keeps_its_line_breaks(self) -> None:
        # Sparkle renders the description as HTML; a newline there is only a space.
        self.assertIn('"<br/>".join(html.escape(line)', DIST)

    def test_the_card_parses_notes_from_both_feeds(self) -> None:
        self.assertIn("let localizedDescription: String?", CHECKER)
        self.assertIn("let notes: String?", CHECKER)
        self.assertIn("notes: entry.localizedDescription", CHECKER)
        self.assertIn("notes: document.notes", CHECKER)

    def test_the_card_shows_them_without_pushing_its_buttons_away(self) -> None:
        # The notes are the scrolling part and the actions are outside it. Capping the notes view
        # with `.frame(maxHeight:)` while the buttons sat after it in the same stack is what pushed
        # the Download button below the fold of a `.medium` detent — "there is no download button".
        self.assertIn("if !update.notes.trimmingCharacters", PROMPT)
        scrolling = PROMPT.split("ScrollView {", 1)[1].split("// The actions never scroll", 1)[0]
        self.assertIn("Text(update.notes)", scrolling)
        self.assertNotIn('Text("Download")', scrolling)
        actions = PROMPT.split("// The actions never scroll", 1)[1]
        self.assertIn('Text("Download")', actions)
        self.assertIn(".presentationDetents([.medium, .large])", PROMPT)


if __name__ == "__main__":
    unittest.main()
