# Hermey → Rakazo local-computer parity tasklist

Baseline shipped in 0.1.561: outbound authenticated socket, host + paired-device auth, **no approval
gate** (owner decision), argv shell with cwd / 30-min timeout / 4 MB output cap, host-side bot CLI,
remote revoke, bridge audit. Remote Login is off on the Mac.

Goal: match Rakazo's desktop-computer capability set — native shell (done), screen observe, GUI act,
file tools, app launching, browser tools, secret-safe output, takeover, activity feed, per-bot
workspaces, and resilient lifecycle. Explicitly **out of scope**: per-action approval prompts.

## Phase 0 — Done (baseline)
- [x] Native shell on the Mac, no SSH
- [x] Bot CLI: `python3 Tools/local_computer.py -- <argv>`
- [x] 20 s heartbeat, 1→30 s reconnect, remote revoke

## Phase 1 — Permissions and onboarding (prerequisite)
- [ ] Stable code-signing identity / entitlements so macOS TCC grants survive app updates
- [ ] Settings → Computer: live status cards for Screen Recording, Accessibility, Input Monitoring, Automation; buttons to open the right System Settings pane
- [ ] Graceful degradation: every tool returns an actionable permission error instead of crashing
- [ ] Acceptance: after granting all four permissions once, they remain granted across a 0.1.x update

## Phase 2 — Screen observation
- [ ] `computer.observe` in the Mac app via ScreenCaptureKit: image + frame id + size + active window title/bundle
- [ ] Transport: downsample/encode (JPEG), rate limit, drop duplicate frames
- [ ] Bridge + CLI endpoint `computer observe`; result includes image reference for the bot
- [ ] Acceptance: screenshot returns in < 1 s at 1440×900; permission failure explains what to enable

## Phase 3 — GUI input
- [ ] `computer.act` via CGEvent: `click`, `move`, `down`, `up`, `type`, `key`, `scroll`, `wait`, `focus`
- [ ] Batches up to 24 ordered actions; coordinate bounds check; stop on first failure; returns a fresh observation
- [ ] Safety: pause input when the physical user moves the mouse, refuse when display is locked/screensaver, per-action audit
- [ ] Bridge + CLI endpoint `computer act`
- [ ] Acceptance: bot can focus TextEdit, type a sentence, click a menu and verify with a screenshot; no runaway input

## Phase 4 — App and window control
- [ ] `launch_app` (bundle id or name), `open_path` (file/URL), `focus` via NSWorkspace
- [ ] Return frontmost app/window metadata after the action
- [ ] Acceptance: launching Calculator and focusing it works without a shell `open`

## Phase 5 — File tools and per-bot workspaces
- [ ] Per-bot workspace directories under `~/Library/Application Support/Hermey/Computer/<bot>/`
- [ ] `read_file`, `write_file`, `list_files`, `attach_file`; path confinement to workspace + explicitly allowed roots
- [ ] Binary-safe base64, atomic writes, size caps; upload/download through the hermes file store
- [ ] Acceptance: bot writes, edits, lists and transfers a file; `../` escape is refused and audited

## Phase 6 — Browser tools
- [ ] `browser_navigate`, `browser_snapshot`, `browser_act` (click/fill/type/upload) on the Mac's browser or a WebKit surface
- [ ] Downloads land in the bot workspace and are listed with paths; fallback to `computer_act` for unresolved pages
- [ ] Acceptance: navigate, snapshot, fill a field, upload a file, download a file, all verified

## Phase 7 — Secret-safe output
- [ ] Reuse the bot's existing Hermes secret store for fills; never echo secrets into command results or logs
- [ ] Redact known secret values from stdout/stderr before returning to the bot
- [ ] Acceptance: a command that prints a known secret returns `[redacted]`

## Phase 8 — Takeover and user intervention
- [ ] Human takeover: pause all bot GUI input on physical mouse/keyboard activity; menu-bar indicator; explicit resume
- [ ] `ask_user` sends a question into the bot conversation and waits for the owner's reply (no modal approvals)
- [ ] Acceptance: takeover pauses input in < 100 ms; bot resumes only after explicit release

## Phase 9 — Activity feed and progress
- [ ] `computer.command` events for shell and GUI actions, shown in Mac Settings → Computer → Activity with bot id, command, outcome
- [ ] Stream progress/live output for long builds instead of only a final result
- [ ] Acceptance: a 2-minute xcodebuild shows live log lines and a final exit code in the feed

## Phase 10 — Concurrency and safety
- [ ] Global GUI driver lock + command queue; one bot drives the screen at a time
- [ ] Per-bot workspaces isolate files; visible "who is driving" indicator
- [ ] Cancellation: kill running process / stop action batch on request or disconnect
- [ ] Acceptance: two bots submitting GUI batches at once are serialized, not interleaved

## Phase 11 — Lifecycle
- [ ] LaunchAgent so Hermey starts at login; sleep/wake handled by existing heartbeat/backoff
- [ ] Verify TCC grants and pairing after macOS/app updates; re-prompt only when needed
- [ ] Acceptance: reboot the Mac, app returns and computer-use reconnects without SSH

## Phase 12 — Bot-facing surface and documentation
- [ ] Extend `Tools/local_computer.py` with `observe`, `act`, `files`, `browser` subcommands
- [ ] Update the shared Hermey skill with every new command and its permission requirements
- [ ] Release notes and regression tests for each phase

## Phase 13 — Verification and performance
- [ ] SLOs: observe < 1 s, GUI action < 500 ms, shell start < 200 ms, reconnect < 30 s
- [ ] 1-hour soak test (heartbeat, memory, screenshot throughput), two-bot stress test, permission-revoke test
- [ ] Acceptance: SLOs met with no leaked processes or stale locks

Ordering: 1 → 2 → 3 → 4 → 9/10 → 12 → 13; phases 5, 6, 7, 8 can run in parallel after phase 3; phase 11 can run independently.
