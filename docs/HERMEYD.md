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
| `GET /v1/bot-icons` · `PUT /v1/bot-icons/{bot}` | `{faces:{bot:{avatar, definition?, color?, material?}}, icons:{}}` — `material` is `solid` (absent means this) or `glass`; anything else is a 400, and clearing `definition` clears it |
| `GET /v1/bots/disabled` · `POST /v1/bots/{bot}/state` | `{disabled:[…]}` / `{enabled:bool}` |
| `GET/PUT /v1/bots/approvals` | `{mode, profiles, unset, updated, failed}` |
| `GET/POST /v1/rooms` | the engine's rooms (`groups.list`, limit 50); create names one and picks 2–6 members |
| `GET /v1/rooms/{id}/log` · `POST …/send` · `POST …/rename` · `POST …/disband` | room log (`?since_seq=`), a message, a rename, a disband — each an engine `groups.*` call |
| `POST /v1/push/{presence,register,test}` | `{ok:true}` — no relay, says so plainly |
| `GET /v1/bots/previews` · `POST /v1/bots/previews` | each bot's newest line, read from its own `state.db` against the conversation the app opens; POST adds `{unread:{profile:n}}`. Best-effort: a locked or missing database yields no row for that bot, never an error for the list |
| `GET /v1/reactions` · `PUT /v1/reactions` | one emoji per message, shared by every device — see below |

`scripts/smoke-app-routes.sh` replays the app's connect sequence (a fresh single-use ticket per call,
like the client) and asserts every shape plus persistence across calls.

## Reactions — `GET/PUT /v1/reactions` (shipped in 0.3.8)

The two apps used to keep reactions in their own `@AppStorage`, so the Mac's menu offered to remove a
"**local** reaction" and the phone never saw it. The host is the only place two devices can meet, so
it owns them now. One emoji per message, and a new one replaces the old — what both apps already did.

```text
GET /v1/reactions?bot=<profile>&session=<session id>       (bearer)
  -> {"reactions": {"row:41": {"emoji": "👍", "by": "Mo's Mac"}}}

PUT /v1/reactions                                           (bearer)
  {"bot":"cody","session":"20261123_101500_ab12cd","message":"row:41",
   "emoji":"👍","by":"Mo's Mac"}
  -> {"message":"row:41","emoji":"👍","by":"Mo's Mac","at":1795…}
  {"…","emoji":""}                                       -> the reaction is removed, "emoji": null
  a bad bot/session/message/emoji/by                     -> 422 {"error":"bad_emoji", "detail": …}
```

`message` is the apps' own message key: `row:<rowID>` for a row the host persisted, `live:<entry.id>`
for one it has not. The host scopes it by bot and session, so a Mac and a phone whose *host labels*
differ still agree — the label is only part of each device's local key.

Storage is one JSON document in the state directory, `reactions.json`, written atomically (temp file,
then `rename`) and capped at 5 000 entries, oldest evicted: a badge on a message nobody has opened in
a year is not worth an unbounded file. A file that cannot be parsed is reported once and treated as
empty rather than refusing every later write.

Every change is broadcast on `/v1/ws` as the engine's own event envelope, which is what both apps
already decode:

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"reaction.updated","session_id":"<session>",
 "payload":{"bot":"cody","session":"…","message":"row:41","emoji":"👍","by":"Mo's Mac"}}}
```

An unpaired app has no host, so it keeps writing its own `@AppStorage` document
(`mac.messageReactions.v1` / `mobile.messageReactions.v1`) — the behaviour it had before — and hands
those entries to the host once, the first time it opens that conversation paired.

## Self-update — `GET/POST /v1/update` (shipped in 0.4.0)

One press updates the host service, and a host that will not start puts itself back. Nothing else
is touched: the engine, the installer and every other file are off limits — this replaces
`/opt/hermey/bin/hermeyd` and writes one record in the state directory.

```text
GET /v1/update[?refresh=1]                                    (bearer)
  -> {"current":"0.3.9",
      "latest":"0.4.0" | null,          # null = the feed could not be read: unknown, not current
      "available": true,
      "notes_url":"https://github.com/macblizzard/hermey/releases/tag/hermeyd-v0.4.0",
      "checked_at":1795222533.13,
      "can_self_update": true,
      "arch":"linux-x86_64",
      "error": null | "the release feed is unreachable (…)",
      "progress": "downloading" | "verifying" | "installing" | null,   # the running press
      "last_update": {"target":"0.4.0","previous":"0.3.9","state":"healthy",
                      "attempts":1,"started_at":1795222533.1} | null}

POST /v1/update                                               (bearer)
  -> 202 {"target":"0.4.0","state":"started"}                 # download, verify, install, exit
  -> 403 self-update is off, no build for this platform, or the binary is not writable
  -> 409 an update is already running / this host is already on that version
  -> 503 the release feed could not be read
```

`latest` is the numerically newest **published, non-draft, non-prerelease** `hermeyd-v*` tag, read
from the GitHub releases API and cached for six hours (`?refresh=1` asks again now); a failed check
is remembered for one minute, so a host whose link just came back stops saying "unknown" promptly.
An app release (`v0.1.N`) carries no host binary and is never a candidate — the same trap
`setup/install.sh:newest_host_tag()` guards against.

The install, in the order it happens after the 202:

1. download `<base>/<tag>/hermeyd-<platform>` and `<base>/<tag>/SHA256SUMS` (asset names are the
   installer's: `linux-x86_64`, `linux-aarch64`, `darwin-arm64`, `darwin-x86_64`);
2. look this asset's digest up **by name** in `SHA256SUMS` (no entry → refuse) and compare it to the
   bytes; a mismatch deletes the download and replaces nothing. That published checksum is the whole
   trust anchor for a prebuilt binary — the same rule `setup/install.sh` applies to a first install;
3. copy the running binary to `hermeyd.prev` beside it (mode 0755);
4. `rename` the verified download over the binary — one atomic step, which is why it is staged in
   the binary's own directory and not in the state directory;
5. write `update-state.json` as `pending`, audit `update.installed`, and `exit(0)`.
   `Restart=always` in the unit starts the new build.

**The record** — `<state>/update-state.json`, written temp-then-`rename`:

```json
{"target":"0.4.0","previous":"0.3.9","state":"pending","attempts":0,"started_at":1795222533.1}
```

`state` is exactly `pending`, `healthy` or `rolled-back` — those three strings are what both apps
switch on.

**Rollback, which never needs the network.** Every boot reads that record before it binds anything:

| record | boot of | what happens |
|---|---|---|
| `pending`, `target` = running | 0.4.0, 1st time | `attempts` → 1, serve normally |
| `pending`, `target` = running | 0.4.0, 2nd time | copy `hermeyd.prev` over the binary, `rolled-back`, audit, `exit(0)` → systemd starts 0.3.9 |
| `pending`, `previous` = running | 0.3.9 | `rolled-back`, audit — the previous build is back and stays |
| `pending`, some third version | anything | left alone; nothing is guessed |
| `rolled-back` / `healthy` | anything | nothing |

Sixty seconds after both listeners are bound, a `pending` record about the running version becomes
`healthy` and `hermeyd.prev` is kept for the next update. A build that crashes, or never binds,
comes back as attempt 2 and is replaced — that is the whole of "it failed to start". The rollback is
`fs::copy` + `rename` only: an air-gapped host rolls back exactly as well as a connected one.

Turning it off: `HERMEYD_SELF_UPDATE=off` (or `0`/`no`/`false`/`disabled`) makes
`can_self_update: false` and `POST` a 403. A mirror or a test listener sets
`HERMEYD_UPDATE_BASE` (default `https://github.com/macblizzard/hermey/releases/download`) and
`HERMEYD_UPDATE_API`; `HERMEYD_UPDATE_BIN` points the updater at a binary other than the running one.

Proven end to end on a real process — report, download, checksum, install, record, exit, two boots
and the restore — against a release server on this machine: `scripts/smoke-self-update.sh`. The apps' side is drawn from the same record: the bell's first row, its four stages, and
Settings ▸ About's host line all come from `GET /v1/update`, and none of them applies anything
without a press.

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

## Office documents — `POST /v1/office/extract` (shipped in 0.4.1)

A PDF, a Word document or a spreadsheet is neither something a chat bubble can draw nor something
every bot can read (no PDF library on a bare host, no spreadsheet parser in a model). If each reader
decided for itself what `budget.xlsx` says, the phone and the bot would disagree about the same file.
So **the host reads it once** and hands back text: no OCR, no formula evaluation, no Word rendering —
what the file already carries, bounded and labelled.

```text
POST /v1/office/extract                        bearer, or loopback with no credential
  x-hermey-filename: budget.xlsx
  <raw bytes, ≤ 8 MiB>

  -> 200 {"name":"budget.xlsx","kind":"xlsx",
          "mime":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          "chars":842,"truncated":false,"notes":[],
          "text":"Region | Units\nNorth | 42\n…",
          "block":"--- attachment: budget.xlsx (sheet: Q4, 3 rows, 2 columns) ---\nRegion | Units\n…"}
  -> 400 {"detail":"empty body"}
  -> 413 {"detail":"document larger than 8 MiB"}     (the router refuses before buffering)
  -> 422 {"detail":"budget.xlsx is named as an Excel workbook (.xlsx) but its contents are a PDF"}
  -> 404 {"detail":"not found"}                      no ticket and not loopback
```

`block` is the thing to paste into a prompt — an app does not format anything itself, which is the
whole reason this is one route and not three parsers. `text` is the same body without the headers (a
preview), `notes` says what was cut and why, and `truncated` is `notes.is_empty() == false`.

The body and the filename header are the same shape `POST /v1/attachments` already takes: raw bytes,
one code path, `curl --data-binary @budget.xlsx` as the whole client.

### What each type becomes

| kind | read as | block label |
|---|---|---|
| PDF | the text layer, page by page (`lopdf`), `[page N]` markers | `pdf, 12 pages` / `pdf, pages 1-50 of 120` |
| DOCX | `word/document.xml`: paragraphs in order, headings as `#`…`######`, tables flattened row by row (`| a | b |`) | `docx, 34 paragraphs, 2 tables, 118 rows` |
| XLSX | every sheet's **used range**, one block per sheet, cells joined with ` | ` | `sheet: Q4, 812 rows, 6 columns` |
| CSV | quote-aware fields, same pipe joining | `csv, 500 rows` |
| TXT/MD/LOG | the lines as they are | `text, 500 lines` |

Cells that carry a date **number format** are rendered as dates (`2026-11-24`, `2026-11-24 14:05`),
not as the serial number the file actually stores; shared strings, inline strings, booleans and error
values all come through. A literal `|` inside a cell becomes `/`, because a pipe is the separator.

### Bounds, and how they are reported

| bound | value |
|---|---|
| body / per attachment | 8 MiB (`attachments::MAX_ATTACHMENT_BYTES`, the relay's own ceiling) |
| per document, text | 24 000 characters |
| per message, all attachments | 48 000 characters |
| PDF pages | 50 |
| DOCX paragraphs / table rows | 2 000 / 2 000 |
| XLSX sheets / rows per sheet / columns per row | 12 / 500 / 40 |
| CSV/TXT rows (and bytes read) | 1 000 (2 MiB) |

A bound that bites is written **into the text where a reader will meet it** — `[... 312 more rows not
shown]`, `[page 51]`, `[... truncated at 24000 characters]` — and named again in `notes`. Truncation is
therefore never silent, and a bot that needs the rest can ask for the missing part instead of
re-reading the file. Every truncation is also written to the host's own log
(`office: budget.xlsx was truncated: stopped after 24000 characters (sheet Q4)`), so a cut that
happened in a reply nobody kept is still traceable. A scanned PDF has no text layer; its block says
so instead of pretending to be empty.

### Trust is decided by the bytes, not the name

The name and the content must agree, and the content wins:

- a PDF starts `%PDF-` (leading whitespace or a BOM tolerated);
- a DOCX is a zip containing `word/document.xml`;
- an XLSX is a zip containing `xl/workbook.xml`;
- CSV/TXT must be UTF-8 with no NUL bytes.

A `.docx` that is really a PDF is refused with both facts in the message. A zip that is neither
(a `.zip`, an `.epub`) is refused as a zip. `.doc`, `.xls`, `.pptx` and everything else are refused
by name — they are formats this host does not read, and pretending otherwise would hand a bot a
filename where the owner expected a summary.

## The send path: `file.attach`, sniffed (shipped in 0.4.1)

The apps did not change how they send a file: a picked document still travels the relay's
`file.attach` with `data:application/octet-stream;base64,` and the same **8 MiB** ceiling as before.
What is new is that the host reads the bytes of the three types the pickers offer *before* the frame
is forwarded, so a mislabelled file never reaches the engine:

```text
file.attach {name: "budget.xlsx", data_url: "data:application/octet-stream;base64,…"}
  -> forwarded unchanged                          the bytes really are an .xlsx
  -> -32602 {"message":"budget.xlsx is named as an Excel workbook (.xlsx) but its contents are a PDF"}
```

- **Only the sniff echoes its reason.** Every other refusal keeps the bridge's fixed
  `-32602 invalid attachment`: the Python checks never said why, and the app already handles that
  shape. The sniff is new, and `invalid attachment` would tell the person who just picked a file
  nothing — so that one message is carried to the app verbatim (it is written for a human, and it
  names the file).
- **`image.attach_bytes` is untouched** — no sniff, the same decoder, byte-identical behaviour — and
  any extension outside `pdf`/`docx`/`xlsx` travels exactly as it always has (the Python bridge had
  no allow-list and this does not invent one for the rest).
- The check runs again wherever those bytes are read (`POST /v1/office/extract`, a message's
  `attachments`, the prompt below), so a file swapped on disk after the send is not read either: its
  block says `[not read: the file could not be parsed as a document]` rather than vanishing.

## The prompt: `prompt.submit` carries the document's text

The app puts the `file.attach` receipt's `@file:` reference into the prompt it submits, and the
engine can only stub a binary as *"binary file, not inlined as text"*. So the relay appends the
labelled blocks to the `text` it forwards — this is how an attached document reaches the bot:

```text
prompt.submit {text: "@file:/…/profiles/cody/attachments/budget.xlsx\n\nwhat does Q4 say?"}
  -> {text: "@file:/…/budget.xlsx\n\nwhat does Q4 say?\n\n--- attachment: budget.xlsx (sheet: Q4, 812 rows, 6 columns) ---\nRegion | Units\n…"}
```

- `prompt.submit`, `prompt.background` and `session.steer` are looked at; nothing else carries a
  turn's text.
- Only **absolute** references that resolve **inside the service's own `engine_home`** are read. A
  prompt may name any path it likes; the host turns a claim into bytes only inside its own profiles,
  so a reference pointing at `/etc/…` travels untouched for the engine to refuse as it always did.
- The `@file:` line itself is **never rewritten**: the stored row's reference is how the app fetches
  the bytes back on another device (and the engine still resolves it, to its usual stub).
- Bounds are the message ones — **4 documents, 24 000 characters each, 48 000 in total** — and a
  prompt that already carries a block for that file grows no second copy (a resent prompt is
  forwarded byte-for-byte).
- Images never reach this code: their references are not office documents, so their prompts are
  forwarded unchanged.

## Reading a file back: `GET /v1/attachments/{profile}/{name}` (shipped in 0.4.1)

The cross-device open — a transcript reference fetched by a device that never saw the bytes — now
serves the three document types beside the pictures:

| extension | looked up in | content type |
|---|---|---|
| png/jpg/jpeg/heic/heif/gif/webp/tiff/bmp | `profiles/<p>/images/`, then `images/` — **unchanged** | the image type, unchanged |
| pdf/docx/xlsx | `profiles/<p>/attachments/`, then `attachments/` (where `file.attach` stages them) | the document's own type |
| anything else | — | `400 {"detail":"not an image attachment"}` — unchanged |

Same device bearer (`require_device`), same 8 MiB ceiling, same one-component name, same symlink
refusal, same 404 for a missing file. The document's bytes are read from disk per request, so a
file staged moments ago is fetchable the moment the transcript quotes its name.

## Documents on the bot-to-bot message, `POST /v1/bots/{profile}/message`

The message route takes an optional `attachments` array, and the host extracts each one before the
message reaches the engine, so the receiving bot sees the **text**, not a path it may not be able to
open:

```json
POST /v1/bots/ops/message                                    (loopback only, no ticket — unchanged)
{"text": "the forecast is attached", "from": "cody", "from_profile": "cody",
 "attachments": [{"name": "forecast.xlsx", "data_base64": "<base64>"},
                 {"name": "terms.pdf", "data_url": "data:application/pdf;base64,<base64>"}]}

-> {"profile":"ops","from":"cody","session_id":"…",
    "text":"Cody (cody) → Ops: the forecast is attached\n\n--- attachment: forecast.xlsx …",
    "reply":"thanks — Q4 is up 9%","delivered":true,
    "attachments":[{"name":"forecast.xlsx","kind":"xlsx","chars":812,"truncated":false},
                   {"name":"terms.pdf","kind":"pdf","chars":9214,"truncated":true}]}
```

- one of `data_base64` / `data_url` per attachment, never both; `data_url` must declare a type this
  host reads (or `application/octet-stream`). No other keys: `{"name", "data_base64"}` is the shape,
  and `path` is refused exactly as the relay refuses it;
- at most **4** attachments per message, **8 MiB** each, at most **48 000** characters of extracted
  text in total. Past that, the surplus attachment arrives as a block that says
  `[not included: this message already carries 48000 characters of attachments]`;
- the label stays the **first line** (`Cody (cody) → Ops: …`) so both apps still parse the sender off
  it, and the blocks follow after a blank line;
- the transfer record and the audit line still carry the caller's **words** and the message's size —
  the document is not a second hand-off;
- `attachments` appears in the response only when there were some, so a message without a document is
  byte-identical to what every caller already reads (six fields);
- `POST /v1/bots/{profile}/ask` refuses attachments (`422 ask does not take attachments: use
  message`) rather than dropping a file the caller believes it sent.

## The way back — how a bot hands a file to the app

This is the contract an app implements; the routes themselves already existed.

1. **The bot writes the file into its own workspace**:

   ```
   <engine home>/profiles/<profile>/workspace/<any sub path>
   ```

   That is the bot's working directory, and it is what `GET /v1/workspace/{profile}` lists as
   `source: "workspace"`.

2. **The bot announces it in its reply with a markdown link to the host's download route**:

   ```markdown
   Here is the forecast: [Q4-forecast.xlsx](/v1/workspace/ops/file?source=workspace&path=reports/q4-forecast.xlsx)
   ```

3. **The app resolves that link against its host base URL and fetches it with its device ticket**:

   ```text
   GET <host>/v1/workspace/ops/file?source=workspace&path=reports%2Fq4-forecast.xlsx
     Authorization: Bearer <ticket>
   -> 200 <bytes>
      content-type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
      content-disposition: inline; filename="q4-forecast.xlsx"
   -> 422 {"detail":"invalid path"}      absolute path, `..`, or a bad profile name
   -> 404 {"detail":"no such file"}      missing, a directory, or a symlink
   ```

Rules the route enforces, so the app does not have to:

- `path` is **relative** to the folder and `/`-separated; `source` is `workspace` or `attachments`,
  and when it is omitted both are tried, `workspace` first (which is what the app already relies on).
- Absolute paths, `..`, and profile names that are not a plain name are `422 invalid path`.
- Symlinks are refused at the leaf **and** on the way in: a link named `notes.md`, or a linked
  directory whose child resolves outside the folder, is `404` — a bot cannot hand out a host file by
  naming one.
- The bytes are read from disk **per request**, so a file written during the same turn is fetchable
  the moment the reply lands. No index, no upload step, no second copy.
- `content-type` comes from the extension: `xlsx`/`docx`/`pdf`/`csv`/`txt`/`md`/`png`/`jpg`/… are
  typed, everything else is `application/octet-stream`. `docx` and `xlsx` are **not** in the
  Library's `previewable` set on purpose: they download rather than render.

So the smallest honest flow is: **bot writes a file, bot links it, app fetches it**. Nothing new
travels with the message, and the link works for a file that did not exist when the turn started.

Bots are taught this by the bundled `office-files` skill (`hermeyd/assets/agent-skills/office-files/`),
installed with the other bundled skills on upgrade.

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
| `/v1/credentials/cards` (+ `/answer`, `/cancel`, `/consume`) | login cards: the bot asks, the owner answers. Values are never returned while pending or answered, `consume` yields them once then drops them, cards expire (default 15 min), pending count bounded. `store: true` saves the answer in `<state>/secrets.json` (`0600`) instead and `consume` answers with `{stored:[{field,name}], ok}` — no value — so a login and an API key are one mechanism with two destinations |
| `GET /v1/vault`, `DELETE /v1/vault/{*name}` | the vault's read and delete face, for the owner's Vault pane on both apps: `{items:[{name,kind,addedAt,site?,note?}]}` and no value field anywhere — the item type has none and `vault.rs` never calls `secrets::get`. Delete answers 404 for a name the store does not have, 422 for a name it would never hold, 409 for an unreadable store. Adding is still the `store` card above, so there is one door into the store. Labels (`site`/`note`/`kind`/`addedAt`) sit in the document store under `vault:index`, so `secrets.json` keeps its one format |

## A device's log, saved on this host — `POST /v1/client-logs`

```text
POST /v1/client-logs                                             (bearer)
  {device, appVersion, appBuild, osVersion, scope, level?, category?, search?, capturedAt, text}
  -> 201 {path, bytes, device}
  -> 401 missing/expired/already-used token      (require_device)
  -> 409 a log from this device for this minute is already on disk; nothing was truncated
  -> 413 the text is over 2 MiB
/var/log/hermey/client-<device>-<YYYYMMDDTHHMMZ>.log            0640 root:root
```

Settings → View log's **Send log to host** is the only caller. It is a plain bearer POST — not the
WS relay — so a conversation streaming a large transcript cannot stand in front of it, and the
upload cannot hold a relay slot while a chat is open. `text` is byte-for-byte what the sheet's Copy
action writes (`ClientLog.text(of:header:)`); the envelope adds only the device name, app version and
build, OS, the capture time, and which filters were on, and the host writes those as a `#` block above
the log so a file found in `/var/log/hermey` explains itself.

Three properties worth keeping:

1. **Never overwritten.** The file is opened with `create_new`, so a second upload inside the same
   minute answers 409 and the first file is untouched — a log someone is reading must not change under
   them. The filename's stamp is UTC to the minute; the device name is slugged to `[a-z0-9-]` first, so
   a device called `../../etc/passwd` becomes `etc-passwd`.
2. **2 MiB on both ends.** The app refuses a larger log before sending it; the handler refuses one
   with its own sentence (`MAX_LOG_BYTES`). The framework body limit (`MAX_BODY_BYTES`, 8 MiB) sits
   above both, so the 413 a client reads is that sentence rather than an empty rejection.
3. **No new content.** The route has no field for a value and does not import `secrets`, `credentials`
   or `vault`: the log has never carried a card or a secret, and this is not the way one gets in.
   `HERMEYD_LOG_DIR` moves the directory for a scratch host or a non-standard install.

## Fast pet asks — `POST /v1/bots/{profile}/ask` (shipped in 0.5.0)

The desktop pet's balloon asks a bot a question and waits for the answer. Until 0.5.0 that question
was delivered into **the bot's endless conversation** — the one `bot_sessions` points the apps at —
so a one-word greeting paid for the whole transcript: measured at **12.55s / 15.51s / 15.16s**,
always against session `20261103_160851_77da50` (tinker's endless conversation), and 147s the
first time the model decided to go run a tool.

`from: "desktop-pet"` is now a routing key (`hermeyd/src/bot_message.rs`, `PET_SENDER`) and
nothing else. What each of the four asks became:

| Ask | Result |
|---|---|
| **Bounded per-bot session** | **Built.** A dedicated `pet_sessions` row per bot (its own table, never `bot_sessions`), minted on the first balloon with `session.create` and resumed on every ask after. Before each delivery the pet's transcript is counted in the bot's own `state.db`; at `PET_WINDOW` (60 rows) the pointer is dropped and a fresh session is minted. Rotation rather than compaction: the gateway's compaction threshold is *profile* config, and a config write would change the bot's normal conversation too. A deleted pet session (`session.resume` −32001) re-mints instead of failing every later question. |
| **Fast model** | **Built.** `session.create` carries `model`/`provider` read out of that profile's own `config.yaml` by `pet_model` — `model.default` when it already names a fast model, else the first `fallback_providers` entry that does, else no pin at all. A name the config does not have is a provider 404 on the first turn, which is the failure the create-time model×provider gate refuses up front, so nothing is ever invented. |
| **No tools** | **Not reachable on the wire.** `session.create` has no toolset parameter (`tui_gateway/contracts/sessions.py`, `SessionCreateParams`), `_make_agent` resolves toolsets from `HERMES_TUI_TOOLSETS` and profile config only (`tui_gateway/agent_factory.py`, `_load_enabled_toolsets`), and `tools.configure` writes the profile's `config.yaml` — which would change the bot's normal conversation too. The pet therefore runs with the profile's own toolset. |
| **Short prompt** | **Not reachable on the wire.** The gateway builds the agent's system prompt from profile config and environment (`tui_gateway/agent_factory.py`, `_startup_system_prompt`); neither `session.create` nor `prompt.submit` carries a prompt parameter. Nothing is sent pretending otherwise. |

**Where the answer lands now — the trade-off, resolved.** Before this change the pet's question
and the bot's reply were rows in the conversation the app opens, and that is exactly why the pet
reused it. They are now rows in the pet's own session instead: the balloon still shows the reply,
but opening the bot in the app no longer shows the exchange. That is the chosen behaviour, and the
alternative was rejected deliberately — keeping both would mean either a second model turn in the
bot's conversation (the bot answering the same thing twice) or hermeyd writing rows directly into a
`state.db` the engine owns and has open. So the pet's session is titled **`Desktop Pet`** and left
visible in the profile's session list — never hidden — so the exchange stays readable exactly
where it happened. Rotating at the cap leaves the old one in the list too, for the same reason.

Every other `from` keeps the old route byte for byte, and so does `POST /v1/bots/{profile}/message`:
the response is still `{profile, from, session_id, question, reply, answered}`, with `session_id`
now naming the pet's own key when the question came from the balloon.

## Agent cards — `GET /v1/cards/{card_id}?session=&message=` (shipped in 0.1.621)

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

## Local computers: the bot-instructions route (`/v1/local-computers/skill`)

Both verbs are device-authenticated (`require_device`, same per-call ticket the revoke uses) and
write into this host, never into the Mac:

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/v1/local-computers/skill` | bearer | read only — `{host, version, present, up_to_date, owned_by_the_user[], cli_present, cli, missing[], stale[], errors[], targets[]}` |
| POST | `/v1/local-computers/skill` | bearer | re-runs boot's own install (`skills::install`); `{written, current, failed[], installed[], script_error, targets[]}` and one `local_computer.skill` audit record |

GET answers what `skills::write_skill` *would* decide, directory by directory: `current` (identical
to the render), `stale` (ours by marker, older content), `foreign` (no marker — the owner's, and an
install leaves it alone), `missing`, `platform-skipped`, `unreadable` (named in `errors[]` with its
reason). `up_to_date` requires every target current **and** the bundled CLI on disk. Nothing on the
read path writes, so the Mac's Settings row can ask as often as it likes.

This route used to be a placeholder that answered **404** to GET. The Mac reads any non-2xx as "the
host did not answer" and drew *Unavailable* beside an Install button whose writes were never
reported, which is what the owner saw as "the Install button does nothing". A host that has not
installed yet now answers 200 with `present:false`, and the row says *Not installed*.

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
