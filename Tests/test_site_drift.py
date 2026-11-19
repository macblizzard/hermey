"""The site drift checker must notice drift and must not invent it."""

import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools" / "site"))

import check_drift  # noqa: E402


class AssetUrls(unittest.TestCase):
    def test_a_url_inside_a_javascript_string_is_not_polluted_by_its_quotes(self):
        """Reported by this check itself: it read `altstore.json',` and called a live feed a 404.

        The page resolves its build number by fetching the feed, so the URL now appears inside a
        single-quoted JS literal. A scrape that stops only at whitespace, `"` and `<` swallows the
        quote and the comma after it, and then probes a URL no browser ever requests.
        """
        page = """fetch('https://macblizzard.github.io/hermey-downloads/altstore.json', {cache: 'no-store'})"""
        self.assertEqual(check_drift.asset_urls(page),
                         ["https://macblizzard.github.io/hermey-downloads/altstore.json"])

    def test_it_reads_html_and_markdown_forms_too(self):
        text = ('<a href="https://macblizzard.github.io/hermey-downloads/Hermey-macOS-0.1.580.dmg">x</a>\n'
                "[feed](https://macblizzard.github.io/hermey-downloads/appcast.xml).\n")
        self.assertEqual(check_drift.asset_urls(text),
                         ["https://macblizzard.github.io/hermey-downloads/Hermey-macOS-0.1.580.dmg",
                          "https://macblizzard.github.io/hermey-downloads/appcast.xml"])

    def test_other_hosts_are_ignored(self):
        self.assertEqual(check_drift.asset_urls("https://example.com/x.dmg"), [])


class ThePageAsksTheFeed(unittest.TestCase):
    def test_the_landing_page_no_longer_carries_a_typed_version(self):
        """A prose number can only be stale; the feed cannot.

        `page_reads_the_feed()` is what the checker asserts, so the regex it replaced must not creep
        back: a page that states a version in markup is a page the release pipeline has to rewrite.
        """
        source = (ROOT / "Tools" / "site" / "check_drift.py").read_text()
        self.assertIn("def page_reads_the_feed", source)
        self.assertIn("def feed_version", source)
        self.assertNotIn("Serving build", source.split('"""', 2)[-1],
                         "the prose-version regex is back in the checker's body")


if __name__ == "__main__":
    unittest.main()
