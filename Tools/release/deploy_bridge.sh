#!/usr/bin/env bash
# Deploy the bridge from this checkout: install the package into the venv the service runs, restart it.
#
# The reason this exists: the bridge on this host was once updated by copying files into
# `site-packages`, which left the running code impossible to trace back to a commit, and a systemd unit
# pointing at a *different* older tree. One command, one source of truth.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV="${HERMES_BRIDGE_VENV:-/opt/hermey/venv}"
# The unit `setup/install.sh` creates is the default, because that is what a fresh install runs.
UNIT="${HERMES_BRIDGE_UNIT:-hermey-bridge}"
# …but a host that was first set up under the predecessor's name keeps serving from *that* unit: the
# installer's name is a second unit on the same loopback port, so it can never bind while the older one
# runs, and restarting it only ever produced an EADDRINUSE crash loop while the live bridge kept the old
# code in memory (found 2026-11-15 on this host). If the default name is not the running one, follow the
# active predecessor instead of pretending the deploy worked.
if [[ -z "${HERMES_BRIDGE_UNIT:-}" ]] && ! systemctl is-active --quiet "$UNIT"; then
  for candidate in hermes-native-bridge hermey-bridge; do
    if systemctl is-active --quiet "$candidate"; then UNIT="$candidate"; break; fi
  done
fi
echo "unit: $UNIT"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "no python in $VENV — set HERMES_BRIDGE_VENV to the venv the unit runs" >&2
  exit 1
fi

echo "installing $REPO_ROOT/Bridge into $VENV"
"$VENV/bin/pip" install -q --force-reinstall --no-deps "$REPO_ROOT/Bridge"

# Say what is about to be running, so a mismatch is visible rather than discovered later.
"$VENV/bin/python" - <<'PY'
import pathlib
import hermes_bridge
root = pathlib.Path(hermes_bridge.__file__).parent
print(f"module: {root}")
for module in ("workspace", "policy", "proxy"):
    print(f"  {module}.py: {(root / (module + '.py')).exists()}")
PY

echo "restarting $UNIT"
# A plain `restart` can race itself: the old process is still holding the loopback port when the new
# one binds, the new one dies with EADDRINUSE, and systemd retries until it happens to win — which
# looks like a deploy that "worked" while the journal fills with bind errors. Stopping first, and
# waiting for the port to be genuinely free, makes it one start.
systemctl stop "$UNIT" 2>/dev/null || true
PORT="${HERMES_BRIDGE_PORT:-8787}"
for _ in $(seq 1 40); do
  ss -ltn 2>/dev/null | grep -q "127.0.0.1:${PORT} " || break
  sleep 0.5
done
systemctl start "$UNIT"
sleep 2
systemctl is-active "$UNIT"
systemctl show "$UNIT" -p ExecStart --value | head -1
