#!/usr/bin/env python3
"""Scan every blob this repository has ever contained for credential-shaped strings.

`secret_scan.sh` greps the working tree, which cannot see a secret that was committed and later
removed — and this repository is public, so history is published too. This walks all reachable
objects once (about two seconds for ~5k blobs) and reports what it finds without ever printing the
value: a short prefix, the length, and a fingerprint, which is enough to recognise a hit across runs
and useless to anyone reading the output.

Test fixtures are legitimate and expected: proving that the bridge redacts a token requires a
token-shaped string in the test. A fixture is accepted when it sits in a test path AND is obviously
fake — a canary, example/fake/test wording, or a low-variety string. A test that embeds something
indistinguishable from a live credential is reported as a finding, because a scanner cannot tell the
difference either, and neither can a reader.

    python3 Tools/ci/secret_scan_history.py            # exit 1 if a real-looking credential appears
    python3 Tools/ci/secret_scan_history.py --json
    python3 Tools/ci/secret_scan_history.py --allow Bridge/tests/test_local_computers.py
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys

PATTERNS = [
    ("github-token", re.compile(rb"ghp_[A-Za-z0-9]{30,}")),
    ("github-pat", re.compile(rb"github_pat_[A-Za-z0-9_]{40,}")),
    ("openai-style-key", re.compile(rb"sk-[A-Za-z0-9]{20,}")),
    ("aws-key-id", re.compile(rb"AKIA[0-9A-Z]{16}")),
    ("private-key", re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("slack-token", re.compile(rb"xox[baprs]-[A-Za-z0-9-]{10,}")),
    ("anthropic-key", re.compile(rb"sk-ant-[A-Za-z0-9_-]{20,}")),
]

TEST_PATH = re.compile(r"(^|/)(tests?|Tests?|specs?)/|test_[^/]+\.py$|_test\.(py|go)$", re.I)

# Strings a maintainer uses on purpose to stand in for a credential.
CANARY = re.compile(rb"canary|example|fake|dummy|placeholder|redact|sample|xxxx|your-|notreal|test12", re.I)
LOW_VARIETY = re.compile(rb"^(.)\1{8,}$")


def git(repo: str, *args: str, stdin: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", repo, *args], input=stdin,
                          capture_output=True, check=False)


def blobs_with_paths(repo: str) -> dict[str, str]:
    """Every object id reachable from any ref, mapped to a path when it has one."""
    out = git(repo, "rev-list", "--objects", "--all").stdout.decode(errors="replace")
    mapping: dict[str, str] = {}
    for line in out.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2 and len(parts[0]) == 40:
            mapping[parts[0]] = parts[1]
    return mapping


def classify(path: str, token: bytes, around: bytes) -> tuple[str, str]:
    """('fixture'|'finding', reason). A fixture must be in a test path AND obviously not real."""
    in_test = bool(TEST_PATH.search(path))
    obvious = bool(CANARY.search(around) or CANARY.search(token) or LOW_VARIETY.search(token))
    if not in_test:
        return "finding", "outside a test path"
    if obvious:
        return "fixture", "test path, obviously fake"
    return "finding", "test path, but the string is indistinguishable from a live credential — make it a canary"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--allow", action="append", default=[],
                        help="path to accept unconditionally (repeatable)")
    args = parser.parse_args()

    mapping = blobs_with_paths(args.repo)
    ids = [o for o in mapping if len(o) == 40]
    if not ids:
        print("no objects found — is this a git repository?", file=sys.stderr)
        return 2

    # one batch read for the whole history instead of a process per blob
    proc = subprocess.run(["git", "-C", args.repo, "cat-file", "--batch"],
                          input="\n".join(ids).encode(), capture_output=True, check=False)
    raw = proc.stdout
    fixtures: list[dict] = []
    findings: list[dict] = []

    pos, scanned = 0, 0
    seen: set[tuple[str, str, str]] = set()
    while pos < len(raw):
        nl = raw.find(b"\n", pos)
        if nl < 0:
            break
        header = raw[pos:nl].decode(errors="replace").split()
        if len(header) < 3:
            pos = nl + 1
            continue
        sha, kind, size = header[0], header[1], int(header[2])
        body = raw[nl + 1: nl + 1 + size]
        pos = nl + 1 + size + 1
        if kind != "blob":
            continue
        scanned += 1
        path = mapping.get(sha, sha)
        for label, pattern in PATTERNS:
            for match in pattern.finditer(body):
                token = match.group(0)
                around = body[max(0, match.start() - 120): match.end() + 120]
                verdict, reason = classify(path, token, around)
                record = {
                    "pattern": label,
                    "path": path,
                    "blob": sha[:12],
                    "prefix": token[:4].decode(errors="replace"),
                    "length": len(token),
                    "fingerprint": hashlib.sha256(token).hexdigest()[:10],
                    "reason": reason,
                }
                # the same token recurs across every blob that ever held the file: report it once
                key = (path, label, record["fingerprint"])
                if key in seen:
                    continue
                seen.add(key)
                if verdict == "finding" and path not in args.allow:
                    findings.append(record)
                else:
                    fixtures.append(record)

    if args.json:
        print(json.dumps({"scanned": scanned, "findings": findings, "fixtures": fixtures}, indent=2))
    else:
        print(f"scanned {scanned} blobs across every ref")
        for f in fixtures:
            print(f"  fixture: {f['path']} ({f['pattern']}, {f['length']} chars, fp {f['fingerprint']}) — {f['reason']}")
        if findings:
            print(f"\n{len(findings)} FINDING(S) — value withheld on purpose:")
            for f in findings:
                print(f"  [{f['pattern']}] {f['path']}  blob {f['blob']}  "
                      f"prefix {f['prefix']!r} len {f['length']} fp {f['fingerprint']}")
                print(f"      {f['reason']}")
            print("\na credential in history is published if the repo is public: rotate it first, then"
                  "\ndecide about a history rewrite (this script never rewrites anything).")
        else:
            print("\nclean: no credential-shaped string outside an obvious test fixture")
    return 0 if not findings else 1


if __name__ == "__main__":
    raise SystemExit(main())
