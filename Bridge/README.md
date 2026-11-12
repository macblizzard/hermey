# hermes-bridge

Loopback FastAPI service between the native macOS/iOS clients and the Hermes TUI
gateway on the same host. It exists so a phone never holds the gateway's own
credential: the phone gets a short-lived ticket and a narrow JSON-RPC surface,
and the bridge holds the token and the method allow-list.

```
iOS / macOS ──HTTPS/WSS via tailscale serve──▶ 127.0.0.1:8787 (this bridge)
                                                     │  ws://127.0.0.1:8080/api/ws?token=…
                                                     ▼
                                              Hermes gateway
```

## Run

```bash
pip install -e ./Bridge
python -m hermes_bridge                 # or: hermes-bridge
python -m hermes_bridge --help
```

`tailscale serve --bg https / http://127.0.0.1:8787` puts it on the tailnet with
TLS. The bridge refuses to bind anything but loopback, and refuses a gateway URL
that is not loopback (the gateway token must never cross a network).

| Variable | Default | Meaning |
| --- | --- | --- |
| `HERMES_BRIDGE_HOST` | `127.0.0.1` | bind host; non-loopback is refused |
| `HERMES_BRIDGE_PORT` | `8787` | bind port |
| `HERMES_BRIDGE_GATEWAY_URL` | `ws://127.0.0.1:8080/api/ws` | local gateway WS endpoint |
| `HERMES_BRIDGE_GATEWAY_TOKEN` | — | gateway credential; never sent to a client |
| `HERMES_BRIDGE_DB` | `~/.local/state/hermes-bridge/bridge.db` | device registry |
| `HERMES_BRIDGE_FRAME_CAP` | `16777216` | max bytes per JSON-RPC frame (16 MiB ceiling) |
| `HERMES_BRIDGE_MAX_PENDING` | `256` | in-flight client requests per socket |
| `HERMES_BRIDGE_EXTRA_METHODS` | — | comma-separated additions to the allow-list |
| `HERMES_BRIDGE_PUBLIC_HOST` | — (the request's `Host` header) | host shown in `pair/start`; the installer sets it to the tailnet name |

## Endpoints

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/v1/health` | no secrets, no gateway URL |
| POST | `/v1/pair/start` | host-only: loopback **and** no proxy headers |
| POST | `/v1/pair/claim` | 8-digit single-use code, rate limited per source |
| POST | `/v1/token` | refresh token → 15 min access token + 30 s WS ticket |
| GET | `/v1/devices` | authenticated list; ids/names/dates only, never a token or hash |
| DELETE | `/v1/devices/{id}` | authenticated revoke; kills outstanding tickets |
| DELETE | `/v1/devices/{id}/revoked` | permanently removes a revoked device record |
| WS | `/v1/ws?ticket=…` | the JSON-RPC relay |

Device listing, revocation and permanent cleanup require an `Authorization` bearer header
containing a fresh WebSocket ticket from an active paired device. Mint one with
`POST /v1/token` for **each** request; the returned `access_token` is not an
authentication credential. Missing, invalid, expired, replayed, or revoked tickets
return 401. Revocation may target the authenticating device itself; the request is
authorized first, then its refresh token, tickets, and live sockets are invalidated.
Permanent cleanup additionally returns 409 for an active device and 404 for an
unknown device.

## WebSocket relay

Both legs are newline-delimited JSON-RPC 2.0, with one wrinkle the fixtures made
obvious: the gateway's WebSocket transport sends one serialized frame per message
and **no trailing newline** (stdio adds it; WS does not). The relay therefore
treats a message boundary as a frame boundary and also accepts newline batches.
Per connection:

1. The ticket is redeemed **before** `accept`; unknown, expired, reused or
   revoked-device tickets get HTTP 403 and never open a socket.
2. `gateway.ready` is forwarded as-is. The bridge then sends
   `client.capabilities {server_requests: true}` itself, because the bridge (not
   the app) is what answers server requests; the gateway's answer is consumed
   rather than leaked to the app. A client-supplied `client.capabilities` is
   normalized to the same declaration so it cannot disable approvals.
3. Client requests outside `hermes_bridge/policy.py` are answered `-32601` and
   never reach the gateway. `shell.exec`, `cli.exec`, `config.set`, `vault.*`
   are deliberately absent.
4. Gateway requests `approval`, `clarify`, `sudo`, `secret`, `vault.code`,
   `terminal.read` are forwarded; the app's response is routed back under the
   gateway's original id. An id collision with an in-flight request is remapped
   (`brq-N`) and restored on the way back. Anything else is answered `-32601`
   upstream so the agent fails fast instead of hanging.
5. A frame over the cap (16 MiB by default, UTF-8 bytes) closes the socket with `1009`;
   gateway failure is `1011`; a bad ticket is `403` before upgrade.

## Security invariants

- Devices are rows in SQLite; only a SHA-256 of the refresh token is stored.
- Pairing codes and WS tickets are stored as SHA-256 digests, single use.
- Codes are minted only for a request that is really local: a `tailscale serve`
  proxy makes every peer loopback, so proxy headers (`Forwarded`,
  `X-Forwarded-For`, `Tailscale-User-Login`) disqualify a mint.
- Audit records contain `device_id`, `method`, duration and bytes. `AuditLog`
  has no parameter that accepts params, prompts or output, and every free-form
  field is matched against a strict token pattern, so prompt text cannot be
  logged by mistake.
- Uvicorn access logs are disabled by the launcher: the ticket is in the query
  string and access logs would write it to disk.

## Tests

```bash
python -m pytest -q Bridge/tests
```

`tests/fake_gateway.py` is a real WebSocket server on loopback that speaks the
recorded wire format, so the proxy tests exercise actual TCP, NDJSON splitting,
close codes and server→client request routing rather than a mock.

## Known gaps

- One device may hold several concurrent sockets. There is no per-device
  connection cap yet.
