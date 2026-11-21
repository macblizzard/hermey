# For agents — install a Hermey host

You are reading this because someone handed you this repository and asked you to set it up. This file
is the whole job, in the order you should do it. Every command is copy-pasteable, every step has a
pass condition, and the failure playbook at the bottom covers what actually goes wrong.

**Hermey is a client, not a server.** The user already runs Hermes on a machine. Hermey adds one
loopback service to it — **hermeyd**, a single Rust binary — which pairs devices, mints 30-second
tickets, relays the engine's WebSocket and serves the apps' `/v1` API. The apps (iOS, macOS) talk only
to hermeyd. Exposure is `tailscale serve`'s job.

> `curl -fsS http://127.0.0.1:8788/v1/health` answers on a host that is already served — skip to
> [verify](#2-verify-before-you-tell-anyone-it-works). `8787` has **no listener** on a hermeyd host,
> and a leftover `:8443` mount answers 502. The apps publish serve-root now.

## Who does what

| Step | Who |
|---|---|
| Install and verify hermeyd on the host | **You** (root shell on the Hermes host) |
| Download and install the iOS/macOS apps | **The human** (you cannot install to their phone) |
| Pair a device | You mint the code; the human enters it |

Your deliverable is: a host where `/v1/health` answers on both loopback and the tailnet URL, plus a
short handoff message with the app links and a fresh pairing code.

## 0. Confirm this host is the right one

Run all of these and check the right-hand column before changing anything.

```bash
id -u                                   # 0?  the installer needs root
uname -sm                               # Linux x86_64/aarch64 or Darwin arm64/x86_64
command -v hermes                       # a path? Hermes is installed
ls -d "${HERMES_HOME:-$HOME/.hermes}/profiles"   # exists? that is the engine home
command -v tailscale && tailscale status --json | head -c 120   # BackendState "Running"?
```

If `hermes` is missing, this is not a Hermes host — stop and say so. If `tailscale status` reports
`Stopped` or `NeedsLogin`, the user has to run `tailscale up` and authenticate; do not attempt that
for them. No Tailscale at all is workable, see [No tailnet](#no-tailnet).

## 1. Install

```bash
curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo sh
```

If policy forbids piping a download into a shell, fetch and read it first — it is a single reviewable
POSIX shell file:

```bash
curl -fsSLO https://github.com/macblizzard/hermey/releases/latest/download/install.sh
less install.sh
sudo sh install.sh
```

What it does, so you can reason about failures:

1. Maps the platform to one of four published assets and stops on anything else, naming the supported
   set and the `--from-source` alternative.
2. Downloads `hermeyd-<platform>` **and `SHA256SUMS`**, and verifies the SHA-256 **before** installing.
   A missing entry or a mismatch aborts with nothing installed.
3. Installs `/opt/hermey/bin/hermeyd`, state at `/var/lib/hermeyd` (`0700`), config at
   `/etc/hermey/hermeyd.env`, and `/etc/systemd/system/hermeyd.service` (macOS: writes the plist and
   prints the `launchctl` commands; it does not bootstrap a daemon itself).
4. Installs the **`hermes-genui`** plugin into `<engine>/plugins/hermes-genui`.
5. Runs `hermeyd --gateway-check`; exit `75` means another gateway owns this `HERMES_HOME` and is
   reported as a warning with the remedy, not a failure.
6. Publishes the service with `tailscale serve --bg http://127.0.0.1:8788` at the serve root, sets
   `HERMEYD_PUBLIC_HOST` to the node's MagicDNS name, and prints a pairing code and URL. It prints
   the command instead of running it only when it cannot: no `tailscale`, no logged-in node, or a
   serve root another service owns. `--no-serve` skips publishing.

Re-running it is the upgrade path. Nothing else on the host is modified. If the platform is not
published, or policy forbids a downloaded binary:

```bash
git clone https://github.com/macblizzard/hermey && cd hermey
sudo setup/install.sh --from-source      # needs cargo + a C compiler
```

Pass conditions: the script exits 0, and `hermeyd --version` prints a version. A non-zero exit is
never "probably fine" — the message names the next command.

## 2. Verify before you tell anyone it works

```bash
curl -fsS http://127.0.0.1:8788/v1/health
curl -fsS "https://$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')/v1/health"
```

Both must answer `{"status":"ok", …}`. **Do not skip the HTTPS one.** A loopback-only pass is the
state that looks finished and is not: the app will fail to connect.

Anything beyond `/v1/health` and `/v1/pair/start` needs the local bearer. It is a file the service
owns, so it is not in an app, not in a bot's config, and never pasted into chat:

```bash
TOKEN=$(sudo cat /var/lib/hermeyd/local.token)     # 0600, reminted on every boot
curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8788/v1/local-computers
```

Without it those routes answer `401`. Loopback is not a substitute for the bearer.

Then the three checks that catch the failures this service actually has:

```bash
sudo HERMEY_HOME=/var/lib/hermeyd HERMEYD_ENGINE_HOME=<engine> hermeyd --gateway-check; echo $?
# 0 = no duplicate gateway; 75 = another one owns this home — see the playbook
sudo ss -ltnp | grep -E '8788|8790'     # both bound to 127.0.0.1, never 0.0.0.0
ls <engine>/plugins/hermes-genui/desktop/plugin.js   # missing -> every card is 503
```

## 3. Pair the human's device

```bash
curl -fsS -X POST http://127.0.0.1:8788/v1/pair/start
# {"code":"482913","host":"localhost","expires_at":…}
```

`/v1/pair/start` answers on loopback only. Codes are short-lived — mint a fresh one when the human is
actually holding the phone. Tell them:

- iOS: in the app, **add server** → the host's tailnet name → enter the code.
- macOS: same, under **Pair a host**.

To check what is paired afterwards:
`curl -s -H "Authorization: Bearer $(sudo cat /var/lib/hermeyd/local.token)" http://127.0.0.1:8788/v1/devices`.
Revoke a device from the app, or by deleting it there.

## 4. Hand over the apps

Send the human these, verbatim:

- **iOS** — install AltStore ([altstore.io](https://altstore.io)) or SideStore
  ([sidestore.io](https://sidestore.io)), then add this source in its *Sources* tab:
  `https://github.com/macblizzard/hermey/releases/latest/download/altstore.json`
  and install **Hermey** from it. Unsigned builds need re-signing every ~7 days with a free Apple ID.
- **macOS** — download `Hermey-macOS-unsigned.dmg` from
  <https://github.com/macblizzard/hermey/releases/latest>, move `Hermey.app` to `/Applications`, then
  right-click → **Open** → **Open**. If macOS still refuses:
  `xattr -dr com.apple.quarantine /Applications/Hermey.app`.
- **The host URL to type by hand**, if there is no QR path: `https://<host>.<tailnet>.ts.net` — the
  tailnet name `tailscale serve` publishes, with **no port**.

## Hard rules

- **Never bind hermeyd to anything but loopback.** `HERMEYD_BIND` accepts only loopback values and
  the process refuses anything else; `tailscale serve` is the only front door. Do not open a firewall
  port and do not put it behind a public reverse proxy.
- **Never publish `8790`.** That is the browser channel; it carries no credential and is
  loopback-only by design. Only `8788` goes into `tailscale serve`.
- **One gateway per `HERMES_HOME`.** Start the engine with `hermes serve --isolated`. A second
  `hermes gateway run --force` bypasses the host lock and fires every routine twice.
- **hermeyd runs as the engine's owner.** It writes a bot's skill into the engine's profiles; a
  different UID is a permission error at runtime, not at install time.
- **Never create a systemd unit named `hermes-gateway.service`.** That is Hermes' own *messaging*
  gateway. The collision is silent until the next restart, when messaging stops coming back.
- **Never hand-edit App Transport Security exceptions into the apps.** The endpoint must have a real
  trusted certificate. Without Tailscale, a real domain + Caddy in front of `127.0.0.1:8788` is the
  supported shape.
- **Do not stop or reconfigure an existing tailnet service** to free a port. Choose another port in
  `/etc/hermey/hermeyd.env` instead.
- **Do not touch the user's profiles or bots.** Hermey reads them; it does not own them.
- Copy no secrets into chat or logs. The local token stays in `/var/lib/hermeyd/local.token`.

## Failure playbook

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (7) Failed to connect` on `127.0.0.1:8787` | nothing listens there; hermeyd is `8788` | `curl -fsS http://127.0.0.1:8788/v1/health`; `sudo ss -ltnp \| grep -E '8788\|8790'` |
| `401` from any `/v1` route except `/v1/health` and `/v1/pair/start` | no local bearer sent | `-H "Authorization: Bearer $(sudo cat /var/lib/hermeyd/local.token)"`; restart the service if the file is missing |
| Installer: `unsupported platform` | not one of the four targets | `setup/install.sh --from-source` |
| Installer: `checksum mismatch` / `SHA256SUMS has no entry` | corrupt or incomplete release | re-run once; if it repeats, do not install that release — report it |
| Installer: `cannot find the Hermes engine home` | no `profiles/` was found | `--engine-home <engine>` |
| App reaches `…:8443` and gets `502` | leftover mount from the old port scheme | `tailscale serve --https=8443 off`; hermeyd publishes serve-root |
| `hermeyd --gateway-check` exits `75` | another gateway for this `HERMES_HOME` | stop it, or `hermes serve --isolated`; nothing is killed for you |
| Audit log `"event":"upstream_error"`, `"reason":"connect_failed"` | the engine is not answering on `ws://127.0.0.1:9121`, or restarted with a new token | start the engine; check `HERMEYD_ENGINE_WS` / `HERMEYD_ENGINE_TOKEN_FILE` in `/etc/hermey/hermeyd.env` |
| Cards are blank, `GET /v1/genui/plugin.js` answers `503` | plugin missing from the engine | re-run the installer; verify `<engine>/plugins/hermes-genui/desktop/plugin.js` |
| `tailscale serve` refused / permission denied | not root, or serve not enabled on the tailnet | run as root; `tailscale serve status`; check the tailnet policy allows serve |
| App connects nowhere, host is healthy | phone is not on the tailnet, or ATS rejects a self-signed cert | join the tailnet on the phone; use the `ts.net` name with the real cert |
| Pairing code rejected | it expired | `curl -fsS -X POST http://127.0.0.1:8788/v1/pair/start` again with the phone in hand |
| iOS app stops launching after ~a week | free-Apple-ID signature expired | re-sign via AltStore/SideStore |

Full detail, including the exact log strings: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## No tailnet

hermeyd binds loopback and only loopback. With no tailnet, terminate TLS yourself with a real
certificate in front of `127.0.0.1:8788` (Caddy is least work), and set `HERMEYD_PUBLIC_HOST` to the
name the apps dial:

```bash
sudo sed -i 's/^HERMEYD_PUBLIC_HOST=.*/HERMEYD_PUBLIC_HOST=hermey.example.com/' /etc/hermey/hermeyd.env
sudo systemctl restart hermeyd
```

Give the apps that URL. Self-signed certificates will be refused.

## Definition of done

- [ ] `systemctl is-active hermeyd` reports `active` (or launchd: the job is loaded and running)
- [ ] `curl -fsS http://127.0.0.1:8788/v1/health` answers `{"status":"ok", …}`
- [ ] `curl -fsS https://<host>.<tailnet>.ts.net/v1/health` answers the same — no port
- [ ] A `/v1` route other than health answers with the bearer, not `401`
- [ ] `hermeyd --gateway-check` exited 0, or its warning has been reported with the remedy
- [ ] `<engine>/plugins/hermes-genui/desktop/plugin.js` exists
- [ ] A pairing code has been minted and given to the human
- [ ] The human has both app links and knows the ~7-day re-sign caveat on iOS
- [ ] You changed nothing else on the host

## Facts you can rely on

| | |
|---|---|
| Unit | `hermeyd.service` (Linux); `com.hermeyd` (macOS launchd) |
| Ports | `127.0.0.1:8788` main API (`HERMEYD_PORT`), `127.0.0.1:8790` browser channel (`HERMEYD_BROWSER_PORT`), published at serve-root |
| Credential | `/var/lib/hermeyd/local.token` (`0600`), sent as `Authorization: Bearer …`; only `/v1/health` and `/v1/pair/start` answer without it |
| Paths | `/opt/hermey/bin/hermeyd`, `/var/lib/hermeyd` (state, SQLite, attachments), `/etc/hermey/hermeyd.env` (`0640`) |
| Engine | `HERMEYD_ENGINE_HOME`, `HERMEYD_ENGINE_WS` (default `ws://127.0.0.1:9121/api/ws`), `HERMEYD_ENGINE_TOKEN_FILE` |
| Env knobs | `HERMEY_VERSION`, `HERMEY_BASE_URL`, `HERMEY_PREFIX`, `HERMEY_STATE`, `HERMEY_CONF`, `HERMEY_USER`, `HERMEY_UNIT_DIR`, `HERMEYD_PORT`, `HERMEYD_BROWSER_PORT`, `HERMEYD_PUBLIC_HOST` |
| Uninstall | `… install.sh \| sudo sh -s -- --uninstall` (`--purge` also deletes state) |
| Health | `GET /v1/health` on the loopback and through the tailnet URL |

## Copy-paste prompt for the human

> Set up a Hermey host on this machine. The repo is <https://github.com/macblizzard/hermey>; read
> `docs/FOR-AGENTS.md` in it and follow it exactly: install hermeyd, verify that `/v1/health` answers
> on both loopback and the tailnet URL, then give me the pairing code and the iOS/macOS install links.
> Do not change anything else on this host, and do not bind hermeyd to a public interface.

## Where the rest lives

| | |
|---|---|
| [`INSTALL.md`](INSTALL.md) | every installer flag and environment variable, what lands on disk |
| [`HERMEYD.md`](HERMEYD.md) | the service contract: routes, state, ports, engine config |
| [`APPS.md`](APPS.md) | iOS and macOS install, first run, revocation |
| [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) | symptom → cause → fix, with real log strings |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | the components, the ticket protocol, the loopback invariant |
| [`SECURITY.md`](SECURITY.md) | threat model, what is and is not protected |
| [`../setup/SKILL.md`](../setup/SKILL.md) | the same install as a Hermes agent skill, if your agent loads skills |
