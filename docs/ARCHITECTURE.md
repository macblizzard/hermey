# Architecture

Two processes on the host, one in your pocket.

```
┌──────────────┐   HTTPS on the tailnet (tailscale serve, real cert)   ┌────────────────┐
│  iOS / macOS │ ────────────────────────────────────────────────────► │  hermey-bridge │
│  Hermey app  │   Authorization: Bearer <single-use ticket, 30 s>      │  FastAPI + WS  │
└──────────────┘ ◄──────────────────────────────────────────────────── └───────┬────────┘
                                                                               │ ws://127.0.0.1:<port>/api/ws
                                                                       ┌───────▼────────┐
                                                                       │ Hermes dashboard│
                                                                       └────────────────┘
```

## Components

| Piece | Where | Job |
|---|---|---|
| `Apps/HermesMobile` | iOS 17 | phone shell: bot list, conversations, rooms, approvals, voice |
| `Apps/HermesMac` | macOS 14 | three-pane desktop shell over the same packages |
| `Sources/HermesKit` | SwiftPM | protocol, transport, pairing models, message refs |
| `Sources/HermesRender` | SwiftPM | markdown → block model (tables, code, quotes) |
| `Sources/OpenBotUI` | SwiftPM | the design system and shared screens |
| `Sources/HermesAppKit` | SwiftPM | shared app state (`AppModel`, refresh, routing) |
| `Bridge/` | Python 3.11 | host API: pairing, devices, tickets, rooms, attachments, voice |
| `setup/install.sh` | shell | the one command that puts the bridge on a host |

## Why a bridge at all

The Hermes dashboard already speaks JSON-RPC over a WebSocket, but a phone needs things a loopback
dashboard does not provide: a device identity, revocable credentials, upload/download of attachments,
voice synthesis with a real audio MIME type, and a stable HTTP surface where a WebSocket is not
available. The bridge is that adapter, and nothing more — it holds no agent logic.

The corollary matters: **the apps depend on the protocol, not on the bridge.** `/v1/*` over HTTP with
a bearer ticket is a contract; the process that serves it could move without the apps noticing.

## Auth flow

1. `POST /v1/pair/start` on the host (loopback only) mints a short numeric code.
2. The app posts the code plus its public key to `/v1/pair/claim`; the host registers a device and
   returns a refresh token.
3. Every subsequent request first calls `POST /v1/token` for a **30-second, single-use** bearer
   ticket, then the route redeems it. A ticket is consumed by exactly one request; it is never a
   session credential and it never appears in a response.
4. Revoking a device drops its outstanding tickets *and* fails the active-device check, so a revoke
   lands even in the window where a ticket was already minted.

The upstream dashboard token is separate, lives in `/etc/hermey/gateway.env` (`0600`) and never
reaches a client, a log line or an error body.

## The loopback invariant

The bridge binds `127.0.0.1` and refuses any other bind at startup, because Hermes accepts its
session token on a loopback WS upgrade and refuses it elsewhere. Exposure is `tailscale serve`'s job:
a real certificate, tailnet only. Nothing in this repo supports a public listener.

## One dashboard per host

Hermes permits exactly one machine-level dashboard per host; a second `hermes dashboard` refuses to
start. The installer therefore discovers a running dashboard first (`hermes dashboard --status`, then
the port and token from its process environment) and only starts its own when there is none.

## State

`/var/lib/hermey/bridge.db` holds the device registry, ticket state and the room-attachment index;
`/var/lib/hermey/room-attachments/` holds the files. Deleting the state unpairs every device — which
is the intended way to start over.
