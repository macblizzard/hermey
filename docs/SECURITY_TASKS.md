# Security task list — from the OSS audit of 2026-11-27

Scanners: gitleaks 8.30, semgrep 1.187 (`p/default` + `p/security-audit`), trivy 0.76,
osv-scanner 2.7, bandit 1.9, pip-audit 2.10, cargo clippy. Run with the `code-audit` skill:
`bash scripts/audit.sh <repo> <out>`.

## Fixed

- [x] **RUSTSEC-2026-0592 — `url` 2.5.8 stack overflow on nested `blob:` URLs.** Bumped to 2.5.9.
- [x] **CVE-2026-119375 — bundled SQLite via `libsqlite3-sys` 0.30.1.** `rusqlite` 0.32 → 0.43,
      which carries `libsqlite3-sys` 0.40.0 and a current SQLite. 470 Rust tests still pass.
- [x] **RUSTSEC-2024-0449 — `unsafe-libyaml` unmaintained.** `serde_yaml` (deprecated) → `serde_yaml_ng` 0.10.
      The advisory is "unmaintained", not a vulnerability; the remaining dependency is accepted and
      allowlisted in `osv-scanner.toml` with that reason, because the crate is used only to read and write
      this host's own config files from trusted input.

## To fix

- [ ] **`run-shell-injection` in `.github/workflows/hermeyd-release.yml:114`** — a tag name interpolated into
      a `run:` script. Pass it through `env:` and quote it.
- [ ] **`ws://` rather than `wss://`** — 31 semgrep hits, mostly the loopback engine socket (correct as-is) but
      `Apps/HermesMac/Pairing/PairingAddress.swift` accepts a tailnet host, where plaintext is wrong. Prefer
      `wss://` whenever the host is not loopback, and refuse to downgrade silently.
- [ ] **`ssl._create_unverified_context` in `Tools/release/publish_dist.py:116`** — behind an explicit
      `--insecure` flag; keep the flag, log loudly when it is used, and never make it the default.
- [ ] **gitleaks false positives** — `project.yml` carries Sparkle's **public** ED key (`SUPublicEDKey`),
      `A2UISurfaceSettings.swift` a UserDefaults key name. Add `.gitleaks.toml` allowlisting those two paths
      with the reason, so a real secret stands out next time.
- [ ] **bandit 189 low findings, almost all in `Tests/_stub_engine.py` and bundled skill scripts** — decide per
      class: `assert`/`subprocess` in test harnesses are intentional. Configure the audit run to skip those
      paths rather than fixing test code that is not shipped behaviour.
- [ ] **`hashlib.sha1` in `Tools/release/sync_store.py:538`** — git blob hashing, where SHA-1 is the format,
      not a security choice. Comment it as such and allowlist the rule for that file.
