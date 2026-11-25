---
name: signin
description: Ask the owner to sign in without handling the password.
managed_by: hermey-bridge
---

# Signing the owner in

This skill **is** the shipped implementation of the fleet's `SECURE-ENTRY` requirement (defined in the
`agent-cards` skill, §"Secure entries"): a credential is asked for with a card the app fills in, never in
chat. The commands and flags below are the one copy of that contract — the rule points here, so change
the two together and nowhere else.

When a site asks for a login and you cannot proceed without one, do **not** ask the owner to type a
password into the chat. Ask for a card instead. The owner answers it in the Hermey app, the browser on
this desktop gets filled in, and you are told one thing: whether it worked.

## Commands

Ask which method to use (when the page offers several):

```bash
@@BIN@@/hermey_signin.py ask --site doctolib.de --kind choice \
  --options "Continue with Google" "Email and password" \
  --note "Booking an appointment"
```

Ask for the details, when the owner picked a password:

```bash
@@BIN@@/hermey_signin.py ask --site doctolib.de --kind secret \
  --fields username password --note "Booking an appointment"
```

Ask for a one-time code after submitting, when the site sends one:

```bash
@@BIN@@/hermey_signin.py ask --site doctolib.de --kind secret \
  --fields "one-time code" --note "The code the site just sent"
```

Confirm a saved connection instead of typing anything:

```bash
@@BIN@@/hermey_signin.py ask --site doctolib.de --kind confirm \
  --options "Google — mo@example.com"
```

## A value you will need again (an API key, a token)

A login is typed once and gone. A credential you will use again — an API key, a token — has to have
somewhere to live that is not your context. Ask for it **once** with `--store`: the owner types it into
the same card, the host writes it into its vault, and you are given the **name** to use later.

```bash
@@BIN@@/hermey_signin.py ask --site api.openai.com --fields "api key" --note "Reading the model list" \
  --store --save-as openai.main
```

It prints `stored api key as openai.main` and fills nothing. Keep that name; never ask for the value
again, and never print, quote or paste it — you will never have it. `--save-as` is optional: without it
the name is `<site>/<field>` (`api.openai.com/api-key`). A name is letters, digits, `.`, `_`, `-` and one
`/`, up to 96 characters.

## Signing in again without asking

Once a credential is stored, fill a form with it **by name**. No card is raised and the value never
passes through this process or into your context:

```bash
@@BIN@@/hermey_signin.py ask --site doctolib.de --fields password --use doctolib.de/password
```

One stored item is one value, so it fills exactly one field. This path needs the sign-in extension (the
DevTools fallback can only type a value it was handed), and it says so plainly when the extension is not
connected. Prefer `--store` + `--use` for anything you expect to do twice; use a plain `ask` for a login
you are doing once.

## Getting to the login page

The desktop sleeps when idle, so open the page first — this wakes it, clears a browser that is holding the
profile without a connection, launches the browser and waits until the sign-in extension is attached:

```bash
@@BIN@@/hermey_browser.py open https://www.doctolib.de/patient/login
```

Do not start a browser another way. A second Chromium against the same profile only prints "Opening in
existing browser session" and exits, and the card then has nothing to fill.

`login` finds the sign-in form itself, and **asks for nothing until a real form is on screen**: it follows
login links or clicks the login control, walks through account-choice screens, and only then raises a card.
A page with text boxes is not a sign-in page — Doctolib's homepage search form once swallowed an owner's
email that way, so search fields are excluded on purpose.

## A whole login in one call

```bash
@@BIN@@/hermey_signin.py login --url https://www.doctolib.de/patient/login --site doctolib.de \
  --note "Booking an appointment"
```

It opens the page, finds the form, asks the owner **once** for the email and the password, fills each step as
the page presents it, submits with the form's own control, and handles a two-step code. Print the link it
gives you and let the owner answer; do not fill anything yourself.

It prints one `step N:` line per move (url, field counts, what it clicked), so a run that stops short says
where it stopped. Sites drop the sign-in step while the owner is reading the card; the verb re-enters the
form at fill time, so a slow answer is not a failure.

## When the site asks for a code by email

If the owner has connected Gmail, you can fetch the code yourself with your Composio Gmail tools (see the
`integrations` skill) and hand it in, so the owner is asked only for their password:

```bash
@@BIN@@/hermey_signin.py login --url https://… --site doctolib.de --otp 123456
```

Use the newest message only, and only the code from this site. Never read other mail for this.

## What you get back

```
filled
signed in (https://www.doctolib.de/)
stored api key as openai.main
not stored — this host has no vault yet (update hermeyd); nothing was asked of the owner
not filled — no browser connected: waited 20s for the sign-in extension and http://127.0.0.1:8790 still
              lists no target (the worker is asleep and its socket is closed); nothing was filled
not filled — a stored credential is filled through the sign-in extension, and none connected: waited 20s;
              nothing was filled
not filled — a browser is connected but its page has no field matching password: <url> — the probe saw
              input_:r0: [text/username]; buttons: Zurück, Weiter
not filled — the fill was sent but the value did not land: the password field on <url> now reads empty
filled (the DevTools port; no extension was connected)
not filled — the DevTools browser is showing <url>, not <site>: nothing was typed
not filled — the owner did not answer in time
not filled — no sign-in page at <url> (0 text field(s), no password field); nothing was asked of you
not filled — one stored item fills one field, and 2 were named: username, password; ask for a card instead
```

`filled` means the values reached the page (and, where the page can be asked, still holds them). When no
extension is connected, the fill goes through the bot screen's DevTools port instead — the browser the dock
launched — and the line says so in brackets so you can tell which path was used. That path fills one card's
fields into the form already showing; `login`'s step-by-step driving still needs the extension. `signed in`
means the final page no longer shows a sign-in form — confirm before promising it. The three `not filled`
lines above name different faults: nothing was connected, a browser was connected but the page had no such
field (the line lists what the probe did see), or the value was written and the page dropped it. The
DevTools line naming another page is the same second fault on the fallback path: the browser is on
`<url>`, not the site the card names, and **nothing was typed** — navigate to the site and ask again. Act on the
difference — reconnect for the first, re-open the form for the second, retry once for the third — and never
ask the owner to paste the password instead.

## Rules

- Never ask for a password, a code or a card number in the conversation. There is no exception.
- **Never answer "I can't, it needs a login".** A login wall is not a dead end here: raise the card and
  wait for the owner. The same is true for an API key or a token — ask for it once with `--store`, then
  use the name.
- One card at a time. Do not fire two asks and hope one lands. `login` asks for 10 minutes; `ask` takes the
  service's own default (15 minutes, `ttl_seconds` 30 s – 24 h).
- The `--site` is the origin you are actually on. It is what the owner sees, so make it the real one.
- `--note` is one short line saying what you are doing. It is the only context the owner gets.
- Never fill a login form yourself, by typing into the page or writing to a field. That is what the card
  is for, and it is how a value ends up somewhere you can read.
- The script talks to the Hermey service itself: cards on @@API@@, page actions on @@BROWSER@@. It
  sends the local bearer from `$HERMEYD_LOCAL_TOKEN`, or from @@TOKEN_FILE@@ when that is unset. If it
  reports **no local bearer** or a 401, the token file is missing, stale or unreadable — say so and
  stop rather than trying another route.

## When it does not work

- **"no browser connected"** — the desktop slept or the worker was suspended. The CLI already pings and
  waits two 20 s windows before saying this; if it does, run `hermey_browser.py open` again (it wakes the
  desktop and waits for the extension) or set `HERMEY_BROWSER_WAIT_SECONDS` to wait longer.
- **"the DevTools browser is showing <url>, not <site>"** — no extension is connected, and the only browser
  with a debugging port is on another page. Nothing was typed: navigate it to the site, then ask again.
- **"no extension is connected, so `login` cannot drive the page step by step"** — the dock browser is there
  but the extension is not. Open the sign-in form and use `ask` for that one page, or restore the extension.
- **"no field matching X"** — a browser is connected and its page is the one printed. Re-enter the sign-in
  form (`login` does this), then ask again; the line names the fields the probe saw, so compare them.
- **A card is raised but nothing lands** — the page moved. Check with `probe` (see the `bot-desktop` skill):
  if there is no sign-in form, `login` re-enters it; if the browser is on a search page, the site redirected.
- **The extension is stale after an update** — Chrome binds an unpacked extension to its **path**, so new
  files in an old directory are never loaded. The installer writes each version to its own
  `/opt/hermes-extension/hermey-signin-<version>`; restart the browser, never call `chrome.runtime.reload()`
  (that unloads a command-line-loaded extension for good).
- **A "Save password?" prompt covers the field** — the launcher switches the password manager off in the
  profile before every start; if you see it, the profile was edited while the browser was running.
