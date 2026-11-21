#!/usr/bin/env bash
# Make the bot desktop able to fill a login form — the part a fresh install cannot guess.
#
# Four things have to be true, and none of them is obvious from the outside:
#
#   1. The browser must be one that honours --load-extension. Stable Google Chrome 137+ accepts the flag and
#      loads NOTHING, silently. Chrome for Testing works. So this script provisions Chrome for Testing under
#      /opt/hermes-chromium and points the launcher at it.
#   2. The sign-in extension must be on disk at a path the browser's user can read. The bridge writes it on
#      every start into /opt/hermes-extension; this is the fallback for a host where that is not writable.
#      Each version gets its OWN directory, because Chrome binds an unpacked extension to its path and never
#      reloads changed files — an update written into the old directory is invisible, with no error anywhere.
#   3. The launcher must pass the flag. That logic lives in the agent's browser.py, which `hermes update`
#      overwrites, so it is re-applied here and is safe to run again.
#   4. The browser must never offer to save a password. It types the owner's credentials by design, and a
#      prompt over the page hides the field it is about to fill. Chrome rewrites Preferences from memory on
#      shutdown, so the switch is written with the browser stopped, at every launch.
#
# Everything is idempotent: running it twice changes nothing the second time.
set -euo pipefail

# ---------------------------------------------------------------- retired with the Python bridge
# Everything here ends in a systemd drop-in for `hermey-bridge.service`, the unit the Python bridge
# ran as. That service no longer exists, so this would add a drop-in for a unit nothing creates and
# report success. Refuse, and point at the host service this repository actually ships.
cat >&2 <<'MESSAGE'
bot-browser: the Python bridge was removed from this repository; install hermeyd instead.

This script provisions Chrome and writes a systemd drop-in for `hermey-bridge.service`. The host
service is `hermeyd` now (see docs/HERMEYD.md and deploy/hermeyd.service), and the sign-in extension
is written by that service rather than refreshed by a drop-in.
MESSAGE
exit 1

EXT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/browser-extension"
EXT_ROOT="/opt/hermes-extension"
BROWSER_PY="/usr/local/lib/hermes-agent/tools/bot_desktop/browser.py"
CHROME_ROOT="/opt/hermes-chromium"
# The unit `setup/install.sh` creates is the default; a host first set up under the predecessor's name
# keeps serving from *that* one, so the drop-in follows whichever is actually running — the same rule
# `Tools/release/deploy_bridge.sh` uses, for the same reason: both names bind one loopback port, and a
# drop-in for the unit that is not there is a no-op that still prints "added". The bridge then cannot
# refresh /opt/hermes-extension, writes the extension into its own state directory instead, while the
# launcher keeps loading the older copy in /opt — a stale extension after an upgrade, all green.
UNIT="${HERMEY_UNIT_PREFIX:-hermey}-bridge"
if ! systemctl is-active --quiet "$UNIT" 2>/dev/null; then
  if systemctl is-active --quiet hermes-native-bridge 2>/dev/null; then
    UNIT="hermes-native-bridge"
  fi
fi
DROPIN="/etc/systemd/system/${UNIT}.service.d/10-signin-extension.conf"

say() { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------------------------------------------
# 1. Chrome for Testing: the only build that actually loads a command-line extension.
# ---------------------------------------------------------------------------------------------------
provision_chrome() {
  if [ -n "${HERMEY_CHROME:-}" ] && [ -x "${HERMEY_CHROME}" ]; then
    say "chrome: using \$HERMEY_CHROME ($HERMEY_CHROME)"
    return 0
  fi
  local existing
  existing=$(find "$CHROME_ROOT" -maxdepth 3 -type f -name chrome 2>/dev/null | head -1 || true)
  if [ -n "$existing" ]; then
    say "chrome: $existing"
    return 0
  fi
  if [ "${HERMEY_SKIP_CHROME_DOWNLOAD:-0}" = "1" ]; then
    say "chrome: not installed and downloading was skipped (HERMEY_SKIP_CHROME_DOWNLOAD=1)"
    return 0
  fi
  say "chrome: downloading Chrome for Testing (stable, linux64)"
  local tmp
  tmp=$(mktemp -d)
  if ! curl -fsSL --max-time 60 \
      https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json \
      -o "$tmp/versions.json"; then
    say "chrome: could not reach the Chrome for Testing index — install it manually and re-run"
    rm -rf "$tmp"
    return 0
  fi
  local url
  url=$(python3 - "$tmp/versions.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for download in data["channels"]["Stable"]["downloads"]["chrome"]:
    if download["platform"] == "linux64":
        print(download["url"])
        break
PY
)
  if [ -z "$url" ]; then
    say "chrome: no linux64 build in the index — skipped"
    rm -rf "$tmp"
    return 0
  fi
  if curl -fsSL --max-time 300 "$url" -o "$tmp/chrome.zip" && unzip -q "$tmp/chrome.zip" -d "$tmp"; then
    mkdir -p "$CHROME_ROOT"
    rm -rf "$CHROME_ROOT/chrome-linux64"
    cp -r "$tmp"/chrome-linux64 "$CHROME_ROOT"/ 2>/dev/null || true
    chmod -R a+rX "$CHROME_ROOT" 2>/dev/null || true
    say "chrome: installed into $CHROME_ROOT/chrome-linux64"
  else
    say "chrome: download failed — install it manually and re-run"
  fi
  rm -rf "$tmp"
}
provision_chrome

# ---------------------------------------------------------------------------------------------------
# 2. The extension, at a version-specific path (path identity is what Chrome caches).
# ---------------------------------------------------------------------------------------------------
EXT_DST=""
if [ -f "$EXT_SRC/manifest.json" ]; then
  EXT_VERSION=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$EXT_SRC/manifest.json")
  EXT_DST="$EXT_ROOT/hermey-signin-$EXT_VERSION"
  rm -rf "$EXT_DST"
  mkdir -p "$EXT_DST"
  cp "$EXT_SRC"/{manifest.json,background.js,popup.html,popup.js} "$EXT_DST"/ 2>/dev/null || true
  chmod -R a+rX "$EXT_ROOT" 2>/dev/null || true
  say "extension: $EXT_DST (version $EXT_VERSION)"
else
  say "extension: source missing at $EXT_SRC — skipped"
fi

# ---------------------------------------------------------------------------------------------------
# 3. The launcher: extension flags, newest-mount selection, and the password-manager switch.
#    Re-applied because the agent tree is overwritten by `hermes update`.
# ---------------------------------------------------------------------------------------------------
if [ -f "$BROWSER_PY" ]; then
  python3 - "$BROWSER_PY" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
changed = []

BLOCK = '''SIGNIN_EXTENSION = "hermey-signin"
# /opt first, deliberately: the bridge state dir is 0750 root, so a browser running as another user cannot
# read an extension installed there — it loads nothing and says nothing.
SIGNIN_EXTENSION_HOMES = ("/opt/hermes-extension", "/var/lib/hermey/extension")


def signin_extension_dir(user_data_dir: str) -> str:
    """Where the sign-in extension lives, newest version first.

    Chrome binds an unpacked extension to its PATH and never reloads changed files, so a fix written into an
    existing directory is invisible: the browser keeps running the code it first loaded. Each version gets its
    own directory, and the highest wins.
    """
    versioned: list[str] = []
    for root in SIGNIN_EXTENSION_HOMES:
        if not os.path.isdir(root):
            continue
        for name in os.listdir(root):
            candidate = os.path.join(root, name)
            if name.startswith(SIGNIN_EXTENSION) and os.path.isfile(os.path.join(candidate, "manifest.json")):
                versioned.append(candidate)
    if versioned:
        def _version(candidate: str) -> tuple:
            try:
                with open(os.path.join(candidate, "manifest.json"), encoding="utf-8") as handle:
                    raw = json.load(handle).get("version", "0")
                return tuple(int(part) for part in str(raw).split(".") if part.isdigit())
            except Exception:  # noqa: BLE001 - an unreadable manifest just sorts last
                return (0,)
        return max(versioned, key=_version)
    for root in SIGNIN_EXTENSION_HOMES:
        candidate = os.path.join(root, SIGNIN_EXTENSION)
        if os.path.isfile(os.path.join(candidate, "manifest.json")):
            return candidate
    return os.path.join(os.path.dirname(user_data_dir), "extension", SIGNIN_EXTENSION)


def disable_password_manager(user_data_dir: str) -> None:
    """Turn the password manager off in the profile before the browser starts.

    Chrome rewrites Preferences from memory on shutdown, so a preference edited while it runs is lost — it has
    to be written with the browser stopped. Chrome for Testing does not read the /etc policy paths, so this
    profile switch is what actually works.
    """
    prefs = os.path.join(user_data_dir, "Default", "Preferences")
    try:
        with open(prefs, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return
    data["credentials_enable_service"] = False
    data["credentials_enable_autofill"] = False
    data.setdefault("profile", {})["password_manager_enabled"] = False
    data.setdefault("autofill", {})["profile_enabled"] = False
    data.setdefault("autofill", {})["credit_card_enabled"] = False
    try:
        with open(prefs, "w", encoding="utf-8") as handle:
            json.dump(data, handle)
    except OSError:
        return


def _signin_extension_args(user_data_dir: str) -> list[str]:
    path_ = signin_extension_dir(user_data_dir)
    if not os.path.isfile(os.path.join(path_, "manifest.json")):
        return []
    return [f"--load-extension={path_}", f"--disable-extensions-except={path_}",
            "--disable-features=DisableLoadExtensionCommandLineSwitch",
            "--no-first-run", "--disable-session-crashed-bubble", "--hide-crash-restore-bubble"]


'''

if "SIGNIN_EXTENSION_HOMES" not in source:
    source = source.replace("_SYSTEM_BROWSERS = (", BLOCK + "_SYSTEM_BROWSERS = (", 1)
    changed.append("extension block")
elif "def disable_password_manager" not in source:
    source = source.replace("def _signin_extension_args", BLOCK.split("def _signin_extension_args")[0].replace(
        'SIGNIN_EXTENSION = "hermey-signin"', '') + "\ndef _signin_extension_args", 1)
    changed.append("password-manager switch")

# The flag has to be in the argv the launcher actually runs.
if "*_signin_extension_args(user_data_dir)" not in source:
    source = source.replace(
        '"--no-default-browser-check", *SHARED_PROFILE_ARGS,',
        '"--no-default-browser-check", *_signin_extension_args(user_data_dir), *SHARED_PROFILE_ARGS,', 1)
    changed.append("extension flags in argv")

# ...and the password-manager switch has to run before every launch, with the profile closed.
for signature in ("def dock_argv(exe: str, user_data_dir: str, *, sandbox_bypass: Optional[bool] = None) -> list[str]:",
                  "def dock_exec_line(exe: str, user_data_dir: str, *, sandbox_bypass: Optional[bool] = None) -> str:"):
    if signature in source and source.split(signature, 1)[1].lstrip().startswith("disable_password_manager"):
        continue
    if signature in source:
        source = source.replace(signature, signature + "\n    disable_password_manager(user_data_dir)", 1)
        changed.append(f"switch before {signature.split('def ')[1].split('(')[0]}")

if changed:
    path.write_text(source)
    print("  launcher: patched (" + ", ".join(changed) + ")")
else:
    print("  launcher: already patched")
PY
else
  say "launcher: $BROWSER_PY not found — is Hermes installed?"
fi

# ---------------------------------------------------------------------------------------------------
# 4. The service must be allowed to write that directory (ProtectSystem=strict makes /opt read-only).
# ---------------------------------------------------------------------------------------------------
if [ "$(id -u)" = "0" ] && [ -d /etc/systemd/system ]; then
  mkdir -p "$(dirname "$DROPIN")"
  if [ ! -f "$DROPIN" ]; then
    printf '[Service]\nReadWritePaths=%s\n' "$EXT_ROOT" > "$DROPIN"
    systemctl daemon-reload 2>/dev/null || true
    say "service: drop-in added ($DROPIN)"
  else
    say "service: drop-in present"
  fi
else
  say "service: skipped (needs root; the bridge will fall back to its own state directory)"
fi

# ---------------------------------------------------------------------------------------------------
# 5. Existing profiles: write the password-manager switch now, so it holds before the next launch.
# ---------------------------------------------------------------------------------------------------
for prefs in /var/lib/hermes/chrome-profile-*/Default/Preferences; do
  [ -f "$prefs" ] || continue
  python3 - "$prefs" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception:
    raise SystemExit(0)
data["credentials_enable_service"] = False
data["credentials_enable_autofill"] = False
data.setdefault("profile", {})["password_manager_enabled"] = False
data.setdefault("autofill", {})["profile_enabled"] = False
json.dump(data, open(path, "w"))
PY
  say "password manager: off for $(dirname "$(dirname "$prefs")")"
done

# ---------------------------------------------------------------------------------------------------
# 6. Say plainly whether the browser can carry the extension.
# ---------------------------------------------------------------------------------------------------
BROWSER_EXE=""
if [ -f "$BROWSER_PY" ] && [ -d /usr/local/lib/hermes-agent ]; then
  BROWSER_EXE=$( cd /usr/local/lib/hermes-agent && \
    env -u PYTHONPATH -u VIRTUAL_ENV python3 -c \
    'from tools.bot_desktop import browser; print(browser.executable() or "")' 2>/dev/null || true )
fi
# A wrapper script is what actually runs; ask the binary it execs, not the wrapper's name.
REAL_BIN="$BROWSER_EXE"
if [ -f "$BROWSER_EXE" ] && head -c 2 "$BROWSER_EXE" 2>/dev/null | grep -q '#!'; then
  REAL_BIN=$(grep -oE '(/[A-Za-z0-9_.-]+)+/chrome' "$BROWSER_EXE" 2>/dev/null | tail -1 || true)
  [ -z "$REAL_BIN" ] && REAL_BIN="$BROWSER_EXE"
fi
if [ -n "$BROWSER_EXE" ]; then
  say "browser: $REAL_BIN"
  BROWSER_VERSION=$( "$REAL_BIN" --version 2>/dev/null || true )
  [ -n "$BROWSER_VERSION" ] && say "  version: $BROWSER_VERSION"
  case "$BROWSER_VERSION" in
    *"Chrome for Testing"*|*Chromium*) say "  loads extensions: yes" ;;
    *"Google Chrome"*) say "  loads extensions: no — stable Chrome 137+ ignores --load-extension silently" ;;
    *) say "  loads extensions: unknown — verify a login card fills before relying on it" ;;
  esac
  if [ -f "$BROWSER_PY" ]; then
    CHOSEN=$( cd /usr/local/lib/hermes-agent && \
      env -u PYTHONPATH -u VIRTUAL_ENV python3 -c \
      'from tools.bot_desktop import browser; print(browser.signin_extension_dir("/var/lib/hermes/chrome-profile-default"))' 2>/dev/null || true )
    [ -n "$CHOSEN" ] && say "  extension chosen: $CHOSEN"
  fi
else
  say "browser: none resolved — the bot desktop cannot open one"
fi

echo "done."
