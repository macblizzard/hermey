"""The `highest=` in the update log is a record the document can never make absurd.

The owner's 0.1.698 phone log carried `highest=1011` beside a document advertising a 0.1.7xx
build. Nothing read that number any more — the stored floor stopped gating offers when the chain
of installs was fixed (`test_update_offer_is_newest.py`) — but a diagnostic that prints a build
newer than the newest build in existence reads as a corrupted install, and a phone log is read by
people. These checks pin the two halves of the correction:

* the number printed and persisted is bounded by the newest build the document named, and a stale
  record is rewritten to the build running here (with one line saying so);
* the record still decides nothing: `settle` never reads it, so clamping it cannot change an offer.

Swift does not build on this host, so the checks read the implementation the way the other update
tests do: they fail if the corresponding line is removed or weakened.
"""

import re
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECKER_PATH = ROOT / "Sources" / "HermesAppKit" / "Updates" / "UpdateChecker.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def block(source: str, start: str, end: str) -> str:
    """The text between two anchors, so an assertion cannot pass from an unrelated file part."""
    if start not in source:
        raise AssertionError(f"missing anchor: {start!r}")
    tail = source.split(start, 1)[1]
    if end not in tail:
        raise AssertionError(f"missing end anchor after {start!r}: {end!r}")
    return tail.split(end, 1)[0]


class TheRecordIsBoundedByTheDocument(unittest.TestCase):
    def setUp(self):
        self.source = read(CHECKER_PATH)
        self.check = block(self.source, "public func check(manual: Bool = false",
                           "/// Turn one read of the feed into an offer")
        self.clamp = block(self.source, "private func plausibleHighest(document: Int?)",
                           "/// Remember the build that was actually shown.")

    def test_the_check_bounds_the_record_against_the_document_it_read(self):
        self.assertIn("plausibleHighest(document:", self.check,
                      "the logged record has to be bounded by the document this check read")
        self.assertIn("read.advertised?.build ?? read.installable?.build", self.check,
                      "the ceiling is the newest build the document named")
        self.assertNotIn("let floor = highestOfferedBuild", self.check,
                         "the raw record is what printed 1011")

    def test_a_record_above_the_newest_build_is_rewritten_to_this_install(self):
        self.assertIn("let ceiling = max(document ?? 0, currentBuild)", self.clamp)
        self.assertIn("guard recorded > ceiling else { return recorded }", self.clamp)
        self.assertIn("defaults.set(reset, forKey: DefaultsKey.highestOfferedBuild)", self.clamp,
                      "a stale number left in defaults prints again on the next failed check")
        self.assertIn("let reset = currentBuild > 0 ? currentBuild : ceiling", self.clamp)

    def test_the_number_printed_never_exceeds_the_newest_build_seen(self):
        # `min(…, ceiling)` on the returned value: `skippedBuild` is the other half of the max and
        # is the person's own answer, so it cannot be rewritten — it has to be bounded on the way out.
        self.assertIn("let reported = min(max(defaults.integer(forKey: DefaultsKey.highestOfferedBuild),",
                      self.clamp)
        self.assertIn("min(skippedBuild ?? 0, ceiling)", self.clamp)
        self.assertIn("return reported", self.clamp)

    def test_the_clamp_says_so_once(self):
        self.assertIn("Self.note(\"update: highest record \\(recorded) is above the newest build",
                      self.clamp,
                      "a silent rewrite leaves the next reader guessing where 1011 went")


class TheRecordStillDecidesNothing(unittest.TestCase):
    """The clamp is safe only because the value was already inert. Pin that it stays inert."""

    def setUp(self):
        self.source = read(CHECKER_PATH)
        self.settle = block(self.source, "private func settle(_ read: FeedRead",
                            "/// Move a visible card to another presentation context")

    def test_settle_never_reads_the_record(self):
        self.assertNotIn("highestOfferedBuild", self.settle,
                         "an offer is a function of the document and the install only")
        self.assertNotIn("plausibleHighest", self.settle)
        self.assertIn("guard found.build > installed else", self.settle)

    def test_the_record_is_only_written_when_a_card_is_actually_shown(self):
        remember = block(self.source, "private func rememberOffered(_ build: Int)",
                         "/// One read of the feed")
        self.assertIn("defaults.set(build, forKey: DefaultsKey.highestOfferedBuild)", remember)
        # Exactly two writers for the key: the offer that was shown, and the clamp above. A third
        # would be a second meaning for the same name.
        writes = re.findall(r"defaults\.set\([^\n]*highestOfferedBuild\)", self.source)
        self.assertEqual(2, len(writes), "only the offer and the clamp may write the record")
        self.assertEqual(1, len(re.findall(r"rememberOffered\(", self.source)) - 1,
                         "rememberOffered is called from exactly one place — the offer")


if __name__ == "__main__":
    unittest.main()
