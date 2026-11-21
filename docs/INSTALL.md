# Installing a Hermey host

The host is a machine that already runs Hermes. Hermey adds one loopback service to it — **hermeyd**,
a single Rust binary that pairs devices, mints 30-second tickets, relays the engine's WebSocket and
serves the apps' `/v1` API. Nothing is exposed beyond `127.0.0.1`; reachability is Tailscale's job.

| | |
|---|---|
| Main API | `127.0.0.1:8788` (`HERMEYD_PORT`) |
| Browser channel | `127.0.0.1:8790` (`HERMEYD_BROWSER_PORT`) — never publish this one |
| State | `/var/lib/hermeyd` (0700) |
| Local bearer | `/var/lib/hermeyd/local.token` (0600), minted on boot |
| Config | `/etc/hermey/hermeyd.env` |
| Unit | `/etc/systemd/system/hermeyd.service` |

## Prerequisites

- **A Hermes host.** Hermes installed and working, with an **engine home** — the directory that
  contains `profiles/` (usually `~/.hermes` or `$HERMES_HOME`).
- **Linux with systemd**, or **macOS** with launchd. The installer needs `sudo` either way because it
  writes to `/opt`, `/etc` and `/var/lib`.
- **Tailscale is optional but recommended.** Without it the service is reachable only from the host
  itself, which is enough to verify but not enough to pair a phone.
- `curl` (or `wget`) and `sha256sum`/`shasum`. Both are present on a stock Linux or macOS install.

Three requirements are worth stating plainly, because each one fails in a way that does not look like
a setup problem:

1. **One gateway per `HERMES_HOME`.** Hermes allows a single dashboard/gateway per engine home. If a
   second one is already running, `hermeyd --gateway-check` exits `75` and the installer warns; every
   routine would otherwise fire twice. Run the engine for this home with `hermes serve --isolated`.
2. **`hermeyd` and the engine must share a UID.** hermeyd reads the engine's profiles and writes a
   bot's skill into them. A different account turns that into a permission error at runtime, not at
   install time.
3. **The `hermes-genui` plugin ships with us.** Upstream Hermes does not have it. The installer puts
   it in `<engine>/plugins/hermes-genui`; without it every generated-UI card answers `503`.

## The one command

```bash
curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo sh
```

What it does, in order:

1. **Detects the platform** — Linux x86_64/aarch64 or macOS arm64/x86_64 — and refuses anything else
   with the supported list and the from-source alternative.
2. **Downloads the matching binary** from this repository's GitHub release, plus `SHA256SUMS`, and
   verifies the **SHA-256 before installing**. A missing or mismatched entry aborts with nothing
   installed: the checksum is the whole trust anchor for a prebuilt binary.
3. **Installs** it to `/opt/hermey/bin/hermeyd`.
4. **Creates state** at `/var/lib/hermeyd` (`0700`, owned by the service account).
5. **Writes `/etc/hermey/hermeyd.env`** with the detected engine home, ports, public host and token
   path. An existing file is kept on upgrade, so ports and a chosen host name are never reset.
6. **Installs the systemd unit** from the installer's own template (Linux) or writes
   `/etc/hermey/com.hermeyd.plist` and prints the two launchd commands (macOS). It does not bootstrap
   a daemon behind your back.
7. **Installs the `hermes-genui` plugin** into `<engine>/plugins/hermes-genui`.
8. **Runs `hermeyd --gateway-check`** and *warns* — does not fail — when another gateway already owns
   the engine home.
9. **Prints** the exact `tailscale serve` command and the token path. It never runs `tailscale serve`
   itself: publishing a host is a decision.

Re-running the same command is the **upgrade** path: same paths, same state, new binary, unit and
plugin replaced, service restarted.

## Prebuilt or from source

Prebuilt is the default and needs no toolchain. Build from source when the platform is not published,
when policy forbids running a downloaded binary, or when you are testing a change:

```bash
git clone https://github.com/macblizzard/hermey
cd hermey
sudo setup/install.sh --from-source
```

`--from-source` needs `cargo` (<https://rustup.rs>) and a C compiler — `cargo build --release
--locked` compiles the bundled SQLite. The plugin is installed from `setup/plugins/hermes-genui` in
the same checkout, so a build is self-contained.

## Options

Flags mirror environment variables, which matters when the script is piped into a shell.

| Flag | Env | Default | Meaning |
|---|---|---|---|
| `--from-source` | — | off | build with cargo instead of downloading |
| `--version TAG` | `HERMEY_VERSION` | `latest` | release tag to install (`v0.2.0`) or `latest` |
| `--prefix DIR` | `HERMEY_PREFIX` | `/opt/hermey` | where the binary goes |
| `--state-dir DIR` | `HERMEY_STATE` | `/var/lib/hermeyd` | state directory (created `0700`) |
| `--engine-home DIR` | `HERMEYD_ENGINE_HOME` | detect | Hermes engine home (contains `profiles/`) |
| `--user NAME` | `HERMEY_USER` | engine owner | account hermeyd runs as |
| `--uninstall` | — | — | remove the service, binary, config and plugin; keep state |
| `--purge` | — | — | with `--uninstall`: delete state too |

`HERMES_HOME` is honoured when `--engine-home` is not given. `HERMEY_BASE_URL` points the download at
a mirror or a local directory of release assets; `HERMEY_SRC` points `--from-source` at a checkout.
`HERMEY_UNIT_DIR` overrides `/etc/systemd/system` (for tests and second instances).

Validation is deliberate: every path must be absolute and free of spaces and `..`, every port must
be 1–65535, and the published and browser ports must differ. All of it is checked before anything is
written.

## What is on disk

| Path | What |
|---|---|
| `/opt/hermey/bin/hermeyd` | the service binary |
| `/var/lib/hermeyd/bridge.db` | devices, tickets, collections (SQLite) |
| `/var/lib/hermeyd/bridge.salt` | per-host salt for refresh hashing (`0600`) |
| `/var/lib/hermeyd/local.token` | the local bearer every CLI reads (`0600`, reminted each boot) |
| `/var/lib/hermeyd/attachments/` | uploaded files |
| `/etc/hermey/hermeyd.env` | configuration, `0640`, read as an `EnvironmentFile` |
| `/etc/systemd/system/hermeyd.service` | the unit (Linux) |
| `/etc/hermey/com.hermeyd.plist` | the launchd job to load (macOS) |
| `<engine>/plugins/hermes-genui/` | the card plugin, with its `desktop/plugin.js` bundle |

The config file is environment variables only — hermeyd has no config file of its own:

```sh
HERMEY_HOME=/var/lib/hermeyd
HERMEYD_PORT=8788
HERMEYD_BROWSER_PORT=8790
HERMEYD_ENGINE_HOME=/path/to/engine
HERMEYD_ENGINE_WS=ws://127.0.0.1:9121/api/ws
HERMEYD_ENGINE_TOKEN_FILE=/path/to/engine.token
HERMEYD_PUBLIC_HOST=localhost
```

## Verify

```bash
# 1. alive (unauthenticated, intentionally says nothing else)
curl -fsS http://127.0.0.1:8788/v1/health
# {"status":"ok","protocol_version":…,"ws":true}

# 2. the local bearer exists and is private
sudo ls -l /var/lib/hermeyd/local.token      # -rw-------  root
TOKEN=$(sudo cat /var/lib/hermeyd/local.token)
curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8788/v1/local-computers

# 3. no duplicate gateway for this engine home (exit 0 good, 75 duplicate)
sudo HERMEY_HOME=/var/lib/hermeyd hermeyd --gateway-check; echo $?

# 4. no public listener
ss -ltnp | grep -E '8788|8790'               # both on 127.0.0.1 only
```

Then publish and pair:

```bash
tailscale serve --bg http://127.0.0.1:8788   # serve-root: URLs carry no :8443
curl -fsS -X POST http://127.0.0.1:8788/v1/pair/start
# {"code":"12345678","host":"localhost","expires_at":…}
```

`/v1/pair/start` only answers on loopback. Enter the code in the app against the host's address;
codes are short-lived, so mint one while the phone is in your hand. Pair as many devices as you like;
each is individually revocable.

Every `/v1` route except `/v1/health` and `/v1/pair/start` requires the local bearer. Loopback is not
a substitute for it.

## Without Tailscale

hermeyd binds `127.0.0.1` and refuses any other bind — a design invariant, not a default. With no
tailnet, put a TLS terminator with a real certificate (Caddy is least work) in front of
`127.0.0.1:8788`. A self-signed certificate will not work: the apps follow App Transport Security and
refuse it. Set `HERMEYD_PUBLIC_HOST` to the name the app dials, then restart the service.

## Uninstall

```bash
curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo sh -s -- --uninstall
```

Stops and removes the unit, the binary, the config and the plugin. **State is kept**, so paired
devices survive a reinstall. Add `--purge` to delete `/var/lib/hermeyd` as well:

```bash
sudo sh install.sh --uninstall --purge
```

If you published the host, take the mapping down with `tailscale serve --bg off`.

## When the first install fails

| Symptom | Cause | Fix |
|---|---|---|
| `could not download …/hermeyd-linux-aarch64` | no published build for that platform/tag | use a release that has it, or `--from-source` |
| `SHA256SUMS has no entry for …` | incomplete release | install a complete release, or build |
| `checksum mismatch` | corrupt download or a replaced asset | re-run once; if it repeats, do not install that release |
| `cannot find the Hermes engine home` | detection found no `profiles/` | `--engine-home /path/to/engine` |
| `unsupported platform` | not one of the four targets | `--from-source` on that platform |
| warning: gateway-check exited 75 | a second gateway for this `HERMES_HOME` | stop it, or `hermes serve --isolated` |
| cards answer `503` | plugin missing from the engine | re-run the installer; check `<engine>/plugins/hermes-genui/desktop/plugin.js` |
| service restarts in a loop | port taken, engine unreachable, or state unreadable | `journalctl -u hermeyd -n 80 --no-pager` |

The installer exits non-zero on any of these and never reports success for a host it did not finish
setting up.
