#!/usr/bin/env python3
"""Open a page on the bot screen: wake the desktop if it is asleep, launch the browser, navigate.

    hermey_browser.py open https://www.zoopla.co.uk/     # THE fallback rung: one command, idempotent
    hermey_browser.py status

This is the command a bot uses when a plain fetch was blocked, and it is the only one it needs: waking the
desktop and having a browser on it are two different things, and a bot that only did the first reported
"Missing X server" or stared at an empty screen. `open` covers both — it starts the desktop if it is down
(running is not an error, it returns at once), launches the browser if none is connected, navigates, and
waits until the sign-in extension has connected, so a login card can be filled the moment this returns.

Stale state is expected and handled, because a previous run may have been killed: runtime.start() reclaims a
display whose X lock names a dead pid, reaps an Xvnc orphaned by a SIGKILLed launcher, and `start.lock` /
`lease.lock` are flock() locks whose owner dying releases them (the files stay behind and that is fine — an
empty lock file is not a held lock).

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
# --- where this host is ------------------------------------------------------------------------
#
# hermeyd serves two loopback listeners and the scripts must not confuse them:
#   * the main API (8788) — cards, integrations, local computers — needs a bearer;
#   * the browser channel (8790) — /v1/browser/* only — carries no device credential.
# An explicit --bridge (or HERMES_BRIDGE_URL) still governs both, so a host that still runs the
# Python bridge works with one override.
DEFAULT_API = "http://127.0.0.1:8788"
DEFAULT_BROWSER = "http://127.0.0.1:8790"
#: The service's local bearer. `HERMEYD_LOCAL_TOKEN` wins; otherwise this file, which sits beside
#: `bin/` in the service's state directory (`<state>/local.token`, mode 0600).
TOKEN_FILE = os.environ.get("HERMEYD_LOCAL_TOKEN_FILE") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "local.token")


class AuthError(RuntimeError):
    """No usable local bearer. The message says where we looked, never what was there."""


def local_token() -> str:
    value = os.environ.get("HERMEYD_LOCAL_TOKEN", "").strip()
    if value:
        return value
    try:
        with open(TOKEN_FILE, encoding="utf-8") as handle:
            token = handle.read().strip()
    except OSError as exc:
        raise AuthError(
            f"no local bearer: set HERMEYD_LOCAL_TOKEN, or make {TOKEN_FILE} readable ({exc.strerror})"
        ) from None
    if not token:
        raise AuthError(f"the local bearer file {TOKEN_FILE} is empty")
    return token


def auth_header() -> dict:
    return {"Authorization": f"Bearer {local_token()}"}


def endpoints(bridge: str | None = None, browser: str | None = None) -> tuple[str, str]:
    """(main API, browser channel). `--bridge` governs both, as it did on the Python bridge."""
    api = (bridge or os.environ.get("HERMEYD_API_URL") or os.environ.get("HERMES_BRIDGE_URL")
           or DEFAULT_API).rstrip("/")
    compat = bridge or os.environ.get("HERMES_BRIDGE_URL")
    channel = browser or os.environ.get("HERMEYD_BROWSER_URL") or compat or DEFAULT_BROWSER
    return api, channel.rstrip("/")


CONNECT_TIMEOUT = 45

# Runs inside the agent tree: it can see the runtime and the browser resolver, which a plain venv cannot.
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
        # A launch that died leaves the transient unit LOADED, and `systemd-run --unit=` then refuses with
        # "Unit ... was already loaded or has a fragment file" — an exit 1 for a browser that is merely
        # restarting. Reaching this point means no browser is connected, so stopping the stale unit is
        # killing nobody's work.
        subprocess.run(["systemctl", "stop", "hermey-bot-browser"], capture_output=True)
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
elif action == "where":
    # Which jar the bot browser will use. The caller needs it to tell ITS browser from another profile's:
    # the path is configurable (``browser.user_data_dir``), so matching on a name substring is wrong.
    print(json.dumps({"user_data_dir": str(browser.profile_dir()), "exe": browser.executable()}))
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


def clear_stale_browser(user_data_dir: str) -> int:
    """Kill OUR browser when it is running but not connected.

    Chromium is single-instance per profile: if one is alive without the extension attached, every new
    launch prints "Opening in existing browser session", exits 0, and the caller waits forever for a socket
    that will never open. Killing it is the only way back, and the profile keeps the cookies — so a login
    done earlier survives.

    Scoped to THIS profile's jar and to a windowed browser. An earlier version matched any Chromium whose
    command line contained ``browser-profile`` or ``chrome-profile`` — which is every sibling profile's
    headless tool browser as well (``/var/lib/hermes/chrome-profile-<profile>``), so opening the bot
    browser killed other bots' browser sessions mid-task. The jar is configurable, so compare the resolved
    path Chrome was given, and leave ``--headless`` alone: that one never holds the visible screen.
    """
    import signal

    if not user_data_dir:
        return 0
    wanted = os.path.realpath(user_data_dir)
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
        if os.path.basename(exe) != "chrome":
            continue
        if "--type=" in cmd or "--headless" in cmd:
            continue
        jar = next((arg.split("=", 1)[1] for arg in cmd.split()
                    if arg.startswith("--user-data-dir=")), "")
        if not jar or os.path.realpath(jar) != wanted:
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
    # The browser channel needs no credential; send the local bearer when one is readable so a
    # reverse proxy in front of it can still identify this host.
    try:
        headers = auth_header()
    except AuthError:
        headers = {}
    request = urllib.request.Request(f"{endpoints()[1]}/v1/browser/targets", headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=10) as reply:
            return len(json.load(reply).get("browsers") or [])
    except Exception:  # noqa: BLE001 - a service we cannot ask is not a browser count
        return -1


def act(payload: dict) -> dict:
    """One control message to the browser channel (no credential: that listener serves /v1/browser/* only)."""
    request = urllib.request.Request(
        f"{endpoints()[1]}/v1/browser/act",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=60) as reply:
        return json.load(reply)


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

    where = ask_agent("where")
    if where.get("error"):
        print(f"could not resolve the bot browser: {where['error']}", file=sys.stderr)
        return 1
    if browsers() > 0:
        # Already up — navigate what is there. Launching again would only be forwarded to the running
        # instance (or refused by systemd as "unit already loaded"), and an idempotent command must not
        # return non-zero for the state it was asked to reach.
        state = ask_agent("status")
        display = state.get("display")
        if url:
            try:
                answer = act({"type": "goto", "url": url})
            except Exception as exc:  # noqa: BLE001 - a channel we cannot talk to is reported, not raised
                print(f"browser is up on {display} but could not be navigated: {exc}", file=sys.stderr)
                return 1
            if answer.get("ok") is False:
                print(f"browser is up on {display} but refused the navigation: "
                      f"{answer.get('error') or answer}", file=sys.stderr)
                return 1
        print(f"browser already open on {display}" + (f" at {url}" if url else "")
              + "; sign-in extension connected")
        return 0
    if browsers() == 0:
        killed = clear_stale_browser(str(where.get("user_data_dir") or ""))
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
