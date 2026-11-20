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

## A whole login in one call

```bash
@@BIN@@/hermey_signin.py login --url https://www.doctolib.de/patient/login --site doctolib.de \
  --note "Booking an appointment"
```

It opens the page, asks the owner **once** for the email and the password, fills each step as the page
presents it, clicks the page's own continue button, and handles a two-step code. Print the link it gives you
and let the owner answer; do not fill anything yourself.

## When the site asks for a code by email

If the owner has connected Gmail, you can fetch the code yourself with your Composio Gmail tools (see the
`integrations` skill) and hand it in, so the owner is asked only for their password:

```bash
@@BIN@@/hermey_signin.py login --url https://… --site doctolib.de --otp 123456
```

Use the newest message only, and only the code from this site. Never read other mail for this.

## What you get back

One line, after the owner answers and the browser has been filled:

```
filled
```
or
```
not filled — the owner cancelled
not filled — no browser could take it
not filled — the owner did not answer in time
```

`filled` means the values reached the page. It does **not** mean the login succeeded — check the page and
carry on. On anything else, stop and tell the owner plainly; never ask them to paste the password
instead.

## Rules

- Never ask for a password, a code or a card number in the conversation. There is no exception.
- One card at a time. Do not fire two asks and hope one lands.
- The `--site` is the origin you are actually on. It is what the owner sees, so make it the real one.
- `--note` is one short line saying what you are doing. It is the only context the owner gets.
- Never fill a login form yourself, by typing into the page or writing to a field. That is what the card
  is for, and it is how a value ends up somewhere you can read.
- The bridge is at @@BRIDGE@@ ; if the script reports it cannot reach it, the bridge is down — say so
  rather than trying another route.
