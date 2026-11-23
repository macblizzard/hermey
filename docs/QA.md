# QA: what is verified, how, and what is not

An approval that blocks the agent until it is answered, a ticket that is single use, a frame over the
cap that never reaches the gateway, a log line that names who but never what was said — none of these
can be checked by reading code. This page says where each kind of check lives today, and which claims
have no check at all.

## What runs

```bash
# The Swift packages: protocol, app state, design system, cards
swift build && swift test

# The host service: unit and route tests, in hermeyd/src
cd hermeyd && cargo test && cargo build --release

# The source guards and the installer tests (no toolchain needed)
python3 -m unittest discover -s Tests -p 'test_*.py'

# End to end, against a running host on this machine
scripts/smoke-hermeyd.sh           # 11 checks: pairing, tickets, revoke, refused bind
scripts/smoke-app-routes.sh        # the app's connect sequence and its writes
scripts/smoke-attachments.sh       # upload, download, delete
scripts/smoke-relay.py             # a turn through the WS relay
```

`scripts/smoke-hermeyd.sh` is the one to read first: it proves health, a minted single-use code, a
registered device, a rejection on replay, a bearer-less `401`, a revoke, and a refused non-loopback
bind, printing a `PASS` line per check. `scripts/smoke-app-routes.sh` replays what the app does on
open — a fresh ticket per call, like the client — asserts the shapes the Swift decoders require, then
re-reads them to prove the writes persisted.

## CI

| Job | What it proves |
|---|---|
| What changed | which suites a push has to run |
| Swift packages | the packages build and their tests pass |
| Apps | `xcodegen` + `xcodebuild` build both apps, the macOS `.dmg` and the unsigned `.ipa` |
| hermeyd | `cargo test`, the release binary, and a source change that left `Cargo.toml`'s version alone is refused |
| Secret and script hygiene | no credential shapes in the tree or its history, `shellcheck` on the installer, Python compiles, the source guards |
| Published pages and README | the served build line matches the newest release |

## What the source guards can and cannot prove

The Python suite in `Tests/` is largely **source assertions**. It runs on a Linux job, where there is
no Swift toolchain, so a test can prove that a call exists, that a guard wraps it, that a store
implements a verb, and that a transcript checks one renderer before another. It cannot prove the
result looks or behaves right.

Stated as untested by CI, and needing a build on a device or a simulator:

- the paging gallery — that the swipe and the arrow keys feel right beside pinch and pull-down
- the Live Activity — that the lock-screen and island layouts render, and that one card is reused
  rather than stacked
- the `::card` renderer — that a `card.v1` file draws, and that a missing one degrades to prose
- computer use — the click mapping at zoom, the control lease, and full screen on both platforms
- the tailnet leg — no TLS, no WireGuard, no radio: nothing here measures what a phone experiences

Where a guard is the only evidence, its docstring says so rather than implying more.

## Adding a check

Prefer the cheapest layer that can fail:

1. a Swift test when the logic lives in a package;
2. a `cargo test` in `hermeyd/src` when it lives in the service;
3. a `Tests/test_*.py` source guard when the contract spans files no compiler here checks — and say
   in the docstring what it cannot prove;
4. a `scripts/smoke-*.sh` check when it needs real HTTP and real state.
