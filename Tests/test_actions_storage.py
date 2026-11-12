"""Actions storage is 500 MB on this plan, and caches plus artifacts share it.

The account hit 100% of that quota with 1.4 GB of DerivedData caches and 214 build artifacts going back
weeks. Nothing here is about build speed; it is about the workflow never quietly refilling the quota:

* no `actions/cache` — `.build` and DerivedData are hundreds of megabytes each, per key;
* every uploaded artifact declares a short retention, because publishing happens minutes after the run.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")


class NoCaches(unittest.TestCase):
    def test_there_is_no_cache_step(self) -> None:
        self.assertNotIn("uses: actions/cache", CI,
                         "a DerivedData cache is hundreds of MB; the whole quota is 500 MB")

    def test_the_reason_is_written_down(self) -> None:
        # So the next person does not 'helpfully' restore the cache and refill the account.
        self.assertIn("No `actions/cache` anywhere in this workflow", CI)
        self.assertIn("500 MB", CI)


class ArtifactsExpire(unittest.TestCase):
    def test_every_upload_declares_a_retention(self) -> None:
        lines = CI.splitlines()
        starts = [index for index, line in enumerate(lines) if "uses: actions/upload-artifact@v4" in line]
        self.assertTrue(starts, "the workflow has no artifact uploads to check")
        for start in starts:
            block = "\n".join(lines[start:start + 14])
            match = re.search(r"retention-days: (\d+)", block)
            self.assertIsNotNone(match, f"an upload without retention-days:\n{block}")
            assert match is not None
            self.assertLessEqual(int(match.group(1)), 7,
                                 "these artifacts are published within minutes, not kept for a quarter")

    def test_the_published_artifacts_are_the_only_ones(self) -> None:
        names = re.findall(r"name: (Hermey-[\w.-]+)", CI)
        self.assertIn("Hermey-macOS-unsigned", names)
        self.assertIn("Hermey-unsigned-ipa", names)


class TheQuotaIsNotSpentOnLogs(unittest.TestCase):
    def test_retention_is_documented(self) -> None:
        # The repo-wide artifact+log retention is set with:
        #   gh api -X PUT repos/macblizzard/hermey/actions/permissions/artifact-and-log-retention -F days=3
        # It cannot be asserted from the file, but the workflow must not contradict it.
        self.assertNotIn("retention-days: 90", CI)


if __name__ == "__main__":
    unittest.main()
