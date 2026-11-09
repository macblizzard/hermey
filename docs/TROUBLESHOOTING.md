# Troubleshooting

Start here:

```bash
hermey doctor
```

It reports the unit state, loopback health, the gateway URL the bridge relays to, Tailscale's state,
and whether the HTTPS endpoint answers through the certificate.

## `hermey doctor` says health FAIL

The bridge is not answering on `127.0.0.1:8787`. Read its log; the first line usually names the cause.

```bash
hermey logs 80
```

| Log line | Meaning |
|---|---|
| `address already in use` | something else holds the port — `sudo ss -ltnp \| grep 8787`, then reinstall with `--port 8788` |
| `"event": "upstream_error"` with `"reason": "connect_failed"` in the audit log | the dashboard it relays to is not answering on the port the unit was given, or restarted with a different token; re-run the installer so it re-reads both |
| `No module named hermes_bridge` | the venv is broken; re-run the installer (it reinstalls) |

## The dashboard already exists / "reusing this host's dashboard: pid …"

Expected. Hermes allows one dashboard per host, and the installer reuses it. If you need a second,
isolated one for testing, use `HERMEY_UNIT_PREFIX` and a separate `HERMEY_CONF`, and point the second
bridge at a dashboard you started with `--isolated`.

## `tailscale serve` refused

```bash
tailscale status          # is this node up and logged in?
tailscale serve status    # what is already published on 8443?
```

If another service owns 8443, re-run the installer with `--https-port 8444`. Do not stop the other
service to make room.

## HTTPS check fails but the bridge is healthy

Tailscale issues the certificate on first use; a fresh domain can take a minute. If it persists:

```bash
tailscale cert <host>.<tailnet>.ts.net
curl -v https://<host>.<tailnet>.ts.net:8443/v1/health
```

## The app cannot reach the host

- Is the phone on the tailnet? (Tailscale app installed, logged into the same tailnet.)
- Does the URL in the app exactly match `hermey pair`'s output, including the port?
- `curl https://<host>.<tailnet>.ts.net:8443/v1/health` from another tailnet device — if that fails,
  the problem is the host, not the app.

## A pairing code is rejected

Codes are single-use and expire in minutes. Mint a fresh one with `hermey pair`. Repeated failures
are rate limited per client, so wait a moment after a handful of attempts.

## The iOS app stops launching after a week

That is free-Apple-ID signing, not a bug. Re-sign through AltStore/SideStore, or use a paid developer
account for a one-year profile. See [`APPS.md`](APPS.md).

## macOS says the app is damaged or from an unidentified developer

The build is unsigned. Right-click → Open the first time, or once:

```bash
xattr -dr com.apple.quarantine /Applications/Hermey.app
```
