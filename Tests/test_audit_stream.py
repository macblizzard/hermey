"""The audit stream is one JSON object per line, and prose in it is a broken record.

`hermes_bridge.audit` is not a log: `Tools/qa/test_audit.py` parses every record that reaches it as
JSON, and the host ships it to a file other tools read. The app's own startup chatter — "sign-in
extension installed at …" and the two best-effort install failures — was written through the audit
logger, so the QA harness failed with `JSONDecodeError: Expecting value: line 1 column 1` on a run
that had done nothing wrong, and the audit file carried a line nothing can parse.
"""
from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = (ROOT / "Bridge" / "hermes_bridge" / "app.py").read_text(encoding="utf-8")


class TheAuditStreamCarriesRecordsOnly(unittest.TestCase):
    def test_the_app_does_not_write_prose_to_the_audit_logger(self) -> None:
        prose = re.findall(r'logging\.getLogger\(cfg\.audit_logger_name\)\.(?:info|warning|error|exception|debug)',
                           APP)
        self.assertEqual(prose, [], "the audit logger is for JSON records; prose belongs to the app logger")

    def test_startup_reports_through_the_app_logger(self) -> None:
        self.assertIn('LOGGER = logging.getLogger(__name__)', APP)
        self.assertIn('LOGGER.info("sign-in extension installed at %s", path)', APP)
        self.assertIn('LOGGER.exception("local computer skill install failed")', APP)

    def test_a_failed_install_is_still_reported_somewhere(self) -> None:
        """Best effort does not mean silent: an install that cannot write is a journal line."""
        self.assertIn('LOGGER.exception("sign-in extension install failed")', APP)


if __name__ == "__main__":
    unittest.main()
