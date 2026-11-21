# Troubleshooting

Start here:

```bash
systemctl status hermeyd --no-pager        # macOS: launchctl print system/com.hermeyd
curl -fsS http://127.0.0.1:8788/v1/health
sudo journalctl -u hermeyd -n 80 --no-pager
```

That is the unit state, liveness, and the log. `{"status":"ok", …}` on `8788` means the service is
up; a `401` from any other `/v1` route means the caller sent no local bearer
(`/var/lib/hermeyd/local.token`) rather than that the service is unwell.

## The service will not start, or restarts in a loop

| Log line | Meaning |
|---|---|
| `address already in use` | something else holds the port — `sudo ss -ltnp \| grep -E '8788\|8790'`; change `HERMEYD_PORT`/`HERMEYD_BROWSER_PORT` in `/etc/hermey/hermeyd.env` and restart |
| `hermeyd refuses HERMEYD_BROWSER_PORT=…` | the browser channel was given the published port; they must differ |
| `hermeyd refuses to bind …` | `HERMEYD_BIND` is not loopback. Only `127.0.0.1`, `::1` or `localhost` are accepted |
| `"event":"upstream_error"`, `"reason":"connect_failed"` in the audit log | the engine is not answering on `ws://127.0.0.1:9121/api/ws`, or restarted with a different token. Start it with `hermes serve --isolated`; check `HERMEYD_ENGINE_WS` and `HERMEYD_ENGINE_TOKEN_FILE` |
| `Permission denied` on a profile or skill file | hermeyd runs as a different UID from the engine's owner. It must share that UID — see [`INSTALL.md`](INSTALL.md) |

After editing `/etc/hermey/hermeyd.env`: `sudo systemctl restart hermeyd` (macOS:
`sudo launchctl kickstart -k system/com.hermeyd`).

## `hermeyd --gateway-check` exits 75

A second Hermes gateway already serves this `HERMES_HOME`, so every routine would fire twice. Nothing
was killed. Either stop that process, or run the engine isolated for this home:

```bash
hermes serve --isolated
```

The check is `sudo HERMEY_HOME=/var/lib/hermeyd HERMEYD_ENGINE_HOME=<engine> hermeyd --gateway-check`;
exit `75` is the duplicate, anything else non-zero is a different failure the output names.

## `tailscale serve` refused

```bash
tailscale status          # is this node up and logged in?
tailscale serve status    # what is already published?
```

hermeyd publishes serve-root — `tailscale serve --bg http://127.0.0.1:8788` — so pairing URLs carry
no `:8443`. A leftover `:8443` mount from the old port scheme answers `502`; remove it with
`tailscale serve --https=8443 off`. Do not stop another tailnet service to free a port.

**Never add `8790` to `tailscale serve`.** The browser channel is loopback-only and carries no
credential.

## HTTPS fails but the service is healthy

Tailscale issues the certificate on first use; a fresh domain can take a minute. If it persists:

```bash
tailscale cert <host>.<tailnet>.ts.net
curl -v https://<host>.<tailnet>.ts.net/v1/health
```

Remember there is no port in the URL. If a `:8443` is in the app's saved host, edit it out.

## The app cannot reach the host

- Is the phone on the tailnet? (Tailscale app installed, logged into the same tailnet.)
- Does the URL in the app exactly match what `tailscale serve status` prints — host only, no port?
- `curl https://<host>.<tailnet>.ts.net/v1/health` from another tailnet device — if that fails, the
  problem is the host, not the app.

## A pairing code is rejected

Codes are single-use and expire in minutes. Mint a fresh one:
`curl -fsS -X POST http://127.0.0.1:8788/v1/pair/start`. That route answers on loopback only.
Repeated failures are rate limited per client, so wait a moment after a handful of attempts.

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

## Cards are blank, or `/v1/genui/plugin.js` answers 503

The `hermes-genui` plugin is missing from the engine. It ships with this repository, not with
upstream Hermes:

```bash
ls <engine>/plugins/hermes-genui/desktop/plugin.js
```

Re-run the installer to restore it. The React shell itself is embedded in the binary, so a 503 here
is always the plugin bundle, never the card page.

## The Mac's computer says "Reconnecting" and will not connect

Check whether the host has that Mac revoked — this is what the trash button beside the computer name
does:

```bash
cat /var/lib/hermeyd/revoked-local-computers.json     # {"revoked": ["<device id>"]}
```

Turning **Let bots use this computer** off and on in the Mac app lifts it (the app calls
`POST /v1/local-computers/<device>/enable`). If it still will not connect, ask the host why rather
than the screen:

```bash
sudo journalctl -u hermeyd --since -10min | grep local_computer.rejected
```

Each line names the check that failed: `no ticket`, `ticket not redeemable`, `device not active`, or
`revoked`.
