#!/usr/bin/env python3
"""Refuse a hermeyd source change that leaves the version alone.

`hermeyd --version` is how anybody answers "is the deployed build the one I just made?". It can only
answer that if the version moves whenever the code does. On 2026-11-22 the service was rebuilt with
rescued fixes and kept saying 0.2.0, so the host and the repo could not be compared at all — the
owner spotted it before the version drifted far enough to be unfixable.

The rule: if anything under `hermeyd/src/` or `hermeyd/assets/` changes, `hermeyd/Cargo.toml` must
carry a different `version` between the base and the head. Docs, tests and CI edits do not need a
bump; only the program does.

Usage:
    python3 Tools/check_hermeyd_version_bump.py --base <ref> [--head <ref>]

Exit status: 0 when the rule holds (or cannot be evaluated), 1 when a source change shipped without
a bump. The CI job passes the base of the PR, or `github.event.before` on a push; both are empty or
all-zero on a branch's first push, and that is treated as "nothing to compare", not a failure.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys

SOURCE_PREFIXES = ("hermeyd/src/", "hermeyd/assets/")
MANIFEST = "hermeyd/Cargo.toml"
CHANGELOG = "CHANGELOG.md"
VERSION_RE = re.compile(r'^version\s*=\s*"([^"]+)"', re.MULTILINE)
# The newest app release heading, e.g. `## [0.1.616] — 2026-11-22`.
APP_VERSION_RE = re.compile(r"^##\s*\[?(\d+\.\d+\.\d+)\]?", re.MULTILINE)


def git(*args: str) -> str:
    """Run git and return stdout, or '' when the command fails (an unreadable ref is not a verdict)."""
    try:
        return subprocess.run(
            ["git", *args], check=True, capture_output=True, text=True
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def version_at(ref: str) -> str | None:
    """The `version` in hermeyd/Cargo.toml at `ref`, or None when it cannot be read."""
    found = VERSION_RE.search(git("show", f"{ref}:{MANIFEST}"))
    return found.group(1) if found else None


def app_version_at(ref: str) -> str | None:
    """The newest app release in CHANGELOG.md at `ref`, or None when it cannot be read."""
    found = APP_VERSION_RE.search(git("show", f"{ref}:{CHANGELOG}"))
    return found.group(1) if found else None


def changed_files(base: str, head: str) -> list[str]:
    """Files that differ between base and head (three-dot: what this branch added, not what base did)."""
    out = git("diff", "--name-only", f"{base}...{head}")
    return [line for line in out.splitlines() if line.strip()]


def evaluate(base: str, head: str) -> tuple[bool, str]:
    """(ok, message) for one comparison.

    Two things oblige a new `hermeyd` version: a change to its own source or bundled skills, and a cut
    app release — the owner wants the host-service number to move with every release, so a build can
    always be traced to the service that was deployed beside it.
    """
    if not base or set(base) <= {"0"} or not head:
        return True, "no base to compare against (first push or missing ref) — version check skipped"

    files = changed_files(base, head)
    if files is None or not files:
        return True, f"no changes between {base} and {head} — version check skipped"

    before, after = version_at(base), version_at(head)
    if before is None or after is None:
        return True, f"could not read {MANIFEST} at both ends — version check skipped"

    touched = [f for f in files if f.startswith(SOURCE_PREFIXES)]
    app_before, app_after = app_version_at(base), app_version_at(head)
    released = bool(app_before and app_after and app_before != app_after)

    if before != after:
        why = []
        if touched:
            why.append(f"{len(touched)} source file(s) changed")
        if released:
            why.append(f"release {app_before} → {app_after}")
        return True, f"hermeyd {before} → {after} ({'; '.join(why) or 'unnamed change'})"

    problems = []
    if touched:
        listing = "\n".join(f"  {f}" for f in touched[:10])
        more = "" if len(touched) <= 10 else f"\n  … and {len(touched) - 10} more"
        problems.append(f"hermeyd source changed ({len(touched)} file(s)):\n{listing}{more}")
    if released:
        problems.append(f"a new app release was cut ({app_before} → {app_after})")

    if not problems:
        return True, "no hermeyd source change and no new release — no bump needed"

    return False, (
        "hermeyd did not get a new version; it is still " + str(before) + ".\n"
        + "\n".join(problems)
        + f"\n\n`hermeyd --version` answers 'is the deployed binary the build I just made?', and it can only "
        f"do that if the version moves when the program does (and with every release). Bump `version` in "
        f"{MANIFEST} (and `hermeyd` in hermeyd/Cargo.lock — `cargo update -p hermeyd` does it), then re-run."
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="", help="ref to compare from (PR base or previous commit)")
    parser.add_argument("--head", default="HEAD", help="ref to compare to (defaults to HEAD)")
    args = parser.parse_args(argv)

    ok, message = evaluate(args.base, args.head)
    print(("ok    " if ok else "FAIL  ") + message)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
