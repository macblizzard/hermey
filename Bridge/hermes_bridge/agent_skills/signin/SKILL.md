---
name: signin
description: Ask the owner to sign in without handling the password.
managed_by: hermey-bridge
---

# Signing the owner in

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
not filled — the browser did not take it: either it is not connected, or the page in front of it has no
              field matching what was asked for
not filled — the owner did not answer in time
not filled — no sign-in page at <url> (0 text field(s), no password field); nothing was asked of you
```

`filled` means the values reached the page. `signed in` means the final page no longer shows a sign-in form —
confirm before promising it. On anything else, stop and tell the owner plainly; never ask them to paste the
password instead.

## Rules

- Never ask for a password, a code or a card number in the conversation. There is no exception.
- One card at a time. Do not fire two asks and hope one lands. Cards last 10 minutes for a login, 2 otherwise.
- The `--site` is the origin you are actually on. It is what the owner sees, so make it the real one.
- `--note` is one short line saying what you are doing. It is the only context the owner gets.
- Never fill a login form yourself, by typing into the page or writing to a field. That is what the card
  is for, and it is how a value ends up somewhere you can read.
- The bridge is at @@BRIDGE@@ ; if the script reports it cannot reach it, the bridge is down — say so
  rather than trying another route.

## When it does not work

- **"no browser connected"** — the desktop slept or the worker was suspended. Run `hermey_browser.py open`
  again; it wakes the desktop and waits for the extension.
- **A card is raised but nothing lands** — the page moved. Check with `probe` (see the `bot-desktop` skill):
  if there is no sign-in form, `login` re-enters it; if the browser is on a search page, the site redirected.
- **The extension is stale after an update** — Chrome binds an unpacked extension to its **path**, so new
  files in an old directory are never loaded. The installer writes each version to its own
  `/opt/hermes-extension/hermey-signin-<version>`; restart the browser, never call `chrome.runtime.reload()`
  (that unloads a command-line-loaded extension for good).
- **A "Save password?" prompt covers the field** — the launcher switches the password manager off in the
  profile before every start; if you see it, the profile was edited while the browser was running.
