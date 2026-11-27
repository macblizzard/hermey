"""The update prompt offers the newest build, from a document read fresh.

The owner's report: several versions behind, the card offered 0.1.583, then after installing that
0.1.584, then 0.1.585 — one FlareStore signing cycle per hop. The published document advertises one
version, the newest, so a chained offer is a stale document or a stale choice. These checks pin the
four rules that stop it:

* the fetch ignores local and remote caches, and says so in headers and a fresh query key;
* a 304 means "the bytes just validated are current", never "there is no update";
* the chosen offer is the document's maximum build, not the first entry newer than this install;
* the persisted "already shown" build can refuse a stale offer, but can never select one.

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


class TheFetchCannotSeeACache(unittest.TestCase):
    def setUp(self):
        self.source = read(CHECKER_PATH)
        self.fetch = block(self.source, "private func fetch(", "static func cacheBusted(")

    def test_the_request_ignores_local_and_remote_caches(self):
        self.assertIn(".reloadIgnoringLocalAndRemoteCacheData", self.fetch,
                      "a protocol-policy request may be answered from URLCache on the phone")
        self.assertNotIn(".useProtocolCachePolicy", self.fetch)
        self.assertNotIn(".reloadIgnoringLocalCacheData,", self.fetch,
                         "the local-only policy leaves the CDN copy in play")

    def test_the_request_says_no_cache_in_headers_as_well(self):
        self.assertIn('setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")',
                      self.fetch)
        self.assertIn('setValue("no-cache", forHTTPHeaderField: "Pragma")', self.fetch)

    def test_the_url_carries_a_cache_key_no_earlier_request_used(self):
        fetch_start = self.source.index("private func fetch(")
        self.assertIn("Self.cacheBusted(url)", self.source[fetch_start:])
        busted = block(self.source, "static func cacheBusted(", "enum UpdateFeedError")
        self.assertIn('URLQueryItem(name: "cb"', busted)
        self.assertIn("Int(Date().timeIntervalSince1970)", busted,
                      "the key has to change between checks, or it is another cache hit")


class A304KeepsTheValidatedBytes(unittest.TestCase):
    def setUp(self):
        self.source = read(CHECKER_PATH)
        self.fetch = block(self.source, "private func fetch(", "static func cacheBusted(")
        self.branch = block(self.fetch, "case 304:", "default:")

    def test_a_304_is_not_an_answer_of_no_update(self):
        # The branch must produce bytes, not nil: `nil` is the shape that withdrew a real offer.
        self.assertNotIn("return nil", self.branch)
        self.assertNotIn("available = nil", self.branch)
        self.assertIn("if !data.isEmpty { return (data, .notModified", self.branch)

    def test_a_bodyless_304_falls_back_to_the_validated_cache_copy(self):
        self.assertIn("URLCache.shared.cachedResponse(", self.branch)
        self.assertIn(".cachedResponse", self.branch)
        self.assertIn("!cached.isEmpty", self.branch)

    def test_only_a_304_with_no_bytes_anywhere_is_an_error(self):
        self.assertIn("throw UpdateFeedError.notModifiedWithoutBody", self.branch)
        self.assertIn("case notModifiedWithoutBody", self.source)


class TheOfferIsTheDocumentsMaximumBuild(unittest.TestCase):
    def setUp(self):
        self.source = read(CHECKER_PATH)
        self.parse = block(self.source, "static func update(in data: Data) -> AvailableUpdate? {",
                           "/// Only HTTPS survives.")
        self.latest = block(self.source, "private func latestUpdate() async", "static func isInstallable(")

    def test_the_parser_reduces_to_the_maximum_build(self):
        self.assertIn("candidates.max(by: { $0.build < $1.build })", self.parse)
        self.assertNotIn("first(where:", self.parse,
                         "first-match returns an intermediate build when the document lists history")

    def test_the_newest_document_entry_is_the_only_installable_candidate(self):
        self.assertIn("let update = Self.update(in: fetched.data)", self.latest)
        self.assertIn("last.with(advertised: update, installable: update)", self.latest)
        self.assertNotIn("first(where:", self.latest)
        # A document whose newest entry is not installable here is skipped, never offered — but only
        # after `update(in:)` has had its chance to prefer an installable entry from the same
        # document, so this guard now means "no installable entry at all".
        self.assertIn("guard Self.isInstallable(update.url) else {", self.latest)
        self.assertIn("continue", self.latest)

    def test_a_document_with_an_installable_entry_is_not_disqualified_by_its_newest_row(self):
        # The newest row of a document can be an artifact this platform cannot use while an
        # installable one sits below it; refusing the whole document for that row turned a feed with
        # an update into "no document at all". The parser therefore reduces the *installable*
        # entries first, and only a document with none of them falls through to the plain maximum.
        self.assertIn("if let installable = candidates", self.parse)
        preference = self.parse.split("if let installable = candidates", 1)[1].split("return newest", 1)[0]
        self.assertIn(".filter({ Self.isInstallable($0.url) })", preference)
        self.assertIn(".max(by: { $0.build < $1.build })", preference)
        self.assertIn("return installable", preference)
        self.assertGreater(preference.index("return installable"),
                           preference.index(".filter("),
                           "the filter feeds the reduction, and its result is the offer")


class TheStoredBuildIsARecordNeverAVeto(unittest.TestCase):
    """A stored number may describe history; it may never refuse a document that is newer than the
    build running here.

    The report: the owner pressed "Check now" on 692 and was told nothing was available while both
    feeds advertised 693. A persisted "highest offered" value that sat above the feed's newest build
    is the one shape of veto that can do that, and there is no way for the app to tell it apart from
    a stale document — so the veto is gone, and only the card already on screen can hold a newer
    offer in place.
    """

    def setUp(self):
        self.source = read(CHECKER_PATH)
        self.check = block(self.source, "public func check(manual: Bool = false, atLaunch: Bool = false) async {",
                           "/// Turn one read of the feed into an offer")
        self.settle = block(self.source, "private func settle(_ read: FeedRead, installed: Int, manual: Bool)",
                            "/// Move a visible card")
        self.remember = block(self.source, "private func rememberOffered(", "/// One read of the feed")
        self.floor = block(self.source, "public var highestOfferedBuild: Int {",
                           "private static func bundleString(")

    def test_no_stored_value_can_refuse_a_fresh_document(self):
        # The old guard, verbatim, must be gone from both halves of the decision.
        self.assertNotIn("guard found.build >= highestOfferedBuild", self.source)
        self.assertNotIn("highestOfferedBuild", self.settle,
                         "the decision may not consult a stored number")
        self.assertNotIn("skippedBuild", self.settle.split("if !manual, found.build == skippedBuild", 1)[1],
                         "the skip applies to exactly one build, and only to an unsolicited check")

    def test_the_floor_is_read_once_for_the_log_and_never_for_a_decision(self):
        self.assertEqual(self.check.count("highestOfferedBuild"), 1)
        for line in self.check.splitlines():
            if "highestOfferedBuild" in line:
                self.assertIn("let floor =", line,
                              "the only read is the value the log line prints")
        self.assertIn("highest: floor", self.check)

    def test_a_document_newer_than_this_install_is_always_offered(self):
        # The last thing `settle` can do is offer: every refusal above it is keyed on the document
        # itself, never on stored history.
        tail = self.settle.split("if !manual, found.build == skippedBuild", 1)[1]
        self.assertIn("available = found", tail)
        self.assertIn("isPromptVisible = true", tail)
        self.assertIn("return (.offered(found)", tail)

    def test_the_stale_document_protection_is_the_card_on_screen(self):
        # What replaces the floor: a document older than a card already up cannot retract it.
        self.assertIn("shown.build > build", self.settle)
        self.assertIn("keepingNewerCard", self.settle)

    def test_the_offer_is_built_from_the_document_only(self):
        self.assertIn("available = found", self.settle)
        # Every AvailableUpdate construction is in the initializer or the parser, never from defaults.
        constructions = [line for line in self.source.splitlines()
                         if "AvailableUpdate(" in line and "public init(" not in line
                         and "-> AvailableUpdate" not in line]
        self.assertTrue(constructions)
        for line in constructions:
            self.assertNotIn("defaults", line)
            self.assertNotIn("highestOffered", line)

    def test_writing_the_floor_is_monotonic(self):
        self.assertIn("guard build > defaults.integer(forKey: DefaultsKey.highestOfferedBuild) else { return }",
                      self.remember)
        self.assertIn("defaults.set(build, forKey: DefaultsKey.highestOfferedBuild)", self.remember)

    def test_an_older_install_still_counts_as_already_shown(self):
        # A device upgrading to this build has only `skippedBuild` from before; the record must still
        # describe what it was shown.
        self.assertIn("max(defaults.integer(forKey: DefaultsKey.highestOfferedBuild), skippedBuild ?? 0)",
                      self.floor)


class EveryCheckLeavesOneSettlingLine(unittest.TestCase):
    def setUp(self):
        self.source = read(CHECKER_PATH)
        self.check = block(self.source, "public func check(manual: Bool = false, atLaunch: Bool = false) async {",
                           "/// Turn one read of the feed into an offer")
        self.log = block(self.source, "static func logCheck(", "/// Remember the build that was actually shown")

    def test_the_check_logs_exactly_once(self):
        self.assertEqual(self.check.count("Self.logCheck("), 1,
                         "one line per check, or the phone's line cannot be matched to a build")

    def test_the_line_names_source_url_state_and_every_build(self):
        self.assertIn("source=\\(source)", self.log)
        self.assertIn(".absoluteString", self.log)
        for field in ("state=", "http=", "age=", "advertised=", "installable=", "installed=",
                      "highest=", "offer="):
            self.assertIn(field, self.log, f"the log line must carry {field!r}")
        self.assertIn('category: "update"', self.log)

    def test_the_installable_build_is_logged_separately_from_the_advertised_one(self):
        # "advertised=693 installable=none" is the shape that explains a phone offered nothing while
        # the document named a newer build; one field for both hid it.
        self.assertIn('let installable = read.installable.map { String($0.build) } ?? "none"', self.log)
        self.assertIn('let advertised = read.advertised.map { "\\($0.build) (\\($0.version))" } ?? "none"',
                      self.log)

    def test_the_log_is_emitted_after_the_decision_and_no_longer_guards_it(self):
        # The line has to describe what `settle` decided, so it is written after it; every reason for
        # "no offer" now reaches the log as text instead of leaving through an early return.
        self.assertLess(self.check.index("let settled = settle("),
                        self.check.index("Self.logCheck("))
        self.assertIn("offer: settled.log", self.check)


if __name__ == "__main__":
    unittest.main()
