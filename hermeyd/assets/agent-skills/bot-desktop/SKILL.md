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

## A site blocked you: switch to this browser, do not ask

**Switching to the bot browser is not a question for the owner.** When a plain fetch comes back blocked —
`403`, a Cloudflare/DataDome "enable JS" interstitial, a JS-only shell with an empty body, a login wall, or a
bare `HTTP 403 from origin` out of `web_extract` — go up this ladder yourself, in one turn, and say what you
did afterwards. Asking "want me to try the browser?" costs the owner a reply and costs you a round trip; doing
it costs six seconds. The owner's standing instruction is to *not* be asked.

| rung | what | how |
| --- | --- | --- |
| 1 | plain fetch | `web_extract`, `curl`, a text endpoint (`llms.txt`, `.md`) |
| 2 | bot desktop browser | the one command under *The switch* — reads the display from the file |
| 3 | a login is needed | the **credential card** (the secure login / Sign-in card: `hermey_signin.py`, the `signin` skill): it types the credential into the page, never into chat and never a pasted password |
| 4 | still blocked (IP-level) | stop, and report exactly what was blocked and what the page said — with the screenshot. Do not loop, do not ask permission to keep trying |

Rung 2 is the answer for anti-bot protection **on this host**: a windowed Chromium on the bot desktop runs the
challenge JS, keeps a real cookie jar, and is the same browser a human would see. It is not a headless retry.

### The switch

```bash
BD="${HERMES_HOME:-$HOME/.hermes}/bot-desktop"
[ -d "$BD" ] || BD=$(dirname "$(readlink -f "$HOME"/.hermes/profiles/*/bot-desktop 2>/dev/null | head -1)")
@@BIN@@/hermey_browser.py open "<url>"    # starts the desktop if asleep; idempotent
@@BIN@@/hermey_desktop.py status          # running on :<display>, browsers connected: N
```

`open` is the whole switch: it wakes the desktop, launches the browser on **the display in `bot-desktop/display`**,
navigates, and returns only once the sign-in extension has connected. Running it twice is fine — the second call
attaches to the browser already up and returns at once. A killed earlier run leaves `start.lock`, `lease.lock` and
`lease.json` behind; those are `flock()` lock *files* (an owner dying releases the lock, the file staying is
normal) and `start` reclaims a display whose X lock names a dead pid, so retry rather than diagnosing.

Read the page with `probe`, then get the text with a screenshot or CDP — `probe` gives you
`title`/`url`/fields, and the DOM text is where the content is:

```bash
curl -s -X POST @@BROWSER@@/v1/browser/act -H 'content-type: application/json' -d '{"type":"probe"}'
DISPLAY=":$(cat "$BD/display")" import -window root /tmp/bot-page.png   # the artefact proving what you saw
```

**Never a hard-coded display number, and never `:10`.** `:10` is the owner's own session on this host: a window
launched there opens, exits 0, and is never seen by anyone — the task is silently lost. The number comes from
`bot-desktop/display` (or `bot-desktop/env`) every time, on every host.

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
curl -s -X POST @@BROWSER@@/v1/browser/act -H 'content-type: application/json' -d '{"type":"probe"}'
```

## The bot browser must load a command-line extension

Stable Google Chrome 137+ accepts `--load-extension` and loads **nothing**, silently — the sign-in extension
never attaches and every fill reports "no browser could take it". Run the bot's browser as Chrome for Testing
or Chromium, never stable Chrome; the extension's source is `browser-extension/` in this repository. If a login
suddenly stops filling after a browser change, check which binary is running before anything else.

The browser also never offers to save a password: it types the owner's credentials by design, and a prompt
over the page hides the field it is about to fill. The launcher writes that preference with the browser
stopped, because Chrome rewrites `Preferences` from memory on shutdown.
