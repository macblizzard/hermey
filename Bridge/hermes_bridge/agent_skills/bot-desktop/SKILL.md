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

## Wake it yourself

The desktop sleeps when nothing is using it — it holds a whole X server and a browser, so leaving it up
idle is waste. What matters is that you bring it back rather than reporting a dead screen:

```bash
@@BIN@@/hermey_desktop.py start     # idempotent; returns at once if already up
@@BIN@@/hermey_desktop.py status
```

Run `start` before opening anything on the bot screen. If a browser later fails with "Missing X server",
that is this: call `start` and retry. Never `stop` it yourself — the watchdog handles idleness.

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

## Reading a page: `probe` before guessing

`probe` returns what the page actually offers, read from the DOM rather than from wording, so it works on a
site or a language never seen before:

```
url, formPresent, usernameFields, passwordFields, otpBoxes, submitLabel, buttons, loginLinks, fields[]
```

- `usernameFields` counts real credential fields (`type=email`, `autocomplete=username`, or a name that says
  so) and **excludes search boxes** — a page with text boxes is not a login page, and treating one as such
  put an owner's email into a search field once.
- `submitLabel` is the form's own submit control; prefer clicking it (`{"type":"submit"}`) over matching a
  button label.
- `loginLinks` are anchors whose `href` says login/auth/sso — follow them with `{"type":"clickHref"}` to reach
  a sign-in page regardless of the page's language.

```bash
curl -s -X POST @@BRIDGE@@/v1/browser/act -H 'content-type: application/json' -d '{"type":"probe"}'
```

## The bot browser is pinned to Chrome for Testing

Stable Google Chrome 137+ accepts `--load-extension` and loads **nothing**, silently — the sign-in extension
never attaches and every fill reports "no browser could take it". `setup/bot-browser.sh` provisions Chrome for
Testing under `/opt/hermes-chromium` and the launcher points at it. If a login suddenly stops filling after a
browser change, check which binary is running before anything else.

The browser also never offers to save a password: it types the owner's credentials by design, and a prompt
over the page hides the field it is about to fill. The launcher writes that preference with the browser
stopped, because Chrome rewrites `Preferences` from memory on shutdown.
