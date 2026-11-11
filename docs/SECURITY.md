# Security model and threat model

The client puts a phone on a host that can run shell commands, read a vault and edit files. The whole
security design is one sentence: **the tailnet is the wall, the device is the identity, and the client
can only answer questions the agent asks — never give itself permission.**

This document states the trust boundaries, the invariants that hold them up, the threats those
invariants are for, and the evidence (a test, or an explicit gap) for each one.

Scope: `Bridge/hermes_bridge` (the only new server-side code), the `wss://` path into it, and the
approval semantics the client relies on. The Swift apps' own storage (a this-device-only Keychain
item, or a `0600` file on the unsigned Mac build) is described where it matters, but not audited
here.

## 1. Trust boundaries

```
┌── iPhone / Mac ─────────────┐        ┌── hermes (100.64.0.1) ─────────────────────────────┐
│ Ed25519 key in Keychain     │        │  tailscale serve :8443  ──TLS 1.3──►  127.0.0.1:8787 │
│ refresh token in Keychain   │        │                                        │            │
│  ── 30 s WS ticket ─────────┼── wss ─┼─► hermes_bridge (FastAPI, loopback only)           │
│                             │        │        │ allow-list, frame cap, audit              │
└─────────────────────────────┘        │        ▼                                            │
                                       │  127.0.0.1:9120/api/ws  (Hermes TUI gateway)        │
                                       │  agent runtime · tools · approvals · vault          │
                                       └─────────────────────────────────────────────────────┘
```

The Mac build ships unsigned and has no keychain entitlement, so it keeps those same items in a
`0600` file under `~/Library/Application Support/Hermey/`, excluded from backups; the phone uses the
Keychain alone.

| Boundary | Crossing it requires | What is on the other side |
|---|---|---|
| Public internet → tailnet | Tailscale identity + ACL | nothing (no public ingress exists) |
| Tailnet → bridge | TLS to `tailscale serve`, then a **single-use 30 s ticket** | pairing, tokens, `/v1/ws` |
| Bridge → gateway | loopback + the **gateway token** (never sent to a device) | full authority over the agent |
| Gateway → app | a server→client JSON-RPC request (approval, clarify, sudo, secret…) | a human decision |
| App → gateway | the **client method allow-list** | sessions, prompts, discovery |

Three consequences worth stating plainly:

- **A compromised device is a compromised *user*, not a compromised host.** The allow-list has no
  `shell.exec`, `cli.exec`, `config.set` or `vault.*`; the worst a stolen phone can do is drive
  sessions the user could drive anyway, and answer approvals — which is why approvals are rendered,
  not auto-accepted.
- **A compromised bridge is already root on the box.** Loopback-only, token-gated and audited, but it
  adds no privilege; the point is that it does not *widen* what an attacker on the host can do.
- **The tailnet is the outer wall.** Every control below assumes an attacker who is already on the
  tailnet or has stolen a device; controls that assume "nobody can reach the port" are marked as such.

## 2. Invariants, and the test that holds each one

Every row is enforced in code and pinned by a test in `Tools/qa` (run with
`python -m pytest -q Tools/qa`).

| # | Invariant | Where | Test |
|---|---|---|---|
| 1 | The bridge refuses to bind anything but loopback, and refuses a non-loopback gateway URL | `config.validate()`, `__main__` | `test_config.py` |
| 2 | Pairing codes are minted **only for a direct host-local caller** — a request carrying `Forwarded`/`X-Forwarded-For`/`Tailscale-User-Login` is refused even though its peer address is loopback | `app._is_local_host_request` | `test_pairing_codes_cannot_be_minted_through_a_proxy` |
| 3 | Pairing codes: 8 digits, **600 s** (`HERMES_BRIDGE_PAIRING_TTL`), **single use**, stored as SHA-256, max 64 outstanding | `tickets.PairingCodes` | `test_pairing_code_is_single_use`, `test_pairing_code_expires` |
| 4 | Pairing claims are throttled per source (**10 / 60 s**, then `429` + `Retry-After`) | `tickets.AttemptThrottle` | `test_pairing_codes_are_rate_limited` |
| 5 | A public key must be a real 32-byte Ed25519 key (base64/urlsafe, padding optional) — placeholders and private keys are refused | `pairing.normalize_public_key` | `test_a_placeholder_public_key_is_rejected` |
| 6 | At most 32 active devices | `app.MAX_DEVICES` | `test_the_device_limit_is_enforced` |
| 7 | A refresh token is 256-bit, stored **only as SHA-256**, compared in constant time; the plaintext is not in `bridge.db` | `registry.hash_token` / `token_matches` | `test_the_refresh_token_is_stored_hashed_and_never_on_disk` |
| 8 | A refresh token is bound to its `device_id`: one without the other is useless | `registry.verify_refresh` | `test_a_token_for_another_device_is_refused`, `test_a_bad_refresh_token_is_refused` |
| 9 | Revocation is immediate for **new** tokens and new upgrades | `registry.revoke`, `tickets.revoke_device` | `test_a_revoked_device_cannot_mint_tokens`, `test_revoking_a_device_kills_its_unused_ticket` |
| 10 | WS tickets are **single use** and consumed *before* `accept()` — an aborted handshake cannot replay one | `app.ws_proxy`, `tickets.TicketStore.redeem` | `test_ticket_is_spent_by_the_first_upgrade` |
| 11 | Tickets live **30 s**, are 256-bit, and are bound to one device | `tickets.TicketStore` | `test_ticket_ttl_is_thirty_seconds`, `test_expired_ticket_is_refused`, `test_tickets_are_unique_and_long` |
| 12 | An invalid, expired, missing or revoked-device ticket is refused **before the gateway is dialled** (no upstream amplification) | `app.ws_proxy` | `test_expired_ticket_is_refused`, `test_missing_ticket_is_refused`, `test_ticket_used_by_a_different_upgrade_after_revoke_is_refused` |
| 13 | Client requests outside the allow-list are answered `-32601` and **never forwarded** | `policy.CLIENT_METHODS`, `proxy._handle_client_request` | `test_methods_outside_the_allow_list_are_refused_by_the_bridge`, `test_dangerous_methods_never_reach_the_gateway_or_the_audit` |
| 14 | Method names are validated as tokens (`^[A-Za-z][A-Za-z0-9_.-]{0,63}$`) before the allow-list | `policy.is_valid_method_name` | `test_method_names_are_validated_before_the_allow_list` |
| 15 | Gateway→app requests outside `SERVER_REQUEST_METHODS` are answered `-32601` by the bridge, so the agent fails fast | `proxy._handle_server_request` | `test_unsupported_server_requests_are_answered_by_the_bridge` |
| 16 | **Approvals stay enabled**: the bridge announces `client.capabilities {server_requests: true}` itself, and *forces* it on a client that asks for less | `proxy._send_capabilities`, `_handle_client_request` | `test_ready_is_forwarded_and_the_bridge_announces_its_own_capabilities`, `test_a_client_cannot_narrow_the_server_requests_capability` |
| 17 | A server request blocks the agent until the app answers (or the bridge declines) — nothing auto-answers | `proxy` + `scenarios/turn-approval.ndjson` | `test_approval_round_trip_blocks_the_agent_until_answered`, `test_declining_an_approval_fails_the_tool` |
| 18 | A server-request id that collides with an in-flight client id is remapped for the app and **restored** upstream | `proxy._handle_server_request` | `test_a_server_request_with_a_colliding_id_is_remapped_and_restored` |
| 19 | A stale answer (unknown id, e.g. from a second device) is dropped, audited, and not forwarded | `proxy._handle_client_response` | `test_a_stale_answer_is_dropped_and_not_forwarded` |
| 20 | Every frame is capped at **1 MiB** (configurable, hard max 16 MiB) **in both directions**; an oversize frame is never forwarded and closes with `1009` | `config.frame_cap`, `proxy.split_frames` | `test_oversized_client_frame_is_refused_and_never_forwarded`, `test_oversized_gateway_frame_is_not_relayed`, `test_oversized_binary_frame_cannot_bypass_the_cap` |
| 21 | The **gateway token** is used only in the upstream dial URI (loopback) — never in a response, an error string, the audit log, or a frame sent to a device | `config.upstream_url`, `AuditLog` | `test_the_gateway_token_is_not_exposed_by_any_http_surface`, `test_the_gateway_token_travels_upstream_only` |
| 22 | The audit log records **device, method, direction, duration, bytes** and nothing else — no params, no prompt text, no tool output, no tokens, no ids | `audit.AuditLog.emit` (no parameter for payload), closed key set | `test_the_audit_log_records_the_turn_but_none_of_its_text`, `test_audit_records_have_a_closed_key_set_and_scalar_values`, `test_the_audit_never_contains_a_token_or_ticket` |
| 23 | A device cannot read another device's secrets from the API: `/v1/devices` returns no token, hash or public key | `app.devices` | `test_the_refresh_token_is_stored_hashed_and_never_on_disk` |
| 24 | HTTP responses under `/v1/` are `no-store` with `nosniff` | `app.no_store` | `test_health_reports_protocol_and_ws` |

## 3. Threat model

Format: **threat → what the attacker wants → control → residual risk**. The tests named above are the
evidence; this table is the reasoning.

| # | Threat | Goal | Control | Residual risk |
|---|---|---|---|---|
| T1 | A device on the tailnet that was never paired | drive the agent | `/v1/ws` requires a ticket from `/v1/token`, which requires a refresh token from a pairing claim; a claim requires a code only the host can mint (invariant 2, 10–12) | a tailnet member can still reach `/v1/health` and `/v1/pair/claim` (see T2) |
| T2 | Brute force of the 8-digit pairing code | pair an unauthorised device | 600 s TTL, single use, 64 outstanding max, **10 attempts/minute/source** (invariant 3–4). One source gets ~10 guesses per 60 s window against 10⁸ codes: a 1-in-5 000 000 chance per code | throttling is per source address; an attacker holding 1 000 tailnet addresses gets ~20 000 guesses per window — a 1-in-5 000 chance per code, and a missed code is dead. Holding 1 000 tailnet identities is already a different incident |
| T3 | Stolen `bridge.db` (backup, misconfigured permissions, root on host) | mint tokens | refresh tokens are SHA-256 only (invariant 7); no gateway token in the DB | root on the host is game over regardless (A1) |
| T4 | Stolen refresh token (malware on the phone, backup extraction) | impersonate the device | the token is useless without the `device_id`, which is not secret — **so a stolen token *is* enough** (invariant 8 is integrity, not proof-of-possession) | see **G1**: no signed assertion. Mitigation today is revocation + 15 min access tokens |
| T5 | Replay of a captured WS URL | hijack a session | 30 s TTL, single use, consumed before accept (invariant 10–11); TLS prevents capture in transit | a ticket captured *from the phone's memory* within 30 s is usable once — that requires code execution on the device |
| T6 | Compromised client asks the bridge for more than the UI shows | shell access | allow-list (`shell.exec`, `cli.exec`, `config.set`, `vault.*` absent) and no generic proxy (invariant 13–14) | a compromised client can still `prompt.submit` — i.e. ask the *agent* to run something, which then needs an approval the user sees (T8) |
| T7 | Malicious/compromised gateway asks the app for something it cannot render | stall the agent, or phish the user | the bridge answers anything outside the six approved methods with `-32601` (invariant 15) | none material: fail-fast is the desired behaviour |
| T8 | Approval fatigue / social engineering (the real risk) | get a destructive action approved | approvals are shown with tool + input + reason; `declines_not_shown` stays true; **nothing auto-approves**; the client cannot widen permissions (invariant 16–17) | the human is the control. Show the command, not just the tool name |
| T9 | Oversize frame / memory exhaustion | DoS the bridge or the agent | 1 MiB per frame both directions, close `1009`, never forwarded (invariant 20) | many small frames are still work; no per-device socket or bandwidth quota (**G4**) |
| T10 | Prompt text or tool output leaks into logs / journald / a bug report | read the user's data | `AuditLog.emit` has no parameter for payload and validates every free-form field against a token pattern; verified with a canary through a real turn (invariant 22) | uvicorn access logs are off (`access_log=False`) but an operator can enable debug logging on the *gateway* |
| T11 | Gateway token exfiltration | full agent authority | token never leaves the process except in the loopback dial URI; never in responses or audit (invariant 21) | a host-level reader (`/proc/…/environ`) can still see it — root on host |
| T12 | Revoked (lost/stolen) device keeps acting | persist access | refresh + tickets are refused immediately (invariant 9, 12) | **the live socket stays open until it reconnects — G2** |
| T13 | Client forges another device's server-request id to answer its approval | approve something the user never saw | ids are per-socket and remapped on collision; a stale answer is dropped (invariant 18–19) | within one socket the app *is* the user; there is no second authenticator by design |
| T14 | Relay is used as a general-purpose proxy into the host | lateral movement | allow-list both directions, no arbitrary URL/method pass-through, no file or shell surface | the agent itself is the powerful surface — that is the product |
| T15 | Protocol smuggling (weird method names, `\n` injection, binary frames) | bypass the allow-list | method names are regex-validated; frames are split and re-serialised per frame; binary frames are parsed as bytes and still capped; invalid JSON gets `-32700` and is not forwarded | a frame split across two WS messages is rejected rather than reassembled — safe failure (**G3**) |

Accepted risks (by design, not bugs):

- **A1** Anyone who is root on the host owns the agent; the bridge adds no privilege.
- **A2** A paired device can read that profile's sessions. There is no per-session ACL; the user model
  is "my devices, my agent".
- **A3** Pairing is a shared secret shown on the host. Shoulder-surfing a QR code within its 600 s
  lifetime is a physical-security problem.
- **A4** The tailnet ACL is not enforced by this code. If a device is on the tailnet and not blocked by
  ACLs, it can reach `/v1/health` and attempt claims (T2 covers the cost).

## 4. Gaps

Each is a real difference between the design and the implementation, with the impact and the fix.
`test_*` names refer to `Tools/qa`.

**G1 — no proof-of-possession on the token exchange (medium).** `POST /v1/token` accepts
`{device_id, refresh_token}`; the Ed25519 key registered at pairing is stored but never used to verify
a signed assertion (`02-architecture.md` §6.4 asks for one). A stolen refresh token is therefore a
bearer credential. *Fix:* sign `{device_id, timestamp, nonce}` with the device key, verify with the
stored public key, reject clock skew > 60 s, and rate-limit per device. Until then, keep the refresh
token in the Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and rely on revocation. The
unsigned Mac build cannot use the Keychain, so there it lives in the `0600` file described above.

**G2 — revoking a device does not drop its live socket (medium).**
`test_revoking_a_device_drops_its_live_socket` is `xfail`. Revocation blocks the next token and the
next upgrade, but a connected client keeps its socket until it reconnects. *Fix:* keep a
`device_id → set[socket]` map in the app runtime and close them from `DELETE /v1/devices/{id}` with
`4401`.

**G3 — a frame split across WebSocket messages is rejected, not reassembled (low).**
`test_a_chunked_frame_is_rejected_rather_than_half_forwarded` pins the behaviour: each half gets
`-32700`, nothing is forwarded. The Swift client sends one frame per message
(`JSONRPCCodec.encodeFrame`), and the gateway's WS transport does the same, so this is not a live path.
*Fix if it ever matters:* accumulate a partial buffer with the same 1 MiB ceiling.

**G4 — no per-device socket or request quota (low).** The bridge caps `max_pending_requests` per
socket (256) and the ticket store at 1 024 pending tickets, but one device can open many sockets, each
with its own upstream connection. *Fix:* per-device socket limit (2 is enough for a phone + a
reconnect overlap) and a per-device connection rate limit.

**G5 — gateway close codes are collapsed into `1011` (low, UX).** When the gateway closes with one of
Hermes' own codes (`4009` session busy, `4004`, `4018` …), the app sees `1011 "gateway closed"` and
cannot tell a busy session from a gateway restart. `test_gateway_close_reaches_the_client` accepts
either code today. *Fix:* forward the upstream close code when it is in the app's known set, else
`1011`. (The `4403` used by that scenario is illustrative; the recorded fixtures contain no close
frames.)

**G6 — approval payload shapes are unverified (informational).** No approval frame exists in
`fixtures/`, so `params.choices`/`call_id` in the scenarios are modelled from the architecture doc.
The envelope and blocking semantics are tested; the field names are not. *Fix:* record one real
approval from the live gateway into `fixtures/approval.ndjson` and diff.

**G7 — pairing-code throttle is per source address (informational).** See T2. Sufficient while the
tailnet is small and ACL'd; a global counter plus a per-device backoff would be stronger.

## 5. Operating it

**Start** (only this way — it validates the bind address before uvicorn sees it):

```bash
HERMES_BRIDGE_GATEWAY_TOKEN=… python -m hermes_bridge --port 8787
tailscale serve --bg --https=8443 http://127.0.0.1:8787
```

Refuses to start if `HERMES_BRIDGE_HOST` is not loopback, or if the gateway URL is not loopback, or has
no path.

**Rotate the gateway token:** stop the bridge, rotate the token on the gateway side, update
`HERMES_BRIDGE_GATEWAY_TOKEN`, start. Live sockets drop with `1011`; the app reconnects with a fresh
ticket. No device has to re-pair.

**Revoke a device:** `DELETE /v1/devices/{id}` (or the app's device list). Kills the refresh token and
any unused ticket immediately; the live socket survives until reconnect (G2) — if that matters,
restart the bridge or rotate the gateway token, both of which close every socket.

**Read the audit log:** one JSON object per line on the `hermes_bridge.audit` logger. Fields:
`ts, event, device, method, bytes, duration_ms, direction, outcome, reason, close_code`. Event names are
a closed set (`audit.EVENTS`), so a typo fails a test instead of shipping silently. Look for
`ticket_rejected`, `client_request_rejected`, `server_request_declined` and `frame_too_large` — those
are the four signals that something is probing the bridge.

**Incident: a device is compromised.** Revoke it, rotate the gateway token (closes every live socket),
check the audit for `client_request` from that `device` around the compromise window, and review which
approvals were answered (`server_response`) in that window — the bridge records that an approval was
answered, never what the prompt said.

## 6. What is deliberately absent

No accounts, no telemetry, no cloud relay, no public ingress, no second copy of your data, no
"danger-full-access" default, no auto-approve, no per-device passwords, and no way for the client to
escalate its own permissions. The bridge is ~1.8k lines of Python that can be read in an afternoon,
which is the point.


## Bot-to-bot messages

`POST /v1/bots/{profile}/message` lets the agent on the host speak into another bot's chat, in the
session the apps open. It is **loopback only** (off-host it answers 404, like any unknown route), it
mints no ticket and writes no device row, and it refuses a profile with no stored conversation
rather than creating one nobody can find. The audit log records the pair and whether a reply came
back — never the words, which are the owner's conversation. A paired device does not need this
route: it types into the chat itself, and letting a phone impersonate another bot would hand it a
privilege it has no use for.

## Threat model, stated plainly (2026-11 audit)

Three things this bridge does *not* defend against, written down because a reader of the allow-list
could otherwise conclude the opposite:

- **A paired device is a root-equivalent credential.** The method allow-list stops a client calling
  `shell.exec` directly, but `prompt.submit` is allowed, and the agent's own tool loop can run
  commands — including approvals, which the bridge relays to the socket that submitted the prompt.
  Treat a device ticket like an SSH key to the host, not like a scoped API key. The smallest real
  fix is a host-side confirmation for `approval`/`sudo`; until then, revoke a device you no longer
  control immediately.
- **The Ed25519 key is recorded, not verified.** Pairing stores the device's public key, and
  `/v1/token` exchanges the refresh token without a challenge, so the key proves nothing today: a
  stolen refresh token is usable from any host. Either implement nonce + signature on `/v1/token`,
  or treat the refresh token as the whole credential (which is what the code does).
- **Device revocation is a shared secret's power.** Any paired device can revoke any other. That adds
  no reach a ticket does not already have (see the first point) — it is listed so nobody mistakes the
  device list for an authorisation boundary.

## Bot management (paired device)

A paired device can now create, disable and delete bots, and rewrite any bot's `SOUL.md`. This is a
deliberate widening of the device's reach, and it is small in practice because a paired device is
already root-equivalent (a device ticket buys shell access, see the threat model above). What the
new verbs add is *authority over other bots*, not reach outside the host.

- **SOUL.md** is written through `profiles.configure` (soul section only) and capped at 64,000
  characters in the bridge's allow-list: a SOUL.md is injected into every turn of that bot, so an
  accidental megabyte paste would be paid for on every message it ever answers.
- **Disable** pauses the bot's scheduled jobs through the loopback dashboard and records which job
  ids it paused in the bridge's state directory (`/var/lib/hermes-bridge/disabled-bots.json`), so
  enabling resumes exactly those. A disabled bot also refuses `POST /v1/bots/{profile}/message`:
  otherwise another bot could make a disabled bot answer.
- **Delete** goes through the dashboard's own `DELETE /api/profiles/{name}` — the process that owns
  tombstones, multiplexer release and alias cleanup — after the bridge tars the profile into
  `/var/lib/hermes-bridge/deleted-bots`. The archive is a mistake-catcher, not a backup contract.
- The bridge still runs under `ProtectSystem=strict` with only `/var/lib/hermes-bridge` writable.
  Nothing here widened that: management verbs are asked of the dashboard, which runs unconfined.

## Bot computer (shared desktop)

One headless desktop serves every bot on the host, on purpose: one Xvnc, one Chromium user-data-dir,
one control lease. The consequences, stated rather than implied:

- **Logins are shared.** A site signed into during a takeover is signed in for every bot on that
  host, and in every later session until the site expires it. That is the feature; it also means a
  bot can act on any site you signed in to.
- **The lease is a tool-level fence, not an OS one.** While a human holds it, `computer_use` and the
  browser tools are refused (`human_has_control`), but a process the agent starts by hand against
  the published `DISPLAY` is inside the documented same-user boundary.
- **The viewer path.** `/v1/display/*` is device-authenticated with the same single-use ticket as
  every other route; `observe` mints a bridge ticket (60 s, single use, bound to device + profile)
  and holds the gateway's own ticket inside the process. The socket carries its ticket in the query
  string because noVNC cannot set a header — the same trade-off the dashboard makes, with the same
  one-minute lifetime. Revoking a device closes an open viewer.
- **Audit** records `display_open` / `display_close` with device, profile, close code and byte
  count — never frame content, because a screen shows passwords.
