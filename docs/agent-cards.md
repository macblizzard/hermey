# Native agent cards in Hermey

Status: draft spec · owner: Aria · target: Hermey 0.1.616+

## Why

The `agent-cards` skill gives a bot three things it currently cannot ask for properly:
an **approval** before anything outward or irreversible, a **task** card for a job that
runs for minutes, and a **draft email** the owner edits and sends. It emits a small JSON
file plus one marker line in the reply.

Today only *Grokbot Override* draws those cards, and that is a Hermes Desktop plugin: a JS
bundle the Electron (or browser-hosted) client loads. Hermey has no plugin host — 126 Swift
files, no `desktop-plugins` reference — so for us the marker degrades to plain text.

Cards are the right shape for the one thing Hermey is still weak at: **letting the owner
approve an action with the payload in front of them**. This spec renders `card.v1` natively,
so any bot that uses the skill works on iPhone and Mac without Electron.

## The contract we must honour

The skill's wire form is one line, on its own, outside code fences:

```
::card{id="c-9b" kind="approval" file="cards/c-9b.json"}
```

`file` is relative to the **session's working directory**; `id` and `kind` must match the
file. One line per card, never two for the same card.

The file (`cards/<id>.json`, ≤ 32 KB):

| Field | Rule |
|---|---|
| `schema` | required, exactly `"card.v1"` |
| `kind` | required: `approval` \| `task` \| `draft-email` |
| `title` | required, non-empty |
| `status.state` | required: `pending` \| `running` \| `done` \| `error` \| `awaiting-approval` |
| `status.label` | optional chip text override |
| `body[]` | optional: `{type:"text", text}` \| `{type:"kv", rows:[[label,value]]}` \| `{type:"fields", items:[{label,value}]}` |
| `email` | for `draft-email`: `{to, cc, subject, bodyText}` |
| `actions[]` | ≤ 3: `{label, send, style?: "primary"\|"danger"}` |
| `resolved` | `null`, or `{action, at}` once the owner chose |

Live behaviour the skill promises: while the chat is open, a card in one of the last eight
messages re-reads its file every **3 s for up to 30 min**, and stops when the file is final
(`resolved` set, or `status.state` is `done`/`error`). To update a card, the bot rewrites the
same file.

## Transport: how Hermey gets the JSON

The file lives on the host in the bot's working directory; the client only has the
transcript. So the engine resolves it, not the client:

```
GET /v1/cards/{id}?session=<session id>      (hermeyd proxies to the engine)
→ 200 {"card": {...}, "mtime": "...", "final": false}
→ 404 {"error": "no_such_card"}              → the client draws "Card not available"
```

Why server-side resolution:

- **Path safety** — the client never sends a path, only an id. The engine resolves
  `<session.cwd>/cards/<id>.json` and refuses anything outside that directory (no `..`,
  no absolute paths, no symlink escape; `id` must match `^[A-Za-z0-9_-]{1,40}$`).
- **Remote engines** — Hermey talks to `hermeyd` over the tailnet; reading host files
  directly was never an option.
- **Live updates** — a re-read is a re-fetch; nothing has to be pushed over the socket.

Rejected alternative: inlining the card JSON in the marker (as A2UI surfaces do). Simpler,
but it cannot honour the 3-second task updates — those need re-reads.

## Client design

New target **`HermesCards`** (Foundation + SwiftUI, depends on `HermesKit` only):

| Piece | Responsibility |
|---|---|
| `CardMarker` | finds `::card{…}` lines, returns refs `(id, kind, file)`; strips the line from prose |
| `CardModel` | lenient `Decodable` for `card.v1`; unknown fields ignored, a broken file yields `.unavailable` |
| `CardStore` | fetch + poll per card: every 3 s while pending/running/awaiting-approval and `resolved == nil`, stop at 30 min or when final; cache by `id` |
| `CardView` | the three layouts, status chip, body blocks, ≤ 3 buttons |
| Transcript hook | same shape as the A2UI branch: if a card marker is present, draw prose then the card |

Polling stops when the row scrolls out of the last eight messages, when the app backgrounds,
and when the file is final. On foreground, one refetch.

### Actions

Tapping a button sends `action.send` as a user turn (that is the value the skill designs for:
`APPROVE c-9b book the cabin`). The card ticks the chosen label optimistically and settles on
the next poll — the bot is expected to rewrite the file with `resolved`.

v1 shows that turn in the transcript. Hiding it (what Grokbot does) needs a per-message
hidden flag; the engine currently exposes only session-level `hidden` (`session.set_hidden`).
Tracked as an enhancement, not a blocker: the send strings are short by design.

## Rendering

- **approval** — title, body, buttons. No status chip.
- **task** — status chip (`running` with spinner, `done`, `error`), body, optional `Stop`
  button in `danger` style.
- **draft-email** — subject as the heading (title when there is no subject), `To`/`Cc` rows,
  `bodyText` as paragraphs, then the buttons.
- A body that is one line under 200 characters and has no line breaks reads as the question
  under the title.
- Styling comes from `HermeyUI` tokens, never from the card: `primary` maps to the accent
  fill, `danger` to the destructive tint. No model-chosen colours.
- Text only. No HTML, no markdown injection, no remote images: a card is data.

Accessibility: the card is one element with `children: .contain`; each button is labelled by
its `label`, not by `send`; the status chip reads its state in words.

## Rollout and rollback

- Flag `cards.enabled` in Hermey, default **on** once P1 lands. Off → `::card` lines render
  as text, which is exactly today's behaviour.
- No change to genui (`::blocks`) or A2UI (`::a2ui`): three independent renderers, each
  preferred only when its own marker is present.
- Server side is read-only: one new GET route. Nothing about the skill changes.

## Phases

| Phase | Scope | Est. |
|---|---|---|
| P1 | `CardMarker` + `CardModel` + approval layout + fetch route + flag | 1 d |
| P2 | actions round-trip (send, optimistic tick, settle on poll) | 0.5 d |
| P3 | task live updates (polling discipline), draft-email layout | 1 d |
| P4 | a11y pass, fixtures/snapshots, e2e with a live bot | 0.5 d |

Roughly three days, verifiable incrementally: P1 alone gives approvals, which is the part
that matters most.

## Test plan

- **Fixtures**: one valid file per kind, plus broken shapes (bad schema, missing title,
  4 actions, 40 KB body, `..` id) that must all degrade rather than throw.
- **Parser tests**: marker found outside code fences, two markers in one reply, marker with
  an unknown kind.
- **Poll logic**: fake clock — stops at final, stops at 30 min, refetches on foreground.
- **View snapshots**: three kinds, light/dark, long title, empty body.
- **E2E**: a bot writes `cards/c-…json` + the marker; the card appears, a tap sends the
  `send` text, the bot rewrites with `resolved`, the buttons lock.

## Open questions

1. Hidden action sends — worth an engine flag? (Nice-to-have; v1 shows the terse turn.)
2. `session.cwd` for sessions opened from iOS: does the host always have one? If not, the
   route needs a per-profile fallback.
3. Do we want the card to survive a transcript reload — i.e. is the file still there when the
   thread is reopened a week later? The skill keeps files in the chat's working directory.
