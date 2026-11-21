# Tests

Two languages live here:

* `test_*.py` — source-text guards over the Swift apps and the Rust host service, run with
  `python3 -m unittest discover -s Tests -p 'test_*.py'` from the repository root. They need no
  simulator, no Python package from this repo, and no network.
* `Hermes*Tests/`, `HermeyUITests/` — SwiftPM/XCTest suites for the packages and the app shells, run
  with `swift test`.

## What was deleted with the Python bridge

`Bridge/` (the `hermes_bridge` package), `Tools/release/deploy_bridge.sh` and `Tools/qa/` were removed
on 2026-11-21. The host service is the Rust crate in `hermeyd/`, whose behaviour is covered by its own
`#[cfg(test)]` modules — run `cargo test` in `hermeyd/` (it is a CI job now).

Two Python modules had no subject left once the package was gone, so they were deleted rather than
left skipping:

| Deleted | What it guarded | Where that lives now |
|---|---|---|
| `test_bridge_deploy.py` | `deploy_bridge.sh`: pip-installing the checkout into a venv, restarting the bridge unit, following a running predecessor unit, and the systemd drop-in that `setup/bot-browser.sh` wrote for it (both scripts are deleted with the bridge) | the scripts and the unit are gone; `deploy/hermeyd.service` and `deploy/com.hermeyd.plist` are static files installed by hand until the installer is rewritten |
| `test_audit_stream.py` | `app.py` never writing prose through the `hermes_bridge.audit` logger, and reporting a failed best-effort install through the app logger | `hermeyd/src/audit.rs` writes one JSON record per event; its Rust tests cover the record shape and that `/v1/health` is not logged |

Everything else that read `Bridge/hermes_bridge/*.py` was retargeted at `hermeyd/src/*.rs`; the test
says so in a comment beside the assertions it changed, and names any behaviour the bridge had that
hermeyd does not.
