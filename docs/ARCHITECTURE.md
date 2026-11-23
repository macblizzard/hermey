# Architecture

Two processes on the host, one in your pocket.

```
┌──────────────┐   HTTPS on the tailnet (tailscale serve, real cert)   ┌────────────────┐
│  iOS / macOS │ ────────────────────────────────────────────────────► │    hermeyd     │
│  Hermey app  │   Authorization: Bearer <ticket, 30 s, single use>     │   Rust + WS    │
└──────────────┘ ◄──────────────────────────────────────────────────── └───────┬────────┘
                                                                               │ ws://127.0.0.1:9121/api/ws
                                                                       ┌───────▼─────────┐
                                                                       │ Hermes engine   │
                                                                       │ (your agents)   │
                                                                       └─────────────────┘
```

## Components

| Piece | Where | Job |
|---|---|---|
| `Apps/HermesMobile` | iOS 17 | phone shell: bot list, conversations, rooms, approvals, voice |
| `Apps/HermesMac` | macOS 14 | three-pane desktop shell over the same packages |
| `Sources/HermesKit` | SwiftPM | protocol, transport, pairing models, message refs |
| `Sources/HermesRender` | SwiftPM | markdown → block model (tables, code, quotes) |
| `Sources/HermeyUI` | SwiftPM | the design system and shared screens |
| `Sources/HermesAppKit` | SwiftPM | shared app state (`AppModel`, refresh, routing) |
| `Sources/HermesA2UI` | SwiftPM | the A2UI surface renderer; `a2ui.surfaces.disabled` turns drawing off |
| `Sources/HermesCards` | SwiftPM | the `::card` renderer (`card.v1`) — **in progress, in no release** |
| `hermeyd/` | Rust | host service: pairing, devices, tickets, the WS relay, attachments, genui, voice |
| `setup/install.sh` | POSIX shell | installs the published `hermeyd` binary (checksum-verified) or builds it |
| `setup/plugins/hermes-genui` | JS bundle | the card plugin the apps load; upstream Hermes does not ship it |

The service contract — every route, every environment variable — is
[`HERMEYD.md`](HERMEYD.md); the mount points are the `.route(...)` calls in `hermeyd/src/main.rs`.

## Why a host service at all

The Hermes engine already speaks JSON-RPC over a WebSocket, but a phone needs things a loopback
engine does not provide: a device identity, revocable credentials, upload/download of attachments,
generated-UI cards, voice synthesis with a real audio MIME type, and a stable HTTP surface where a
WebSocket is not available. hermeyd is that adapter, and nothing more — it holds no agent logic.

The corollary matters: **the apps depend on the protocol, not on the service.** `/v1/*` over HTTP with
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

Two credentials are separate and must not be confused:

- the **device ticket**, above — what an app presents;
- the **local bearer** at `/var/lib/hermeyd/local.token` (`0600`, reminted each boot), which the
  bundled CLIs and any operator on the host present to `/v1/*`. It never leaves the host.

The engine's own per-boot token is a third thing: hermeyd reads it from
`HERMEYD_ENGINE_TOKEN_FILE` and uses it on the relay's WS upgrade. It reaches no client, no log line
and no error body.

## The loopback invariant

hermeyd binds `127.0.0.1` and refuses any other bind at startup, because the engine accepts its token
on a loopback WS upgrade and refuses it elsewhere. The browser channel is a second listener on
`127.0.0.1:8790`, carries no credential, and is never published. Exposure is `tailscale serve`'s job:
a real certificate, tailnet only. Nothing in this repo supports a public listener.

## One gateway per `HERMES_HOME`

Hermes permits exactly one gateway per engine home; a second `hermes gateway run --force` bypasses the
host lock and fires every routine twice. hermeyd detects that at boot and in `hermeyd --gateway-check`,
which exits `75` with the pid, cmdline and remedy. It never kills anything. The engine for a Hermey
host is launched with `hermes serve --isolated`.

## State

`/var/lib/hermeyd/bridge.db` holds the device registry, ticket state and the small collections the apps
own; `/var/lib/hermeyd/attachments/` holds uploaded files. Deleting the state unpairs every device —
which is the intended way to start over.
