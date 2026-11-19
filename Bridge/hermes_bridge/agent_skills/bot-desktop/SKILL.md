---
name: bot-desktop
description: "Use when a bot must use its own desktop or browser."
version: 1.0.0
metadata:
  hermes:
    tags: [desktop, gui, browser, bot-desktop, xvnc]
managed_by: hermey-bridge
---

# Your desktop is one shared screen

Every bot on this host uses **one** desktop: one X server, one browser profile, one set of logins,
one control lease. It is not per-bot and not per-profile. Read where it is — never assume.

## Where it is

The Hermes install creates a `bot-desktop` directory, and every profile has a symlink to it. Three
files matter:

| fact | read it from |
| --- | --- |
| the display number | `bot-desktop/display` |
| `DISPLAY`, `XAUTHORITY`, dbus address | `bot-desktop/env` |
| who holds control of the screen | `bot-desktop/lease.json` |

```bash
BD="${HERMES_HOME:-$HOME/.hermes}/bot-desktop"
[ -d "$BD" ] || BD=$(dirname "$(readlink -f "$HOME"/.hermes/profiles/*/bot-desktop 2>/dev/null | head -1)")
export DISPLAY=":$(cat "$BD/display")"
export XAUTHORITY="$BD/Xauthority"
xdpyinfo >/dev/null && echo "desktop reachable on $DISPLAY"
```

Never hard-code the number: read `display`, or source `env`. Another host's number is not yours.

## Never use a display that is not the one in `bot-desktop/display`

This is the mistake this skill exists to prevent, and it does not announce itself:

- **Somebody else's X server.** A host can carry more than one — the owner's own session, a leftover
  from an older install, a test harness. Launching `DISPLAY=:10 chrome …` there **works**: the
  window opens, the command exits 0, your logs look healthy, and the owner's viewer shows an empty
  screen because nothing is ever drawn on their display. The task is silently lost, and it is
  reported as done.
- **A private `Xvfb :99` "just for this task"** because `DISPLAY` was unset. Same outcome: invisible
  work.

If `DISPLAY` is unset, or is not what `display` says, set it from that file and carry on. Do not
create a second server, and do not "try the other one" when a window does not appear — check that
you are on the right display first.

## Prove the window landed before claiming success

```bash
DISPLAY=":$BD_DISPLAY" xdotool search --name "<window title>" | head
```

A non-zero exit from a launcher is evidence of nothing. If the window is not on the canonical
display, close it and relaunch with the right `DISPLAY`.

## One screen means a shared browser profile

Browsers run against the shared profile (`bot-desktop/browser-profile`), so logins and cookies are
shared with every other bot. Do not save personal credentials there, do not assume a fresh session,
and do not run a browser with a private `--user-data-dir` and expect the owner to see it — that is
how the wrong-display failure above usually starts.

## A human shares this screen

`lease.json` names who holds control (`holder`, `viewer_id`, `epoch`). Physical keyboard or mouse
input pauses bot actions (takeover); if the owner takes over, stop acting until `resume`. There is
also only one pointer: two bots acting at once fight over it, so serialise GUI work and never assume
your click landed where you aimed if another bot was active.
