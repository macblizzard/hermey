# Endless chat + bot-first IA

Decisions that the code must follow. Measured facts, not preferences.

## 1. Main screen is the bot list

After pairing, the app opens on **all bots** (`profiles.list`, 15 on this host) — no drawer, no
hidden switcher. Each row: avatar initial, bot name, last message preview, latency-neutral.

Tapping a bot opens that bot's conversation. Leaving the conversation returns to the list.

## 2. One endless conversation per bot

There is **no session list** in the UI. Per bot there is exactly one session id, and it is
**shared by every paired device** — the phone and the Mac open the same stored id instead of each
minting its own.

The authority is the bridge (`GET`/`PUT /v1/bots/{profile}/session`, device-authenticated with a
freshly minted single-use ticket, body `{"stored_session_id": …}`). On open:

- ask the bridge for `stored_session_id`; if present → resume **that** id (always with `profile`;
  a multiplexed gateway cannot resolve a stored id without it);
- if the bridge has none → resume the locally cached id and **publish** it;
- if neither → `session.create` (deterministic key `bot-chat:<profile>`), store the **stored** id
  (`stored_session_id`), then publish it so the other device adopts it.

Local cache: `UserDefaults`, key `hermes.endlessSession.<botID>`, value = stored session id. It is
only a cache/fallback — a device that boots offline still opens its last conversation, and an older
bridge (no such route) behaves exactly as before. Every pointer call fails open: a read that cannot
be made falls back to the cache without publishing (a value we could not see must not be
clobbered), and a failed publish is logged, never shown as a conversation error.

A stored id that answers `4001`/`4007` is forgotten and replaced by a create, and the replacement is
published. "Reset conversation" (overflow menu, behind a confirmation) clears the local key **and**
publishes an empty pointer; the old session is left on the host — reset means "stop reopening this",
not "delete history". Because the deployed `PUT` refuses a null (`422`, "never a delete"), the reset
device also keeps a local tombstone (`hermes.endlessSessionReset.<botID>`) so the bridge's row cannot
pull the forgotten conversation straight back; the tombstone is retired as soon as a replacement is
published.

## 3. Auto-compaction

`message.complete` carries real usage:
`usage.context_used`, `usage.context_max`, `usage.context_percent`.

After every completed turn, if `context_used >= threshold` and no compression is in flight:

1. call `session.compress` (params `{"session_id": <runtime id>}`),
2. re-`session.resume` to refresh the transcript,
3. surface a one-line notice ("conversation compacted"), never a blocking spinner.

Threshold: `UserDefaults` key `hermes.autoCompactTokens`, **default 200_000**. `0` disables
compaction. The conversation header always shows `context_used / context_max` so the user can see
it approaching the limit.

## 4. Settings holds settings, not a device dump

Sections, in order:

| Section | Contents |
|---|---|
| Connection | host, state (`direct`/`reconnecting`), latency, *Disconnect*, *Re-pair* |
| Chat | auto-compact threshold (numeric field + "off"), show reasoning toggle, show tool output toggle |
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
