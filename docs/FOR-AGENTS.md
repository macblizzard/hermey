# For agents — install a Hermey host

You are reading this because someone handed you this repository and asked you to set it up. This file
is the whole job, in the order you should do it. Every command is copy-pasteable, every step has a
pass condition, and the failure playbook at the bottom covers what actually goes wrong.

**Hermey is a client, not a server.** The user already runs Hermes on a machine. Hermey adds one
loopback service to that machine — the **bridge** — which adapts the Hermes dashboard to a small
HTTP/WS API, and exposes it to the tailnet with `tailscale serve`. The apps (iOS, macOS) talk only to
that bridge.

> **Read this first: is this host already on `hermeyd`?** Hosts installed today run **hermeyd**, the
> Rust host service, not the Python bridge. It serves the main API on `127.0.0.1:8788` and the browser
> channel on `8790`, publishes **serve-root** (`tailscale serve --bg http://127.0.0.1:8788`, so pairing
> URLs carry no `:8443`), and every `/v1` route except `/v1/health` and `/v1/pair/start` requires the
> **local bearer** it mints at `<state>/local.token` (`0600`) on boot. If `curl -fsS
> http://127.0.0.1:8788/v1/health` answers, this host is already served — skip the install below and
> go to [verify](#2-verify-before-you-tell-anyone-it-works). On such a host `8787` has **no listener**
> and a leftover `:8443` mount answers 502. The rest of this file is the bridge procedure, which still
> applies to a host that has not migrated.

## Who does what

| Step | Who |
|---|---|
| Install and verify the bridge on the host | **You** (root shell on the Hermes host) |
| Download and install the iOS/macOS apps | **The human** (you cannot install to their phone) |
| Pair a device | You mint the code; the human scans or pastes it |

Your deliverable is: a host where `hermey doctor` reports healthy on both the loopback and the tailnet
URL, plus a short handoff message containing the app links and the pairing instructions.

## 0. Confirm this host is the right one

Run all of these and check the right-hand column before changing anything.

```bash
id -u                                   # 0?  the installer needs root
systemctl --version | head -1           # systemd present
python3 --version                       # 3.11 or newer
command -v hermes                       # a path? Hermes is installed
command -v tailscale && tailscale status --json | head -c 120   # BackendState "Running"?
command -v hermey                        # a path means Hermey is already installed
```

If `hermes` is missing, this is not a Hermes host — stop and say so. If `tailscale status` reports
`Stopped` or `NeedsLogin`, the user has to run `tailscale up` and authenticate; do not attempt that
for them. No Tailscale at all is workable, see [No tailnet](#no-tailnet).

## 1. Install

```bash
curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo bash
```

If your policy forbids piping a download into a shell, fetch and read it first — it is a single
reviewable bash file:

```bash
curl -fsSLO https://github.com/macblizzard/hermey/releases/latest/download/install.sh
less install.sh
sudo bash install.sh
```

What it does, so you can reason about failures: preflight (python, systemd, `hermes`) → installs the
bridge into `/opt/hermey/venv` → runs it as `hermey-bridge.service` on `127.0.0.1:8787` as the owner
of the Hermes home → **reuses** the dashboard already running on this host (Hermes allows exactly one
per host) and only creates `hermey-gateway.service` if there is none → `tailscale serve --bg
--https=8443` in front of the bridge → installs `/usr/local/bin/hermey`.

Re-running it is the upgrade path. Nothing else on the host is modified.

Pass conditions: the script ends with a healthy loopback check, and `hermey status` exits 0.

## 2. Verify before you tell anyone it works

```bash
hermey doctor          # unit, loopback health, gateway URL, tailscale state, HTTPS through the cert
hermey status
```

Then the explicit check — on a **hermeyd** host it is `8788`, and the tailnet URL has no port:

```bash
curl -fsS http://127.0.0.1:8788/v1/health                       # hermeyd (the retired bridge: 8787)
curl -fsS "https://$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')/v1/health"
```

Both must answer `{"status":"ok", ...}`. A bridge host publishes `:8443` and answers there instead —
add the port if the loopback one is `8787`.

Do not skip the HTTPS one. A loopback-only pass is the state that looks finished and is not: the app
will fail to connect.

Anything beyond `/v1/health` needs the service's local bearer. It is a file the service owns, so it is
not in an app, not in a bot's config, and never pasted into chat:

```bash
TOKEN=$(cat /var/lib/hermeyd/local.token)     # <state> wherever hermeyd keeps the database
curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8788/v1/local-computers
```

Without it those routes answer `401` — that is a missing credential, not an unhealthy service.

## 2.5 The Mac skill installs itself — confirm it landed

The bridge writes a `mac-local-computer` skill into this host's bot skills directory on every start,
plus the CLI it points at (`/var/lib/hermey/bin/local_computer.py`). That is what makes the owner's
Mac a capability for *every* bot on the host instead of something each one has to discover.

```bash
curl -s -X POST -H "Authorization: Bearer $(cat /var/lib/hermeyd/local.token)" \
  http://127.0.0.1:8788/v1/local-computers/skill | python3 -m json.tool   # installed: [...]
```

Pass condition: `installed` is a non-empty list, and that path holds `mac-local-computer/SKILL.md`.
A skill of the same name that the owner wrote themselves is never overwritten — the response says
`"outcome": "foreign"` for that directory and the owner's file stays as it is.

Two knobs matter if it does not land:

- **Where.** `skills.external_dirs` in the Hermes `config.yaml` is used when set (one copy, every
  profile). Otherwise the bridge writes into the install home's `skills/` and every
  `profiles/*/skills/`. Both are under `ProtectHome=read-only` unless the unit lists them in
  `ReadWritePaths`; `setup/install.sh` does, and a unit written by an older installer does not.
- **The Mac still has to allow it.** The skill explains the switch: Hermey on the Mac → Computer →
  **Let bots use this computer**. With that off, every call answers "no local computer is connected"
  and the skill tells the bot to stop and ask rather than retry.
- **The trash button is reversible.** The bin beside the computer name revokes that Mac on the host
  (it drops out of `/v1/local-computers` and its socket is closed). Turning **Let bots use this
  computer** back on asks the host to lift the revoke: the app calls
  `POST /v1/local-computers/<device>/enable` and reconnects. Before this existed the revoke was
  permanent and only editing `revoked-local-computers.json` on the host would undo it.
- **When a Mac will not connect**, the host now says why. Every rejected handshake logs a
  `local_computer.rejected` audit event naming the failed check — no ticket, ticket not redeemable,
  device not active, or revoked — instead of failing silently. A refusal reaches the app as close
  code `4401`/`4403`, not an opaque "bad response from the server".

## 3. Pair the human's device

```bash
hermey pair
```

It prints a short code, a `hermes://pair?…` deep link, and a QR in the terminal. Codes are
short-lived — mint a fresh one when the human is actually holding the phone. Tell them:

- iOS: in the app, **add server** → scan the QR (or paste the deep link).
- macOS: the Mac has no camera; paste the `hermes://` link into **Pair a host**.

To check what is paired afterwards: `hermey doctor`, or
`curl -s -H "Authorization: Bearer $(cat /var/lib/hermeyd/local.token)" http://127.0.0.1:8788/v1/devices`
(loopback and the local bearer, on a hermeyd host; the bridge answered on `8787` with no credential).
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
- **The host URL to type by hand**, if QR scanning is not available:
  `https://<host>.<tailnet>.ts.net:8443` (this is what `hermey pair` shows).

## Hard rules

- **Never bind the bridge to anything but `127.0.0.1`.** Hermes accepts its session token on a
  loopback upgrade and refuses it elsewhere; `tailscale serve` is the only front door. Do not open a
  firewall port and do not put it behind a public reverse proxy.
- **Never create a systemd unit named `hermes-gateway.service`.** That is Hermes' own *messaging*
  gateway. The collision is silent until the next restart, when messaging stops coming back. Hermey's
  units are `hermey-bridge.service` and, only when needed, `hermey-gateway.service`.
- **Never hand-edit App Transport Security exceptions into the apps.** The endpoint must have a real
  trusted certificate. If the user wants to avoid Tailscale, a real domain + Caddy in front of
  `127.0.0.1:8787` with `--no-serve` is the supported shape.
- **Do not stop or reconfigure an existing tailnet service** to free port 8443. Reinstall with
  `--https-port 8444` (and `--port 8789` if 8787 is busy — `8788` belongs to hermeyd, so a bridge
  install cannot take it).
- **Do not touch the user's profiles or bots.** Hermey reads them; it does not own them.
- Copy no secrets into chat or logs. Provider keys for voice go in `/etc/hermey/providers.env` (0600).

## Failure playbook

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (7) Failed to connect` on `127.0.0.1:8787` | this host runs **hermeyd**, whose loopback API is `8788`; nothing listens on 8787 any more | `curl -fsS http://127.0.0.1:8788/v1/health`; `sudo ss -ltnp \| grep -E '8788\|8790'` |
| `401` from any `/v1` route except `/v1/health` and `/v1/pair/start` | no local bearer on a hermeyd host | `-H "Authorization: Bearer $(cat <state>/local.token)"`; restart the service if the file is missing |
| App reaches `…:8443` and gets `502` | a leftover `:8443` mount pointing at the retired bridge | `tailscale serve --https=8443 off` (hermeyd publishes serve-root) |
| `the bridge did not answer on 127.0.0.1:8787` | port taken, venv broken, or a crash on start (bridge installs) | `hermey logs 80`; `sudo ss -ltnp \| grep 8787`; reinstall with `--port 8788` |
| `reusing this host's dashboard: pid …` | a dashboard exists; Hermes allows one | expected — let the installer reuse it; `hermes dashboard --status` |
| `hermey doctor` health FAIL, audit log says `"event": "upstream_error"` with `"reason": "connect_failed"` | the dashboard is not answering on that port, or restarted with a new token | re-run the installer; it re-reads both |
| `tailscale serve` refused / permission denied | not root, or serve not enabled on the tailnet | run as root; `tailscale serve status`; check the tailnet policy allows serve |
| HTTPS fails, loopback healthy | serve mapping points elsewhere, or the tailnet DNS name is wrong | `tailscale serve status`, then `--https-port` if the port was taken |
| App connects nowhere, host is healthy | phone is not on the tailnet, or ATS rejects a self-signed cert | join the tailnet on the phone; use the `ts.net` name with the real cert |
| Pairing code rejected | it expired (they are short-lived) | `hermey pair` again with the phone in hand |
| iOS app stops launching after ~a week | free-Apple-ID signature expired | re-sign via AltStore/SideStore |

Full detail, including the exact log strings: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## No tailnet

Set up TLS yourself and skip `tailscale serve`:

```bash
sudo bash install.sh --no-serve            # or HERMEY_SERVE=no
```

Then terminate TLS in front of `127.0.0.1:8787` with a real certificate (Caddy is least work) and give
the apps that URL. Self-signed certificates will be refused by the apps.

## Definition of done

- [ ] `hermey doctor` — unit active, health ok, HTTPS ok
- [ ] `curl -fsS https://<host>.<tailnet>.ts.net/v1/health` answers `{"status":"ok", …}` (hermeyd:
      serve-root, no `:8443`; a bridge host publishes the port)
- [ ] A `/v1` route other than health answers with `-H "Authorization: Bearer …"`, not `401`
- [ ] `hermey pair` produced a code the human has been given
- [ ] The human has both app links and knows the ~7-day re-sign caveat on iOS
- [ ] You changed nothing else on the host

## Facts you can rely on

| | |
|---|---|
| Units | `hermey-bridge.service` (always), `hermey-gateway.service` (only if the host had no dashboard) |
| Ports | `hermeyd` `127.0.0.1:8788` (main API) and `127.0.0.1:8790` (browser channel), published at serve-root; the retired bridge used `127.0.0.1:8787` behind tailnet `8443` |
| Credential | `<state>/local.token` (`0600`), sent as `Authorization: Bearer …`; only `/v1/health` and `/v1/pair/start` answer without it |
| Paths | `/opt/hermey/venv`, `/var/lib/hermey` (state, SQLite, attachments), `/etc/hermey/*.env` (0600) |
| CLI | `hermey status \| pair \| logs [n] \| doctor \| update \| uninstall` |
| Env knobs | `HERMEY_PORT`, `HERMEY_HTTPS_PORT`, `HERMEY_REF`, `HERMEY_LOCAL_SRC`, `HERMEY_SERVE`, `HERMEY_PREFIX`, `HERMEY_STATE`, `HERMEY_CONF`, `HERMEY_USER`, `HERMEY_BINDIR`, `HERMEY_UNIT_PREFIX` |
| Uninstall | `… install.sh \| sudo bash -s -- --uninstall` (`--purge` also deletes state, config, service user) |
| Health | `GET /v1/health` on the loopback and through the tailnet URL |

## Copy-paste prompt for the human

> Set up a Hermey host on this machine. The repo is <https://github.com/macblizzard/hermey>; read
> `docs/FOR-AGENTS.md` in it and follow it exactly: install the bridge, verify that `/v1/health` answers
> on both loopback and the tailnet URL, then give me the pairing code and the iOS/macOS install links.
> Do not change anything else on this host, and do not bind the bridge to a public interface.

## Where the rest lives

| | |
|---|---|
| [`INSTALL.md`](INSTALL.md) | every installer flag and environment variable, what lands on disk |
| [`APPS.md`](APPS.md) | iOS and macOS install, first run, revocation |
| [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) | symptom → cause → fix, with real log strings |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | how the bridge adapts the dashboard, and the WS protocol |
| [`../SECURITY.md`](../SECURITY.md) | threat model, what is and is not protected |
| [`../setup/SKILL.md`](../setup/SKILL.md) | the same install as a Hermes agent skill, if your agent loads skills |
