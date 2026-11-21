---
name: hermey-host
description: Install and run a Hermey host (the native apps' backend) on a Hermes box.
version: 2.0.0
author: Assistant
license: MIT
metadata:
  hermes:
    tags: [install, hosting, tailscale, native-apps, hermes]
---

# Hermey host

Hermey is the native iOS/macOS client for a Hermes agent. The apps talk to **hermeyd** on your Hermes
host: one loopback HTTP/WS service, a single Rust binary, that relays the engine's WebSocket. This
skill installs it, pairs a device, and diagnoses it. Repo: `github.com/macblizzard/hermey`.

Contract and environment: [`docs/HERMEYD.md`](../docs/HERMEYD.md). Install reference and every flag:
[`docs/INSTALL.md`](../docs/INSTALL.md).

## Install (one command, as root)

```bash
curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo sh
```

What it does — and what it deliberately does not:

1. Detects Linux x86_64/aarch64 or macOS arm64/x86_64 and refuses anything else with the supported
   list plus the from-source alternative.
2. Downloads the matching `hermeyd` binary **plus `SHA256SUMS`, and verifies the SHA-256 before
   installing**. A missing or mismatched entry aborts with nothing installed.
3. Installs `/opt/hermey/bin/hermeyd`, state at `/var/lib/hermeyd` (`0700`), and
   `/etc/hermey/hermeyd.env` (ports, engine home, token path, public host).
4. Installs the systemd unit (Linux) or writes the launchd plist and prints the two load commands
   (macOS). The service runs as the engine's owner: it must share that UID, because it writes skills
   into the engine's profiles.
5. Installs the **`hermes-genui`** plugin into `<engine>/plugins/hermes-genui`. Upstream Hermes does
   not ship it; without it every generated-UI card answers `503`.
6. Runs `hermeyd --gateway-check`. Exit `75` means another gateway already serves this `HERMES_HOME`
   — a warning, with the remedy, not a failure.
7. Publishes the service with `tailscale serve --bg http://127.0.0.1:8788` — the serve root, so
   pairing URLs carry no port — sets `HERMEYD_PUBLIC_HOST` to the node's MagicDNS name, and prints a
   pairing code and URL. Only where it cannot act does it print the command instead: no `tailscale`,
   no logged-in node, or a serve root another service owns. `--no-serve` skips publishing.

`--from-source` builds with `cargo build --release --locked` from a checkout instead of downloading.

Re-running the same command is an **upgrade**: same paths, same state, new binary, unit and plugin.

Three requirements, each of which fails in a way that does not look like setup:

- **One gateway per `HERMES_HOME`.** Start the engine with `hermes serve --isolated`; a duplicate
  ticker fires every routine twice.
- **hermeyd and the engine share a UID.**
- **The `hermes-genui` plugin is ours**, not upstream's.

## Pair a device

```bash
curl -fsS -X POST http://127.0.0.1:8788/v1/pair/start
# {"code":"12345678","host":"…","expires_at":…}
```

`/v1/pair/start` answers on loopback only. Codes are short-lived, so mint one with the phone in hand.
In the app: add server → this host's tailnet name → enter the code. Pair as many devices as you like;
each is individually revocable.

## Verify

```bash
curl -fsS http://127.0.0.1:8788/v1/health                         # unauthenticated liveness
TOKEN=$(sudo cat /var/lib/hermeyd/local.token)                   # 0600, minted on boot
curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8788/v1/local-computers
curl -fsS "https://$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')/v1/health"
sudo HERMEY_HOME=/var/lib/hermeyd hermeyd --gateway-check; echo $?   # 0 good, 75 duplicate
```

A working install answers `{"status":"ok", …}` on both the loopback and the tailnet URL.

## Pitfalls (each of these cost real time on a live host)

- **Never create a unit called `hermes-gateway.service`.** That is Hermes' *messaging* gateway; the
  collision only surfaces at the next restart, when messaging does not come back.
- **One gateway per `HERMES_HOME`.** A second `hermes gateway run --force` bypasses the host lock and
  duplicates every routine. Use `serve --isolated`, and read `hermeyd --gateway-check`'s exit code.
- **hermeyd stays on loopback.** `HERMEYD_BIND` accepts only loopback values and the process refuses
  anything else; `tailscale serve` is the front door.
- **Do not publish `8790`.** That is the browser channel, it carries no credential, and it is
  loopback-only by design.
- **iOS needs a trusted cert.** A self-signed endpoint fails in the app; use `tailscale serve` (or a
  real domain + Caddy). Do not hand-edit ATS exceptions into the app.

## Uninstall

```bash
curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo sh -s -- --uninstall
# add --purge to delete /var/lib/hermeyd too
```

`--uninstall` stops and removes the unit, the binary, the config and the plugin, and keeps state and
paired devices unless you add `--purge`. It also reminds you to take down the `tailscale serve`
mapping, which it never created.
