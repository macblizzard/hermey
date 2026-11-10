# Installing a Hermey host

The host is a machine that already runs Hermes. Hermey adds one loopback service to it — the bridge
— and exposes that service through `tailscale serve`.

## The one command

```bash
curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo bash
```

What it does, in order:

1. **Preflight.** Python 3.11+, systemd, and a `hermes` binary it can find. It stops with a clear
   message if any is missing rather than half-installing.
2. **Service account.** The bridge runs as the owner of your Hermes home — the account that can
   already read your bots' profiles, which is exactly what it reports on. `HERMEY_USER` names a
   different account if you prefer (it then needs read access to the profiles directory, granted by
   `HERMES_PROFILES_ROOT`). State goes to `/var/lib/hermey`: device registry, SQLite, attachments.
3. **Bridge.** Installed into `/opt/hermey/venv` from this repo, run as `hermey-bridge.service`
   bound to `127.0.0.1:8787`.
4. **Gateway.** Hermes allows exactly one machine-level dashboard per host, so the installer *reuses*
   the one already running (reading its port and session token from the process environment). Only
   when there is none does it create `hermey-gateway.service`.
5. **TLS and reachability.** `tailscale serve --bg --https=8443 http://127.0.0.1:8787` — a real
   certificate, tailnet only, no public listener. It then verifies the HTTPS endpoint answers.
6. **The `hermey` CLI** in `/usr/local/bin`: `status`, `pair`, `logs`, `doctor`, `update`,
   `uninstall`.

Re-running the same command is an **upgrade**: same units, same state, package reinstalled and
services restarted.

## Pairing

```bash
hermey pair
```

prints a code, a `hermes://pair?host=…&code=…` link and — when the `qrcode` package could be
installed — a QR. Codes are short-lived, so mint one when the phone is in your hand. Pair as many
devices as you like; each is individually revocable.

## Options

Flags are also readable as environment variables, which matters if you are piping the script into a
shell.

| Flag | Env | Default | Meaning |
|---|---|---|---|
| `--port N` | `HERMEY_PORT` | `8787` | bridge port (loopback) |
| `--https-port N` | `HERMEY_HTTPS_PORT` | `8443` | tailnet port for `tailscale serve` |
| `--ref R` | `HERMEY_REF` | `main` | git ref to install (a release tag pins a build; tags are `v<version>`) |
| `--local DIR` | `HERMEY_LOCAL_SRC` | — | install from a checkout instead of GitHub |
| `--no-serve` | `HERMEY_SERVE=no` | auto | do not touch `tailscale serve` |
| `--uninstall` | — | — | remove the units and the serve mapping, keep state |
| `--purge` | — | — | with `--uninstall`: also delete state, config and the service user |

Paths are overridable too: `HERMEY_PREFIX` (`/opt/hermey`), `HERMEY_STATE` (`/var/lib/hermey`),
`HERMEY_CONF` (`/etc/hermey`), `HERMEY_USER` (the owner of the Hermes home),
`HERMEY_UNIT_PREFIX` (`hermey`). The last
two exist so you can run a second isolated instance for testing.

## Without Tailscale

The bridge refuses to listen on anything but loopback — that is a design invariant, not a default.
If the host has no tailnet, put your own TLS proxy in front of `127.0.0.1:8787` (Caddy with a real
certificate is the least work) and pass `--no-serve`. A self-signed certificate will not work: the
apps follow App Transport Security and will refuse it.

## What is on disk

| Path | What |
|---|---|
| `/opt/hermey/venv` | the installed bridge |
| `/var/lib/hermey/bridge.db` | devices, tickets, room attachments index |
| `/var/lib/hermey/room-attachments/` | uploaded files |
| `/etc/hermey/gateway.env` | the loopback gateway token, `0600` (the unit reads it as an `EnvironmentFile`, so the token is never in a world-readable unit file) |
| `/etc/hermey/providers.env` | optional, the same `EnvironmentFile` for voice provider keys |
| `/etc/systemd/system/hermey-bridge.service` | the service |
| `/etc/systemd/system/hermey-gateway.service` | only created when this host had no dashboard |

Never name a unit `hermes-gateway.service`: that is Hermes' own *messaging* gateway, and overwriting
it only surfaces at the next restart, when messaging does not come back.

## Uninstall

```bash
curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo bash -s -- --uninstall
```

Stops and removes the units, turns the `tailscale serve` mapping off, and keeps your state and paired
devices. Add `--purge` to delete `/opt/hermey`, `/var/lib/hermey` and `/etc/hermey` as well.
