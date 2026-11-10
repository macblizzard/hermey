# QA: what is verified, how, and what is not

The Swift apps and the bridge make claims that cannot be checked by reading code: *an approval
blocks the agent until the user answers*, *a ticket is single use*, *a 1 MiB frame never reaches the
gateway*, *no prompt text is logged*. Those are timing and envelope behaviours, so they are tested
against a **scripted fake gateway** — a replay server that serves recorded fixtures and synthetic
scenarios over a real WebSocket — with the real bridge in front of it.

```
Tools/qa/
├── replay_server.py         fake Hermes TUI gateway: fixtures/*.ndjson + script directives
├── harness.py               boots the real bridge on loopback, with a throwaway DB
├── rpc.py                   minimal NDJSON JSON-RPC client (typed ids, hard timeouts)
├── conftest.py              fixtures; no pytest-asyncio, one event loop per call
├── scenarios/               scripted gateway transcripts (see below)
├── test_replay.py           the replay server, tested like code
├── test_config.py           startup refuses to be unsafe (bind address, gateway URL, cap)
├── test_pairing.py          identity: pairing codes, tokens, devices, revocation
├── test_ws.py               the relay: approvals, tickets, frame caps, close codes
├── test_audit.py            the audit log may say who/what, never what was said
├── test_latency.py          the latency instrument, tested for lying
└── latency.py               the measurement CLI behind §7 of the architecture doc
```

## Running it

Everything runs from the repo root; no services, no network, no tailnet. Each test boots a replay
server and the bridge on ephemeral loopback ports, with `HERMES_BRIDGE_DB` pointed at a temp file, so
the suite never touches `~/.local/state/hermes-bridge/bridge.db`.

```bash
# with the bridge venv (or any venv with pytest/httpx/fastapi/uvicorn/websockets)
PY=$HOME/.hermes/profiles/<profile>/cache/scratch/venv-bridge/bin/python

$PY -m pytest -q Tools/qa                 # the whole harness, ~40 s
$PY -m pytest -q Tools/qa/test_ws.py -k approval   # one area

# the numbers
$PY Tools/qa/latency.py                    # gateway leg, 20 samples
$PY Tools/qa/latency.py --through-bridge   # phone → bridge → gateway
$PY Tools/qa/latency.py --csv /tmp/lat.csv --samples 50
```

Expected: **87 passed, 0 xfailed**. A red test here means the
bridge or the scenario is wrong — not that the fake gateway is slow. `test_replay.py` exists precisely
so the fake gateway cannot be the suspect.

## 1. The replay server

`fixtures/m0-handshake.ndjson` is a recording: five real frames, byte for byte. It is replayed
verbatim (a test asserts the bytes match the file), which is how a decoding bug shows up — the fixtures
win over the docs, per `fixtures/NOTES.md`.

But a recording is one-way: it cannot express "answer `ping`, then go quiet on `session.list`", or
"send the approval, then wait for the answer before releasing the tool". So the same format carries
**directives** under the reserved key `"$qa"`. One frame per line, as before; directives between them.

```json
{"$qa": {"auto_reply": {"ping": {"result": {"pong": true}}}}}
{"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}}
{"$qa": {"wait_for": {"method": "prompt.submit", "timeout": 10}}}
{"jsonrpc": "2.0", "method": "event", "params": {"type": "message.delta", "payload": {"delta": "hi"}}}
{"jsonrpc": "2.0", "id": "srq-1", "method": "approval", "params": {"choices": ["allow_once", "deny"]}}
{"$qa": {"wait_for_response": {"id": "srq-1", "timeout": 10}}}
{"$qa": {"close": {"code": 1000, "reason": "done"}}}
```

| Directive | Meaning |
|---|---|
| `sleep: 0.05` | wait, then continue (models a slow gateway) |
| `auto_reply: {method: {result\|error}}` | answer *every* request for that method, whenever it arrives, in any order — this is how `ping` and `client.capabilities` behave on a real gateway |
| `reply: {method, result\|error, delay?}` | answer the next *unanswered* request for that method, keeping its id; `delay` models a slow answer |
| `wait_for: {method, occurrence?, timeout?}` | block until that request arrives |
| `wait_for_response: {id, timeout?}` | block until the client answers that server→client request — this is what makes an approval *block* |
| `require: [m1, m2]` | wait for several requests, in order |
| `unmatched: "silent" \| "method_not_found"` | how to treat requests no directive answers; `silent` is the default and matches the observed `session.list` behaviour |
| `mark: "label"` | record a timestamped point for reports |
| `close: {code, reason}` | close the socket with a specific code |

Two properties matter more than the vocabulary:

- **Request-gated, never sleep-gated.** A scenario says "wait for `prompt.submit`", not "sleep 200 ms".
  A slow CI box cannot make it flaky, and the order of frames is a fact, not a hope.
- **The fake gateway never enforces a limit the bridge is supposed to enforce.** It accepts up to
  `max_size=None` and records the byte size of every frame, so "the bridge forwarded an oversize frame"
  is observable. If the fake gateway rejected it first, the test would pass for the wrong reason.

It also records every inbound and outbound frame with a relative timestamp
(`ReplayServer.connection(i).timeline()`), which is how "the gateway did not release the tool until
the answer arrived" is asserted instead of assumed.

Fresh recordings replay directly: `Tools/record_fixtures.py` writes
`{"t": …, "dir": "stdin"|"stdout", "frame": {…}}` records, and the parser accepts that shape —
`stdout` records are replayed in order and `stdin` records become `wait_for` gates, so a recording made
on a new Hermes version can be dropped into `Tools/qa/scenarios/` without hand-editing (see
`test_a_recording_from_tools_record_fixtures_replays_as_a_scenario`).

## 2. Scenarios in the repo

| File | Simulates | Used by |
|---|---|---|
| `fixtures/m0-handshake.ndjson` | the real recording: ready, ping, capabilities, `-32601`, per-session-submit | `test_replay.py` (byte-for-byte), `test_ws.py` (relay smoke) |
| `handshake.ndjson` | a well-behaved gateway that answers `ping`/`client.capabilities` | relay, tickets, limits, audit |
| `turn-approval.ndjson` | a full turn: two deltas, `tool.start`, an `approval` request that blocks, then completion | the approval round trip |
| `turn-decline.ndjson` | same, with `tool.complete {ok: false}` after a decline | decline path |
| `silent-session-list.ndjson` | `session.list` answered by silence (`fixtures/NOTES.md` §4) | "absence is not `[]`" |
| `resume-open-request.ndjson` | `session.resume` returning `inflight` + `open_requests`, then the live request again | reconnect mid-approval |
| `latency-stream.ndjson` | 31 deltas at 8 ms, then completion | `latency.py`, `test_latency.py` |

Approval **payload shapes are illustrative**: the recorded fixtures contain no approval frame, so
`params.choices`, `call_id` and friends are modelled from `02-architecture.md`, not observed. The
envelope (`id` + `method`, and the fact that the agent blocks) is what these tests pin. See §6.

## 3. What the tests assert

**The replay server** (`test_replay.py`) — the recording replays byte for byte; every message is one
newline-terminated JSON object; `wait_for` really blocks; `reply` preserves the client's id *and its
type* (`1` ≠ `"1"`); silence is silence; close codes propagate; scripts are handed out one per
connection; a malformed scenario fails loudly instead of silently no-oping; every scenario in the repo
parses.

**Startup** (`test_config.py`) — the bridge refuses a non-loopback bind, a non-loopback gateway URL, a
non-`ws://` URL, a URL without a path, a zero or absurd frame cap; the gateway token appears only in the
upstream dial URI, never in the loggable form.

**Identity** (`test_pairing.py`) — 8-digit single-use codes; 600 s expiry; codes cannot be minted by a
request that came through `tailscale serve` (proxy headers present, even though the peer is loopback);
claims are throttled (10/minute, then `429`); a placeholder public key is rejected; the device limit
holds; refresh tokens are stored hashed (the plaintext is not in `bridge.db`, the SHA-256 is); a
refresh token is useless without its `device_id`; revocation is immediate for *new* tokens; the device
listing never contains a secret; the gateway token never appears in any HTTP response or audit record.

**The relay** (`test_ws.py`) — `gateway.ready` arrives; the bridge announces
`client.capabilities {server_requests: true}` itself and swallows the answer; a client cannot *narrow*
that capability; ids and payloads pass through unchanged; a silent gateway stays silent; the method
allow-list refuses `shell.exec`/`cli.exec`/`config.set`/`vault.read` and never forwards them; invalid
method names are refused before the allow-list; malformed frames get `-32700` and do not kill the
socket; unsupported server→client requests are answered `-32601` by the bridge so the agent fails fast;
a server request whose id collides with an in-flight client request is remapped for the app and
restored upstream; coalesced frames are split; a chunked frame fails *safely* (`-32700`, nothing
half-forwarded).

**Approvals** (`test_ws.py`) — the request reaches the app as a *request* (id + method), not as an
event; nothing else arrives while it is unanswered; the answer reaches the gateway with its original
id; the tool completes only after the answer; a decline produces `ok: false`; a stale answer from a
second device is dropped and audited; `session.resume` replays the open request and answering it once
finishes the turn.

**Limits and tickets** — a ticket is spent by the first upgrade, even if the peer hangs up; expired,
missing and revoked tickets are refused *before* the gateway is dialled (no upstream amplification);
oversize frames are refused in both directions with `1009` and never forwarded; an oversize *binary*
frame cannot bypass the cap; the gateway token is used only in the upstream dial URI.

**Audit** (`test_audit.py`) — a canary in the prompt text and in the tool input never appears in the
audit records, the log lines, or the database; records have a closed key set and scalar values; each
record is one JSON line; no token, ticket or public key is ever recorded; a rejected upgrade is audited
without the ticket; dangerous methods never appear in the audit *and* never reach the gateway.

## 4. Latency

`latency.py` measures the transport, not the model, against `latency-stream.ndjson` — whose first
delta has **no scripted delay**, and whose cadence is **8 ms**, so the two numbers that matter are
readable directly: `submit → first delta` is pure transport, and the delta interval shows buffering.

Recorded on this host, loopback only, 20 samples, 5 Nov 2026 (regression baseline, **not** the tailnet
budget — it excludes WireGuard, TLS and the radio):

| | gateway direct p50 / p95 | through the bridge p50 / p95 |
|---|---|---|
| TCP + WS open | 3.24 / 8.03 ms | 4.48 / 8.14 ms |
| connect → `gateway.ready` | 3.30 / 8.10 ms | 8.49 / 14.16 ms |
| `ping` RTT | 0.48 / 2.07 ms (p99 2.26) | 1.87 / 4.90 ms (p99 8.45) |
| `prompt.submit` → 1st delta | 0.82 / 1.82 ms (max 4.08) | 1.53 / 3.20 ms (max 4.01) |
| delta interval (scripted 8 ms) | 8.39 / 10.75 ms | 8.52 / 12.15 ms |
| stream total (31 deltas) | 262 / 304 ms | 269 / 376 ms |

Reading it: the bridge costs about **1.4 ms per round trip** on loopback (ping 0.48 → 1.87 ms) and
adds ~5 ms to the first byte after a cold connect (two handshakes instead of one). That is the entire
server-side cost of the architecture; the tailnet hop is measured separately, on device, by the app's
own harness (`02-architecture.md` §7).

`--csv` writes one row per sample for a trend line; `--json` emits the summary plus samples for a
dashboard. Run it before and after a transport change; compare runs, not absolute numbers.

## 5. Adding a scenario

1. Write `Tools/qa/scenarios/<name>.ndjson`. Start with `auto_reply` for `ping` and
   `client.capabilities`, then `gateway.ready`.
2. Gate every step on a request (`wait_for`) or an answer (`wait_for_response`) — never `sleep`.
3. Add a test in `test_ws.py`: mint a ticket, `Socket.open`, drive it, then assert on **both** sides —
   what the client received and what the gateway recorded (`relay.connection(0)`).
4. Assert the audit record if the scenario touches a security property.
5. `python -m pytest -q Tools/qa/test_ws.py -k <name>` — then the whole suite (scenario parse errors
   are caught by `test_every_scenario_in_the_repo_parses`).
6. If the scenario proves a new invariant, add it to the table in `docs/SECURITY.md`.

## 6. What this does not verify, and what it found

Not covered here:

- **The Swift client.** `GatewayClientActor`, the decoders, the reconnect policy and the UI are tested
  by `Tests/` (and by nothing that runs a socket). This harness tests the *server* end of the contract.
- **The real gateway.** These are recordings and synthetic scripts. Anything Hermes changes after
  v0.22.6 (a new event shape, a different approval payload) is invisible until a fixture is recorded.
  `Tools/record_fixtures.py` produces that recording and its output replays directly (see §1), so the
  refresh loop is: upgrade Hermes → record → drop the file in `Tools/qa/scenarios/` → run the suite.
- **The tailnet leg.** No TLS, no WireGuard, no radio, no ATS. `latency.py` numbers are loopback.
- **APNs, Secure Enclave.** Phase 5 / client-side. Refresh tokens do live in the Keychain already
  (`Apps/HermesMobile/App/Secrets.swift`, `Apps/HermesMac/Pairing/PairingStore.swift`), but this
  harness never reads them.
- **Approval payload shape.** Envelope only, as noted in §2.

Found while building this harness (all recorded in `docs/SECURITY.md`, "gaps"):

1. **Revoking a device does not drop its live socket** (`test_revoking_a_device_drops_its_live_socket`,
   `xfail`). The design promises immediate teardown (`02-architecture.md` §6.5); today revocation
   blocks the next token and the next upgrade, but a connected phone keeps its socket until it
   reconnects. Fix: tag sockets with `device_id` and close them from `DELETE /v1/devices/{id}`.
2. **Gateway close codes are collapsed into `1011`** on the way to the app. Hermes' own `4009`
   (session busy) / `4004` / `4018` family carries meaning; the client cannot distinguish those from
   "gateway restarted". `test_gateway_close_reaches_the_client` accepts either code today and documents
   it (the `4403` in that scenario is illustrative — the recorded fixtures contain no close frames).
3. **A frame split across two WebSocket messages is rejected** (`-32700` per half) rather than
   reassembled. Safe failure, not a live path (the Swift client sends one frame per message), but it
   makes the relay non-transparent for a chunking client.
4. ~~**No per-device socket limit.**~~ Fixed: four relays per device, 64 per process (4429 on the fifth).

## 7. CI

The suite runs in `.github/workflows/ci.yml` (`pytest -q Tools/qa`, after the `bridge` job). It sat next to the existing `bridge`
job (same runner, same install line):

```yaml
      - name: QA harness (replay server + bridge scenarios)
        run: pytest -q Tools/qa
```

It needs only `pytest`, `httpx`, `fastapi`, `uvicorn` and `websockets` — already installed by the
`Install` step of the `bridge` job — and takes about 40 s.
