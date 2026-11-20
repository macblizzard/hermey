---
name: integrations
description: Use the owner's connected Gmail, Calendar and Drive.
managed_by: hermey-bridge
---

# The owner's connected accounts

The owner connects their own Google accounts to this host through Composio. When they are connected you
can read and act in them — mail, calendar, files, documents, sheets, places — on their behalf.

## What is connected

```bash
@@BIN@@/hermey_integrations.py list
```

```
gmail	Gmail
googlecalendar	Google Calendar
```

Nothing listed means nothing is connected: say so and stop. Do not try to work around a missing account,
and never ask for a password or a token.

## The exact tool names

```bash
@@BIN@@/hermey_integrations.py tools gmail
```

```
GMAIL_FETCH_EMAILS	Fetch emails
GMAIL_SEND_EMAIL	Send email
...
```

Use these names exactly. Guessing (`send_email`, `list_messages`) wastes a turn and gets a
tool-not-found back.

## Reading and acting

```bash
@@BIN@@/hermey_integrations.py run --tool GMAIL_FETCH_EMAILS \
  --account <account id from list> --args '{"max_results": 5}'
```

That is the call that actually reads mail or changes a calendar event. It goes through the bridge, which holds
the project key — you never see a token. The result is the tool's own JSON.

The account is required whenever a service has more than one. An unqualified call silently picks one, which
with two Gmails is the wrong mailbox half the time.

## If the service the owner wants is not connected

```bash
@@BIN@@/hermey_integrations.py connect googlecalendar
```

It prints a link for **the owner** to open and approve, then waits until the connection appears. Give them
the link and let them finish; do not try to sign in yourself.

## More than one account

An owner may connect two Gmails ("personal", "work"). `list` shows every account, and when a service has
more than one, **every tool call must say which** — with two accounts an unqualified call silently uses
whichever the session picks, which is how the wrong mailbox gets read or the wrong one sends.

```bash
@@BIN@@/hermey_integrations.py list
```

```
gmail	personal
gmail	work
```

Say the account out loud in your reply ("using *work*"), and pass that account when you call the tool. If the
owner says "my mail" and there are two, ask which — do not choose for them.

## Rules

- Reading is fine; **writing needs care**. Sending mail, deleting, moving, or creating events on the
  owner's behalf: say what you are about to do first, and do it only for what they asked.
- One action at a time. Do not batch "tidy the inbox" into deletions.
- Never put a token, a password or a connection link in a file, a commit, or a message to anyone else.
- The connection belongs to the owner, not to you. If a tool reports the account is not connected, that is
  theirs to fix — point them at Settings → Integrations rather than retrying.
- The bridge is at @@BRIDGE@@. If it is unreachable, say so; do not attempt another route to the data.
