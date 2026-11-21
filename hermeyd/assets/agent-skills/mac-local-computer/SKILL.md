---
name: mac-local-computer
description: Use when a task must run on the owner's own Mac.
version: 1.0.0
author: Hermey
license: MIT
metadata:
  hermes:
    tags: [mac, computer-use, shell, remote, hermey, desktop]
    category: desktop
    related_skills: [computer-use, hermey-app-development]
    managed_by: hermey-bridge
---

# The owner's Mac

The owner's Mac is reachable **from this host, without SSH**. The Hermey app on the Mac holds a
socket open to the Hermey service (hermeyd) running beside this agent, and one small CLI sends work
through it. Remote Login can be off, the Mac can be on any network, and nothing is exposed to the
internet.

Reach for this whenever a task is "on my Mac" / "on my desktop", needs macOS or Xcode (no Xcode
exists on a Linux host), or needs the owner's own logged-in apps and screen.

## The one command

```
python3 @@CLI@@ <subcommand> [flags]
```

It prints the Mac's stdout/stderr and exits with the Mac command's exit code. Everything below runs
through it.

The CLI sends the service's local bearer for you, read from `$HERMEYD_LOCAL_TOKEN` or, when that is
unset, from `@@TOKEN_FILE@@`. If it reports **no local bearer**, that file is missing or not readable
by your user: say so and stop — do not look for another route to the Mac. The service's main API is
`@@API@@`.

## First: is a Mac even connected?

```
curl -s -H "Authorization: Bearer $(cat @@TOKEN_FILE@@)" @@API@@/v1/local-computers
```

`{"computers":[{"device_id":"…","name":"MacBook Air","connected":true}]}` — an empty list means
no Mac right now. Ask the owner to open Hermey on the Mac, go to the Computer tab and turn on **Let
bots use this computer**. Do not guess at SSH, and do not retry in a loop.

## Choose the surface

| The task | Use |
|---|---|
| Build, test, inspect anything (`xcodebuild`, `brew`, `git`, `swift`) | shell |
| "What's on my screen" / "take a screenshot" / find click targets | `observe` |
| Click, type, scroll, switch app, open a file or URL | `act` |
| Read/write a file in the shared Hermey workspace | `files` |
| A page that needs the owner's logged-in browser | `browser` |
| Need a decision from the owner | `ask` |

## Shell — argv, never a shell string

```
python3 @@CLI@@ -- sw_vers
python3 @@CLI@@ --cwd ~/project -- make -j8
python3 @@CLI@@ --stream -- xcodebuild -project App.xcodeproj -scheme App -configuration Debug
```

- The command is an **argv array**: no shell runs it. `cd a && b`, pipes, `>` redirects, globs and
  `$VAR` are not interpreted, so `cd x && y` must become `--cwd x` plus the argv of `y`, and `~` is
  **not** expanded — write `/Users/<name>/…` or let the shell on the Mac do it:
  `-- /bin/sh -lc 'ls ~/Desktop | wc -l'`.
- `--timeout-ms` defaults to 900000 (15 min) and maxes at 1800000 (30 min). A longer build should
  `--stream` so the deadline keeps moving with progress, or be split.
- `--computer "MacBook Air"` picks one Mac when several are paired; it is optional.
- The Mac's `PATH` includes Homebrew and the system toolchain.

## Screen — always look before you touch

```
python3 @@CLI@@ observe --save /tmp/mac-$(date +%s).jpg
```

Prints JSON: `path`, `width`, `height`, `frame_id`, `active_window` (`owner`, `title`, `bundleID`,
`bounds`), `captured_at`. Open the JPEG with your vision tool to see the screen; `active_window`
alone tells you what is frontmost without looking at pixels.

## Acting on the GUI

```
python3 @@CLI@@ act '[{"kind":"focus","application":"Safari"},{"kind":"click","x":812,"y":420},{"kind":"type","text":"hello\n"}]' --bot <your-bot-name>
```

1–24 actions per batch; the batch returns a **fresh observation** afterwards.

| `kind` | Fields |
|---|---|
| `click` | `x`, `y`, `button` (`left` / `right`) |
| `move` | `x`, `y` |
| `down` / `up` | `button` — hold and release, for drags |
| `type` | `text` (`"\n"` presses Return) |
| `key` | `key` (`return`, `tab`, `space`, `escape`, `delete`, `left`, `right`, `up`, `down`), `modifiers` (`cmd`, `shift`, `option`, `control`) |
| `scroll` | `direction` (`up`/`down`/`left`/`right`), `amount` (pixels) |
| `wait` | `milliseconds` (≤ 5000) |
| `focus` | `application` (name or bundle id) |
| `open_path` | `path` (file, folder or URL) |

Five rules that will bite you:

1. **`click`, `move` and `scroll` need an `observe` in the last 30 seconds** — otherwise the Mac
   refuses the act with `observe first`.
2. **Coordinates are screen points** from the observation you just took (`0,0` is the top-left of
   the main display). They are checked against the union of all connected displays; anything outside
   is rejected. If the JPEG was downscaled, scale your coordinates by
   `width / <the pixels you measured>` before sending them.
3. **One GUI batch at a time.** A global gate serialises batches — two bots queue, they do not
   interleave. Keep batches short so the other bot is not blocked for long.
4. **The owner wins.** If they touch the Mac, the batch pauses (takeover). Stop, tell them, and use
   `resume` only when they hand control back.
5. **A locked screen refuses everything** (`Act failed: locked`). Ask the owner to unlock it.

## Files in the shared workspace

```
python3 @@CLI@@ files list "" | read <path> [--save local-path] | write <path> <local-file> | mkdir <path>
```

`write` sends a file from **this** machine to the Mac. Confined to the shared Hermey workspace, not
the whole disk — for anything else use the shell.

## The Mac's private browser

```
python3 @@CLI@@ browser navigate <url> | snapshot | act '<json-actions>' | downloads
```

Use it for pages that need the owner's **logged-in** browser profile. For ordinary page content,
prefer this host's own headless browser tooling.

## Ask, then resume

```
python3 @@CLI@@ ask <profile> "Should I deploy this build?"
python3 @@CLI@@ resume
```

`ask` posts a labelled row into that bot's chat and waits for the owner's next reply there — use it
instead of guessing when the next step is destructive or ambiguous. `resume` hands control back
after a takeover.

## When it fails

| Message | Meaning | What to do |
|---|---|---|
| `no local computer is connected` | app closed, not paired, or the switch is off | run the `curl` check, then ask the owner |
| `access revoked` (close code 4403) | the owner turned the switch off | ask; never retry in a loop |
| `503 that computer is not connected` | the socket dropped mid-call | retry once, then report |
| `504 the computer did not answer in time` | command outran the deadline | raise `--timeout-ms`, or `--stream` |
| `observe first` | no observation in the last 30 s | `observe`, then act |
| `(x, y) is outside the displays` | stale or mis-scaled coordinates | re-`observe` and recompute |
| `Permission: Accessibility` | the Mac has not granted accessibility | owner: Computer tab → **Request Access** |
| `Permission: Screen Recording` | observe cannot capture | owner: Computer tab → **Request Access** |
| `Act failed: locked` | screen is locked | ask the owner to unlock |
| `401` on a `curl` | no bearer, or a stale one | send `Authorization: Bearer $(cat @@TOKEN_FILE@@)`; a stale file needs the service restarted |
| `403` on a `curl` from another machine | these routes are **loopback-only** | run the command on this host |

## Hard rules

- **Never type, read back or screenshot a secret** — no password, API key, card number or 2FA code,
  in a field or from an image. If a login needs one, ask the owner to do it.
- **Stop at any permission, consent or payment dialog** and ask. Never click through one.
- Commands run as the owner's own macOS user with their full authority. Treat `rm -rf`,
  `git push --force`, deploys and installers as if they were typed on the owner's keyboard, and
  confirm destructive ones first.
- Do not disturb the owner's unrelated windows, tabs or documents — someone is using this Mac.

## Prove it works

```
python3 @@CLI@@ -- uname -a      # Darwin … means the Mac answered
```
