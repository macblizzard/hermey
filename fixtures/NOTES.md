# Recorded gateway fixtures (M0)

Captured on 5 Nov 2026 from a real `tui_gateway` process
(`python -m tui_gateway.entry`, Hermes Agent **v0.22.6**, `/usr/local/lib/hermes-agent`) over stdio,
in a throwaway `HERMES_HOME`. These are observed bytes, not documentation — where they disagree with
the docs, **the fixtures win**, and this file records the disagreement.

Recorder: `Tools/record_fixtures.py` (same script shape; drives the gateway and appends every frame).

## 1. The event envelope (important)

The docs describe events as `message.delta`, `tool.start`, … — but on the wire every event arrives
as a notification whose **method is `event`**, with the real name inside `params.type`:

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{…}}}
```

Consequences for `HermesKit`:

- `JSONRPCCodec` must keep decoding the notification method (`event`) — it does.
- The event model must unwrap **two** levels: `params.type` (name) and `params.payload` (body).
- A client that switches on `method == "message.delta"` will never fire. This is exactly the bug
  fixtures exist to prevent.

## 2. `client.capabilities` is mandatory, and its answer is a contract

Request:

```json
{"jsonrpc":"2.0","id":2,"method":"client.capabilities","params":{"server_requests":true}}
```

Response (observed, full list):

```json
{"result":{"server_requests":["approval","clarify","display.install.sudo","preview.act",
"preview.read","secret","setup_beat","sudo","terminal.read","theme.apply","theme.pick","tour",
"vault.code","vault.save_login","vault.unlock_prompt","window.read"],
"declines_not_shown":true,"canonical_clarify_batch":true}}
```

So the six methods we must implement in v1 are a subset: `approval`, `clarify`, `sudo`, `secret`,
`vault.code`, `terminal.read`. The rest can be answered `-32601` and the agent fails fast.

## 3. The unknown-method answer

```json
{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"unknown method: no.such.method — not available on this Hermes backend"}}
```

Codes confirmed: **-32601** unknown method, **-32700** parse error (from `entry.py`),
**-32000** handler crash, and Hermes' own **4009 session busy / 4004 / 4018 / 4029 / 4033** family for
rewind safety.

## 4. `session.list` can be slow or silent — timeouts are mandatory

`session.list {limit:5}` produced **no response frame at all** within the 60 s probe window on a cold,
unconfigured profile, while `ping`, `client.capabilities`, `gateway.capabilities` and the error case
all answered immediately. Two lessons:

1. Every call needs a **timeout** (recommend 30 s default, 120 s for `session.list` on first attach),
   surfacing a retry affordance instead of a spinner forever.
2. Never treat "no reply" as "empty list" — an empty list is an explicit `result`, absence is not.

## 5. Startup ordering

`gateway.ready` is written **before** any request is read. A client that sends frames before receiving
`gateway.ready` is fine (the loop is already reading), but `client.capabilities` must be sent once
per connection *after* ready, before any prompt that could raise an approval.

---

## 6. The approval contract (from Hermes source, not from a recording)

Source of truth: `tui_gateway/server.py::_approval_request_payload` and `_emit_approval_request`
(Hermes v0.22.6). See `fixtures/approval.ndjson`. This closes QA finding #5 ("approval payload
shapes unverified") — the shapes are now read from the code that builds them.

**The frame** (`srq-<12 hex>` is the real id format, not `srq-7`):

```json
{"jsonrpc":"2.0","id":"srq-9f2c1a4b77e0","method":"approval","params":{
  "request_id":"apr-73","command":"rsync -a --delete ...","description":"--delete removes 1 file",
  "choices":["once","session","always","deny"],"allow_session":true,"allow_permanent":true}}
```

**`choices` is server-computed, ordered, and authoritative.** The builder starts at `["once"]`, appends
`"session"` unless `smart_denied` or `allow_session is False`, appends `"always"` unless
`allow_permanent is False`, then always appends `"deny"`. Therefore:

- the client must render one button per entry in `params.choices` — **never a hardcoded
  Allow once / Always / Deny triple**. A smart-denied command legitimately offers only two choices.
- the client must not invent labels for choices it does not know; show the raw token.

**The answer** is `{"choice": <one of params.choices>, "all": <bool>}`; `all: true` resolves every
queued approval of the same shape at once.

**Not answering is not denying.** If the client replies `-32601` (or never replies), Hermes
*withdraws* the queue entry and tells the agent "the attached client cannot answer approval requests
(update the Hermes app)". A withdrawal is not consent and not refusal. The UI must therefore keep
three visually distinct outcomes: **allowed**, **denied**, **withdrawn/expired** — never render a
withdrawal as a deny.

**`command` and `description` arrive redacted** (`_redact_approval_command`), because a credential-shaped
value must not echo to a client. Render exactly what you receive; never reconstruct the command from
the tool call.

**Withdrawal event**: `request.cancel` with `{"id","method","reason"}`.

---

## 7. Every profile-scoped method takes `profile`, not just `session.list`

Measured on a live multiplexed gateway (15 bots), and the cause of a real mis-delete during this
deployment: `session.delete` resolves its database from `params["profile"]`
(`_profile_db(params, writer=True)`). Called without it, it searches the gateway's *default*
profile and answers `4007 session not found` — which looks like a missing row, not a wrong scope.

So any session-level method that touches storage must carry the bot's id:

```
session.list   {limit, include_hidden: true, profile}
session.create {profile}            # binds the session's profile_home for its whole life
session.delete {session_id, profile}
session.title / session.archive / session.close …
```

Calls that act on an already-attached session (`prompt.submit`, `session.resume`,
`session.interrupt`) do not need it: the session carries its own `profile_home`.

Two related facts from the same session:

- `session.create` returns a **runtime** id immediately, and a `stored_session_id` once the session
  is persisted. No row exists until a turn writes one, so a create followed by `session.list` shows
  no change — that is correct, not a failure.
- `session.delete` refuses a session the gateway still holds live (`4023 cannot delete an active
  session`), even after `session.close`, until the owning process drops it. Restart the gateway (or
  let the turn fully settle) before deleting.
