#!/usr/bin/env python3
"""Report where the published site has fallen behind the repo.

The docs site is generated (`Tools/site/build_docs.py`) from markdown that also lives in the repo, and
the landing page reads its version from the published feed at load time. Both can silently drift: this
script compares the claims on the site against the code and docs that are authoritative, so a daily job
can decide "nothing to do" honestly instead of re-reading prose and hoping.

    python3 Tools/site/check_drift.py                    # human summary, exit 1 on drift
    python3 Tools/site/check_drift.py <site-dir>         # check a build somewhere else
    python3 Tools/site/check_drift.py --json             # for a machine
    python3 Tools/site/check_drift.py --online           # also HEAD the published artifact URLs

`<site-dir>` is the site root that holds `index.html` and `docs/`; without it the gh-pages worktree beside
the repo is used (or `HERMEY_SITE_DIR`). That is what makes "build into a scratch directory and check it"
a thing you can actually do.

Checks
  cli        the verbs the site documents vs the verbs the CLI actually dispatches
  ports      the port numbers on the site vs the ones hermeyd actually binds
  routes     the endpoints the site documents vs hermeyd's actual routes
  stamp      the feed the landing page reads vs the newest release tag
  sections   every heading in a mirrored docs/*.md page should exist on its site page
  assets     (--online) the download URLs the site offers should answer
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import urllib.request
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
# The gh-pages worktree normally sits beside the repo; HERMEY_SITE_DIR overrides it so the check can
# run against a fresh checkout (CI) or a copy, instead of only on the machine that has the worktree.
_override = os.environ.get("HERMEY_SITE_DIR")
SITE_DIR = pathlib.Path(_override).resolve() if _override else ROOT.parent / "hermey-pages"
GENERATOR = ROOT / "Tools" / "site" / "build_docs.py"
INSTALLER = ROOT / "setup" / "install.sh"
# The host service is part of this repository now: one route table, one integration catalogue.
APP = ROOT / "hermeyd" / "src" / "main.rs"
INTEGRATIONS_RS = ROOT / "hermeyd" / "src" / "integrations.rs"

# Markdown page -> (site page, mode). "full" pages must carry every heading of their source; "summary"
# pages deliberately condense a long document, so they are required to link to it instead of duplicating
# it. Without that distinction the check demands that a 300-line audit be copied onto a summary page,
# which is how a "keep in sync" job turns into a page nobody wants to read.
MIRRORED = {
    "docs/PREREQUISITES.md": ("prerequisites", "full"),
    "docs/INSTALL.md": ("install", "full"),
    "docs/APPS.md": ("apps", "full"),
    "docs/TROUBLESHOOTING.md": ("troubleshooting", "full"),
    "docs/FOR-AGENTS.md": ("agents", "summary"),
    "docs/SECURITY.md": ("security", "summary"),
    "docs/INTEGRATIONS.md": ("integrations", "full"),
    "docs/CREDENTIALS.md": ("credentials", "full"),
    "docs/IMPORT-FROM-ANOTHER-PLATFORM.md": ("importing", "full"),
}

# The host service's own defaults. Its source is `hermeyd/src` in this repo, and its documented
# contract is these constants: the main API on 8788 — the port this repo's tools default to — and the
# credential-free browser channel on 8790. Loopback only, published at serve-root. The retired Python
# bridge's 8787 is still read out of the installer (which refuses to run now), but only as a
# historical fact the site may keep stating, never as the port a host listens on.
HERMEYD_API_PORT = "8788"
HERMEYD_BROWSER_PORT = "8790"
#: Where the local bearer lives, as the live pages have to say when they tell a bot to call the API.
HERMEYD_TOKEN_NAME = "local.token"

STOPWORDS = {
    "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "it", "that",
    "this", "as", "at", "by", "from", "not", "no", "you", "your", "its", "be", "if", "when", "what",
    "which", "so", "than", "then", "there", "their", "them", "they", "we", "our", "but", "can", "do",
}


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def words(text: str) -> list[str]:
    return [w for w in re.findall(r"[a-z0-9]+", text.lower()) if w not in STOPWORDS and len(w) > 2]


def cli_verbs() -> set[str]:
    """The verbs the installed `hermey` wrapper dispatches."""
    text = read(INSTALLER)
    start = text.find("/hermey\" <<EOF")
    if start < 0:
        start = text.find("/hermey\" <<")
    if start < 0:
        return set()
    block = text[start:start + 4000]
    verbs = set()
    for line in block.splitlines():
        match = re.match(r"\s{2,}([a-z][a-z-]*)\)", line)
        if match:
            verbs.add(match.group(1))
    return verbs


def host_routes() -> set[str]:
    """Every path hermeyd mounts, read from its one router.

    Retargeted from `hermes_bridge/app.py` (deleted with the Python bridge): FastAPI decorators are
    now `.route("/v1/…", …)` calls in `hermeyd/src/main.rs`.
    """
    text = read(APP)
    return set(re.findall(r'\.route\(\s*"(/v1/[^"]+)"', text))


def site_text() -> str:
    """Everything the site claims, plus the landing page."""
    chunks = [read(GENERATOR)]
    chunks.append(published_text())
    return "\n".join(chunks)


def published_text() -> str:
    """Only what a visitor can read: the built pages.

    The port and credential facts are checked against this and not the generator, because a generator
    that says `8788` while every built page still says `8787` is exactly the drift that matters — the
    reader never sees the source file.
    """
    chunks = []
    for name in ("index.html", "install.html", "apps.html", "reference.html", "troubleshooting.html",
                 "agents.html", "security.html", "computer-use.html"):
        chunks.append(read(SITE_DIR / "docs" / name))
    chunks.append(read(SITE_DIR / "index.html"))
    return "\n".join(chunks)


def newest_tag() -> str | None:
    try:
        out = subprocess.run(["git", "-C", str(ROOT), "tag", "--sort=-v:refname"],
                             capture_output=True, text=True, timeout=30).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return None
    return out[0].lstrip("v") if out else None


FEED_URL = "https://macblizzard.github.io/hermey-downloads/altstore.json"


def page_reads_the_feed() -> bool:
    """Whether the landing page still resolves its version from the feed.

    It used to carry a number that the release pipeline rewrote. Every release therefore had to keep
    two prose sentences true, and they could be rewritten or missed independently of the feed they
    described. The page now asks the feed, so the check is that the wiring is intact — plus, when
    online, that the feed itself agrees with the newest tag.
    """
    text = read(SITE_DIR / "index.html")
    return 'id="build"' in text and FEED_URL in text


def feed_version() -> str | None:
    """The version the public feed advertises, or None when it cannot be read."""
    try:
        with urllib.request.urlopen(FEED_URL, timeout=20) as response:
            document = json.loads(response.read().decode("utf-8"))
        return str(document["apps"][0]["versions"][0]["version"])
    except Exception:  # noqa: BLE001 - an unreadable feed is a finding, not a crash
        return None


def asset_urls(text: str) -> list[str]:
    """The download URLs a page offers, wherever they appear.

    A URL can sit in HTML, in Markdown, or inside a JavaScript string literal, so the match stops at
    every quote style and at the punctuation that can follow one. Without the single quote and comma
    this captured `altstore.json',` straight out of the page's fetch call and reported a 404 for a
    URL no browser ever requests.
    """
    found = re.findall(r"https://macblizzard\.github\.io/hermey-downloads/[^\s\"'<>,)]+", text)
    return sorted({url.rstrip(".,;)]}") for url in found})



def catalog_services() -> list[tuple[str, str]]:
    """The integrations the app actually offers, read from hermeyd's one list."""
    text = read(INTEGRATIONS_RS)
    block = re.search(r"const CATALOG: \[.*?\] = \[(.*?)\n\];", text, flags=re.S)
    if not block:
        return []
    return [(slug, name) for slug, name, _ in
            re.findall(r'\("([^"]+)",\s*"([^"]+)",\s*"([^"]*)"\)', block.group(1))]


def doc_headings(rel: str) -> list[str]:
    text = read(ROOT / rel)
    return [h.strip() for h in re.findall(r"^##\s+(.+)$", text, flags=re.M)]


def main() -> int:
    global SITE_DIR
    as_json = "--json" in sys.argv
    online = "--online" in sys.argv
    # A positional directory is the site to check: build into /tmp/site-check and pass it, rather than
    # editing the worktree the owner publishes from.
    given = [arg for arg in sys.argv[1:] if not arg.startswith("-")]
    if given:
        SITE_DIR = pathlib.Path(given[0]).resolve()
    drift: list[dict[str, str]] = []
    checked: list[str] = []

    site = site_text()
    site_words = set(words(site))

    # cli — every dispatched verb must be documented, and nothing else claimed
    verbs = cli_verbs()
    checked.append(f"cli: {len(verbs)} verbs in the wrapper")
    if verbs:
        documented = set(re.findall(r"<code>hermey ([a-z][a-z-]*)", site))
        for missing in sorted(verbs - documented):
            drift.append({"check": "cli", "what": f"`hermey {missing}` is dispatched but not documented",
                          "where": "docs/reference + docs/agents"})
        for extra in sorted(documented - verbs):
            if extra not in {"computer"}:  # documented as a family, dispatched by the app
                drift.append({"check": "cli", "what": f"`hermey {extra}` is documented but not dispatched",
                              "where": "docs/reference"})

    # ports — the live host is hermeyd, and the *published* page has to say so
    published = published_text()
    checked.append(f"ports: hermeyd {HERMEYD_API_PORT}/{HERMEYD_BROWSER_PORT}")
    for live_port, label in ((HERMEYD_API_PORT, "the host API port"),
                             (HERMEYD_BROWSER_PORT, "the browser channel port")):
        if live_port not in published:
            drift.append({"check": "ports",
                          "what": f"{label} {live_port} (hermeyd) is not on the built site — a page "
                                  f"still sending readers to the retired bridge's port",
                          "where": "docs/reference + docs/install + docs/agents — rebuild with Tools/site/build_docs.py"})
    if "hermeyd" not in published:
        drift.append({"check": "ports",
                      "what": "the built site never names hermeyd, the service a host runs today",
                      "where": "docs/install + docs/reference"})
    if HERMEYD_TOKEN_NAME not in published:
        drift.append({"check": "auth",
                      "what": f"the built site tells readers to call the API but never mentions "
                              f"{HERMEYD_TOKEN_NAME}, the bearer hermeyd requires",
                      "where": "docs/agents + docs/reference"})
    # routes — what the host serves vs what the site promises
    routes = host_routes()
    checked.append(f"routes: {len(routes)} in hermeyd")
    for route in sorted(r for r in routes if r.startswith("/v1/")):
        leaf = route.rstrip("/")
        if leaf not in site:
            drift.append({"check": "routes", "what": f"{route} is served but not documented",
                          "where": "docs/reference"})


    # integrations — the page is generated from one list, so a new service must appear in the doc too
    services = catalog_services()
    checked.append(f"catalog: {len(services)} services")
    doc = read(ROOT / "docs/INTEGRATIONS.md")
    for slug, name in services:
        if slug not in doc:
            drift.append({"check": "catalog", "what": f"integration `{slug}` ({name}) is offered but missing "
                                                      "from docs/INTEGRATIONS.md", "where": "docs/INTEGRATIONS.md"})
    documented = set(re.findall(r"\|\s*`([a-z0-9-]+)`\s*\|", doc))
    for extra in sorted(documented - {slug for slug, _ in services}):
        drift.append({"check": "catalog", "what": f"`{extra}` is documented but not in CATALOG",
                      "where": "docs/INTEGRATIONS.md"})

    # stamp — the page must still read the feed, and (online) the feed must match the newest tag
    tag = newest_tag()
    wired = page_reads_the_feed()
    served = feed_version() if online else None
    checked.append(f"stamp: newest tag {tag}, page reads the feed: {wired}"
                   + (f", feed says {served}" if online else ""))
    if not wired:
        drift.append({"check": "stamp",
                      "what": "the landing page no longer reads its version from the feed",
                      "where": "gh-pages index.html (id=\"build\" + the feed URL)"})
    if online and tag and served is None:
        # A feed that cannot be read is not "nothing to report": the page would fall back to its
        # static sentence and no visitor would see a version at all.
        drift.append({"check": "stamp", "what": f"the feed at {FEED_URL} could not be read",
                      "where": "hermey-downloads altstore.json"})
    if online and tag and served and tag != served:
        drift.append({"check": "stamp",
                      "what": f"the feed advertises {served}, newest tag is {tag}",
                      "where": "hermey-downloads altstore.json / appcast.xml"})

    # sections — a page that gained a heading the site never got
    for rel, (slug, mode) in MIRRORED.items():
        page = read(SITE_DIR / "docs" / f"{slug}.html")
        headings = doc_headings(rel)
        checked.append(f"sections: {len(headings)} headings in {rel} ({mode})")
        if not page:
            drift.append({"check": "sections", "what": f"no built site page for {rel}",
                          "where": f"docs/{slug}.html — run Tools/site/build_docs.py"})
            continue
        if mode == "summary":
            # a condensed page must send the reader to the full document
            if rel not in page:
                drift.append({"check": "sections",
                              "what": f"the {slug} page condenses {rel} without linking to it",
                              "where": f"docs/{slug}.html"})
            continue
        page_words = set(words(page))
        for heading in headings:
            needed = words(heading)
            if not needed:
                continue
            covered = sum(1 for w in needed if w in page_words)
            if covered / len(needed) < 0.6:
                drift.append({"check": "sections",
                              "what": f"{rel} has a section the site page lacks: “{heading}”",
                              "where": f"docs/{slug}.html"})

    # assets — opt-in, because it needs the network
    if online:
        urls = asset_urls(site)
        for url in urls[:8]:
            result = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-L", url],
                                    capture_output=True, text=True, timeout=45)
            checked.append(f"assets: {url} -> {result.stdout.strip()}")
            if result.stdout.strip() not in {"200"}:
                drift.append({"check": "assets", "what": f"{url} answers {result.stdout.strip()}",
                              "where": "docs/reference + gh-pages"})

    if as_json:
        print(json.dumps({"ok": not drift, "drift": drift, "checked": checked}, indent=2))
    else:
        print(f"checked: {len(checked)} facts")
        for line in checked:
            print(f"  · {line}")
        if not drift:
            print("\nin sync: nothing on the site disagrees with the repo")
        else:
            print(f"\n{len(drift)} drift item(s):")
            for item in drift:
                print(f"  [{item['check']}] {item['what']}\n      fix in: {item['where']}")
    return 0 if not drift else 1


if __name__ == "__main__":
    raise SystemExit(main())
