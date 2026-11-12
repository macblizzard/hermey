#!/usr/bin/env bash
# Deploy the bridge from this checkout: install the package into the venv the service runs, restart it.
#
# The reason this exists: the bridge on this host was once updated by copying files into
# `site-packages`, which left the running code impossible to trace back to a commit, and a systemd unit
# pointing at a *different* older tree. One command, one source of truth.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV="${HERMES_BRIDGE_VENV:-/opt/hermey/venv}"
# The unit `setup/install.sh` creates. It used to default to the retired predecessor unit
# (`hermes-native-bridge`), so a deploy could install the new package and restart a unit nobody was
# serving from — reporting success while the live bridge kept the old code in memory.
UNIT="${HERMES_BRIDGE_UNIT:-hermey-bridge}"

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
systemctl restart "$UNIT"
sleep 2
systemctl is-active "$UNIT"
systemctl show "$UNIT" -p ExecStart --value | head -1
