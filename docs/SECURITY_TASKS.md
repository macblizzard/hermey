# Security task list — from the OSS audit of 2026-11-27

Scanners: gitleaks 8.30, semgrep 1.187 (`p/default` + `p/security-audit`), trivy 0.76,
osv-scanner 2.7, bandit 1.9, pip-audit 2.10, cargo clippy. Run with the `code-audit` skill:
`bash scripts/audit.sh <repo> <out>`.

A finding is a lead, not a fact: every entry below was reproduced or explained before it was
fixed, and every entry that remains says why it is not a vulnerability in *this* codebase. The
allowlist files (`.gitleaks.toml`, `osv-scanner.toml`, `.bandit`) carry the same reasons beside the
thing they suppress, so the next sweep's output is already triaged.

## Fixed

### Dependency advisories (earlier, same sweep)

- [x] **RUSTSEC-2026-0592 — `url` 2.5.8 stack overflow on nested `blob:` URLs.** Bumped to 2.5.9.
- [x] **CVE-2026-119375 — bundled SQLite via `libsqlite3-sys` 0.30.1.** `rusqlite` 0.32 → 0.43,
      which carries `libsqlite3-sys` 0.40.0 and a current SQLite. 470 Rust tests still pass.
- [x] **RUSTSEC-2024-0449 — `unsafe-libyaml` unmaintained.** `serde_yaml` (deprecated) →
      `serde_yaml_ng` 0.10. What remains is an "unmaintained" advisory, not a vulnerability; it is
      accepted in `osv-scanner.toml` with the reason and a review date, because the crate is
      reached only to read and write this host's own config files from input the operator wrote.

### 2026-11-27 — shell injection, plaintext sockets, the TLS escape hatch, the allowlists

- [x] **`run-shell-injection` — `.github/workflows/hermeyd-release.yml`.** The `Tag` step had
      `tag="${{ github.event_name == 'push' && github.ref_name || inputs.tag }}"`: a `${{ }}` inside
      `run:` is substituted into the script *before the shell parses it*, so a tag named
      `v1"; curl … | sh; #` was shell code in a job holding `contents: write`. The value now arrives
      through `env:` (`REF_NAME`, `INPUT_TAG`, `EVENT_NAME`) and is used as `"$REF_NAME"`; an event
      with no tag name stops the job instead of running it empty. The same shape was found and fixed
      in three more places in `ci.yml`: the PR base sha in the `changes` job (`BASE_SHA`), the same
      sha in the version-bump guard, and `MARKETING_VERSION=${{ env.APP_VERSION }}` in both
      `xcodebuild` steps — `inputs.version` on a dispatch is a free-text box, so it was script text
      too. `Tests/test_audit_findings_guards.py` now walks every workflow and fails if `github.`,
      `inputs.`, `steps.`, `env.` or `secrets.` appears inside any `run:` body again.
- [x] **Plaintext WebSocket to a host that is not this machine — `PairingAddress.swift`.** The pair
      sheet took a typed URL, and a plaintext one was refused only by a string compare against
      `["127.0.0.1", "localhost", "[::1]"]` — which never matched IPv6 loopback, because
      `URLComponents` returns `::1` without the brackets. Worse, that check was the only thing
      between a tailnet name and a plaintext dial, and nothing stopped a decoded or directly
      constructed `PairingAddress` from carrying the plaintext scheme into `webSocketURL`,
      `localComputerSocketURL` and `apiOrigin`. Now: one predicate (`LoopbackHost.isLoopback`, in
      `Sources/HermesKit/LoopbackHost.swift`) decides what "this machine" means, `parse` **upgrades**
      a plaintext URL for any other host to `wss` and keeps the rest of the URL, all three builders
      go through `securedBaseURL()` (so a pairing saved by an older build cannot dial cleartext
      either), and the fallback that could have re-emitted the URL as typed is gone — an
      unparseable upgrade throws instead. The phone's `BridgeService` and the display viewer's
      `BotComputer.socketURL` derive the plaintext scheme only when the base is `http` **and** the
      host is loopback. `Tests/HermesKitTests/LoopbackHostTests.swift` executes the predicate; the
      source guards are in `Tests/test_audit_findings_guards.py`.
- [x] **`ssl._create_unverified_context` — `Tools/release/publish_dist.py`.** The unverified context
      was built inline in `fetch`, so any caller passing a truthy `insecure` got it, and nothing
      said so out loud. Now there is one builder, `unverified_context()`, reached only from
      `fetch(insecure=True)`, and `fetch` takes it only on `insecure is True` — not on anything
      merely truthy — so the one route is the `--insecure` flag that `main` passes. `main` prints
      `INSECURE_WARNING` to stderr as soon as the flag is parsed (one line, greppable, once per
      run). Nothing retries with verification off: a failed check is recorded by `verify()` and the
      publish exits non-zero. `fetch` also refuses a non-http(s) URL now, because `urlopen` would
      otherwise read `file://`.
- [x] **gitleaks false positives.** `.gitleaks.toml` allowlists the two lines *by path **and**
      value* (`regexTarget = "line"` and the exact text), never by path alone, so both files stay
      scanned and a real credential pasted beside either is still reported:
      `project.yml`'s `SUPublicEDKey` (Sparkle's **public** EdDSA key — it ships in every copy of the
      app; the private half never leaves the release Mac's Keychain) and
      `A2UISurfaceSettings.swift`'s `disabledKey` (a UserDefaults key *name*).
- [x] **osv-scanner — `RUSTSEC-2024-0449`.** `osv-scanner.toml` ignores it with the reason above and
      `effectiveUntil = 2027-06-30`. osv-scanner 2.7 does not discover that file on its own, so
      `scripts/audit.sh` in the `code-audit` skill now passes `--config osv-scanner.toml` when the
      repository has one (an allowlist the sweep ignores is an allowlist nobody audits).
- [x] **bandit — build the test harness out of the report.** `.bandit` excludes two *paths*,
      `Tests/` and `hermeyd/assets/agent-skills/`, and disables no rule: `assert`, `subprocess` and
      `try/except/pass` are how a test asserts and how a fake engine is launched, and neither path
      runs as host behaviour. A rule switched off would have been switched off for `hermeyd/src`
      too, which is the code that handles credentials. 189 findings → 45, all of them in `Tools/`
      and `scripts/`.
- [x] **`hashlib.sha1` — `Tools/release/sync_store.py`.** Not a false positive to suppress blindly:
      the digest is git's blob id, so it is computed with `usedforsecurity=False` (SHA-1 is the
      *format* here, and the value is only ever compared with the one GitHub returned for the same
      bytes) and carries a `# nosemgrep` with that reason. The `eval` in
      `Tests/test_live_activity.py` parses `8 * 60 * 60` out of this repository's own Swift, with
      `__builtins__` emptied, and carries its reason the same way.

## Accepted, and why

Nothing critical or high remains. What the sweep still prints, and why each line is not a bug:

- **semgrep `detect-insecure-websocket` (regex rule, `ERROR`).** It matches the plaintext WebSocket
  scheme anywhere, including in a comment, and cannot see where an address came from. Every
  remaining site is a loopback socket: `hermeyd/src/relay.rs` and `hermeyd/src/routes.rs` tests dial
  a listener the test itself bound on `127.0.0.1` (one note at the top of each test module, a
  `nosemgrep` at each construction), and `scripts/smoke-relay.py` targets `HERMEYD`, default
  `127.0.0.1:8788`. None of them is suppressed at file level, so a plaintext URL built anywhere else
  in those files is still reported.
- **bandit `B310` — `urlopen` on a URL that is not a literal (10 sites, `Tools/` and `scripts/`).**
  Each is an operator tool fetching either the host's own loopback API or a constant `https://`
  endpoint (GitHub API, the Pages feed); none takes a URL from a document it fetched.
  `publish_dist.fetch` now also refuses a non-http(s) scheme, so the class cannot become a local
  file read there.
- **bandit `B108` — a `/tmp` path in `Tools/local_computer.py` (2 sites).** A screenshot or a
  file read from the paired Mac is written to a predictable name under `/tmp` by the CLI the
  operator is already running as themselves, and the path is printed as the result. Worth making
  `tempfile`-based, not worth a security fix in this pass.
- **bandit `B101/B105/B404/B603/B607/B110/B112` — `Tools/` and `scripts/` (33 sites, all `LOW`).**
  A `subprocess` on a command the operator wrote, a `"password"` string that is an argv name, an
  `assert` in a record-fixtures tool.
- **semgrep `dynamic-urllib-use-detected` (23 sites, `WARNING`).** The same `urlopen` calls as
  `B310`, plus the bundled agent-skill copies under `hermeyd/assets/agent-skills/`.
- **semgrep `detect-non-literal-regexp` and `react-dangerouslysetinnerhtml` —
  `setup/plugins/hermes-genui/desktop/plugin.js` (the second only in some runs).** A `RegExp` built
  from the plugin's own card markup to find a card id, and `__html: PATHS[name]` where `PATHS` is a
  frozen map of SVG icons in the same file: `name` selects a key and nothing it can hold is written
  back into the page. The file is the pre-built plugin bundle the app ships (no sources, no build
  script in this repository), so it is read, not edited.
- **trivy: nothing.** **pip-audit: did not run** — there is no `requirements*.txt` or
  `pyproject.toml` at the root; the Python here is the stdlib plus the release tools' optional
  PyNaCl.

## Known limitations — documented, not fixed

- **Mac Sparkle installs can never pass the code-signature check, because the app is ad-hoc
  signed.** `.github/workflows/ci.yml` builds with `CODE_SIGNING_ALLOWED=NO` and only ad-hoc signs
  (`codesign --force --sign -`) before the DMG is packed. Sparkle 2 refuses to install an update
  whose code signature it cannot verify against the *running* app: the appcast's EdDSA signature is
  valid, but the app-signature half of the check cannot succeed, so in-app Mac updates fail after
  the download — every time, forever, on every machine. Nothing here fixes that; in-app Mac updates
  remain unusable by design of the current build. What would fix it: a paid Apple Developer
  account, signing the app (and every shipped build) with a **Developer ID Application**
  certificate, and **notarising** the DMG (`notarytool` + `stapler`) so Sparkle's verification chain
  has a trusted root — plus `SUPublicEDKey`/`SUFeedURL` staying as they are. Until that exists, the
  Mac channel is the download page, not Sparkle.

## Re-running

    bash ~/.hermes/profiles/cody/skills/software-development/code-audit/scripts/audit.sh \
        /root/jobs/hermey-cody /tmp/hermey-audit

Exit 0 means no unsuppressed high or critical finding. Anything new that is a real problem belongs
in the *Fixed* section with what was actually wrong, not in an allowlist.
