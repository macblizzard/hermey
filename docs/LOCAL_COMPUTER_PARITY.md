# Hermey → Rakazo local-computer parity tasklist (revised)

Baseline shipped in 0.1.561: outbound authenticated socket, host + paired-device auth, **no approval
gate** (owner decision), argv shell with cwd / 30-min timeout / 4 MB cap, host-side bot CLI, remote
revoke, bridge audit. Remote Login is off on the Mac.

Owner decisions that shape this plan:
- **No LaunchAgent.** Only act while the Mac is online and Hermey is running; "not connected" is a
  normal 503, not a failure to recover.
- **No per-bot permission system.** A small set of bots will be used; no grants UI.
- **No Apple Developer certificate.** Ad-hoc signing stays; TCC grants may need re-granting after an
  app update. Permission status cards make that obvious rather than silently failing.
- **One shared workspace** for all bots, not per-bot directories. Path confinement applies to file
  tools; shell commands remain full-access as today.

Goal: match Rakazo's desktop-computer capability set: screen observe, GUI act, app launch, file tools,
browser tools, secret-safe output, takeover, activity feed, serialization, resilient reconnect.

## Phase 0 — Done
- [x] Native shell, outbound socket, heartbeat/backoff, revoke, audit, bot CLI

## Phase 1 — Permission onboarding (no stable signing)
- [ ] Settings → Computer shows live status for Screen Recording, Accessibility, Input Monitoring and Automation, each with a button opening the right System Settings pane
- [ ] Detect with `AXIsProcessTrusted`, ScreenCaptureKit status and a harmless `osascript` probe; Automation failures name the app that needs consent
- [ ] Every tool returns an actionable "enable X" error; no crashes
- [ ] Accepted trade-off: ad-hoc signing can invalidate TCC grants on update; re-prompt cleanly
- [ ] Acceptance: after granting, observe/act work; after a simulated update the UI says which grant is missing

## Phase 2 — `computer.observe`
- [ ] ScreenCaptureKit full-display capture + active window title/bundle from CGWindowList
- [ ] JPEG q≈0.7, max 1600 px, ≤1 fps by default, duplicate-frame suppression, 4 MB cap
- [ ] `computer observe` CLI subcommand; result carries image plus frame metadata
- [ ] Acceptance: screenshot in < 1 s; locked display returns a clear refusal

## Phase 3 — `computer.act`
- [ ] CGEvent actions: `click`, `move`, `down`, `up`, `type`, `key`, `scroll`, `wait`, `focus`; batches up to 24; stop on first failure; return a fresh observation
- [ ] Mark our own events with `eventSourceUserData` so a listen-only tap can distinguish physical input
- [ ] Coordinate actions require an observation in the last 30 s; refuse when display is locked
- [ ] Physical mouse/keyboard activity pauses the batch immediately (takeover primitive)
- [ ] `computer act` CLI subcommand; per-action audit
- [ ] Acceptance: focus TextEdit, type, click a menu, verify by screenshot; no runaway input

## Phase 4 — App and window control
- [ ] `launch_app` / `open_path` / `focus` via NSWorkspace; return frontmost app/window metadata
- [ ] `computer launch` CLI subcommand
- [ ] Acceptance: launch and focus an app by name/bundle id without a shell `open`

## Phase 5 — File tools, shared workspace
- [ ] One workspace at `~/Library/Application Support/Hermey/Computer/Workspace/`
- [ ] `read_file`, `write_file`, `list_files`, `attach_file`; confine file tools to that workspace (plus roots explicitly added in Settings)
- [ ] Binary-safe base64, atomic writes, size caps; upload/download through the existing hermes file store
- [ ] `computer files ...` CLI subcommand
- [ ] Acceptance: write/edit/list/transfer a file; `../` escape refused and audited; two bots see the same workspace

## Phase 6 — Browser tools
- [ ] Embedded WKWebView surface with `browser_navigate`, `browser_snapshot`, `browser_act` (click/fill/type/upload)
- [ ] Downloads saved into the shared workspace and listed with paths; unresolved pages fall back to `computer_act`
- [ ] `computer browser ...` CLI subcommand
- [ ] Acceptance: navigate, snapshot, fill, upload, download — verified by snapshot and saved file

## Phase 7 — Secret-safe output
- [ ] Reuse the bot's existing Hermes secret store; no new vault UI
- [ ] Redact known secret values from command stdout/stderr before returning them; redact from logs
- [ ] Accepted limit: screenshots are not content-redacted
- [ ] Acceptance: a command printing a known secret returns `[redacted]`

## Phase 8 — Takeover and ask_user
- [ ] Menu-bar "Bot control active" indicator; physical input pauses bot GUI actions, explicit resume required
- [ ] `ask_user` posts a question into the bot's conversation via the existing bot-message route and waits for the owner's reply
- [ ] No modal approvals or per-action gate
- [ ] Acceptance: takeover pauses in < 100 ms; bot resumes only on explicit release

## Phase 9 — Activity feed and live progress
- [ ] `computer.command` events for shell and GUI actions in Settings → Computer → Activity (bot label, action, outcome)
- [ ] Stream NDJSON progress for long commands so Xcode builds show live log lines
- [ ] Acceptance: a 2-minute xcodebuild shows live output and final exit code

## Phase 10 — Concurrency and cancellation
- [ ] Global GUI driver lock + FIFO queue; one bot drives the screen at a time; shell commands may queue behind GUI actions
- [ ] Cancel kills the running process or stops an action batch; disconnect releases the lock
- [ ] Audit records which bot label drove each action
- [ ] Acceptance: two simultaneous batches are serialized, not interleaved; cancel leaves no orphan process

## Phase 11 — Connectivity discipline (no LaunchAgent)
- [ ] CLI/bridge return 503 "computer not connected" when the Mac is offline or Hermey is closed
- [ ] Existing 20 s heartbeat / 1→30 s reconnect handles sleep, wake and network changes
- [ ] Acceptance: closing Hermey immediately disables computer use; reopening reconnects without restart

## Phase 12 — Bot surface, verification
- [ ] Extend the shared Hermey skill with every new subcommand and permission requirement
- [ ] SLOs: observe < 1 s, act < 500 ms, shell start < 200 ms, reconnect < 30 s
- [ ] 1-hour soak, two-bot stress, permission-revoke and offline/reconnect tests
- [ ] Acceptance: SLOs met, no leaked processes or stale locks

Ordering: 1 → 2 → 3 → 4 → 9/10 → 12; phases 5, 6, 7, 8, 11 can proceed in parallel after phase 3.
