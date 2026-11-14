# Contributing

Thanks for taking a look. This is a small project with a strict bar: changes ship to a phone, so
"it compiles" is not the goal.

## Before you start

- For anything larger than a typo, open an issue first — it saves you building something that will
  not be merged.
- Security issues go through [`SECURITY.md`](SECURITY.md), not the issue tracker.

## The loop

1. `git checkout -b fix/what-it-fixes`
2. Make the change **and** a test when the behaviour is testable. The protocol layer
   (`Sources/HermesKit`) and the bridge have real suites; use them.
3. Run what CI runs, locally where you can:
   ```bash
   swift build && swift test                     # packages
   .venv/bin/pytest Bridge/tests                 # bridge
   bash -n setup/install.sh                      # installer syntax
   ```
4. Open a PR. CI must be green: packages, macOS app, iOS app, unsigned `.ipa`, bridge tests, QA
   harness, secret scan.

## Style

- Swift: no force-unwraps on network, user or QR data; errors surfaced, not swallowed.
- Python: type hints on public functions, no bare `except`, and every log line that touches a
  credential must be provably free of it.
- Shell: `set -euo pipefail`, quote every expansion, and remember the installer is piped into a root
  shell — that is a security boundary, not a convenience.
- Comments explain *why*, in the code's own voice. If a comment would need the pull request to make
  sense, rewrite it.

## Commits and PRs

- One logical change per PR; squash on merge.
- Write the commit message for someone reading `git log` in a year: what was wrong, what the fix
  relies on.
- Note user-visible changes in `CHANGELOG.md` under *Unreleased*.

## Releasing

Maintainers only: tag `vX.Y.Z`, let CI build the artifacts, then publish with
`python3 Tools/release/publish_altstore.py --ipa … --mac-dmg …` — it attaches the `.ipa`, the macOS
`.dmg` and `install.sh` to the release, writes and uploads the AltStore manifest, and stamps the
README and the landing page in the same run. `sync_store.py --check` proves the source, the Pages copy
and the pages agree (CI runs it nightly at 03:30, so a stale source cannot survive).
[`docs/APPS.md`](docs/APPS.md) explains what users do with them.
