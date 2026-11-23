# hermeyd — the host service (Rust)

The layer between the apps and the engine: **pairing, devices, credentials and the WS relay**.
It holds no agent logic — bots, sessions and transcripts belong to the engine, so an engine swap
cannot touch pairing.

## Why Rust, and why this layer

| | Python bridge (retired, for comparison) | hermeyd (Rust) |
|---|---|---|
| Artifact | venv + 117 packages | **one 4.3 MB binary** |
| Runtime needed on host | Python 3.11–3.14 | none |
| Install on Linux/macOS | venv per host | copy one file |
| Build | — | 2m20s cold, ~12s incremental |

The engine stays Python on purpose (it is 47 tools and a working agent loop). The host service is
small, security-critical and distribution-facing — exactly the shape a single static binary wins.

## The core routes

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/v1/health` | none | `{status, protocol_version, ws}` — no device count, no fingerprints |
| POST | `/v1/pair/start` | **loopback only** | mints a 6-digit, 10-minute, single-use code |
| POST | `/v1/pair/claim` | code | `{code, public_key, device_name, platform}` → `{device_id, refresh_token}` |
| POST | `/v1/token` | refresh | → `{access_token, ws_ticket, expires_in}` |
| GET | `/v1/devices` | bearer | device list (no secrets) |
| DELETE | `/v1/devices/{id}` | bearer | revoke; nulls the refresh hash in the same statement |
| GET | `/v1/ws` | **ticket** | single-use 30s ticket (query `?ws_ticket=` or bearer) → spliced onto the engine's `/api/ws` |

## Security properties, each one tested

`scripts/smoke-hermeyd.sh` proves all 11 lines below on every run (real HTTP, real state):

```
PASS  health 200 · health status=ok
PASS  pair/start minted 6-digit code
PASS  pair/claim registered device
PASS  pairing code is single-use (replay 401)
PASS  token minted access + ws_ticket, expires_in=300s
PASS  bad refresh rejected (401)
PASS  devices without bearer (401)
PASS  devices with bearer → 1 device(s)
PASS  revoke 200
PASS  revoked device cannot mint (401)
PASS  hermeyd refuses to bind 0.0.0.0 (exit 1)
```

- **Loopback only.** A non-loopback bind is refused at startup with a message naming the fix
  (`tailscale serve`). Exposure is never this process's job.
- **Codes are single-use and expiring.** Redeeming a used or expired code is indistinguishable from
  a wrong one (401, no detail).
- **Refresh tokens are stored hashed** (salted SHA-256 via the `sha2` crate — deliberately not
  hand-rolled) and compared in constant time.
- **Tickets are 30 seconds and single-use** (`consume_ticket` removes on first redemption).
- **Revoke is atomic with the credential.** The refresh hash is nulled in the same UPDATE, so a
  revoke lands even if a request was already in flight.
- **Claims are rate-limited** per client address (10/minute), so pairing codes cannot be enumerated.

## Port 8788, not 8787

hermeyd listens on **8788**, and it is the only port involved now. It was picked to sit beside the
retired Python bridge's 8787 so both could run on one machine during the swap; the bridge is gone, and
a host that still answers on 8787 is a leftover mount, not a service (see TROUBLESHOOTING).

## State

```
$HERMEY_HOME/bridge.db      devices (device_id, name, platform, public_key, refresh_hash, …)
$HERMEY_HOME/bridge.salt    per-host salt for refresh hashing (0600)
```

`$HERMEY_HOME` defaults to `$HOME/.hermey`. Device records only — never sessions, never transcripts.

## Build & run

```sh
cd hermeyd && cargo build --release        # 4.3 MB binary at target/release/hermeyd
HERMEY_HOME=../var/hermeyd ./target/release/hermeyd
../scripts/smoke-hermeyd.sh
```

## Version

`hermeyd --version` is how a host answers "is the deployed binary the build I just made?", so the
`version` in `Cargo.toml` moves whenever `hermeyd/src/` or its bundled skills change — and **only**
then. A client release does not bump it; a service number dragged along by app builds would say
nothing about the service. `Tools/check_hermeyd_version_bump.py` runs in CI and refuses a source
change that leaves the version alone. The service is released separately, as tag `hermeyd-vX.Y.Z`
(`hermeyd-release.yml`), while the apps keep `v0.1.N`.

## WS relay (built)

```
GET /v1/ws?ws_ticket=<ticket>
  → consume ticket (single use) → dial ws://127.0.0.1:9121/api/ws?token=<engine per-boot token>
  → splice frames both ways; whichever side closes tears down the other
```

The engine's token never reaches a client, and the engine never listens on anything but loopback.
Close codes a client must model: **4401** ticket missing/unknown/expired/spent, **1011** engine
unreachable. Config: `HERMEYD_ENGINE_WS` (default `ws://127.0.0.1:9121/api/ws`) and
`HERMEYD_ENGINE_TOKEN_FILE` (default: beside this service's state, else the sibling engine home).

Proven end to end (`scripts/smoke-relay.py`, real HTTP + real sockets + a real model turn):

```
PASS  pair/start — code 395330
PASS  pair/claim — device M2C8K3ZA…
PASS  token — ws_ticket 43 chars, expires_in=300s
PASS  ws upgrade through relay
PASS  profiles.list via relay — 2 bot(s)
PASS  session.create via relay — runtime 719922e3
PASS  real turn through relay — RELAY-OK
PASS  ticket is single-use — InvalidStatus
PASS  bogus ticket refused — InvalidStatus
RELAY SMOKE OK — pair → ticket → socket → turn
```

## Collections hermeyd owns (built)

These are UI state, not agent state: they live in our SQLite `documents` table and survive an engine
swap. Shapes were taken from the Swift decoders, not invented.

| Route | Returns / accepts |
|---|---|
| `GET /v1/bot-categories` | `{categories:[{id,name}], assignments:{bot:id}, order:[id]}` |
| `POST /v1/bot-categories` | create by `{name}` or replace the document |
| `PATCH/DELETE /v1/bot-categories/{id}` | rename / reassign / delete |
| `PUT /v1/bot-categories/order` | `{order:[…]}` |
| `GET /v1/bot-defaults` · `PUT /v1/bot-defaults/soul` | `{soul:{text,chars,present,updated_at}, built_in}` |
| `GET /v1/bot-icons` · `PUT /v1/bot-icons/{bot}` | `{faces:{bot:{avatar}}, icons:{}}` |
| `GET /v1/bots/disabled` · `POST /v1/bots/{bot}/state` | `{disabled:[…]}` / `{enabled:bool}` |
| `GET/PUT /v1/bots/approvals` | `{mode, profiles, unset, updated, failed}` |
| `GET/POST /v1/rooms` | the engine's rooms (`groups.list`, limit 50); create names one and picks 2–6 members |
| `GET /v1/rooms/{id}/log` · `POST …/send` · `POST …/rename` · `POST …/disband` | room log (`?since_seq=`), a message, a rename, a disband — each an engine `groups.*` call |
| `POST /v1/push/{presence,register,test}` | `{ok:true}` — no relay, says so plainly |
| `GET /v1/bots/previews` · `POST /v1/bots/previews` | each bot's newest line, read from its own `state.db` against the conversation the app opens; POST adds `{unread:{profile:n}}`. Best-effort: a locked or missing database yields no row for that bot, never an error for the list |

`scripts/smoke-app-routes.sh` replays the app's connect sequence (a fresh single-use ticket per call,
like the client) and asserts every shape plus persistence across calls.

## Pitfall that cost the first real device: frames must be NDJSON

The iOS/macOS client decodes WebSocket frames with `NDJSONBuffer`, which **only yields a frame when it
sees `0x0A`**. The engine does *not* newline-terminate its frames (measured by raw bytes), so a relay
that forwards them verbatim leaves the app buffering forever: no `gateway.ready`, no
`client.capabilities`, and the handshake timer closes the socket at ~20 s in a retry loop — the app
shows **"connecting" forever** while both server logs look healthy (`ws accepted`, `messages=0`).
The relay now terminates every engine→client text frame with `\n`.

Diagnosis path that found it: engine log `messages=0` + our frame log showing `gateway.ready`
forwarded → suspicion of framing → read `JSONRPC.swift::NDJSONBuffer` → confirm by printing the last
bytes of the first frame (`ends_with_newline: False`).

## Attachments (built)

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/v1/attachments` | bearer | raw bytes + `x-hermey-filename`; 25 MiB ceiling |
| GET | `/v1/attachments/{id}` | bearer | owner-scoped; `x-hermey-sha256` on the response |
| DELETE | `/v1/attachments/{id}` | bearer | removes the row **and** the bytes |

Metadata in SQLite, bytes on disk under `$HERMEY_HOME/attachments/`. Proven 10/10
(`scripts/smoke-attachments.sh`) on Linux and macOS:

```
PASS  upload 200 · server sha256 matches local · download bytes identical (sha256)
PASS  upload without bearer → 401
PASS  other device's attachment → 404 (existence not leaked)
PASS  filename traversal sanitised → 'passwd'      ('../../etc/passwd')
PASS  26 MiB upload → 413
PASS  delete 200 · deleted attachment → 404
```

Design notes: raw body rather than multipart (one code path, nothing to mis-parse); the size ceiling
is enforced by the framework so an oversized upload is refused before it is buffered; a cross-device
read answers 404 rather than 403 so ids are not an existence oracle.

## Platforms (measured)

| Target | Binary | Contract | Attachments |
|---|---|---|---|
| Linux x86_64 | 4.9 MB | 11/11 | 10/10 |
| macOS arm64 (M1, 27.2.1) | 4.3 MB | 11/11 | 10/10 |

Cross-build note: the Mac already had `cargo` via Homebrew (1.100.0); a cold build took 37s there.

## Rooms (built)

The engine hosts rooms (`groups.*` owns the log and routes to members); hermeyd is the translator,
which is all the retired bridge ever was here. A small server-side JSON-RPC client (`engine_client.rs`) dials
the engine per call — low-frequency, idempotent, and no cached socket that a restart invalidates.

| Route | Engine call |
|---|---|
| `GET /v1/rooms` | `groups.list {limit:50}` + `groups.log` per room for who spoke last |
| `POST /v1/rooms` | `groups.create {room_id, name, members[{member_id,profile,handle}]}` |
| `GET /v1/rooms/{id}/log` | `groups.log {room_id, limit:200, since_seq?}` |
| `POST /v1/rooms/{id}/send` | `groups.send {room_id, event_id, payload{thread_id,text}}` |
| `POST /v1/rooms/{id}/rename` | `groups.rename {room_id, name, event_id}` |
| `POST /v1/rooms/{id}/disband` | `groups.disband` |

Proven live: create → list → send → log returned the owner's line **and a bot's reply**:

```
CREATE -> 200 room_id: morning-sync-tar2rtkk
SEND   -> 200
LOG    -> 200 events: 2
   message.user   | None    | 'Team, say hi in one short line.'
   message.member | default | "Morning! 👋 Hi from @default — @scratch, you're up…"
```

Two engine requirements that are easy to miss: every member needs **`member_id`** (the engine answers
`5111 member 0 is missing fields: member_id` otherwise), and the log must be **flattened** to
`{seq, kind, actor{…}, text}` with `turn.*`/`room.*` bookkeeping rows dropped.

## Skills, MCP and Library — where each actually comes from

Correction worth recording: only **Library** is REST. Skills and MCP are WebSocket JSON-RPC and need
no route in hermeyd at all — the relay already carries them to the engine.

| Page | Transport | Call |
|---|---|---|
| Skills / MCP | **WS JSON-RPC** | `profiles.describe {name}` → `skills[]`, `mcp_servers[]`; `skills.manage {action:"list", profile\|session_id}` → host index; `profiles.configure` to toggle |
| Library | **REST** | `GET /v1/workspace/{profile}` (+ `/file?source=&path=`) |

What actually populates them (measured, after being wrong about it once):

- `skills.manage {action:"list"}` enumerates **the profile's own** `<profile>/skills/` directory —
  not the shared library and not `optional-skills/`. Copying skills in is what makes the page show rows.
- `profiles.describe` reports those skills plus the profile's `mcp_servers:` config block.
- `optional-skills/` is therefore **kept** in the strip (it is the library you install *from*): dropping
  it costs 11 MB of source and leaves the Skills page permanently empty.

Populated on the dev host: 5 skills installed into `profiles/scratch/skills/`, and the reddit MCP
server (`http://127.0.0.1:8765/mcp`) added to that profile's config. Verified through the tailnet
relay exactly as the app sees it::

```
SKILLS (via relay) -> categories: 1 | names: ['canvas','decision-questionnaire','gif-search','polymarket','songsee']
MCP    (via relay) -> servers: [{'name': 'reddit', 'enabled': True, 'transport': 'http'}]
```

Library is implemented (listing + bytes, traversal and symlink refusal):

```
LIST   -> 200 | files: 1 | ('report.md','md',61,True)
BYTES  -> 200 | text/plain; charset=utf-8 | '# Library test'
TRAVERSAL -> 422 invalid path
```

## Bot computer (display)

`GET/POST /v1/display/{status,thumbnail,start,stop,lease,observe}` translate to the engine's `display.*`
RPC; `GET /v1/display/ws?display_ticket=…` splices the app's viewer to the engine's `/api/display/ws`
(RFB inside the WebSocket).

Three things that are traps, each measured:

1. **`viewer_id` is minted per engine connection.** `display.lease.acquire` refuses an id another
   connection minted, and the app's flow is observe → lease with the id observe returned. Display calls
   therefore ride ONE long-lived socket (`DisplayHub`); per-call connections mint on socket A and get
   refused on socket B, so takeover could never work.
2. **The viewer socket takes the ticket as its only credential.** Appending `?token=` made the engine
   refuse the upgrade. And `engine_ws` already ends in `/api/ws`, so the display URL must be built from
   the origin — appending produced `…/api/ws/api/display/ws` and an instant close.
3. **The hub must retry once on a fresh socket.** After an engine restart the first display call lands
   on a dead connection; without the retry the user's first action fails while the next one works.

Engine dependencies the display page needs: `pillow` (thumbnails fail with `No module named 'PIL'`)
and, on Python 3.14, `truststore`, `watchfiles`, `tenacity`, `tomli-w`, `pyjwt`, `cryptography`,
`httptools<0.9`, `Markdown==3.11.2`, `pathspec`, `ruamel.yaml.clib`.

Verified end to end on 2026-11-20 (15/15): previews, routines, model-settings, library, memory, notes,
display status/thumbnail/observe/lease/stop-guard/RFB, rooms, skills, mcp.

## Search, backup, credential cards, transfers

Four families added after the bot-menu pages, all device-authenticated with a **fresh single-use
ticket per call** (a second use of the same ticket answers 401 — worth remembering when writing tests):

| Route | Behaviour |
|---|---|
| `GET /v1/search?q=&limit=&offset=` | per-bot newest matches (cap 20/bot) read from read-only `state.db`, assembled and paged newest-first; `<2` chars answers empty because the app searches per keystroke; snippets are char-boundary safe |
| `GET /v1/bot-transfers?between=a,b&limit=` | JSONL hand-offs between two bots, either direction, oldest-first. Written by `POST /v1/bots/{profile}/message` — a bot speaking into another bot's chat — in the retired bridge's line format; `session_id` is `null` when the message reached no session |
| `GET /v1/backup`, `POST /v1/backup/restore` | the bridge's document shape (kind/version/bots with soul, memory, notes, routines). Restore is additive and idempotent: identical content is not a write, memory only fills when empty, nothing is deleted, `routines_added` drives `restart_required` |
| `/v1/credentials/cards` (+ `/answer`, `/cancel`, `/consume`) | login cards: the bot asks, the owner answers. Values are never returned while pending or answered, `consume` yields them once then drops them, cards expire (default 15 min), pending count bounded |

## Agent cards — `GET /v1/cards/{card_id}` (in progress, in no release)

A reply may carry one directive line, `::card{id="c-9b" kind="approval" file="cards/c-9b.json"}`,
naming a `card.v1` JSON file the bot wrote under its session's working directory. The host resolves
the id and returns the file; the client sends only an id, never a path.

- `hermeyd/src/cards.rs` validates the id before it builds a path, canonicalises the result, refuses
  a symlink that leaves `<base>/cards/`, and snapshots the last good read per `(session, message)` so
  a card file rewritten or removed after the turn still serves the message that referenced it.
- `final` and `mtime` are in the response for a polling phase that is not built.
- The native renderer is `Sources/HermesCards`, behind `cards.enabled`
  (`defaults write dev.hermey.app cards.enabled -bool NO` puts the marker line back to plain text).

No release carries it; both apps check `::card` after `::a2ui` and before `::blocks`, so a host
without the route simply shows the prose. See [`a2ui-migration.md`](a2ui-migration.md).

## genui and integrations

Both are now served, so all **21** client REST families exist (`genui` and `integrations` were the last
two).

**genui** — `POST /session` trades one device ticket for a 120 s card session (a webview cannot mint a
single-use ticket per subresource), `GET /host` + `/assets/*` serve the React shell **embedded in the
binary**, `GET /blocks/{id}` and `/blocks/{id}/state` read the plugin's boards, `GET /plugin.js` stays
live from the engine home so a plugin update reaches the apps without a rebuild. The plugin bundle is
shipped in this repo (`setup/plugins/hermes-genui/`) and installed into `<engine>/plugins/hermes-genui`
by `setup/install.sh` (and by the release's `hermes-genui-plugin.tar.gz` asset) — without it every
card answers 503.

**integrations** — a Composio proxy (`/v1/integrations`, `/{slug}/connect|tools|alias|disconnect`,
`/run`) with the project key in `$HERMEY_HOME/.env` (`HERMEY_COMPOSIO_API_KEY`). `connected` is derived
from the account list, and every active account is returned — showing only the first hid a second Gmail
and made Disconnect revoke whichever it found.

**The key that works is not the one in `/etc/hermes/.env`.** Measured 2026-11-20:

| Source | Prefix | Result |
|---|---|---|
| `/etc/hermes/.env` `COMPOSIO_API_KEY` | `ck_` (23 ch) | `401` on v3.1 and v3, `410` on v2 |
| `/etc/hermey/composio.key` | `ak_` (23 ch) | **`200`** |

A host with a stale consumer key in the environment looks broken even though a working project key is
right beside it. hermeyd reads only `$HERMEY_HOME/.env`; copying the `ak_` key in (0600) made everything work with **no code change**:

```
LIST    -> 200 | configured=True | gmail connected=True accounts=2
CONNECT -> 200 | url host: connect.composio.dev
TOOLS   -> 200 | 50 tools | GMAIL_CREATE_EMAIL_DRAFT, GMAIL_ADD_LABEL_TO_EMAIL, …
```

`connected` is derived from that list, and both of the owner's Gmail accounts appear — which is the bug
the "show every active account" rule exists to prevent.

## Browser channel: a second listener on 8790, never published

`/v1/browser/{act,targets,ws}` answer **without a device credential** — the extension and the on-host
sign-in skill hold none. Mounted on the main port they would be reachable by anyone on the tailnet through
`tailscale serve` (measured before the fix, on the retired bridge's `:8445` scheme: `GET
https://…:8445/v1/browser/targets` returned 200). They now live on their own listener:

```
HERMEYD_BROWSER_PORT  default 8790, always 127.0.0.1 (HERMEYD_BIND does not apply)
GET  http://127.0.0.1:8790/v1/browser/targets  -> {"browsers":[{"id","label"}]}
POST http://127.0.0.1:8790/v1/browser/act      -> the browser's reply, or 409 "no browser connected"
WS   ws://127.0.0.1:8790/v1/browser/ws         the extension's socket; hello first
```

* **The main router no longer mounts them**, so `127.0.0.1:8788/v1/browser/*` and the tailnet's
  `https://host:8445/v1/browser/*` both answer **404**. Do not add them back "for convenience".
* **8790 must never be added to `tailscale serve`.** Boot says so: `HERMEYD_BROWSER_READY
  127.0.0.1:8790 (loopback only — never add this port to tailscale serve)`.
* **The extension dials `ws://127.0.0.1:8790/v1/browser/ws`.** The bundled sign-in script already
  points there (`DEFAULT_BROWSER`), and a test forbids `8787` anywhere in the bundled scripts; an
  explicit `--bridge http://127.0.0.1:8790` still governs both the API and the channel, which is what
  a host running something other than the defaults passes.
* **A browser listener that cannot bind is fatal at boot**, not a silent degradation: a service that
  looks healthy while every sign-in gets "connection refused" is worse than one that refuses to start.
  `HERMEYD_BROWSER_PORT` may not equal `HERMEYD_PORT`.

Measured 2026-11-20 on the running service:

```
127.0.0.1:8788/v1/browser/targets        -> 404
127.0.0.1:8790/v1/browser/targets        -> 200 {"browsers":[]}
https://hermes…:8445/v1/browser/targets  -> 404
WS peer hello + POST act probe           -> 200 {"ok":true,…}
```

## Local computers: the browser route (parity complete)

`POST /v1/local-computers/{id}/browser` is device-authenticated and forwards one `{op}` frame down the
Mac's channel: `navigate` (`url`, http/https only), `snapshot`, `act` (`actions`, 1..10), `downloads`.
It answers the Mac's `browser` object, redacted like every other result. The envelope and refusals
mirror `local_computers.py`: 422 for an unsupported op / non-http url / wrong action count, 503 when
that computer is not connected, 504 when it does not answer, 409 for a Mac-side failure, 502 when the
Mac answered without a `browser` object. Measured against a live simulated Mac: navigate / snapshot /
act / downloads each 200, not-connected 503, closed socket 503.

## Providers and a bot's provider+model

Sign-in is **not** a client feature: the owner adds keys on the host with `hermes auth add|refresh|status`.
The app reads what that produced and may pin a bot to one of those providers.

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/v1/providers[?profile=bot]` | bearer | engine `model.options` (with `include_unconfigured`) → every known provider: `models[]`, `model_count`, `authenticated`, `usable`, `state`, `reason`, `priority`, `limit`, `usage`, `plan_usage`; top-level `default {provider, model}` |
| GET | `/v1/bots/{profile}/model` | bearer | `profiles.describe` (the pin) + the catalogue for that profile: `provider`, `model`, `provider_known`, `authenticated`, `usable`, `state`, `models[]`, compact `providers[]` |
| PUT/POST | `/v1/bots/{profile}/model` | bearer | `{provider?, model, confirm_expensive_model?, force?}` → engine `profiles.configure`, then read back with `profiles.describe`. A bare `{model}` keeps the current provider |

`state` is one word a UI switches on: `ready`, `not_authenticated`, `no_models`, `rate_limited`,
`model_limited`, `warning`. Refusals carry a stable `error` code **and** the bridge's `detail`:

| Status | `error` | Meaning |
|---|---|---|
| 404 | `unknown_bot` | the engine has no such profile (`4064` from `profiles.describe`) |
| 422 | `unknown_provider` | not in the engine's catalogue; `known_providers[]` accompanies it |
| 409 | `provider_not_authenticated` | known, but no credential on the host; `hint` names the `hermes auth add` command |
| 409 | `provider_unavailable` | authenticated but the engine advertises no models |
| 422 | `model_not_offered` | the provider's catalogue does not list that model; `suggestions[]`; `force: true` overrides |

The write is only reported applied after the read-back agrees — `applied: true` never comes from the
write's own 200. A guarded model answers `200 {applied: false, confirm_required: true}` with the
engine's message, and the client resends with `confirm_expensive_model: true`.

Measured on the dev host (2026-11-21): 51 catalogue rows, 9 with credentials (openrouter 63 models,
opencode-zen 111, opencode-go 48, kimi-coding 10, openai-codex 6, minimax 5, minimax-oauth 3,
deepseek 2, freellmapi 1); `cody` moved opencode-go/`deepseek-v4.1-flash` → deepseek/`deepseek-v4-pro`
and back, read back through the engine both times, with all 17 owner bots unchanged.

## Running against a stock Hermes install

hermeyd is supposed to work against the engine as shipped, not only our patched build. Three
places assumed the patched one (each has tests that pin the behaviour):

1. **`skills.manage` wire shape.** The Skills page sends `session_id` so the engine resolves the
   *bot's* tree; that field exists only in `patches/0001-…`. A stock engine refuses it with
   `4000 Extra inputs are not permitted`, and its `search` action raises `5024` because
   `_skills_search` reads a non-existent `SkillMeta.describe()`. The relay now sends `session_id`
   optimistically, and on that refusal re-sends the same request id **once** without it and
   remembers `ProfileOnly` for the life of the process (`skills_dialect.rs`, wired in `relay.rs`).
   A `5024` (or the `.describe()` message) on `search` becomes `{results: [], degraded: true}`
   instead of an error card, and later searches are answered locally. Our patched engine still
   receives `session_id` — a successful reply records `SessionScoped` and nothing changes.
2. **`.env` location.** `host_env.rs` resolves `$HERMEY_HOME/.env` (when set), then
   `<engine_home>/.env`, then `<engine_home>/../.env`, picks the first that exists, and logs which
   one at boot (`env: using … (found via HERMEY_HOME)`). A missing file is "not configured", never
   a failure. `integrations.rs` and `voice.rs` read through it; `transfers.rs` was checked and
   never read a `.env`.
3. **One cron ticker per engine home.** `hermes gateway run --force` bypasses the full install's
   host lock, so a host that also runs a full Hermes gateway for the same `HERMES_HOME` fires every
   routine twice. `gateway_guard.rs` scans `/proc` for another `hermes gateway run` (both spellings,
   `…/bin/hermes` and `python -m hermes_cli.main`) whose `HERMES_HOME`/cwd is this engine home, and
   `hermeyd --gateway-check` exits **75** with the pid, cmdline, home and remedy. Nothing is
   killed; the check reports the pid, cmdline, home and remedy and exits, so the thing that
   launches the engine can decide what to do with it.

Vision settings read `auxiliary.vision.provider` / `.model` (the engine's own keys) and fall back
to the flat `auxiliary.vision_provider` / `vision_model` for a config written before that fix;
writes always land nested and preserve every sibling (`base_url`, `timeout`, `auxiliary.free_only`).

## Known limits

- **Per-device authority scoping.** Any paired device can list and revoke the others, as in
  production: there is no admin device, no per-device scope. A stolen paired device is a stolen
  pairing.
