# Troubleshooting

Start here:

```bash
hermey doctor
```

It reports the unit state, loopback health, the gateway URL the bridge relays to, Tailscale's state,
and whether the HTTPS endpoint answers through the certificate.

## `hermey doctor` says health FAIL

On a **hermeyd** host there is no bridge to answer: the service listens on `127.0.0.1:8788`, so
`curl -fsS http://127.0.0.1:8788/v1/health` is the whole health check, and a `401` from any other
`/v1` route means the caller sent no local bearer (`<state>/local.token`) rather than that the service
is unwell. The rest of this section is the retired bridge's log.

The bridge is not answering on `127.0.0.1:8787`. Read its log; the first line usually names the cause.

```bash
hermey logs 80
```

| Log line | Meaning |
|---|---|
| `address already in use` | something else holds the port — `sudo ss -ltnp \| grep 8787`, then reinstall with `--port 8788` |
| `"event": "upstream_error"` with `"reason": "connect_failed"` in the audit log | the dashboard it relays to is not answering on the port the unit was given, or restarted with a different token; re-run the installer so it re-reads both |
| `No module named hermes_bridge` | the Python bridge, which this page describes, is no longer in the repo — a host on it is running the retired service. See [`HERMEYD.md`](HERMEYD.md) for the host service that replaced it |

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

On a **hermeyd** host there is no port to negotiate: it publishes serve-root
(`tailscale serve --bg http://127.0.0.1:8788`), so pairing URLs carry no `:8443`, and any leftover
`:8443` mount pointing at the retired bridge on `8787` answers 502 — remove it with
`tailscale serve --https=8443 off`.

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

## "There was a problem updating" / an update error in the Mac app

Two different things wear that message.

1. **You checked during the first ten minutes after a release.** The feed and the download are
   published separately: GitHub Pages serves `appcast.xml` for ~10 minutes before it serves the
   `.dmg` it points at, so a check in that window finds a version whose file is still `404`. Nothing
   is wrong with your Mac — check again in ten minutes. The release page is always current even when
   the mirror is not.
2. **A signature that does not verify.** The app trusts exactly one Ed25519 public key
   (`SUPublicEDKey`), so a feed signed with a different key installs nothing. Check without guessing:

   ```bash
   curl -s https://macblizzard.github.io/hermey-downloads/appcast.xml | head -30   # version + signature
   curl -sI https://macblizzard.github.io/hermey-downloads/Hermey-macOS-0.1.580.dmg | head -3
   ```

   The `length=` in the feed must equal the served `content-length`, or the file was replaced after
   the feed was signed.

## The Mac's computer says "Reconnecting" and will not connect

Check whether the host has that Mac revoked — this is what the trash button beside the computer name
does:

```bash
cat /var/lib/hermey/revoked-local-computers.json      # {"revoked": ["<device id>"]}
```

Turning **Let bots use this computer** off and on in the Mac app lifts it (the app calls
`POST /v1/local-computers/<device>/enable`). If it still will not connect, ask the bridge why rather
than the screen:

```bash
journalctl -u hermes-native-bridge --since -10min | grep local_computer.rejected
```

Each line names the check that failed: `no ticket`, `ticket not redeemable`, `device not active`, or
`revoked`.
