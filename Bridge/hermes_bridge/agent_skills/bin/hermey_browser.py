#!/usr/bin/env python3
"""Open a page on the bot screen: wake the desktop if it is asleep, launch the browser, navigate.

    hermey_browser.py open https://www.doctolib.de/patient/login
    hermey_browser.py status

This exists because waking the desktop and having a browser on it are two different things, and a bot that
only did the first reported "Missing X server" or stared at an empty screen. One command now covers both,
and it waits until the sign-in extension has actually connected, so a login card can be filled the moment
this returns.

The browser is the one the bot desktop resolves (dock flags included, extension preloaded). It is launched
detached: the caller's shell going away must not take the browser with it — that killed three attempts of
mine before I stopped launching it from a terminal.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.request

AGENT_ROOT = os.environ.get("HERMES_AGENT_ROOT", "/usr/local/lib/hermes-agent")
BRIDGE = os.environ.get("HERMES_BRIDGE_URL", "http://127.0.0.1:8787")
CONNECT_TIMEOUT = 45

# Runs inside the agent tree: it can see the runtime and the browser resolver, which the bridge's venv cannot.
_CHILD = r"""
import json, os, subprocess, sys
from tools.bot_desktop import browser, runtime

action, url = sys.argv[1], sys.argv[2]
if action == "open":
    status = runtime.start(wait_seconds=30)      # idempotent: returns at once when already up
    exe = browser.executable()
    if not exe:
        print(json.dumps({"error": "no browser resolved on this host"}))
        raise SystemExit(0)
    user_data_dir = str(browser.profile_dir())
    argv = browser.dock_argv(exe, user_data_dir)
    if url:
        argv = argv + [url]
    env = dict(os.environ)
    env["DISPLAY"] = getattr(status, "display", ":20") or ":20"
    state = runtime.state_dir()
    for name in ("Xauthority", "xauth"):
        candidate = os.path.join(str(state), name)
        if os.path.isfile(candidate):
            env["XAUTHORITY"] = candidate
            break
    # Detach properly. A plain Popen still dies with the caller's session (three attempts of mine did, with
    # no error at all — the browser simply vanished). A transient systemd unit is owned by PID 1 instead, so
    # the browser outlives whoever asked for it; Popen stays as the fallback for hosts without systemd.
    launched = False
    if os.geteuid() == 0 and os.path.isdir("/run/systemd/system"):
        cmd = ["systemctl", "reset-failed", "hermey-bot-browser"]
        subprocess.run(cmd, capture_output=True)
        run = ["systemd-run", "--unit=hermey-bot-browser", "--description=Hermey bot browser",
               *[f"--setenv={k}={v}" for k, v in (("DISPLAY", env.get("DISPLAY", ":20")),
                                                  ("XAUTHORITY", env["XAUTHORITY"] if "XAUTHORITY" in env else ""))
                 if v],
               *argv]
        result = subprocess.run(run, capture_output=True, text=True)
        launched = result.returncode == 0
        if not launched:
            print(json.dumps({"error": (result.stderr or "systemd-run failed").strip()[-200:]}))
            raise SystemExit(0)
    if not launched:
        subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, cwd=str(state))
    print(json.dumps({"launched": True, "display": env.get("DISPLAY"), "exe": exe,
                      "user_data_dir": user_data_dir}))
else:
    status = runtime.status()
    print(json.dumps({"running": bool(getattr(status, "running", False)),
                      "display": getattr(status, "display", None)}))
"""


def ask_agent(action: str, url: str = "") -> dict:
    env = dict(os.environ)
    env["PYTHONPATH"] = AGENT_ROOT + (":" + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    env.pop("VIRTUAL_ENV", None)
    proc = subprocess.run([sys.executable, "-c", _CHILD, action, url], cwd=AGENT_ROOT,
                          capture_output=True, text=True, timeout=180, env=env)
    if proc.returncode != 0:
        return {"error": (proc.stderr or proc.stdout or "failed").strip()[-300:]}
    try:
        return json.loads(proc.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        return {"error": "unreadable answer from the agent tree"}


def clear_stale_browser() -> int:
    """Kill a browser that is running but not connected.

    Chromium is single-instance per profile: if one is alive without the extension attached, every new
    launch prints "Opening in existing browser session", exits 0, and the caller waits forever for a socket
    that will never open. Killing it is the only way back, and the profile keeps the cookies — so a login
    done earlier survives.
    """
    import signal

    killed = 0
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            exe = os.readlink(f"/proc/{entry.name}/exe")
            with open(f"/proc/{entry.name}/cmdline", "rb") as handle:
                cmd = handle.read().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        if os.path.basename(exe) != "chrome" or "browser-profile" not in cmd and "chrome-profile" not in cmd:
            continue
        if "--type=" in cmd:
            continue
        try:
            os.kill(int(entry.name), signal.SIGTERM)
            killed += 1
        except OSError:
            pass
    if killed:
        time.sleep(3)
    return killed


def browsers() -> int:
    try:
        with urllib.request.urlopen(f"{BRIDGE}/v1/browser/targets", timeout=10) as reply:
            return len(json.load(reply).get("browsers") or [])
    except Exception:  # noqa: BLE001 - a bridge we cannot ask is not a browser count
        return -1


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    if action not in ("open", "status"):
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    url = sys.argv[2] if len(sys.argv) > 2 else ""

    if action == "status":
        state = ask_agent("status")
        if state.get("error"):
            print(f"bot screen: {state['error']}", file=sys.stderr)
            return 1
        print(f"desktop {'running' if state.get('running') else 'stopped'}"
              + (f" on {state['display']}" if state.get("display") else "")
              + f"; browsers connected: {max(browsers(), 0)}")
        return 0

    if browsers() == 0:
        killed = clear_stale_browser()
        if killed:
            print(f"cleared {killed} browser(s) holding the profile without a connection", file=sys.stderr)

    result = ask_agent("open", url)
    if result.get("error"):
        print(f"could not open the browser: {result['error']}", file=sys.stderr)
        return 1

    # Wait for the extension: a fill issued before it connects belongs to nobody.
    deadline = time.time() + CONNECT_TIMEOUT
    while time.time() < deadline:
        if browsers() > 0:
            print(f"browser open on {result.get('display')}" + (f" at {url}" if url else "")
                  + "; sign-in extension connected")
            return 0
        time.sleep(2)
    print(f"browser launched on {result.get('display')}, but the sign-in extension did not connect "
          f"within {CONNECT_TIMEOUT}s — a login card could not be filled", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
