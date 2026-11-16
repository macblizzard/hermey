#!/usr/bin/env python3
"""The release notes for the build being published: what changed since the last release tag.

Written to be *read in the update prompt*, not by a historian: one bullet per user-visible change,
conventional-commit prefixes stripped, machinery (publishing, CI plumbing, test-only work) dropped.
The publisher puts this string in `appcast.xml` (Sparkle shows it in the update dialog), in
`mac.json` (the iOS prompt shows it) and in `altstore.json` (`localizedDescription`).
"""

from __future__ import annotations

import re
import subprocess
import sys

#: Commits that change how the product *behaves* under prefixes a person cares about.
KEEP_PREFIXES = ("feat", "fix", "perf")
#: Never worth a line in a prompt: the release machinery and the tests themselves.
DROP_PREFIXES = ("chore", "test", "ci", "build", "docs", "style", "refactor", "revert")
#: A `fix(tests):` or `feat(release):` is machinery wearing a feature's prefix.
DROP_SCOPES = ("test", "tests", "ci", "release", "docs", "tooling", "scripts")
MAX_LINES = 12


def run(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True, check=False).stdout


def previous_tag() -> str | None:
    tag = run("git", "describe", "--tags", "--abbrev=0", "HEAD^").strip()
    return tag or None


def commits(since: str | None) -> list[str]:
    span = f"{since}..HEAD" if since else "HEAD"
    # Subject only, newest last; the merge commits carry no news of their own.
    raw = run("git", "log", "--no-merges", "--pretty=%s", span).splitlines()
    return [line.strip() for line in raw if line.strip()]


def clean(subject: str) -> str | None:
    """One commit subject as a bullet, or None when it is machinery rather than news."""
    match = re.match(r"^(?P<kind>[a-z]+)(?:\((?P<scope>[^)]*)\))?!?:\s*(?P<rest>.+)$", subject)
    if match:
        kind = match.group("kind")
        if (match.group("scope") or "").strip().lower() in DROP_SCOPES:
            return None
        rest = match.group("rest").strip()
        if kind in DROP_PREFIXES:
            return None
        if kind not in KEEP_PREFIXES:
            return rest
        return rest[0].upper() + rest[1:] if rest else None
    # No conventional prefix: a plain sentence is news unless it is obviously publishing.
    if re.match(r"^(publish|release|chore|bump)\b", subject, re.IGNORECASE):
        return None
    return subject


def main() -> int:
    tag = previous_tag()
    seen: list[str] = []
    for subject in reversed(commits(tag)):
        line = clean(subject)
        if not line or line in seen:
            continue
        seen.append(line)
    if not seen:
        # A shallow CI checkout has one commit and no tags, so there is nothing to read — and a
        # release note is never the place to fail a build.
        print(f"No user-visible changes since {tag}." if tag else "Build published from CI.")
        return 0
    for line in seen[:MAX_LINES]:
        print(f"– {line}")
    if len(seen) > MAX_LINES:
        print(f"…and {len(seen) - MAX_LINES} more.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
