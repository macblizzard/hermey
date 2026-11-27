"""The update machinery's four repair points, pinned where neither compiler can see them.

The audit of 2026-11-27 (`docs/SECURITY_TASKS.md`, updates machinery) found four defects that no
compile or unit test caught, because each lives in the *order* of two steps that are both individually
correct:

1. the iOS feed was read from `releases/latest/download/altstore.json` first, and a `hermeyd-v*`
   release being `latest` made that a 404 whose only fallback named a `.dmg` — so the phone said
   "not installable here" while the correct Pages document was never tried;
2. the host update row's "Try again" was dead code: `refused`/`timedOut` settle the row, so the
   retry POSTed (and the host did install), then discarded the ack and kept saying "Update failed";
3. a manual "Check now" landing on an in-flight launch check was folded into it with the launch
   check's own presentation, so the card it offered was queued behind the Settings sheet;
4. `hermeyd`'s install swapped the binary and *then* wrote `update-state.json`, so a failed state
   write left a new binary on disk with no rollback record.

Swift does not build on this host; the Rust side has its own suite (`hermeyd`), which carries the
behavioural proof of #4. These checks pin the source of both.
"""

from __future__ import annotations

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

CHECKER = (ROOT / "Sources" / "HermesAppKit" / "Updates" / "UpdateChecker.swift").read_text(
    encoding="utf-8"
)
TRACKER = (ROOT / "Sources" / "HermesAppKit" / "HostUpdate.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesKit" / "HostUpdate.swift").read_text(encoding="utf-8")
UPDATE_RS = (ROOT / "hermeyd" / "src" / "update.rs").read_text(encoding="utf-8")


def block(source: str, start: str, end: str) -> str:
    """The text between two anchors, so an assertion cannot pass from an unrelated file part."""
    if start not in source:
        raise AssertionError(f"missing anchor: {start!r}")
    tail = source.split(start, 1)[1]
    if end not in tail:
        raise AssertionError(f"missing end anchor after {start!r}: {end!r}")
    return tail.split(end, 1)[0]


class TheFeedOrderPutsThePagesDocumentFirst(unittest.TestCase):
    """`/releases/latest` is whichever release GitHub marks latest, and every publish also cuts a
    `hermeyd-v*` release — one with no `altstore.json` asset at all. So the release URL that used to
    be the primary source was a 404 more often than not, and the only fallback (`mac.json`) names a
    `.dmg` the iOS check refuses: the phone concluded "not installable here" without ever reading
    the Pages document that is always the app feed."""

    def setUp(self) -> None:
        self.checker = CHECKER
        self.feeds = block(self.checker, "static var feedURLs: [URL] {", "}")

    def test_the_primary_source_is_the_pages_document(self) -> None:
        self.assertIn(
            'public static let sourceURL = URL(string: '
            '"https://macblizzard.github.io/hermey-downloads/altstore.json")',
            self.checker,
            "the app feed must be the one URL every publish rewrites, not a moving `latest`")

    def test_the_release_asset_survives_as_a_fallback(self) -> None:
        self.assertIn(
            "https://github.com/macblizzard/hermey/releases/latest/download/altstore.json",
            self.checker,
            "the release asset is still a document when an app release is `latest`")

    def test_the_check_reads_pages_first_then_the_release_then_the_mac_document(self) -> None:
        order = [self.feeds.index(name) for name in
                 ("Self.sourceURL", "Self.releaseSourceURL", "Self.fallbackSourceURL")]
        self.assertEqual(order, sorted(order),
                         "the Pages app feed answers first; the others are fallbacks")
        self.assertIn("for url in Self.feedURLs", self.checker,
                      "the read walks the ordered list, not two hand-picked URLs")

    def test_the_log_says_which_document_answered(self) -> None:
        latest = block(self.checker, "private func latestUpdate() async",
                       "/// Whether this platform can install")
        self.assertIn('Self.note("update: answered by \\(url.absoluteString)',
                      latest,
                      "three sources can carry the same build; the log must name the one read")


class ADocumentWithAnInstallableEntryIsNeverDisqualified(unittest.TestCase):
    """The platform filter refused a whole document because its *newest* row was a `.dmg`, even when
    an installable `.ipa` sat below it — one manifest with a non-installable top entry read as "no
    document at all"."""

    def setUp(self) -> None:
        self.parse = block(CHECKER, "static func update(in data: Data) -> AvailableUpdate? {",
                           "/// Only HTTPS survives.")

    def test_the_newest_installable_entry_is_preferred_over_the_newest_overall(self) -> None:
        self.assertIn("candidates\n                .filter({ Self.isInstallable($0.url) })",
                      self.parse,
                      "the installable entries are filtered before the reduction, not after")
        installable = self.parse.split("if let installable = candidates", 1)[1]
        self.assertIn(".max(by: { $0.build < $1.build })", installable,
                      "the newest installable entry is the offer")
        self.assertIn("return installable", installable)

    def test_a_document_with_no_installable_entry_still_falls_through_to_newest(self) -> None:
        # `latestUpdate` refuses whatever comes back with no installable URL, so `newest` here is
        # only ever a *description* for the log — never an offer. The document is not swallowed.
        self.assertIn("return newest", self.parse)
        self.assertGreater(self.parse.index("return newest"),
                           self.parse.index("return installable"))

    def test_the_reduction_is_still_a_max_not_a_first_match(self) -> None:
        self.assertIn("candidates.max(by: { $0.build < $1.build })", self.parse)
        self.assertNotIn("first(where:", self.parse)


class AFailedHostUpdateRowIsRetryable(unittest.TestCase):
    """`refused` and `timedOut` settle their row, and `pressed` refused a settled row — so the "Try
    again" button the failed row itself offers POSTed to the host (which installed), then discarded
    the ack and left the row saying "Update failed"."""

    def setUp(self) -> None:
        self.pressed = block(TRACKER, "public mutating func pressed(",
                             "/// The host refused the press")

    def test_a_settled_failure_is_reopened_by_a_press(self) -> None:
        self.assertIn("guard !settled || update?.phase.isFailure == true else { return }",
                      self.pressed,
                      "a failed row is pressable; a settled success is not")

    def test_the_retry_clears_the_settled_state_so_the_poll_watches_it_again(self) -> None:
        self.assertIn("settled = false", self.pressed,
                      "without this the poll still saw the attempt as finished and broke at once")

    def test_a_failure_is_a_phase_the_row_can_name(self) -> None:
        self.assertIn("public var isFailure: Bool", MODEL)
        self.assertIn("if case .failed = self { return true }", MODEL)

    def test_a_refused_or_timed_out_attempt_leaves_no_pending_install(self) -> None:
        # `settle` is the only way both write, and it clears `pressedAt` — the press is closed, so
        # no later check can complete an attempt nobody is pressing.
        settle = TRACKER.split("private mutating func settle(", 1)[1]
        self.assertIn("settled = true\n        pressedAt = nil", settle)
        for caller in ("public mutating func refused(", "public mutating func timedOut()"):
            self.assertLess(TRACKER.index(caller), TRACKER.index("private mutating func settle("),
                            f"{caller} settles through the one closing site")


class AManualCheckAlwaysSurfacesItsOwnOutcome(unittest.TestCase):
    """A manual press folded into an in-flight launch check settled with the launch check's
    presentation (`promptHost = .root`), so the card was asked for by the shell and queued behind the
    Settings sheet the press came from."""

    def setUp(self) -> None:
        self.check = block(CHECKER, "public func check(manual: Bool = false, atLaunch: Bool = false) async {",
                           "/// Turn one read of the feed into an offer")

    def test_a_press_on_a_check_in_flight_joins_it_by_name(self) -> None:
        self.assertIn('Self.note("update: check(source=manual) joins=in-flight")', self.check)
        gate = self.check.split("guard !isChecking else {", 1)[1].split("return", 1)[0]
        self.assertIn("manualJoinsCheck = true", gate,
                      "the press is answered by the check in flight, with its own presentation")

    def test_the_join_flag_is_consumed_before_the_decision(self) -> None:
        consume = block(self.check, "let asked = manual || manualJoinsCheck",
                        "let settled = settle(read, installed: installed, manual: asked)")
        self.assertIn("manualJoinsCheck = false", consume,
                      "consumed once, so it cannot leak into a later unsolicited check")
        self.assertIn("settle(read, installed: installed, manual: asked)", self.check,
                      "the joined press rides on the answer, not on `manual` alone")

    def test_the_log_names_both_askers(self) -> None:
        self.assertIn('source += "+manual"', self.check,
                      "one line per check, and the line says a manual press was folded in")


class TheHostRecordsTheInstallBeforeSwappingTheBinary(unittest.TestCase):
    """`update-state.json` is the whole of the rollback mechanism. Written *after* the rename, a
    failed write left the new binary on disk with no record: no attempt counting, no `.prev`
    restore, and a broken build crash-looping with nothing to roll back to."""

    def setUp(self) -> None:
        self.install = block(UPDATE_RS, "fn install(cfg: &Config, target: &str) -> Result<(), StepError> {",
                             "async fn fetch_bytes")
        self.apply = block(UPDATE_RS, "async fn apply(cfg: Config, release: Release,",
                           "// ---- boot")

    def test_the_state_is_written_before_the_backup_and_the_rename(self) -> None:
        self.assertIn('write_state(&cfg.state_path(), &record)', self.install)
        order = [self.install.index(needle) for needle in
                 ("write_state(&cfg.state_path(), &record)",
                  "std::fs::copy(&cfg.bin, cfg.prev())",
                  "std::fs::rename(cfg.staged(), &cfg.bin)")]
        self.assertEqual(order, sorted(order),
                         "record, then backup, then swap — a swap with no record is unrollbackable")

    def test_a_state_write_failure_refuses_the_swap(self) -> None:
        after = self.install.split("write_state(&cfg.state_path(), &record)", 1)[1]
        before_copy = after.split("std::fs::copy", 1)[0]
        self.assertIn('"state_write_failed"', before_copy)
        self.assertIn(".map_err", before_copy)
        self.assertIn("})?;", before_copy,
                      "the failure propagates with `?`, so install returns before anything is swapped")

    def test_a_state_write_failure_is_exercised_and_installs_nothing(self) -> None:
        self.assertIn("fn a_state_write_failure_installs_nothing", UPDATE_RS)
        test = block(UPDATE_RS, "fn a_state_write_failure_installs_nothing(",
                     "    // ---- the state machine")
        self.assertIn('"state_write_failed"', test)
        self.assertIn('b"OLD-BUILD"', test, "the running binary was never swapped")
        self.assertIn("!cfg.prev().exists()", test, "no backup either")

    def test_the_success_path_no_longer_writes_state_after_the_exit_line(self) -> None:
        # The write moved into `install`; `apply`'s Ok branch audits and exits. Reintroducing a
        # write there would re-open the gap this fixes.
        ok = self.apply.split("Ok(()) => {", 1)[1].split("Err(failure) =>", 1)[0]
        self.assertNotIn("write_state", ok, "the record is written before the swap, not after")
        self.assertIn("std::process::exit(0)", ok)

    def test_the_verified_download_leaves_a_pending_record_behind(self) -> None:
        test = block(UPDATE_RS, "fn a_verified_download_replaces_the_binary_and_keeps_the_previous_one(",
                     "    #[test]")
        self.assertIn('read_state(&cfg.state_path())', test)
        self.assertIn("assert_eq!(record.state, PENDING);", test)


if __name__ == "__main__":
    unittest.main()
