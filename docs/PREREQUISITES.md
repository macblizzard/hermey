# Getting Hermey running

From nothing to a paired app. Four steps, about five minutes after Hermes is up.

> **Hermey is an independent project.** It is not affiliated with, endorsed by, or supported by the Hermes
> project or its maintainers, and it is not an official Hermes client. "Hermes" is named only to say what
> Hermey connects to. Please don't ask the Hermes maintainers for support with Hermey — and please don't
> assume a Hermey problem is a Hermes problem until you've checked the logs on both sides.

## 1. Hermes

Hermey is a client and a host service for **Hermes**, the agent runtime. Hermes has to be installed and
working before anything here is useful, and its own documentation is the authority on installing it — follow
that, not this page.

What Hermey needs from your Hermes install, once it is running:

- **a gateway** — the engine's WebSocket API, normally on loopback (`/api/ws`);
- **at least one bot** (a profile) — Hermey lists them; an empty install shows an empty app;
- **a discoverable home** — a `HERMES_HOME` (or engine home) whose `profiles/` directory is visible, because
  Hermey reads each bot's `state.db`, `memories/`, `config.yaml` and `skills/` directly;
- **one gateway per `HERMES_HOME`** — see [Requirements](#requirements) below.

## 2. Install hermeyd

`hermeyd` is the host service that fronts Hermes for the apps: pairing, the conversation relay, the shared
computer, browser control, credentials, backups and routines.

```sh
curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sh
```

The script detects your platform, verifies the published SHA-256 of the binary it downloads, installs
`/opt/hermey/bin/hermeyd`, creates `/var/lib/hermeyd`, writes `/etc/hermey/hermeyd.env`, installs the systemd
unit, and prints the token path and the serve command.

Refuse to pipe a script into a shell? Build it instead — same binary, your compiler:

```sh
git clone https://github.com/macblizzard/hermey && cd hermey
cargo build --release --locked --manifest-path hermeyd/Cargo.toml
sudo install -m 0755 hermeyd/target/release/hermeyd /opt/hermey/bin/hermeyd
```

## 3. Publish it

`hermeyd` listens on loopback only. Give it a reachable address on your tailnet (the apps need TLS, and
tailnet is the simplest honest way to get it):

```sh
tailscale serve --bg http://127.0.0.1:8788
```

That is `serve` at the root — **no port in the URL**. Pairing links therefore look like
`https://your-host.ts.net/?code=…`, not `:8443`.

## 4. Pair the app

Ask the host for a one-time code — `hermeyd` mints it over loopback and prints the code, the URL to
open and a QR code the app can scan:

```sh
hermeyd pair
```

```
pairing code  250240
expires       2026-11-21 20:31:33 +01:00 (9 min left)
pairing URL   https://your-host.ts.net/?code=250240
protocol      1
```

Enter the code in Hermey, open the pairing URL on a device on the same tailnet, or scan the QR. A code is single-use and
expires in ten minutes; run `hermeyd pair` again for another. `--json` prints the route's object unchanged
for scripts (`hermeyd pair --json | jq -r .code`), and `--host` overrides the name in the URL when
`HERMEYD_PUBLIC_HOST` is not the one you want to publish.

Prefer `curl`? It is the same route, and the local token is the bearer:

```sh
curl -s -X POST -H "Authorization: Bearer $(cat /var/lib/hermeyd/local.token)" \
  http://127.0.0.1:8788/v1/pair/start
# {"code":"…","expires_at":1795289493.7,"host":"your-host.ts.net","protocol_version":1}
```

The device appears on the host immediately; `/v1/devices` lists it. If `hermeyd pair` says the service is
not running, fix that first — `hermeyd status` then names the half that is missing (service, engine, token
file, browser channel, gateway).

## Verify

```sh
curl -s http://127.0.0.1:8788/v1/health                  # the service answers
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $(sudo cat /var/lib/hermeyd/local.token)" \
  http://127.0.0.1:8788/v1/integrations                  # 200 with the token, 401 without
```

Then in the app: a bot list, and a conversation that opens. If the conversation hangs on "connecting", the
relay reached your engine and the engine refused the session — check the engine's log, not Hermey's.

## Requirements

Three things that cause almost every setup problem:

1. **One gateway per `HERMES_HOME`.** A second gateway bypasses the host lock and can double-fire routines
   against the same cron store. `hermeyd --gateway-check` exits `75` when it sees a duplicate and names the
   process; treat that as "stop, fix this".
2. **`hermeyd` and the engine must run as the same user.** Hermey reads `state.db`, `memories/*.md`,
   `config.yaml` and `skills/` directly. Different users means permission errors that look like missing data.
3. **The `hermes-genui` plugin ships with Hermey**, not with Hermes. The installer places it; a host without it
   answers `503` on `/v1/genui/plugin.js` and cards come up blank.

## Troubleshooting

See [Troubleshooting](troubleshooting.html). The two failures worth knowing before you start:

- **401 on every call** — no bearer. `local.token` is minted at boot, `0600`, owner-only; if the bots run as a
  different user than the service, grant that one principal `0640` via `HERMEYD_LOCAL_TOKEN_GROUP`.
- **502 from the tailnet URL** — a leftover `:8443` mount pointing at the retired Python bridge. Remove it with
  `tailscale serve --https=8443 off`; the current service is published at serve-root.
