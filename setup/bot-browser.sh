#!/usr/bin/env bash
# Make the bot desktop able to fill a login form — the part a fresh install cannot guess.
#
# Three things have to be true, and none of them is obvious from the outside:
#
#   1. The sign-in extension is on disk, in ONE fixed directory that the browser's user can read. The
#      bridge writes it on every start; this is the fallback for a host where the bridge's own directory
#      is not writable.
#   2. The browser is launched with --load-extension. That lives in the agent's browser.py, which
#      `hermes update` overwrites, so this script re-applies it and is safe to run again.
#   3. The browser honours the flag. Stable Chrome 137+ accepts --load-extension and loads NOTHING, with no
#      error anywhere — verified here against 158 and against Chrome for Testing 145. Only a Chrome for
#      Testing 148 build loaded the extension, so this check exists to say so out loud.
#
# Everything is idempotent: running it twice changes nothing the second time.
set -euo pipefail

EXT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/browser-extension"
EXT_DST="/opt/hermes-extension/hermey-signin"
BROWSER_PY="/usr/local/lib/hermes-agent/tools/bot_desktop/browser.py"
DROPIN="/etc/systemd/system/hermes-native-bridge.service.d/10-signin-extension.conf"

say() { printf '  %s\n' "$*"; }

# 1. the extension itself
if [ -f "$EXT_SRC/manifest.json" ]; then
  mkdir -p "$EXT_DST"
  cp "$EXT_SRC"/{manifest.json,background.js,popup.html,popup.js} "$EXT_DST"/ 2>/dev/null || true
  chmod -R a+rX /opt/hermes-extension 2>/dev/null || true
  say "extension: $EXT_DST"
else
  say "extension: source missing at $EXT_SRC — skipped"
fi

# 2. the launcher flag, re-applied because the agent tree is overwritten by updates
if [ -f "$BROWSER_PY" ]; then
  if grep -q "SIGNIN_EXTENSION_HOMES" "$BROWSER_PY"; then
    say "launcher: already patched"
  else
    python3 - "$BROWSER_PY" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if "SIGNIN_EXTENSION" in s:
    raise SystemExit(0)
s = s.replace('_SYSTEM_BROWSERS = (', '''SIGNIN_EXTENSION = "hermey-signin"
SIGNIN_EXTENSION_HOMES = ("/opt/hermes-extension", "/var/lib/hermey/extension")


def signin_extension_dir(user_data_dir: str) -> str:
    """One fixed home first: it must be readable by the browser's user and must not move with a profile."""
    import os
    for root in SIGNIN_EXTENSION_HOMES:
        candidate = os.path.join(root, SIGNIN_EXTENSION)
        if os.path.isfile(os.path.join(candidate, "manifest.json")):
            return candidate
    return os.path.join(os.path.dirname(user_data_dir), "extension", SIGNIN_EXTENSION)


def _signin_extension_args(user_data_dir: str) -> list:
    import os
    path = signin_extension_dir(user_data_dir)
    if not os.path.isfile(os.path.join(path, "manifest.json")):
        return []
    return [f"--load-extension={path}", f"--disable-extensions-except={path}",
            "--disable-features=DisableLoadExtensionCommandLineSwitch"]


_SYSTEM_BROWSERS = (''', 1)
s = s.replace('"--no-default-browser-check", *SHARED_PROFILE_ARGS,',
              '"--no-default-browser-check", *_signin_extension_args(user_data_dir), *SHARED_PROFILE_ARGS,', 1)
p.write_text(s)
print("  launcher: patched")
PY
  fi
else
  say "launcher: $BROWSER_PY not found — is Hermes installed?"
fi

# 3. the service must be allowed to write that directory (ProtectSystem=strict makes /opt read-only)
if [ "$(id -u)" = "0" ] && [ -d /etc/systemd/system ]; then
  mkdir -p "$(dirname "$DROPIN")"
  if [ ! -f "$DROPIN" ]; then
    printf '[Service]\nReadWritePaths=/opt/hermes-extension\n' > "$DROPIN"
    systemctl daemon-reload 2>/dev/null || true
    say "service: drop-in added ($DROPIN)"
  else
    say "service: drop-in present"
  fi
else
  say "service: skipped (needs root; the bridge will fall back to its own state directory)"
fi

# 4. say plainly whether the browser can carry the extension
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
else
  say "browser: none resolved — the bot desktop cannot open one"
fi

echo "done."
