---
name: hermey-host
description: Install and run a Hermey host (the native apps' backend) on a Hermes box.
version: 1.0.0
author: Assistant
license: MIT
metadata:
  hermes:
    tags: [install, hosting, tailscale, native-apps, hermes]
---

# Hermey host

Hermey is the native iOS/macOS client for a Hermes agent. The apps talk to a **bridge** on your
Hermes host: one loopback HTTP/WS service that relays to the Hermes dashboard. This skill installs
it, pairs a device, and diagnoses it. Repo: `github.com/macblizzard/hermey`.

## Install (one command, as root)

```bash
curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo bash
```

What it does — and what it deliberately does not:

1. Checks the host: Python 3.11+, systemd, and a `hermes` binary (it refuses politely otherwise).
2. Runs the bridge as the owner of your Hermes home — the account that can already read your
   bots — with state in `/var/lib/hermey` (device registry, SQLite, attachments). `HERMEY_USER` names
   a different account if you prefer.
3. Installs the bridge into `/opt/hermey/venv` and runs it as **`hermey-bridge.service`**, bound to
   `127.0.0.1` only.
4. **Reuses the dashboard this host already runs.** Hermes permits exactly one machine-level
   dashboard per host, so the installer reads the running one's port and session token from its
   process environment. Only when none is running does it install **`hermey-gateway.service`**.
5. Exposes the bridge with `tailscale serve --bg --https=8443 http://127.0.0.1:8787` — a real
   certificate, tailnet-only, no public listener.
6. Installs `/usr/local/bin/hermey` for status, pairing, logs, doctor and updates.

Re-running the same command is an **upgrade**: same units, same state, package reinstalled.

## Pair a device

```bash
hermey pair     # prints a fresh code, a hermes:// deep link, and a QR
```

Codes are short-lived, so mint one when the phone is in hand. In the app: add server → scan the QR
or paste the link. The URL to type by hand is `https://<host>.<tailnet>.ts.net:8443`.

## Verify

```bash
hermey doctor   # unit, loopback health, gateway URL, tailscale state, HTTPS through the cert
curl -fsS https://<host>.<tailnet>.ts.net:8443/v1/health
```

A working install answers `{"status":"ok", ...}` on both the loopback and the tailnet URL.

## Pitfalls (each of these cost real time on a live host)

- **Never create a unit called `hermes-gateway.service`.** That is Hermes' *messaging* gateway; the
  collision only surfaces at the next restart, when messaging does not come back. Units here are
  `hermey-*`.
- **One dashboard per host.** A second `hermes dashboard` refuses to start ("this host is already
  served by PID …"). That is why the installer prefers to reuse: run `hermes dashboard --status`
  before assuming you need your own.
- **The bridge must stay on loopback.** Hermes accepts the session token on a loopback WS upgrade
  and refuses it on any other bind; `tailscale serve` is the only front door.
- **iOS needs a trusted cert.** A self-signed endpoint will fail in the app, so use `tailscale serve`
  (or a real domain + Caddy). Do not hand-edit ATS exceptions into the app.
- **Port 8443 may already be taken** by another tailnet service; pass `--https-port 8444` (and
  `--port 8788` for a second bridge) instead of stopping the other service.

## Uninstall

```bash
curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo bash -s -- --uninstall
# add --purge to delete /opt/hermey, /var/lib/hermey and /etc/hermey too
```

`--uninstall` stops the units, removes them, turns the `tailscale serve` mapping off, and keeps your
state and paired devices unless you add `--purge`.
