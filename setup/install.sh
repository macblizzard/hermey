#!/bin/sh
# Hermey host installer — hermeyd, the Rust host service.
#
#   curl -fsSL https://github.com/macblizzard/hermey/releases/latest/download/install.sh | sudo sh
#
# The binary is downloaded from this repository's GitHub release and checked against a published
# SHA-256 before it is installed. `--from-source` compiles it instead, for a platform with no
# published build or a host that will not run a download.
#
# What it installs, and nothing else:
#
#   /opt/hermey/bin/hermeyd          the service binary
#   /var/lib/hermeyd                 its state (devices, SQLite, attachments, local.token) — 0700
#   /etc/hermey/hermeyd.env          its configuration, read as a systemd EnvironmentFile
#   /etc/systemd/system/hermeyd.service
#   <engine>/plugins/hermes-genui    the card plugin the apps need, which upstream Hermes lacks
#
# It never binds a public interface: hermeyd listens on 127.0.0.1:8788 and 127.0.0.1:8790, and
# reachability is `tailscale serve`'s job — which this installer does. Once the service answers it
# publishes 8788 at the serve root and prints a real pairing URL. It declines, naming the command to
# run, only where it cannot act: --no-serve, no `tailscale` binary, no logged-in node, or a serve
# root another service already owns.
#
# Re-running it is an upgrade: same paths, same state, the binary and unit are replaced and the
# service restarted. `--uninstall` reverses it and keeps state; `--uninstall --purge` deletes it.
set -eu

REPO=${HERMEY_REPO:-macblizzard/hermey}
VERSION=${HERMEY_VERSION:-latest}
BASE_URL=${HERMEY_BASE_URL:-}
PREFIX=${HERMEY_PREFIX:-/opt/hermey}
STATE=${HERMEY_STATE:-/var/lib/hermeyd}
CONF=${HERMEY_CONF:-/etc/hermey}
UNIT_DIR=${HERMEY_UNIT_DIR:-/etc/systemd/system}
ENGINE_HOME=${HERMEYD_ENGINE_HOME:-}
SVC_USER=${HERMEY_USER:-}
SVC_GROUP=${HERMEY_GROUP:-}
MAIN_PORT=${HERMEYD_PORT:-8788}
BROWSER_PORT=${HERMEYD_BROWSER_PORT:-8790}
PUBLIC_HOST=${HERMEYD_PUBLIC_HOST:-localhost}
# Whether the owner named the pairing host. If they did, publishing must not overwrite it with the
# MagicDNS name this install discovers.
if [ -n "${HERMEYD_PUBLIC_HOST:-}" ]; then PUBLIC_HOST_SET=1; else PUBLIC_HOST_SET=0; fi
# Publishing is on by default. `--no-serve` / HERMEY_SERVE=no is for hosts that front the service
# themselves (Caddy, an existing reverse proxy, a port already mounted by hand).
SERVE=${HERMEY_SERVE:-yes}
case "$SERVE" in no|NO|No|0|false) SERVE=no ;; *) SERVE=yes ;; esac
TS_BIN=${HERMEY_TAILSCALE:-}
FROM_SOURCE=0
UNINSTALL=0
PURGE=0
PUBLISHED=0
PAIR_CODE=""
PAIR_URL=""
SERVE_LINE=""
BASE=""
OS=""
SRC=""

BIN_NAME=hermeyd
BIN="$PREFIX/bin/$BIN_NAME"
UNIT=hermeyd
UNIT_FILE="$UNIT_DIR/$UNIT.service"
PLIST="$CONF/com.hermeyd.plist"
PLUGIN=hermes-genui
TMP=""

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# Every failure says what to do next. A half-installed host that exits 0 is the failure this
# installer is written to avoid.
fail() {
    printf 'error: %s\n' "$1" >&2
    shift
    for line in "$@"; do printf '  %s\n' "$line" >&2; done
    exit 1
}

cleanup() {
    if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
}
trap cleanup EXIT INT TERM

usage() {
    cat <<'USAGE'
Hermey host installer (hermeyd)

  sudo sh install.sh [options]

  --from-source        build hermeyd with cargo instead of downloading a release binary
  --version TAG        release to install: a tag (v0.2.0) or "latest" (default: latest)
  --prefix DIR         where the binary goes (default: /opt/hermey)
  --state-dir DIR      hermeyd's state directory (default: /var/lib/hermeyd)
  --engine-home DIR    the Hermes engine home — the directory containing profiles/ (default: detect)
  --user NAME          the account hermeyd runs as; must be the engine's owner (default: detect)
  --uninstall          stop and remove the service, binary, config and plugin; keep state
  --purge              with --uninstall: also delete the state directory
  --no-serve           do not publish with `tailscale serve`; print the command instead
  -h, --help           this text

Environment overrides: HERMEY_REPO, HERMEY_VERSION, HERMEY_BASE_URL, HERMEY_PREFIX,
HERMEY_STATE, HERMEY_CONF, HERMEY_UNIT_DIR, HERMEY_USER, HERMEY_GROUP, HERMEYD_ENGINE_HOME, HERMEYD_PORT,
HERMEYD_BROWSER_PORT, HERMEYD_PUBLIC_HOST, HERMEY_SERVE, HERMEY_TAILSCALE, HERMES_HOME, HERMEY_SRC.

Exit status: 0 on success, 1 on a failure the message explains, 2 on bad usage.
USAGE
}

# ---------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --from-source) FROM_SOURCE=1; shift ;;
        --version)     [ $# -ge 2 ] || fail "--version needs a tag" "try --help"; VERSION=$2; shift 2 ;;
        --prefix)      [ $# -ge 2 ] || fail "--prefix needs a directory" "try --help"; PREFIX=$2; shift 2 ;;
        --state-dir)   [ $# -ge 2 ] || fail "--state-dir needs a directory" "try --help"; STATE=$2; shift 2 ;;
        --engine-home) [ $# -ge 2 ] || fail "--engine-home needs a directory" "try --help"; ENGINE_HOME=$2; shift 2 ;;
        --user)        [ $# -ge 2 ] || fail "--user needs an account name" "try --help"; SVC_USER=$2; shift 2 ;;
        --uninstall)   UNINSTALL=1; shift ;;
        --purge)       PURGE=1; shift ;;
        --no-serve)    SERVE=no; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             printf 'error: unknown option %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

BIN="$PREFIX/bin/$BIN_NAME"
PLIST="$CONF/com.hermeyd.plist"

# These knobs arrive from the environment, and `curl | sh` means the environment is attacker
# territory (sudo -E, env_keep, a wrapper script). Everything is validated before it is used as a
# path, a unit name, a port, or written into a root-owned file.
valid_user() { printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; }
valid_path() {
    case "$1" in /*) : ;; *) return 1 ;; esac
    case "$1" in *[[:space:]]*|*..*|*'$'*|*'`'*|*'"'*|*"'"*|*\\*) return 1 ;; esac
    [ "$1" != "/" ]
}
valid_port() { printf '%s' "$1" | grep -Eq '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# The systemctl binary exists on hosts where systemd is not PID 1 (containers, WSL). Restarting a
# unit there fails with a message about a bus, which reads as "the install broke" — so the check is
# whether this machine is actually running systemd.
have_systemd() { [ "$(cat /proc/1/comm 2>/dev/null || true)" = systemd ]; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "this installer writes to $PREFIX, $STATE and $CONF, so it needs root" \
            "re-run it with sudo: sudo sh install.sh $*"
    fi
}

# ---------------------------------------------------------------- platform
# The release asset name. One place, so the installer and the release workflow cannot disagree: CI
# publishes exactly these four binaries and a SHA256SUMS covering them.
detect_target() {
    uname_s=$(uname -s)
    uname_m=$(uname -m)
    case "$uname_s:$uname_m" in
        Linux:x86_64)              TARGET=linux-x86_64 ;;
        Linux:aarch64|Linux:arm64) TARGET=linux-aarch64 ;;
        Darwin:arm64)              TARGET=darwin-arm64 ;;
        Darwin:x86_64)             TARGET=darwin-x86_64 ;;
        *)
            fail "unsupported platform: $uname_s $uname_m" \
                "hermeyd publishes builds for: linux x86_64, linux aarch64, macOS arm64, macOS x86_64." \
                "On another platform, build it from a checkout: setup/install.sh --from-source" \
                "(that needs a Rust toolchain — https://rustup.rs)."
            ;;
    esac
    OS=$(printf '%s' "$uname_s" | tr '[:upper:]' '[:lower:]')
}

# The account hermeyd runs as. It must be the engine's owner: the service writes skills into the
# engine's profiles, and a different UID turns every install into a permission error at runtime.
resolve_user() {
    if [ -z "$SVC_USER" ]; then
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
            SVC_USER=$SUDO_USER
        elif [ -d "$ENGINE_HOME" ]; then
            SVC_USER=$(stat -c %U "$ENGINE_HOME" 2>/dev/null || stat -f %Su "$ENGINE_HOME" 2>/dev/null || true)
        fi
        if [ -z "$SVC_USER" ]; then SVC_USER=root; fi
    fi
    valid_user "$SVC_USER" || fail "HERMEY_USER / --user must be a plain account name (got '$SVC_USER')" \
        "pick the account that owns the Hermes engine home, e.g. --user hermey"
    if [ -z "$SVC_GROUP" ]; then
        SVC_GROUP=$(id -gn "$SVC_USER" 2>/dev/null || true)
        if [ -z "$SVC_GROUP" ]; then SVC_GROUP=$SVC_USER; fi
    fi
    SVC_HOME=$(getent passwd "$SVC_USER" 2>/dev/null | cut -d: -f6 || true)
    if [ -z "$SVC_HOME" ]; then SVC_HOME=${HOME:-/root}; fi
}

# The engine home holds profiles/, and hermeyd reads its .env, profiles and skills from it.
# Detection is deliberately conservative: a wrong guess installs a plugin nobody loads. Only the
# guess is skipped when --engine-home names the path — the validation below is not, because a typo
# there would otherwise write the plugin, env file and unit against a directory that is not there,
# and the failure would surface much later as bots that never load.
detect_engine_home() {
    if [ -z "$ENGINE_HOME" ]; then
        if [ -n "${HERMES_HOME:-}" ]; then
            ENGINE_HOME=$HERMES_HOME
        elif [ -d "$STATE/engine" ]; then
            ENGINE_HOME=$STATE/engine
        elif [ -d "$SVC_HOME/.hermes" ]; then
            ENGINE_HOME=$SVC_HOME/.hermes
        else
            fail "cannot find the Hermes engine home on this host" \
                "it is the directory that contains profiles/ — the one Hermes itself uses." \
                "name it explicitly: setup/install.sh --engine-home /path/to/hermes/home" \
                "(or set HERMES_HOME)."
        fi
    fi
}

# Validation runs for every engine home, detected or named, and before anything is written.
require_engine_home() {
    [ -d "$ENGINE_HOME" ] || fail "engine home $ENGINE_HOME does not exist" \
        "pass --engine-home with the directory Hermes uses (it must contain profiles/)."
    [ -d "$ENGINE_HOME/profiles" ] || fail "engine home $ENGINE_HOME has no profiles/" \
        "that is not a Hermes engine home — pass the directory Hermes itself uses," \
        "the one that contains profiles/ (e.g. --engine-home /root/.hermes)."
}

# ---------------------------------------------------------------- filesystem
ensure_dirs() {
    mkdir -p "$PREFIX/bin" "$CONF" || fail "cannot create $PREFIX/bin and $CONF" \
        "check that / is writable and that --prefix/--state-dir point at real paths."
    if [ ! -d "$STATE" ]; then
        mkdir -p "$STATE" || fail "cannot create the state directory $STATE" \
            "pick another location with --state-dir."
    fi
    chmod 0700 "$STATE"
    chown "$SVC_USER:$SVC_GROUP" "$STATE" 2>/dev/null || \
        warn "could not give $STATE to $SVC_USER:$SVC_GROUP — hermeyd may not be able to write state"
}

# ---------------------------------------------------------------- download
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        fail "no SHA-256 tool on this host (sha256sum or shasum)" \
            "install coreutils (Linux) or use the built-in shasum (macOS), then re-run."
    fi
}

fetch() {
    url=$1
    dest=$2
    proto='=https'
    case "$url" in
        file://*) proto='=file' ;;
        http://*) proto='=http,https' ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto "$proto" --proto-redir "$proto" -o "$dest" "$url" 2>/dev/null || \
            fail "could not download $url" \
                "check this host's network and that the release exists:" \
                "  $BASE" \
                "A host with no outbound access can build instead: setup/install.sh --from-source"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url" || fail "could not download $url" \
            "check this host's network and that the release exists: $BASE" \
            "A host with no outbound access can build instead: setup/install.sh --from-source"
    else
        fail "no downloader on this host (curl or wget)" \
            "install curl, or build from a checkout: setup/install.sh --from-source"
    fi
}

# The published checksum is the entire trust anchor for a prebuilt binary: an asset that does not
# match is not installed, and the message says so rather than suggesting a retry loop.
verify_checksum() {
    file=$1
    sums=$2
    name=$3
    expected=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$sums")
    if [ -z "$expected" ]; then
        fail "SHA256SUMS has no entry for $name" \
            "this release cannot be verified, so nothing was installed." \
            "Use a release that publishes SHA256SUMS, or build from source:" \
            "  sudo setup/install.sh --from-source"
    fi
    actual=$(sha256_of "$file")
    if [ "$actual" != "$expected" ]; then
        fail "checksum mismatch for $name" \
            "  expected $expected" \
            "  got      $actual" \
            "The download is corrupt or is not what this script expects. Nothing was installed." \
            "Re-run once; if it repeats, do not install this release — report it."
    fi
    note "checksum ok: $name"
}

download_binary() {
    if [ -n "$BASE_URL" ]; then
        BASE=$BASE_URL
    elif [ "$VERSION" = latest ]; then
        BASE="https://github.com/$REPO/releases/latest/download"
    else
        case "$VERSION" in v*) tag=$VERSION ;; *) tag=v$VERSION ;; esac
        BASE="https://github.com/$REPO/releases/download/$tag"
    fi
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/hermey-install.XXXXXX") || fail "cannot create a temporary directory" \
        "set TMPDIR to a writable directory and re-run."
    asset="$BIN_NAME-$TARGET"
    say "Downloading hermeyd for $TARGET"
    note "$BASE/$asset"
    fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS"
    fetch "$BASE/$asset" "$TMP/$asset"
    verify_checksum "$TMP/$asset" "$TMP/SHA256SUMS" "$asset"
    install -m 0755 "$TMP/$asset" "$BIN.new" || fail "cannot write $BIN" \
        "check that $PREFIX is writable and on a filesystem that allows executables."
    mv -f "$BIN.new" "$BIN"
}

build_binary() {
    if [ -z "$SRC" ]; then
        here=$(cd -- "$(dirname -- "$0")" && pwd)
        SRC=$(cd -- "$here/.." && pwd)
    fi
    [ -f "$SRC/hermeyd/Cargo.toml" ] || fail "no hermeyd source tree at $SRC" \
        "clone the repository and run the installer from it:" \
        "  git clone https://github.com/macblizzard/hermey && cd hermey" \
        "  sudo setup/install.sh --from-source" \
        "or set HERMEY_SRC to a checkout."
    command -v cargo >/dev/null 2>&1 || fail "cargo is not on PATH, so --from-source cannot build" \
        "install Rust first: https://rustup.rs (then open a new shell)." \
        "Or drop --from-source to install a published binary."
    say "Building hermeyd from $SRC/hermeyd (this takes a few minutes)"
    ( cd "$SRC/hermeyd" && cargo build --release --locked ) || fail "cargo build failed" \
        "the compiler output above names the cause. A missing C toolchain (cc, pkg-config) is the" \
        "usual one; installing build-essential/pkg-config and re-running fixes it." \
        "Or install a published binary: setup/install.sh (without --from-source)."
    SOURCE_BIN="$SRC/hermeyd/target/release/$BIN_NAME"
    [ -x "$SOURCE_BIN" ] || fail "cargo finished but $SOURCE_BIN is missing" \
        "check that hermeyd/Cargo.toml still declares the $BIN_NAME binary."
    install -m 0755 "$SOURCE_BIN" "$BIN.new" || fail "cannot write $BIN" \
        "check that $PREFIX is writable."
    mv -f "$BIN.new" "$BIN"
}

# ---------------------------------------------------------------- plugin
# The apps draw generated-UI cards by loading this plugin's bundle from the engine. Upstream Hermes
# does not ship it, so without this step every card answers 503 and the failure looks like a bug in
# the app. Installed into the engine home, never into hermeyd's own state.
install_plugin() {
    plugins="$ENGINE_HOME/plugins"
    if [ "$FROM_SOURCE" = 1 ]; then
        src_plugin="$SRC/setup/plugins/$PLUGIN"
        [ -d "$src_plugin" ] || fail "the source tree has no $src_plugin" \
            "the plugin bundle belongs in setup/plugins/$PLUGIN; restore it from the repository."
        mkdir -p "$plugins" || fail "cannot create $plugins" \
            "check that $ENGINE_HOME is writable by root."
        rm -rf "${plugins:?}/$PLUGIN"
        cp -R "$src_plugin" "$plugins/$PLUGIN" || fail "cannot copy the plugin into $plugins" \
            "check free space and permissions on $ENGINE_HOME."
    else
        asset="$PLUGIN-plugin.tar.gz"
        fetch "$BASE/$asset" "$TMP/$asset"
        verify_checksum "$TMP/$asset" "$TMP/SHA256SUMS" "$asset"
        # Refuse an archive that would write outside the plugin directory.
        if tar -tzf "$TMP/$asset" 2>/dev/null | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
            fail "$asset contains absolute or parent paths; refusing to extract it" \
                "this release is malformed — do not install it. Report it at" \
                "https://github.com/$REPO/issues"
        fi
        mkdir -p "$plugins" || fail "cannot create $plugins" \
            "check that $ENGINE_HOME is writable by root."
        rm -rf "${plugins:?}/$PLUGIN"
        tar -xzf "$TMP/$asset" -C "$plugins" || fail "cannot extract $asset into $plugins" \
            "check free space and permissions on $ENGINE_HOME."
    fi
    [ -f "$plugins/$PLUGIN/desktop/plugin.js" ] || fail "the plugin did not land at $plugins/$PLUGIN/desktop/plugin.js" \
        "the release asset is malformed; hermeyd is installed but cards will answer 503." \
        "Report it at https://github.com/$REPO/issues"
    chown -R "$SVC_USER:$SVC_GROUP" "$plugins/$PLUGIN" 2>/dev/null || true
    note "plugin: $plugins/$PLUGIN"
}

# ---------------------------------------------------------------- configuration
write_env() {
    engine_token="$ENGINE_HOME/../engine.token"
    if [ ! -f "$engine_token" ]; then engine_token="$STATE/engine.token"; fi
    ENVFILE="$CONF/hermeyd.env"
    if [ -f "$ENVFILE" ]; then
        # An upgrade must not reset ports or a public host name the owner chose.
        chmod 0640 "$ENVFILE"
        note "kept existing $ENVFILE (delete it to regenerate)"
        return 0
    fi
    cat > "$ENVFILE" <<EOF
# hermeyd configuration — written by setup/install.sh. Read as a systemd EnvironmentFile.
# Every value here is an environment variable hermeyd reads at boot; there is no config file.
HERMEY_HOME=$STATE
HERMEYD_PORT=$MAIN_PORT
HERMEYD_BROWSER_PORT=$BROWSER_PORT
HERMEYD_BIND=127.0.0.1
HERMEYD_ENGINE_HOME=$ENGINE_HOME
HERMEYD_ENGINE_WS=ws://127.0.0.1:9121/api/ws
HERMEYD_ENGINE_TOKEN_FILE=$engine_token
# What a pairing invite tells the app. On a tailnet this is <host>.ts.net; the apps add no port
# because tailscale serve publishes serve-root.
HERMEYD_PUBLIC_HOST=$PUBLIC_HOST
EOF
    chmod 0640 "$ENVFILE"
    chown "root:$SVC_GROUP" "$ENVFILE" 2>/dev/null || true
    note "wrote $ENVFILE"
}

# ---------------------------------------------------------------- service
install_unit() {
    if [ "$OS" = linux ]; then
        mkdir -p "$UNIT_DIR" || fail "cannot create $UNIT_DIR for the systemd unit" \
            "check that /etc is writable, or point HERMEY_UNIT_DIR at a directory that is."
        cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Hermey host service (hermeyd) — pairing, devices, tickets
Documentation=https://github.com/$REPO/blob/main/docs/HERMEYD.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_GROUP
WorkingDirectory=$PREFIX
EnvironmentFile=-$CONF/hermeyd.env
ExecStart=$BIN
Restart=always
RestartSec=2

# Loopback networking and its own state, nothing else. ProtectHome is deliberately off: the engine
# home is often under the service account's home, and hermeyd has to read profiles and write a bot's
# skill into them.
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=no
ReadWritePaths=$STATE $ENGINE_HOME
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
        chmod 0644 "$UNIT_FILE"
        note "installed $UNIT_FILE"
    else
        # launchd is not loaded from here. An installer that bootstraps a daemon on a laptop without
        # saying so is a malware pattern; printing the two commands is one paste.
        cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.hermeyd</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HERMEY_HOME</key><string>$STATE</string>
    <key>HERMEYD_ENGINE_HOME</key><string>$ENGINE_HOME</string>
    <key>HERMEYD_PORT</key><string>$MAIN_PORT</string>
    <key>HERMEYD_PUBLIC_HOST</key><string>$PUBLIC_HOST</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$STATE/hermeyd.log</string>
  <key>StandardErrorPath</key><string>$STATE/hermeyd.log</string>
</dict>
</plist>
EOF
        chmod 0644 "$PLIST"
        note "wrote $PLIST"
    fi
}

start_service() {
    if [ "$OS" != linux ]; then
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1 || ! have_systemd; then
        warn "systemd is not running here, so the unit was written but not started."
        note "start it by hand: HERMEY_HOME=$STATE $BIN"
        return 0
    fi
    mkdir -p "$UNIT_DIR"
    systemctl daemon-reload || fail "systemctl daemon-reload failed" \
        "the unit at $UNIT_FILE may be malformed; fix it and run 'systemctl daemon-reload'."
    systemctl enable "$UNIT" >/dev/null 2>&1 || warn "could not enable $UNIT at boot"
    if systemctl restart "$UNIT"; then
        note "restarted $UNIT"
    else
        fail "the $UNIT service did not start" \
            "its log says why: journalctl -u $UNIT -n 50 --no-pager" \
            "the binary is installed at $BIN; fix the cause and run 'systemctl restart $UNIT'."
    fi
    if ! systemctl is-active --quiet "$UNIT"; then
        warn "$UNIT is not active right after starting"
        note "check: journalctl -u $UNIT -n 50 --no-pager"
    fi
}

# A duplicate gateway is not this installer's failure to abort on — the host is otherwise fine — but
# it is the exact cause of every routine firing twice, so it is reported with the remedy.
gateway_check() {
    if [ ! -x "$BIN" ]; then return 0; fi
    set +e
    out=$(HERMEY_HOME="$STATE" HERMEYD_ENGINE_HOME="$ENGINE_HOME" "$BIN" --gateway-check 2>&1)
    status=$?
    set -e
    if [ "$status" -eq 75 ]; then
        warn "another Hermes gateway already serves $ENGINE_HOME (hermeyd --gateway-check exited 75)"
        printf '%s\n' "$out" | sed 's/^/  /'
        note "Fix: stop that process, or run the engine isolated for this home:"
        note "  hermes serve --isolated"
        note "Nothing was killed — routines would otherwise fire twice."
    elif [ "$status" -ne 0 ]; then
        warn "hermeyd --gateway-check failed (exit $status); the service may still run"
        printf '%s\n' "$out" | sed 's/^/  /'
    else
        note "gateway-check: clear to run"
    fi
}

# ---------------------------------------------------------------- verification
verify() {
    [ -x "$BIN" ] || fail "the binary is not executable at $BIN" \
        "check the filesystem's mount options (a noexec mount cannot run it)." \
        "Pick another --prefix."
    version=$("$BIN" --version 2>/dev/null || true)
    [ -n "$version" ] || fail "$BIN did not answer --version" \
        "the binary is for another architecture or is corrupt — this is what the checksum guards." \
        "Re-run the installer; if it repeats, report it at https://github.com/$REPO/issues"
    note "$version"

    if [ "$OS" = linux ] && command -v systemctl >/dev/null 2>&1 && have_systemd; then
        tries=0
        while [ "$tries" -lt 10 ]; do
            if curl -fsS "http://127.0.0.1:$MAIN_PORT/v1/health" >/dev/null 2>&1; then
                note "health: http://127.0.0.1:$MAIN_PORT/v1/health answers"
                return 0
            fi
            tries=$((tries + 1))
            sleep 1
        done
        warn "the service is running but /v1/health did not answer within 10s"
        note "check: journalctl -u $UNIT -n 50 --no-pager"
    fi
}

# ---------------------------------------------------------------- publishing
# A host nobody can reach is a host that was not installed. hermeyd binds loopback and nothing
# else, so the serve root is what turns it into `https://<node>.ts.net/?code=…`, and this script
# runs `tailscale serve` rather than handing the reader a command. The branches that end with a
# command are the ones nothing here can act on: no binary, no login, a root another service owns,
# and --no-serve.

# `tailscale`, from the override first and then PATH. Empty means this host has no tailnet client.
tailscale_bin() {
    if [ -n "$TS_BIN" ]; then
        command -v "$TS_BIN" 2>/dev/null || true
        return 0
    fi
    command -v tailscale 2>/dev/null || true
}

# A tailscale call that fails is a branch to report, not a reason to abort an otherwise finished
# install, so these return what was printed and let the caller read the state.
ts_status() { "$1" status --json 2>/dev/null || true; }
ts_serve() { "$1" serve status --json 2>/dev/null || true; }

# "Running" is the only BackendState that can serve; NeedsLogin and Stopped cannot, and that is the
# difference between "install the command for later" and "run it now".
ts_state() {
    printf '%s' "$1" | tr -d ' \t\r\n' \
        | sed -n 's/.*"BackendState":"\([^"]*\)".*/\1/p' | head -1 || true
}

# The MagicDNS name of this node, without the trailing dot tailscale prints on it. Everything after
# "Self" is a peer list whose entries also carry a DNSName, so the match is anchored at the first one.
ts_node() {
    printf '%s' "$1" | tr -d ' \t\r\n' \
        | sed 's/^[^{]*"Self":{//' \
        | sed -n 's/^[^}]*"DNSName":"\([^"]*\)".*/\1/p' \
        | head -1 | sed 's/\.$//' || true
}

# The proxy behind the serve root — the "/" handler on :443, which is the URL a pairing link names.
# jq is not a dependency an installer can assume, so this reads the flattened JSON: the handler
# object has no nested braces, which makes the root readable without a parser. Empty output means
# serve has no root yet, the only case where taking it is not taking something from someone.
ts_root() {
    flat=$(printf '%s' "$1" | tr -d ' \t\r\n')
    case "$flat" in *':443":{"Handlers"'*) : ;; *) return 0 ;; esac
    printf '%s' "$flat" | sed 's@.*:443":{"Handlers":{@@' | sed 's@}}.*@@' \
        | grep -o '"/":{"Proxy":"[^"]*"' 2>/dev/null \
        | sed 's@.*"Proxy":"@@; s@"$@@' | head -1 || true
}

# The first https port serve is not already terminating, so the alternative command in the
# foreign-root case is printable as one paste.
ts_free_port() {
    port=8443
    while printf '%s' "$1" | grep -q "\"$port\":{"; do
        port=$((port + 1))
        if [ "$port" -gt 8460 ]; then break; fi
    done
    printf '%s' "$port"
}

# The pairing URL is built from HERMEYD_PUBLIC_HOST, which a fresh install sets to localhost — a
# URL no phone can open. Unless the owner named a host, the name this node reports is written in and
# the service restarted, so `hermeyd pair` here and later prints the URL that actually works. A name
# already in the file is the owner's choice from an earlier install and is kept.
adopt_public_host() {
    [ "$PUBLIC_HOST_SET" = 0 ] || return 0
    [ -n "$1" ] || return 0
    [ -r "$ENVFILE" ] || return 0
    current=$(sed -n 's/^HERMEYD_PUBLIC_HOST=//p' "$ENVFILE" | head -1 || true)
    if [ -n "$current" ] && [ "$current" != localhost ] && [ "$current" != 127.0.0.1 ]; then
        PUBLIC_HOST=$current
        return 0
    fi
    [ "$PUBLIC_HOST" != "$1" ] || return 0
    if [ -n "$current" ]; then
        sed "s|^HERMEYD_PUBLIC_HOST=.*|HERMEYD_PUBLIC_HOST=$1|" "$ENVFILE" > "$ENVFILE.tmp" || return 0
    else
        { cat "$ENVFILE"; printf 'HERMEYD_PUBLIC_HOST=%s\n' "$1"; } > "$ENVFILE.tmp" || return 0
    fi
    chmod 0640 "$ENVFILE.tmp" 2>/dev/null || true
    mv -f "$ENVFILE.tmp" "$ENVFILE" || return 0
    PUBLIC_HOST=$1
    note "pairing host: $1 (HERMEYD_PUBLIC_HOST in $ENVFILE)"
    if [ "$OS" = linux ] && command -v systemctl >/dev/null 2>&1 && have_systemd; then
        systemctl restart "$UNIT" >/dev/null 2>&1 || warn "could not restart $UNIT after the pairing-host change"
        tries=0
        while [ "$tries" -lt 10 ]; do
            if curl -fsS "http://127.0.0.1:$MAIN_PORT/v1/health" >/dev/null 2>&1; then break; fi
            tries=$((tries + 1))
            sleep 1
        done
    fi
}

# Mint a code with the installed binary rather than inventing a URL: what is printed here is what
# the app will open. A service that cannot be paired with (no systemd, so not started) leaves the
# shape of the URL and says where the live code comes from.
mint_pairing() {
    host=$1
    out=""
    if [ -x "$BIN" ] && [ -n "$host" ]; then
        out=$(HERMEY_HOME="$STATE" HERMEYD_PORT="$MAIN_PORT" "$BIN" pair --host "$host" 2>/dev/null || true)
    fi
    PAIR_CODE=$(printf '%s' "$out" | sed -n 's/^pairing code  *//p' | head -1)
    PAIR_URL=$(printf '%s' "$out" | sed -n 's/^pairing URL  *//p' | head -1)
    if [ -z "$PAIR_URL" ] && [ -n "$host" ]; then
        PAIR_URL="https://$host/?code=…"
    fi
    PUBLISHED=1
}

publish() {
    want="http://127.0.0.1:$MAIN_PORT"
    SERVE_LINE="Reachable at $want on this host only."
    if [ "$SERVE" != yes ]; then
        note "serve: skipped (--no-serve)"
        SERVE_LINE="Reachable at $want on this host only — --no-serve was given; publish it when you want: tailscale serve --bg $want"
        return 0
    fi
    ts=$(tailscale_bin)
    if [ -z "$ts" ]; then
        note "serve: no tailscale on this host, so nothing was published"
        SERVE_LINE="Reachable at $want on this host only — install Tailscale and log in, then run: tailscale serve --bg $want"
        return 0
    fi
    status_json=$(ts_status "$ts")
    state=$(ts_state "$status_json")
    if [ "$state" != Running ]; then
        note "serve: tailscale is installed but this node is ${state:-not answering}, so nothing was published"
        SERVE_LINE="Reachable at $want on this host only — run 'tailscale up' and log in, then: tailscale serve --bg $want"
        return 0
    fi
    node=$(ts_node "$status_json")
    serve_json=$(ts_serve "$ts")
    root=$(ts_root "$serve_json")
    if [ -n "$root" ] && [ "$root" != "$want" ]; then
        alt=$(ts_free_port "$serve_json")
        warn "the tailscale serve root already points at $root — left as it is"
        note "publish beside it instead:"
        note "  tailscale serve --https=$alt $want"
        note "pairing URLs then carry the port: https://${node:-<host>}:$alt/?code=…"
        note "and $ENVFILE needs HERMEYD_PUBLIC_HOST=${node:-<host>}:$alt, then: systemctl restart $UNIT"
        SERVE_LINE="Reachable at $want on this host only — https://${node:-<host>}/ belongs to $root, so nothing published over it. Run the --https=$alt command above to have both."
        return 0
    fi
    if [ -n "$root" ]; then
        note "serve: the root already publishes $want"
    elif "$ts" serve --bg "$want" >/dev/null 2>&1; then
        note "serve: published $want at the root"
    else
        warn "tailscale serve --bg $want did not succeed"
        SERVE_LINE="Reachable at $want on this host only — run it by hand to see why: tailscale serve --bg $want"
        return 0
    fi
    if [ -z "$node" ]; then
        note "serve: published $want, but this node reported no MagicDNS name"
        SERVE_LINE="Reachable at $want on this host only — tailscale reported no MagicDNS name for this node; check 'tailscale status'"
        return 0
    fi
    adopt_public_host "$node"
    # The host the app dials: the owner's name when there is one, the MagicDNS name otherwise.
    pair_host=$PUBLIC_HOST
    if [ -z "$pair_host" ] || [ "$pair_host" = localhost ] || [ "$pair_host" = 127.0.0.1 ]; then
        pair_host=$node
    fi
    mint_pairing "$pair_host"
    note "8790 is not published: the browser channel is loopback-only."
    SERVE_LINE="Reachable at https://$node/ from your tailnet."
}

# Take down the mapping this installer made, and only that one: the root is removed when it points
# at this install's port. A root that points anywhere else belongs to somebody else.
unpublish() {
    if [ "$SERVE" != yes ]; then
        note "serve: left alone (--no-serve)"
        return 0
    fi
    ts=$(tailscale_bin)
    if [ -z "$ts" ]; then
        note "serve: no tailscale on this host, so there is no mapping to take down"
        return 0
    fi
    want="http://127.0.0.1:$MAIN_PORT"
    root=$(ts_root "$(ts_serve "$ts")")
    if [ -z "$root" ]; then
        note "serve: no root mapping to remove"
        return 0
    fi
    if [ "$root" != "$want" ]; then
        note "serve: the root points at $root, not at $want — left in place"
        return 0
    fi
    if "$ts" serve --https=443 --set-path=/ off >/dev/null 2>&1; then
        note "serve: removed the root mapping to $want"
    else
        warn "could not remove the serve root mapping to $want"
        note "remove it by hand: tailscale serve --https=443 --set-path=/ off"
    fi
}

next_steps() {
    printf '\n'
    say "Installed."
    note "binary:  $BIN"
    note "state:   $STATE (0700, owned by $SVC_USER)"
    note "config:  $CONF/hermeyd.env"
    note "plugin:  $ENGINE_HOME/plugins/$PLUGIN"
    note "token:   $STATE/local.token (0600, minted on first boot — the CLIs read it, never paste it)"
    printf '\n'
    say "Start the engine this service relays to:"
    note "hermes serve --isolated          # one gateway per HERMES_HOME; --isolated is required"
    if [ "$PUBLISHED" = 1 ]; then
        printf '\n'
        say "Pair a device:"
        if [ -n "$PAIR_CODE" ]; then note "code  $PAIR_CODE"; fi
        note "url   $PAIR_URL"
        note "single use, ten minutes. 'hermeyd pair' mints another and prints its QR."
    fi
    printf '\n'
    say "Verify:"
    note "curl -fsS http://127.0.0.1:$MAIN_PORT/v1/health"
    note "curl -fsS -X POST http://127.0.0.1:$MAIN_PORT/v1/pair/start   # code for the app"
    printf '\n'
    say "$SERVE_LINE"
}

# ---------------------------------------------------------------- uninstall
do_uninstall() {
    need_root --uninstall
    say "Removing hermeyd"

    # The engine home and the state directory survive by default; read the engine home back from the
    # config, because the caller usually does not pass it again.
    ENVFILE="$CONF/hermeyd.env"
    if [ -z "$ENGINE_HOME" ] && [ -r "$ENVFILE" ]; then
        ENGINE_HOME=$(sed -n 's/^HERMEYD_ENGINE_HOME=//p' "$ENVFILE" | head -1)
    fi

    if [ "$OS" = darwin ]; then
        if command -v launchctl >/dev/null 2>&1; then
            launchctl bootout "system/com.hermeyd" >/dev/null 2>&1 || true
        fi
        rm -f "/Library/LaunchDaemons/com.hermeyd.plist"
        note "removed /Library/LaunchDaemons/com.hermeyd.plist"
    else
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
        fi
        rm -f "$UNIT_FILE"
        if command -v systemctl >/dev/null 2>&1 && have_systemd; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        note "removed $UNIT_FILE"
    fi

    rm -f "$BIN"
    rmdir "$PREFIX/bin" 2>/dev/null || true
    rmdir "$PREFIX" 2>/dev/null || true
    note "removed $BIN"

    rm -f "$ENVFILE" "$PLIST"
    rmdir "$CONF" 2>/dev/null || true
    note "removed $ENVFILE"

    if [ -n "$ENGINE_HOME" ] && [ -d "$ENGINE_HOME/plugins/$PLUGIN" ]; then
        rm -rf "$ENGINE_HOME/plugins/$PLUGIN"
        note "removed $ENGINE_HOME/plugins/$PLUGIN"
    fi

    if [ "$PURGE" = 1 ]; then
        rm -rf "$STATE"
        say "Purged $STATE (devices and pairing are gone; every app must pair again)."
    else
        say "Service removed. State kept in $STATE — delete it with --uninstall --purge."
    fi
    unpublish
}

# ---------------------------------------------------------------- install
main() {
    need_root "$@"

    valid_path "$PREFIX" || fail "--prefix must be an absolute path without spaces or '..' (got '$PREFIX')"
    valid_path "$STATE"  || fail "--state-dir must be an absolute path without spaces or '..' (got '$STATE')"
    valid_path "$CONF"   || fail "the config directory must be absolute (got '$CONF')"
    if [ "$PREFIX" = "$STATE" ] || [ "$STATE" = "$CONF" ]; then
        fail "prefix, state and config must be different directories" \
            "pick distinct --prefix/--state-dir values."
    fi
    valid_port "$MAIN_PORT"    || fail "HERMEYD_PORT must be 1-65535 (got '$MAIN_PORT')" \
        "pick a free loopback port, e.g. HERMEYD_PORT=8788."
    valid_port "$BROWSER_PORT" || fail "HERMEYD_BROWSER_PORT must be 1-65535 (got '$BROWSER_PORT')" \
        "the browser channel needs its own port, e.g. 8790."
    if [ "$MAIN_PORT" = "$BROWSER_PORT" ]; then
        fail "HERMEYD_PORT and HERMEYD_BROWSER_PORT must differ" \
            "hermeyd refuses to serve the browser channel on the published port."
    fi

    detect_target
    say "Hermey host installer — $TARGET"

    if [ "$FROM_SOURCE" = 1 ] && [ -z "$SRC" ]; then
        # Building needs the checkout, so it is resolved before anything else; install_plugin reads
        # the vendored plugin out of the same tree.
        here=$(cd -- "$(dirname -- "$0")" && pwd)
        SRC=$(cd -- "$here/.." && pwd)
    fi

    resolve_user
    detect_engine_home
    valid_path "$ENGINE_HOME" || fail "--engine-home must be an absolute path without spaces (got '$ENGINE_HOME')" \
        "pass the directory Hermes uses, e.g. /var/lib/hermes."
    require_engine_home
    note "engine:  $ENGINE_HOME"
    note "service: $SVC_USER:$SVC_GROUP"

    ensure_dirs
    if [ "$FROM_SOURCE" = 1 ]; then
        build_binary
    else
        download_binary
    fi
    install_plugin
    write_env
    install_unit
    start_service
    gateway_check
    verify
    publish

    if [ "$OS" = darwin ]; then
        printf '\n'
        say "This host uses launchd. Load the service yourself:"
        note "sudo cp $PLIST /Library/LaunchDaemons/com.hermeyd.plist"
        note "sudo launchctl bootstrap system /Library/LaunchDaemons/com.hermeyd.plist"
        note "sudo launchctl kickstart -k system/com.hermeyd"
    fi
    next_steps
}

if [ "$PURGE" = 1 ] && [ "$UNINSTALL" != 1 ]; then
    fail "--purge only makes sense with --uninstall" "remove state with: sudo sh install.sh --uninstall --purge"
fi

if [ "$UNINSTALL" = 1 ]; then
    OS=$(printf '%s' "$(uname -s)" | tr '[:upper:]' '[:lower:]')
    do_uninstall
    exit 0
fi

main "$@"
