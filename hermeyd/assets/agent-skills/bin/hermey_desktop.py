#!/usr/bin/env python3
"""Wake, check or stop this host's bot desktop.

The desktop sleeps when nothing is using it — that is deliberate, it holds a whole X server and a browser.
What was missing is the other half: whoever needs it must be able to bring it up, instead of discovering
"Missing X server" and stopping there.

    hermey_desktop.py start     # idempotent: starts it if down, returns at once if up
    hermey_desktop.py status    # running | stopped
    hermey_desktop.py stop      # only when the owner asks; the watchdog handles idleness

Run `start` before you open a browser on the bot screen.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

#: Where Hermes lives on this host. A service venv cannot import it, so the check runs in a child
#: with that tree on the path rather than duplicating the runtime's logic here.
AGENT_ROOT = os.environ.get("HERMES_AGENT_ROOT", "/usr/local/lib/hermes-agent")

_SCRIPT = """
import json, sys
from tools.bot_desktop import runtime
action = sys.argv[1]
if action == "status":
    s = runtime.status()
elif action == "start":
    s = runtime.start(wait_seconds=30)
else:
    runtime.stop()
    s = runtime.status()
print(json.dumps({"running": bool(getattr(s, "running", False)),
                  "display": getattr(s, "display", None)}))
"""


def run(action: str) -> dict:
    env = dict(os.environ)
    env["PYTHONPATH"] = AGENT_ROOT + (":" + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    env.pop("VIRTUAL_ENV", None)
    proc = subprocess.run([sys.executable, "-c", _SCRIPT, action], cwd=AGENT_ROOT,
                          capture_output=True, text=True, timeout=180, env=env)
    if proc.returncode != 0:
        return {"running": False, "error": (proc.stderr or proc.stdout or "failed").strip()[-300:]}
    try:
        return json.loads(proc.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        return {"running": False, "error": "unreadable status"}


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    if action not in ("start", "status", "stop"):
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    result = run(action)
    if result.get("error"):
        print(f"bot desktop: {result['error']}", file=sys.stderr)
        return 1
    state = "running" if result.get("running") else "stopped"
    print(f"bot desktop {state}" + (f" on {result['display']}" if result.get("display") else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
