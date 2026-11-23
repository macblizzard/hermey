# Endless chat + bot-first IA

Decisions that the code must follow. Measured facts, not preferences.

## 1. Main screen is the bot list

After pairing, the app opens on **all bots** (`profiles.list`, 15 on this host) — no drawer, no
hidden switcher. Each row: avatar initial, bot name, last message preview, latency-neutral.

Tapping a bot opens that bot's conversation. Leaving the conversation returns to the list.

## 2. One endless conversation per bot

There is **no session list** in the UI. Per bot there is exactly one session, and it is shared by
every paired device *and by Hermes itself*.

**The host owns the identity.** Hermes keeps exactly one canonical session per profile: the row
titled exactly `Bot Chat`, born hidden, resolved by name on every open, and shared by Desktop, the
TUI, `hermes -p <bot> chat -c "Bot Chat"`, cron `bot-chat` delivery, `message_agent` between bots and
the official mobile app. Hermey opens **that** session, so the conversation here is the same
conversation everywhere — a routine's report or another bot's DM lands in the chat the user reads.

On open (`CanonicalBotChat.plan`, carrying out by `AppModel.endlessSession(for:)`):

- ask the host: `profiles.list` with `include_sessions`, read `canonical_session.resolved_id` — the
  **live compression tip**, because rotation compaction can leave the registry title on a row that
  is no longer the one moving. Resume it (always with `profile`; a multiplexed gateway cannot
  resolve a stored id without it);
- the host has no Bot Chat but this bot already has a conversation (session pointer, else the local
  cache) → resume it and `session.title` it `Bot Chat`: the history the user already has becomes the
  shared chat instead of being stranded behind a fresh empty one;
- neither → `session.create` with `title: "Bot Chat"`, `hidden: true`, `follow_profile_config: true`
  and the deterministic key `bot-chat:<profile>` — the same call Desktop makes.

Two failures are handled without showing the user anything, because both mean "the canonical chat
exists already": a **title conflict** on create re-reads the host and opens the row that holds the
name (never mints a twin next to it — Desktop documents this as "retry, never mint"), and a host too
old to accept `title`/`hidden` falls back to a plain create.

The session pointer (`GET`/`PUT /v1/bots/{profile}/session`, device-authenticated with a freshly
minted single-use ticket, body `{"stored_session_id": …}`) is a **cache** now, not the authority: it
still answers for the bot list's previews and for an older build or an unreadable host, and every
open publishes to it. Local cache: `UserDefaults`, key `hermes.endlessSession.<botID>`, value = stored
session id. Every identity read fails open: a read that cannot be made falls back to the cache
without publishing (a value we could not see must not be clobbered), and a failed publish is logged,
never shown as a conversation error. A bot Chat read that *cannot* be made is `.unavailable`, never
`.absent` — `.absent` licenses minting a new conversation, and minting one beside a real Bot Chat is
how a client creates a second, competing chat.

A stored id that answers `4001`/`4007` is forgotten and replaced by a create, and the replacement is
published. "Reset conversation" (overflow menu, behind a confirmation) clears the local key, publishes
an empty pointer **and retires the Bot Chat on the host**: `session.archive`, which keeps the history
but stops the host treating it as this bot's chat, so the next open mints a successor that can take
the name. This is Desktop's retire semantics, not `/new` — a `/new` inside a Bot Chat is rerouted to
`/compact` there, which is what this app's separate "compact now" affordance already does. Because
the deployed `PUT` refuses a null (`422`, "never a delete"), the reset device also keeps a local
tombstone (`hermes.endlessSessionReset.<botID>`) so the pointer's row cannot pull the forgotten
conversation straight back; the tombstone is retired as soon as a replacement is published, and a
create that finds the tombstoned row holding the name retires it and mints (bounded once, so two
devices resetting at each other cannot ping-pong).

## 3. Compaction

**The host owns it.** Hermes compacts at the *start* of a turn when the context crosses
`compression.threshold` (a fraction of the model's own window), so a conversation arrives here
already summarised. The app does not second-guess that: there is no client-side threshold, no
`hermes.autoCompactTokens` default, and no trigger after a turn. A second threshold was an opinion
nobody asked for, and it could compact a thread the host was about to.

What the app still owns is the manual verb — "Compact now" — because a user who wants the context
summarised *before* the host gets to it should not have to wait for the next turn:

1. call `session.compress` (params `{"session_id": <runtime id>}`),
2. re-`session.resume` to refresh the transcript,
3. surface a one-line notice ("conversation compacted"), never a blocking spinner.

`message.complete` still carries real usage (`usage.context_used`, `usage.context_max`,
`usage.context_percent`), and the conversation header always shows `context_used / context_max` so
the reader can see it approaching the limit.

## 4. Settings holds settings, not a device dump

Sections, in order:

| Section | Contents |
|---|---|
| Connection | host, state (`direct`/`reconnecting`), latency, *Disconnect*, *Re-pair* |
| Chat | show reasoning toggle, expand-reasoning toggle, show tool output toggle |
| Devices | one row per device, `this phone` badge, revoke — its own sub-screen |
| About | app version + build (from `Bundle`), protocol version |

Device management moved off the top level: 20+ rows of device toggles buried the actual settings.

## 5. Bugs this batch must also fix

These are wire-verified; the payload shapes below are from the live gateway.

| Bug | Cause | Correct source |
|---|---|---|
| model chip shows `anthropic/claude-fable…` | reads `providers[0].models[0]` | `model.options` → `model` + `provider` (`deepseek-v4.1-flash` / `opencode-go`) |
| tool rows labelled `tool` | card built from transcript projection | `tool.start` payload `name` |
| tool rows say `No output.` | reads a key that is not sent | `tool.complete`: `result_text` → `result` → `summary` |
| reply never renders until a session switch | deltas applied to a session the view is not watching | attribute to the attached session; `message.complete` must clear streaming |
| stuck on `Thinking…` | streaming flag never cleared when no turn is in flight | clear on complete, and after a resume whose `inflight` is nil/not streaming |
| reasoning invisible | `thinking.delta` dropped | `thinking.delta` payload `{"text"}` → separate reasoning stream |

`message.delta` / `thinking.delta` / `message.complete` carry **no** `session_id`; `tool.start` /
`tool.complete` are `{tool_id, name, args?, result_text?, result?, summary?, duration_s?}`.
