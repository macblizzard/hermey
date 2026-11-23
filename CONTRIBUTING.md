# Contributing

Thanks for taking a look. This is a small project with a strict bar: changes ship to a phone, so
"it compiles" is not the goal.

## Before you start

- For anything larger than a typo, open an issue first — it saves you building something that will
  not be merged.
- Security issues go through [`SECURITY.md`](SECURITY.md), not the issue tracker.

## The loop

1. `git checkout -b fix/what-it-fixes`
2. Make the change **and** a test when the behaviour is testable. The Swift layer
   (`Sources/HermesKit`, the app state in `Sources/HermesAppKit`) and the host service
   (`hermeyd/src`) have real suites; use them.
3. Run what CI runs, locally where you can:
   ```bash
   swift build && swift test                               # Swift packages
   cd hermeyd && cargo test && cargo build --release       # host service
   bash -n setup/install.sh                                # installer syntax
   python3 -m unittest discover -s Tests -p 'test_*.py'    # the source guards
   ```
4. Open a PR. CI must be green: Swift packages, both apps (the unsigned `.ipa` and `.dmg`), the
   `hermeyd` Rust tests with the version-bump guard, the source guards, and the secret and script scan.

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

Maintainers only, and two separate things to release:

- **The apps** — tag `v0.1.N`. CI builds both apps and the unsigned `.ipa`; then publish with
  `python3 Tools/release/publish_altstore.py --ipa … --mac-dmg …`, which attaches the `.ipa`, the
  macOS `.dmg` and `install.sh` to the release, writes and uploads the AltStore manifest, and stamps
  the landing page's build line. An app tag does not touch `hermeyd`'s version.
- **The host service** — `hermeyd/Cargo.toml` moves first (only when `hermeyd/src/` or its bundled
  skills changed), then tag `hermeyd-vX.Y.Z`; `hermeyd-release.yml` publishes the four platform
  binaries, `SHA256SUMS`, the plugin tarball and `install.sh` the installer expects.

`sync_store.py --check` proves the source, the Pages copy and the served pages agree (CI runs it
nightly at 03:30, so a stale source cannot survive).
[`docs/APPS.md`](docs/APPS.md) explains what users do with the apps.
