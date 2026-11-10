#!/usr/bin/env bash
# Hermey host setup — one command, on a host that already runs Hermes.
#
#   curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo bash
#
# It installs two services and nothing else:
#
#   hermey-bridge.service   the HTTP/WS surface the apps talk to (loopback only)
#   hermey-gateway.service  a Hermes dashboard on loopback — skipped entirely when this host
#                           already runs one, because Hermes permits exactly one per machine
#
# TLS and reachability are `tailscale serve`'s job: a real certificate, tailnet-only, no public
# listener. The apps therefore never see a self-signed cert and nothing is exposed to the internet.
#
# Re-running it is an upgrade: same unit names, same state, the package is reinstalled and the
# services restarted. `--uninstall` reverses all of it.
set -euo pipefail

# ---------------------------------------------------------------- knobs (env or flags)
PREFIX=${HERMEY_PREFIX:-/opt/hermey}
STATE=${HERMEY_STATE:-/var/lib/hermey}
CONF=${HERMEY_CONF:-/etc/hermey}
SVC_USER=${HERMEY_USER:-}
BINDIR=${HERMEY_BINDIR:-/usr/local/bin}
BRIDGE_PORT=${HERMEY_PORT:-8787}
HTTPS_PORT=${HERMEY_HTTPS_PORT:-8443}
UNIT_PREFIX=${HERMEY_UNIT_PREFIX:-hermey}
REF=${HERMEY_REF:-}
LOCAL_SRC=${HERMEY_LOCAL_SRC:-}
DO_SERVE=${HERMEY_SERVE:-auto}
UNINSTALL=0
PURGE=0

REPO=macblizzard/hermey
GATEWAY_PORT_DEFAULT=9120

# These knobs arrive from the environment, and `curl | bash` means the environment is attacker
# territory (sudo -E, env_keep, a wrapper script). Everything below is validated before it is used
# as a path, a unit name, a port, or interpolated into a root-executed script.
valid_user() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_path() { [[ $1 == /* && $1 != *[[:space:]]* && $1 != *..* ]] && [[ $1 != *['$`"\\']* ]]; }
valid_unit() { [[ $1 =~ ^[A-Za-z0-9_.-]{1,40}$ ]]; }

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF=${2:?}; shift 2;;
    --port) BRIDGE_PORT=${2:?}; shift 2;;
    --https-port) HTTPS_PORT=${2:?}; shift 2;;
    --local) LOCAL_SRC=${2:?}; shift 2;;
    --no-serve) DO_SERVE=no; shift;;
    --serve) DO_SERVE=yes; shift;;
    --uninstall) UNINSTALL=1; shift;;
    --purge) PURGE=1; shift;;
    -h|--help) cat <<'USAGE'
Hermey host installer

  sudo bash install.sh [options]

  --ref R          git ref to install (default: main; use a tag to pin)
  --port N         bridge port on 127.0.0.1 (default 8787)
  --https-port N   tailnet port for tailscale serve (default 8443)
  --local DIR      install from a checkout instead of GitHub
  --no-serve       do not configure tailscale serve
  --uninstall      remove the units and the serve mapping, keep state
  --purge          with --uninstall: delete state, config and the service user

Environment overrides: HERMEY_PREFIX, HERMEY_STATE, HERMEY_CONF, HERMEY_USER,
HERMEY_BINDIR, HERMEY_PORT, HERMEY_HTTPS_PORT, HERMEY_UNIT_PREFIX, HERMEY_REF,
HERMEY_LOCAL_SRC, HERMEY_SERVE, HERMES_HOME, HERMES_PROFILES_ROOT
USAGE
      exit 0;;
    *) die "unknown option $1 (try --help)";;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
command -v systemctl >/dev/null || die "this installer needs systemd"

[ -z "$SVC_USER" ] || valid_user "$SVC_USER" || die "HERMEY_USER must match ^[a-z_][a-z0-9_-]*$ (got '$SVC_USER')"
valid_unit "$UNIT_PREFIX"   || die "HERMEY_UNIT_PREFIX must be a unit-name fragment (got '$UNIT_PREFIX')"
valid_path "$PREFIX"        || die "HERMEY_PREFIX must be an absolute path without spaces or '..'"
valid_path "$STATE"         || die "HERMEY_STATE must be an absolute path without spaces or '..'"
valid_path "$CONF"          || die "HERMEY_CONF must be an absolute path without spaces or '..'"
valid_path "$BINDIR"        || die "HERMEY_BINDIR must be an absolute path without spaces or '..'"
valid_port "$BRIDGE_PORT"   || die "HERMEY_PORT must be 1-65535"
valid_port "$HTTPS_PORT"    || die "HERMEY_HTTPS_PORT must be 1-65535"
[ "$PREFIX" != "/" ] && [ "$STATE" != "/" ] && [ "$CONF" != "/" ] || die "refusing to install into /"
[ "$PREFIX" != "$STATE" ] && [ "$STATE" != "$CONF" ] || die "prefix, state and config must differ"

GW_UNIT="$UNIT_PREFIX-gateway"
BR_UNIT="$UNIT_PREFIX-bridge"
UNIT_FILE="/etc/systemd/system/$BR_UNIT.service"

# The account an install created, for `--purge`. `HERMEY_USER` is normally not in the environment
# when someone runs `--uninstall --purge`, and `SVC_USER` is only resolved further down, so the
# account is read back from the unit file. It is only deleted when it still looks like the account
# `useradd --system` made — a system uid, `$STATE` as its home, no login shell — because an install
# that adopted an existing account (`User=<the owner of the Hermes home>`) must never delete a real
# person's login.
purgeable_service_user() {
  local user=$1 passwd uid home shell
  [ -n "$user" ] || return 1
  passwd=$(getent passwd "$user" 2>/dev/null) || return 1
  [ -n "$passwd" ] || return 1
  uid=$(printf '%s' "$passwd" | cut -d: -f3)
  home=$(printf '%s' "$passwd" | cut -d: -f6)
  shell=$(printf '%s' "$passwd" | cut -d: -f7)
  [ "$uid" -gt 0 ] && [ "$uid" -lt 1000 ] && [ "$home" = "$STATE" ] || return 1
  case "$shell" in */nologin|*/false) return 0;; esac
  return 1
}

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
  say "Removing Hermey services"
  PURGE_USER=$SVC_USER
  if [ -z "$PURGE_USER" ] && [ -r "$UNIT_FILE" ]; then
    PURGE_USER=$(sed -n 's/^User=//p' "$UNIT_FILE" | head -1 || true)
  fi
  systemctl disable --now "$BR_UNIT" >/dev/null 2>&1 || true
  systemctl disable --now "$GW_UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$BR_UNIT.service" "/etc/systemd/system/$GW_UNIT.service"
  systemctl daemon-reload
  rm -f "$BINDIR/hermey"
  if command -v tailscale >/dev/null; then
    tailscale serve --https="$HTTPS_PORT" off >/dev/null 2>&1 || true
  fi
  if [ "$PURGE" = 1 ]; then
    rm -rf -- "$PREFIX" "$STATE" "$CONF"
    if purgeable_service_user "$PURGE_USER"; then
      userdel "$PURGE_USER" >/dev/null 2>&1 || true
      say "Purged $PREFIX, $STATE, $CONF and the $PURGE_USER account"
    else
      say "Purged $PREFIX, $STATE, $CONF"
    fi
  else
    say "Services removed; state kept in $STATE (and $CONF). Re-run with --purge to delete it."
  fi
  exit 0
fi

# ---------------------------------------------------------------- preflight
say "Checking this host"
case "$(uname -m)" in x86_64|aarch64|arm64) :;; *) die "unsupported architecture $(uname -m)";; esac

PY=""
for cand in python3.13 python3.12 python3.11 python3; do
  if command -v "$cand" >/dev/null; then
    if "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
      PY=$(command -v "$cand"); break
    fi
  fi
done
[ -n "$PY" ] || die "Python 3.11+ is required (Hermes itself needs it, so it is usually present)"
note "python: $PY ($("$PY" -V 2>&1))"

HERMES_BIN=$(command -v hermes 2>/dev/null || true)
for cand in /usr/local/lib/hermes-agent/.hermes/bin/hermes "$HOME/.hermes/bin/hermes" \
            /usr/local/bin/hermes /opt/hermes/bin/hermes; do
  [ -n "$HERMES_BIN" ] && break
  [ -x "$cand" ] && HERMES_BIN=$cand
done
[ -n "$HERMES_BIN" ] || die "no \`hermes\` on this host — install Hermes first: https://hermes-agent.nousresearch.com/docs"
note "hermes: $HERMES_BIN"

# ---------------------------------------------------------------- source
say "Fetching the bridge"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
if [ -n "$LOCAL_SRC" ]; then
  SRC=$LOCAL_SRC
  note "using the checkout at $SRC"
else
  REF=${REF:-main}
  URL="https://github.com/$REPO/archive/refs/${REF}.tar.gz"
  case "$REF" in refs/*) URL="https://github.com/$REPO/archive/${REF}.tar.gz";; esac
  curl -fsSL "$URL" -o "$WORK/src.tgz" || die "could not download $URL"
  tar -xzf "$WORK/src.tgz" -C "$WORK"
  SRC=$(find "$WORK" -maxdepth 1 -type d -name 'hermey-*' | head -1)
  [ -n "$SRC" ] || die "the downloaded archive did not look like a Hermey checkout"
  note "source: $REF"
fi
[ -f "$SRC/Bridge/pyproject.toml" ] || die "$SRC is not a Hermey checkout (no Bridge/pyproject.toml)"

# ---------------------------------------------------------------- venv
say "Installing the bridge into $PREFIX/venv"
[ -x "$PREFIX/venv/bin/python" ] || "$PY" -m venv "$PREFIX/venv"
"$PREFIX/venv/bin/python" -m pip install --quiet --upgrade pip wheel
"$PREFIX/venv/bin/python" -m pip install --quiet --upgrade "$SRC/Bridge"
note "installed: $("$PREFIX/venv/bin/python" -c 'import hermes_bridge,sys;print("hermes_bridge",getattr(hermes_bridge,"__version__","ok"))' 2>/dev/null || echo ok)"
# The QR is a nicety; the deep link is always printed.
"$PREFIX/venv/bin/python" -m pip install --quiet qrcode 2>/dev/null || true

# ---------------------------------------------------------------- the gateway it relays to
say "Finding the Hermes dashboard this bridge relays to"
GW_PID=""; GW_PORT=""; GW_TOKEN=""
STATUS=$("$HERMES_BIN" dashboard --status 2>/dev/null || true)
GW_PID=$(printf '%s' "$STATUS" | grep -o 'PID [0-9]*' | head -1 | awk '{print $2}' || true)
if [ -n "$GW_PID" ] && [ -r "/proc/$GW_PID/cmdline" ]; then
  GW_PORT=$(tr '\0' ' ' < "/proc/$GW_PID/cmdline" | grep -o -- '--port [0-9]*' | awk '{print $2}' | head -1 || true)
  GW_PORT=${GW_PORT:-9119}
  GW_TOKEN=$(tr '\0' '\n' < "/proc/$GW_PID/environ" 2>/dev/null \
             | sed -n 's/^HERMES_DASHBOARD_SESSION_TOKEN=//p' | head -1 || true)
  note "reusing this host's dashboard: pid $GW_PID on 127.0.0.1:$GW_PORT"
  [ -n "$GW_TOKEN" ] || note "warning: that dashboard runs without a session token; the bridge will connect without one"
else
  GW_PORT=$GATEWAY_PORT_DEFAULT
  if [ -f "$CONF/gateway.env" ]; then
    GW_TOKEN=$(sed -n 's/^HERMES_DASHBOARD_SESSION_TOKEN=//p' "$CONF/gateway.env" | head -1)
  else
    GW_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '\n/+=' | cut -c1-43)
  fi
  note "no dashboard on this host — will run one on 127.0.0.1:$GW_PORT (profile: default)"
fi

# The bridge reports on the agent's profiles, so it belongs to whoever can read them. Running it as
# a stranger with no access produced an empty bot list on a clean host.
if [ -z "${HERMES_HOME:-}" ]; then
  HERMES_HOME=$(tr '\0' '\n' < "/proc/${GW_PID:-0}/environ" 2>/dev/null | sed -n 's/^HERMES_HOME=//p' | head -1)
fi
HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
# A running dashboard often carries a *profile* home in HERMES_HOME (`…/profiles/<name>`), so the
# profiles directory is derived from the shape of the path rather than appended blindly.
if [ -n "${HERMES_PROFILES_ROOT:-}" ]; then
  PROFILES_ROOT=$HERMES_PROFILES_ROOT
elif [ "${HERMES_HOME%%/profiles/*}" != "$HERMES_HOME" ]; then
  PROFILES_ROOT=${HERMES_HOME%%/profiles/*}/profiles
else
  PROFILES_ROOT=$HERMES_HOME/profiles
fi
note "hermes home: $HERMES_HOME"
note "profiles:    $PROFILES_ROOT"

if [ -z "$SVC_USER" ]; then
  SVC_USER=$(stat -c %U "$HERMES_HOME" 2>/dev/null || echo root)
fi
valid_user "$SVC_USER" || die "cannot use '$SVC_USER' as the service user"
note "service user: $SVC_USER"

# ---------------------------------------------------------------- service user, dirs
say "Creating the service account and directories"
if [ "$SVC_USER" = root ]; then
  note "user: root (the Hermes home is root's; no privilege is gained that the agent did not have)"
elif ! id -u "$SVC_USER" >/dev/null 2>&1; then
  useradd --system --home "$STATE" --shell /usr/sbin/nologin -- "$SVC_USER"
  note "user: $SVC_USER (system, no shell)"
fi
install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$STATE"
install -d -m 0750 "$CONF"
install -d -m 0755 "$PREFIX"
install -d -m 0755 "$BINDIR"

umask 077
cat > "$CONF/gateway.env" <<EOF
# The token Hermes accepts on a loopback WS upgrade. Both services read this file.
HERMES_DASHBOARD_SESSION_TOKEN=$GW_TOKEN
EOF
umask 022
chmod 0600 "$CONF/gateway.env"

TAIL_HOST=""
if command -v tailscale >/dev/null; then
  TAIL_HOST=$(tailscale status --json 2>/dev/null | "$PY" -c 'import json,sys
try:
    d=json.load(sys.stdin); print((d.get("Self") or {}).get("DNSName","").rstrip("."))
except Exception: print("")' 2>/dev/null || true)
fi

# ---------------------------------------------------------------- units
say "Writing the services"
cat > "/etc/systemd/system/$BR_UNIT.service" <<EOF
[Unit]
Description=Hermey bridge (the native apps' host API; loopback only)
Documentation=https://github.com/$REPO
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=$CONF/gateway.env
EnvironmentFile=-$CONF/providers.env
Environment=HERMES_BRIDGE_HOST=127.0.0.1
Environment=HERMES_BRIDGE_PORT=$BRIDGE_PORT
Environment=HERMES_BRIDGE_DB=$STATE/bridge.db
Environment=HERMES_BRIDGE_GATEWAY_URL=ws://127.0.0.1:$GW_PORT/api/ws
Environment=HERMES_BRIDGE_STATE_DIR=$STATE
Environment=HERMES_PROFILES_ROOT=$PROFILES_ROOT
Environment=XDG_STATE_HOME=$STATE
Environment=HERMES_BRIDGE_PUBLIC_HOST=${TAIL_HOST:-127.0.0.1}
ExecStart=$PREFIX/venv/bin/python -m hermes_bridge
WorkingDirectory=$PREFIX
Restart=on-failure
RestartSec=2
# Loopback networking and one state directory: nothing else.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$STATE
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes

[Install]
WantedBy=multi-user.target
EOF

if [ -z "$GW_PID" ]; then
  cat > "/etc/systemd/system/$GW_UNIT.service" <<EOF
[Unit]
Description=Hermes dashboard for Hermey (loopback; Hermes allows one per host)
Documentation=https://github.com/$REPO
After=network.target

[Service]
Type=simple
User=root
EnvironmentFile=$CONF/gateway.env
ExecStart=$HERMES_BIN dashboard --port $GW_PORT --host 127.0.0.1 --no-open
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
if [ -n "$GW_PID" ]; then
  systemctl disable --now "$GW_UNIT" >/dev/null 2>&1 || true
else
  systemctl enable --now "$GW_UNIT" >/dev/null
fi
systemctl enable --now "$BR_UNIT" >/dev/null

# ---------------------------------------------------------------- health
say "Waiting for the bridge"
ok=0
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$BRIDGE_PORT/v1/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 0.5
done
[ "$ok" = 1 ] || { journalctl -u "$BR_UNIT" -n 20 --no-pager || true; die "the bridge did not answer on 127.0.0.1:$BRIDGE_PORT"; }
note "healthy on 127.0.0.1:$BRIDGE_PORT"

# ---------------------------------------------------------------- tailnet front door
if [ "$DO_SERVE" != no ] && [ -n "$TAIL_HOST" ]; then
  say "Exposing it to your tailnet with a real certificate"
  if tailscale serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$BRIDGE_PORT" >/dev/null 2>&1; then
    if curl -fsS --max-time 20 "https://$TAIL_HOST:$HTTPS_PORT/v1/health" >/dev/null 2>&1; then
      note "https://$TAIL_HOST:$HTTPS_PORT  (tailnet only, certificate valid)"
    else
      note "serve is configured but the HTTPS check has not passed yet (tailscale cert issuance can take a minute)"
    fi
  else
    note "tailscale serve refused; run it yourself: tailscale serve --bg --https=$HTTPS_PORT http://127.0.0.1:$BRIDGE_PORT"
  fi
elif [ "$DO_SERVE" = no ]; then
  note "skipping tailscale serve (--no-serve)"
else
  note "tailscale not found: the bridge is loopback-only until you expose it"
fi

# ---------------------------------------------------------------- the hermey command
cat > "$BINDIR/hermey" <<EOF
#!/usr/bin/env bash
# Installed by Hermey. Status, pairing, logs and updates for this host.
set -euo pipefail
PORT=\${HERMEY_PORT:-$BRIDGE_PORT}
HTTPS=\${HERMEY_HTTPS_PORT:-$HTTPS_PORT}
UNIT=$BR_UNIT
CONF=$CONF
HOST_DNS=${TAIL_HOST:-}
base="http://127.0.0.1:\$PORT"

case "\${1:-status}" in
  status)
    systemctl --no-pager --lines=0 status "\$UNIT" | head -3 || true
    if curl -fsS "\$base/v1/health" >/dev/null 2>&1; then echo "bridge:   healthy on \$base"; else echo "bridge:   NOT answering on \$base"; fi
    [ -n "\$HOST_DNS" ] && echo "tailnet:  https://\$HOST_DNS:\$HTTPS (tailscale serve)"
    ;;
  pair)
    # A pairing code lives for minutes, so it is minted when you ask, not at install time.
    out=\$(curl -fsS -X POST "\$base/v1/pair/start") || { echo "could not mint a code — is the bridge running?" >&2; exit 1; }
    code=\$(printf '%s' "\$out" | sed -n 's/.*"code"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
    host=\$(printf '%s' "\$out" | sed -n 's/.*"host"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
    # The Host header of this loopback call carries the bridge port; the link wants the
    # outside port, so a host that already names one must not end up with two.
    host=\${host%%:*}
    case "\$host" in
      ""|127.*|localhost|::1)
        # No tailnet name was configured, so nothing this prints could be pasted into the app:
        # 127.0.0.1 from the phone is the phone. The code is still good — it is entered against
        # whatever address reaches this host.
        echo "Pair in the Hermey app: add this host's address, then enter this code"
        echo "  code: \$code"
        echo "  (no address is configured for this host, so there is no link to scan)"
        ;;
      *)
        link="hermes://pair?host=https://\$host:\$HTTPS&code=\$code"
        echo "Pair in the Hermey app: add server → paste this, or scan the QR"
        echo "  \$link"
        if "$PREFIX/venv/bin/python" -c 'import qrcode' 2>/dev/null; then
          "$PREFIX/venv/bin/python" -c 'import qrcode,sys
qr=qrcode.QRCode(border=1); qr.add_data(sys.argv[1]); qr.print_ascii(invert=True)' "\$link" || true
        fi
        ;;
    esac
    ;;
  logs)   journalctl -u "\$UNIT" -n "\${2:-50}" --no-pager;;
  doctor)
    echo "unit:      \$(systemctl is-active "\$UNIT")"
    echo "health:    \$(curl -fsS "\$base/v1/health" >/dev/null 2>&1 && echo ok || echo FAIL)"
    echo "gateway:   \$(systemctl show -p Environment "\$UNIT" --value | tr ' ' '\n' | sed -n 's/^HERMES_BRIDGE_GATEWAY_URL=//p' | head -1)"
    if command -v tailscale >/dev/null; then
      echo "tailscale: \$(tailscale status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p' | head -1)"
      [ -n "\$HOST_DNS" ] && curl -fsS --max-time 10 "https://\$HOST_DNS:\$HTTPS/v1/health" >/dev/null 2>&1 \\
        && echo "https:     ok" || true
    fi
    ;;
  update)  curl -fsSL "https://github.com/$REPO/releases/latest/download/install.sh" | bash;;
  uninstall) echo "run: curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | sudo bash -s -- --uninstall";;
  *) echo "usage: hermey [status|pair|logs|doctor|update|uninstall]"; exit 1;;
esac
EOF
chmod 0755 "$BINDIR/hermey"

say "Done"
if [ -n "$TAIL_HOST" ]; then
  echo
  echo "  Add a server in the Hermey app:"
  echo "    https://$TAIL_HOST:$HTTPS_PORT"
  echo "  then mint a pairing code here:"
  echo "    hermey pair"
else
  echo
  echo "  The bridge listens on 127.0.0.1:$BRIDGE_PORT only. To reach it from a phone,"
  echo "  join both to a tailnet and run:"
  echo "    tailscale serve --bg --https=$HTTPS_PORT http://127.0.0.1:$BRIDGE_PORT"
  echo "    hermey pair"
fi
