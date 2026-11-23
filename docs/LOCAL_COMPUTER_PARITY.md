# Hermey → Rakazo local-computer parity tasklist (revised)

Baseline shipped in 0.1.561: outbound authenticated socket, host + paired-device auth, **no approval
gate** (owner decision), argv shell with cwd / 30-min timeout / 4 MB cap, host-side bot CLI, remote
revoke, audit. Remote Login is off on the Mac.

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

## Phase 1 — Permission onboarding (no stable signing) — done
- [x] Settings → Computer shows live status for Screen Recording, Accessibility, Input Monitoring and Automation, each with a button opening the right System Settings pane
- [x] Detect with `AXIsProcessTrusted`, ScreenCaptureKit status and a harmless `osascript` probe; Automation failures name the app that needs consent
- [x] Every tool returns an actionable "enable X" error; no crashes
- [x] Accepted trade-off: ad-hoc signing can invalidate TCC grants on update; re-prompt cleanly
- [x] Acceptance: after granting, observe/act work; after a simulated update the UI says which grant is missing

## Phase 2 — `computer.observe` — done
- [x] ScreenCaptureKit full-display capture + active window title/bundle from CGWindowList
- [x] JPEG q≈0.7, max 1600 px, ≤1 fps by default, duplicate-frame suppression, 4 MB cap
- [x] `computer observe` CLI subcommand; result carries image plus frame metadata
- [x] Acceptance: screenshot in < 1 s; locked display returns a clear refusal

## Phase 3 — `computer.act` — done
- [x] CGEvent actions: `click`, `move`, `down`, `up`, `type`, `key`, `scroll`, `wait`, `focus`; batches up to 24; stop on first failure; return a fresh observation
- [x] Mark our own events with `eventSourceUserData` so a listen-only tap can distinguish physical input
- [x] Coordinate actions require an observation in the last 30 s; refuse when display is locked
- [x] Physical mouse/keyboard activity pauses the batch immediately (takeover primitive)
- [x] `computer act` CLI subcommand; per-action audit
- [x] Acceptance: focus TextEdit, type, click a menu, verify by screenshot; no runaway input

## Phase 4 — App and window control — done
- [x] `launch_app` / `open_path` / `focus` via NSWorkspace; return frontmost app/window metadata
- [x] `computer launch` CLI subcommand
- [x] Acceptance: launch and focus an app by name/bundle id without a shell `open`

## Phase 5 — File tools, shared workspace — done
- [x] One workspace at `~/Library/Application Support/Hermey/Computer/Workspace/`
- [x] `read_file`, `write_file`, `list_files`, `attach_file`; confine file tools to that workspace (plus roots explicitly added in Settings)
- [x] Binary-safe base64, atomic writes, size caps; upload/download through the existing hermes file store
- [x] `computer files ...` CLI subcommand
- [x] Acceptance: write/edit/list/transfer a file; `../` escape refused and audited; two bots see the same workspace

## Phase 6 — Browser tools — done
- [x] Embedded WKWebView surface with `browser_navigate`, `browser_snapshot`, `browser_act` (click/fill/type/upload)
- [x] Downloads saved into the shared workspace and listed with paths; unresolved pages fall back to `computer_act`
- [x] `computer browser ...` CLI subcommand
- [x] Acceptance: navigate, snapshot, fill, upload, download — verified by snapshot and saved file

## Phase 7 — Secret-safe output — done
- [x] Reuse the bot's existing Hermes secret store; no new vault UI
- [x] Redact known secret values from command stdout/stderr before returning them; redact from logs
- [x] Accepted limit: screenshots are not content-redacted
- [x] Acceptance: a command printing a known secret returns `[redacted]`

## Phase 8 — Takeover and ask_user — done
- [x] Menu-bar "Bot control active" indicator; physical input pauses bot GUI actions, explicit resume required
- [x] `ask_user` posts a question into the bot's conversation via the existing bot-message route and waits for the owner's reply
- [x] No modal approvals or per-action gate
- [x] Acceptance: takeover pauses in < 100 ms; bot resumes only on explicit release

## Phase 9 — Activity feed and live progress — done
- [x] `computer.command` events for shell and GUI actions in Settings → Computer → Activity (bot label, action, outcome)
- [x] Stream NDJSON progress for long commands so Xcode builds show live log lines
- [x] Acceptance: a 2-minute xcodebuild shows live output and final exit code

## Phase 10 — Concurrency and cancellation — done
- [x] Global GUI driver lock + FIFO queue; one bot drives the screen at a time; shell commands may queue behind GUI actions
- [x] Cancel kills the running process or stops an action batch; disconnect releases the lock
- [x] Audit records which bot label drove each action
- [x] Acceptance: two simultaneous batches are serialized, not interleaved; cancel leaves no orphan process

## Phase 11 — Connectivity discipline (no LaunchAgent) — done
- [x] hermeyd answers 503 "that computer is not connected" when the Mac is offline or Hermey is closed
- [x] Existing 20 s heartbeat / 1→30 s reconnect handles sleep, wake and network changes
- [x] Acceptance: closing Hermey immediately disables computer use; reopening reconnects without restart

## Phase 12 — Bot surface, verification
- [x] Extend the shared Hermey skill with every new subcommand and permission requirement
- [x] SLOs: observe < 1 s, act < 500 ms, shell start < 200 ms, reconnect < 30 s
- [x] Two-bot stress, permission-revoke and offline/reconnect tests
- [x] 1-hour soak (clean: 0 failures)
- [x] Acceptance: SLOs met, no leaked processes or stale locks

## Build batches (one release per batch)

Phase 0–2 and the socket fix are already shipped (0.1.567). The remaining work is grouped into three
builds so each release is a coherent, testable capability step:

**Build A — GUI core:** phases 3 + 4 + 10
`computer.act` (CGEvent batches), `launch_app`/`open_path`/`focus`, and the global GUI lock, FIFO queue,
cancellation and bot-label audit. The lock ships with input, not after it, so two bots can never drive
the mouse at once.

**Build B — Productivity:** phases 5 + 6 + 7
One shared workspace with read/write/list/attach and file-store transfer, embedded WKWebView browser
tools with downloads into that workspace, and secret redaction across command output and logs.
Browser downloads depend on the workspace; redaction covers both file and browser results.

**Build C — Polish and proof:** phases 8 + 9 + 11 + 12
Takeover plus `ask_user`, activity feed with live build progress, connectivity discipline (the 503 /
reconnect behaviour is already mostly proven), then CLI/skill docs and the SLO/soak/stress suite.
This batch validates the whole stack after the features exist.

Status: all three builds are shipped and verified. Every phase is implemented, tested and verified
live; the 1-hour soak finished with zero failures.

No separate release per phase; acceptance checks for every phase still apply within its batch.
