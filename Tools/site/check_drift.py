#!/usr/bin/env python3
"""Report where the published site has fallen behind the repo.

The docs site is generated (`Tools/site/build_docs.py`) from markdown that also lives in the repo, and
the landing page reads its version from the published feed at load time. Both can silently drift: this
script compares the claims on the site against the code and docs that are authoritative, so a daily job
can decide "nothing to do" honestly instead of re-reading prose and hoping.

    python3 Tools/site/check_drift.py                    # human summary, exit 1 on drift
    python3 Tools/site/check_drift.py --json             # for a machine
    python3 Tools/site/check_drift.py --online           # also HEAD the published artifact URLs

Checks
  cli        the verbs the site documents vs the verbs the CLI actually dispatches
  ports      the port numbers on the site vs the installer's defaults
  units      the unit names on the site vs the installer's prefix
  routes     the endpoints the site documents vs the bridge's actual routes
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
APP = ROOT / "Bridge" / "hermes_bridge" / "app.py"

# Markdown page -> (site page, mode). "full" pages must carry every heading of their source; "summary"
# pages deliberately condense a long document, so they are required to link to it instead of duplicating
# it. Without that distinction the check demands that a 300-line audit be copied onto a summary page,
# which is how a "keep in sync" job turns into a page nobody wants to read.
MIRRORED = {
    "docs/INSTALL.md": ("install", "full"),
    "docs/APPS.md": ("apps", "full"),
    "docs/TROUBLESHOOTING.md": ("troubleshooting", "full"),
    "docs/FOR-AGENTS.md": ("agents", "summary"),
    "docs/SECURITY.md": ("security", "summary"),
}

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


def installer_defaults() -> dict[str, str]:
    """Default port and unit prefix, read from the installer's own assignments.

    The shell variables are named differently from the env knobs they read (`BRIDGE_PORT=${HERMEY_PORT:-8787}`),
    so the pattern matches on the env knob and takes the fallback.
    """
    text = read(INSTALLER)
    out = {}
    for key, knob in (("bridge_port", "HERMEY_PORT"), ("https_port", "HERMEY_HTTPS_PORT"),
                      ("unit_prefix", "HERMEY_UNIT_PREFIX")):
        match = re.search(rf"^\w+=\$\{{{knob}:-([^}}]+)\}}", text, flags=re.M)
        if match:
            out[key] = match.group(1)
    return out


def bridge_routes() -> set[str]:
    text = read(APP)
    return set(re.findall(r'@app\.(?:get|post|websocket)\("([^"]+)"\)', text))


def site_text() -> str:
    """Everything the generated site claims, plus the landing page."""
    chunks = [read(GENERATOR)]
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


def doc_headings(rel: str) -> list[str]:
    text = read(ROOT / rel)
    return [h.strip() for h in re.findall(r"^##\s+(.+)$", text, flags=re.M)]


def main() -> int:
    as_json = "--json" in sys.argv
    online = "--online" in sys.argv
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

    # ports and units — the installer is the authority
    defaults = installer_defaults()
    checked.append(f"ports: installer defaults {defaults}")
    for key, label in (("bridge_port", "bridge port"), ("https_port", "tailnet port")):
        value = defaults.get(key)
        if value and value not in site:
            drift.append({"check": "ports", "what": f"{label} {value} from the installer is not on the site",
                          "where": "docs/reference + docs/install"})
    prefix = defaults.get("unit_prefix")
    if prefix:
        for unit in (f"{prefix}-bridge.service", f"{prefix}-gateway.service"):
            if unit not in site:
                drift.append({"check": "units", "what": f"{unit} is not mentioned on the site",
                              "where": "docs/install + docs/reference"})

    # routes — what the bridge serves vs what the site promises
    routes = bridge_routes()
    checked.append(f"routes: {len(routes)} in the bridge")
    for route in sorted(r for r in routes if r.startswith("/v1/")):
        leaf = route.rstrip("/")
        if leaf not in site:
            drift.append({"check": "routes", "what": f"{route} is served but not documented",
                          "where": "docs/reference"})

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
