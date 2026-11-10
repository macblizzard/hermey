#!/usr/bin/env python3
"""The one visible build line, shared by the landing page and the README.

Two files advertise which build is live — `gh-pages/index.html` (what a visitor sees) and
`README.md` (what a stranger reads first) — and both used to say nothing at all, or would have to be
edited by hand on every release. They now carry the same pair of markers, and the release tools
rewrite what sits between them from the IPA that was just published:

    <!-- build:start --> …anything… <!-- build:end -->

That makes "which version does this page advertise?" a fact read out of the artifact instead of a
number somebody typed, and it makes a stale page a *drift* the sync tool can see.

A file without the markers is left alone: a fork that trimmed its README must not break a publish.
"""

from __future__ import annotations

BEGIN = "<!-- build:start -->"
END = "<!-- build:end -->"


def current(text: str) -> str | None:
    """What is between the markers, or `None` when the file has no markers."""
    start = text.find(BEGIN)
    end = text.find(END)
    if start < 0 or end < start:
        return None
    return text[start + len(BEGIN):end]


def replace(text: str, body: str) -> str | None:
    """`text` with the marked block replaced by `body`, or `None` when there is nothing to stamp."""
    start = text.find(BEGIN)
    end = text.find(END)
    if start < 0 or end < start:
        return None
    return text[:start + len(BEGIN)] + body + text[end:]


def matches(text: str, body: str) -> bool:
    """Is the stamped block already exactly `body`? (Whitespace-only differences count as drift.)"""
    return current(text) == body


def readme_body(version: str, build: str) -> str:
    """Markdown, centred under the badges: the build a visitor would get if they installed now."""
    return (
        f'\n<p align="center"><sub>Latest published build '
        f"<b>{version}</b> (build {build})</sub></p>\n"
    )


def index_body(version: str, build: str, ipa_name: str) -> str:
    """HTML for the landing page: the build, and the file the source actually serves."""
    return (
        f'\n    <p class="build">Serving build <strong>{version}</strong> '
        f"(build {build}) · <code>{ipa_name}</code></p>\n  "
    )
