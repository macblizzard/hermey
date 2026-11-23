"""Every section of a mirrored document must exist on the page built from it.

`Tools/site/build_docs.py` used to carry its own prose for the install, apps, agents and troubleshooting
pages, so a section added to `docs/*.md` reached GitHub and never reached the site — the drift check found
three of those at once. The pages are now rendered from the docs, and this pins the contract from the other
side: take each `## ` heading in a doc, and find it as a heading on the built page.
"""

import contextlib
import html
import io
import pathlib
import re
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools" / "site"))

import build_docs  # noqa: E402

# doc -> the page it is rendered into. The docs the drift checker calls "full" mirrors.
MIRRORS = {
    "PREREQUISITES.md": "prerequisites.html",
    "INSTALL.md": "install.html",
    "APPS.md": "apps.html",
    "PETS.md": "pets.html",
    "TROUBLESHOOTING.md": "troubleshooting.html",
    "FOR-AGENTS.md": "agents.html",
    "SECURITY.md": "security.html",
    "INTEGRATIONS.md": "integrations.html",
    "CREDENTIALS.md": "credentials.html",
    "IMPORT-FROM-ANOTHER-PLATFORM.md": "importing.html",
}


def doc_sections(rel: str) -> list[tuple[str, str]]:
    """(heading, body) for every `## ` section of a doc, in order."""
    text = (ROOT / "docs" / rel).read_text(encoding="utf-8")
    out = []
    for part in re.split(r"^## ", text, flags=re.M)[1:]:
        heading, _, body = part.partition("\n")
        out.append((heading.strip(), body))
    return out


def plain(markdown: str) -> str:
    """A heading as both sides state it: `code` spans and *emphasis* are markup, not words."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", markdown)
    return re.sub(r"\s+", " ", re.sub(r"[`*_]", "", text)).strip()


def headings_on(page: str) -> list[str]:
    found = re.findall(r"<h([23])[^>]*>(.*?)</h\1>", page, flags=re.S)
    return [plain(html.unescape(re.sub(r"<[^>]+>", "", text))) for _, text in found]


def tidy(text: str) -> str:
    """Markup out, spacing normalised — so a tag boundary is not read as punctuation in the prose."""
    text = re.sub(r"[`*_]", "", text)
    text = re.sub(r"\s+", " ", text)
    return re.sub(r"\s+([.,;:!?)\]])", r"\1", text).strip()


def text_of(page: str) -> str:
    """The reader's text, whitespace-collapsed: markup differences must not matter, words must."""
    body = page.split('<main class="content"', 1)[-1]
    return tidy(html.unescape(re.sub(r"<[^>]+>", " ", body)))


def opening(body: str, window: int = 48) -> str:
    """The first run of real prose in a section, as plain text — enough to prove the body was rendered."""
    prose = re.sub(r"```.*?```", " ", body, flags=re.S)
    for block in (b.strip() for b in prose.split("\n\n")):
        if not block or block[0] in "-*|>#123456789":   # a list, table or heading, not a sentence
            continue
        flat = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", block)
        flat = tidy(re.sub(r"[#>|]", " ", flat))
        if len(flat) >= window:
            return flat[:window]
    return ""


class PageIsBuiltFromTheDoc(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        cls.out = pathlib.Path(cls._tmp.name) / "docs"
        with contextlib.redirect_stdout(io.StringIO()):   # the builder reports what it wrote
            build_docs.build(cls.out)
        cls.pages = {doc: (cls.out / page).read_text(encoding="utf-8") for doc, page in MIRRORS.items()}

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmp.cleanup()

    def test_every_doc_section_is_a_heading_on_its_page(self) -> None:
        for doc, page in MIRRORS.items():
            on_page = headings_on(self.pages[doc])
            headings = [heading for heading, _ in doc_sections(doc)]
            self.assertTrue(headings, f"{doc} has no `## ` sections — this test would pass vacuously")
            for heading in headings:
                with self.subTest(doc=doc, heading=heading):
                    self.assertIn(plain(heading), on_page,
                                  f"“{heading}” is in {doc} and missing from {page}")

    def test_every_doc_section_brings_its_own_words(self) -> None:
        """A heading alone would let the page keep a hand-written stub under the doc's title."""
        for doc, page in MIRRORS.items():
            seen = text_of(self.pages[doc])
            for heading, body in doc_sections(doc):
                passage = opening(body)
                if not passage:
                    continue
                with self.subTest(doc=doc, heading=heading):
                    self.assertTrue(passage in seen,
                                    f"{page} does not carry the opening of {doc} § “{heading}”: "
                                    f"expected “{passage}”")

    def test_the_new_page_is_first_in_the_getting_started_group(self) -> None:
        """The order the site is read in: getting started, then install, then the apps."""
        getting_started = [p["slug"] for p in build_docs.PAGES if p["group"] == "Getting started"]
        self.assertEqual(getting_started[:4], ["index", "prerequisites", "install", "apps"])

    def test_every_page_carries_the_independence_statement(self) -> None:
        for page in sorted(self.out.glob("*.html")):
            with self.subTest(page=page.name):
                text = page.read_text(encoding="utf-8")
                self.assertIn("independent project", text)
                self.assertIn("prerequisites.html", text)


class TheBuildLeavesTheLandingPageAlone(unittest.TestCase):
    """The docs build writes into `docs/`; the landing page's version line belongs to the release tools."""

    def test_it_refuses_to_write_over_a_stamped_index(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp)
            stamped = ('<p>landing</p><!-- build:start --> Serving build 1.2.3 '
                       '<!-- build:end -->\n<a class="btn btn-primary" href="#install">Install Hermey</a>')
            (out / "index.html").write_text(stamped, encoding="utf-8")
            with self.assertRaises(SystemExit), contextlib.redirect_stdout(io.StringIO()):
                build_docs.build(out)
            self.assertEqual((out / "index.html").read_text(encoding="utf-8"), stamped)

    def test_it_refuses_the_site_root_even_with_no_build_stamp(self) -> None:
        """The landing page stopped carrying a stamp; the shape of the path has to be checked instead.

        Built one level too high, the run wrote the overview page over index.html and dropped a second
        copy of every page at the root, while the pages in `docs/` kept their old text. The site then
        served the stale copy and nothing failed.
        """
        with tempfile.TemporaryDirectory() as tmp:
            site = pathlib.Path(tmp)
            landing = '<!doctype html><title>Hermey</title><h1>Your agent, in a real app</h1>'
            (site / "index.html").write_text(landing, encoding="utf-8")
            with self.assertRaises(SystemExit), contextlib.redirect_stdout(io.StringIO()):
                build_docs.build(site)
            self.assertEqual((site / "index.html").read_text(encoding="utf-8"), landing)
            self.assertFalse((site / "prerequisites.html").exists(),
                             "the build wrote a page at the site root")

    def test_it_refuses_a_landing_page_inside_the_output_directory(self) -> None:
        """A directory named `docs` that holds the hand-written landing page is still not the docs dir."""
        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp) / "docs"
            out.mkdir()
            landing = '<!doctype html><title>Hermey</title><h1>Your agent, in a real app</h1>'
            (out / "index.html").write_text(landing, encoding="utf-8")
            with self.assertRaises(SystemExit), contextlib.redirect_stdout(io.StringIO()):
                build_docs.build(out)
            self.assertEqual((out / "index.html").read_text(encoding="utf-8"), landing)

    def test_the_landing_cta_points_at_the_new_page_and_keeps_the_stamp(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            site = pathlib.Path(tmp)
            landing = ('<div class="cta-row">\n'
                       '  <a class="btn btn-primary" href="#install">Install Hermey</a>\n'
                       '</div>\n'
                       '<p class="build" id="build"><!-- build:start --> Serving build 1.2.3 '
                       '<!-- build:end --></p>\n'
                       '<footer><p class="colophon">MIT licensed</p></footer>\n')
            (site / "index.html").write_text(landing, encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                build_docs.build(site / "docs")
            after = (site / "index.html").read_text(encoding="utf-8")
            self.assertIn('href="docs/prerequisites.html">Get started</a>', after)
            self.assertIn("independent project", after)
            self.assertIn("<!-- build:start --> Serving build 1.2.3 <!-- build:end -->", after)


if __name__ == "__main__":
    unittest.main()
