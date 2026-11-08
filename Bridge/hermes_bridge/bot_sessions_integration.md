# Shared bot session pointer: integration contract

Mounted by `create_app`. One row per bot profile in the bridge SQLite database
(`bot_sessions`, beside `devices` and `bot_icons`), shared by every paired
device on that bridge. No gateway change is involved; this is only the answer to
"which stored session is this bot".

Authentication is identical to `/v1/bot-icons`: every GET/PUT needs its own
fresh single-use `ws_ticket` from `POST /v1/token`, sent as
`Authorization: Bearer <ticket>`. Never reuse a socket's ticket; the
`access_token` from `/v1/token` is not verifiable and is refused. Missing,
used, expired or revoked ticket → 401.

## Routes

`GET /v1/bots/{profile}/session`

```json
{"profile": "research", "stored_session_id": "20261106_165329_293f4b"}
```

`stored_session_id` is `null` when no device has stored one yet (an unknown
profile is a normal answer, never a 404 or an error). `<profile>` is the bot's
profile id, URL-encoded, 1–64 chars of `A-Z a-z 0-9 _ . -`, starting
alphanumeric; anything else is 422.

`PUT /v1/bots/{profile}/session` with body

```json
{"stored_session_id": "20261106_165329_293f4b"}
```

→ the same object with the stored value. Last write wins (no compare-and-set).
The value must be 1–128 chars of `A-Z a-z 0-9 _ -`, starting alphanumeric:
that is the host's stored session key shape and it can never contain `/`, `\`
or `.`, so it cannot be read as a path. Empty, whitespace-only, null, too long,
path-like values, a missing field, or any extra field → 422 and the existing
row is left untouched. There is no delete route: an empty body can never remove
a bot's conversation.

## App wiring

Read the pointer on bot open; if non-null, `session.resume` that **stored** id
(always pass `profile`). If null (or the resume reports unknown), create with
`idempotency_key = "bot-chat:<profile>"` and PUT the resulting stored id. On a
local reset, PUT the new id (or clear the local pointer, never the shared one
implicitly). Treat the pointer as advisory: another device may overwrite it
between your GET and your write, so re-read after a create race.

The bridge records `session_pointer` audit events (`profile`, method, outcome
`found`/`missing`/`stored`/`rejected`, reason) and never the session id value.
