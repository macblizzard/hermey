#!/usr/bin/env python3
"""Run a command on the paired Mac through Hermey's local-computer executor.

Bots run on the hermes host, so they reach the bridge over loopback (no device ticket needed). The
bridge refuses the same call through tailscale serve. Examples:

    python3 Tools/local_computer.py -- sw_vers
    python3 Tools/local_computer.py --cwd ~/hermey-build -- Tools/release/build_on_mac.sh 0.1.561 561
    python3 Tools/local_computer.py --computer "MacBook Air" -- ls -la

The Mac must be paired and the "Let bots use this computer" switch on. Output is base64 on the wire;
this script prints it and exits with the Mac command's exit code.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

BRIDGE = os.environ.get("HERMES_BRIDGE_URL", "http://127.0.0.1:8787")


def request(path: str, payload: dict | None = None, method: str | None = None) -> dict:
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        BRIDGE + path,
        data=data,
        method=method or ("POST" if data is not None else "GET"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=1800) as response:
        return json.loads(response.read().decode())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--computer", help="device id or a substring of the Mac's name")
    parser.add_argument("--cwd", help="working directory on the Mac")
    parser.add_argument("--timeout-ms", type=int, default=900_000,
                        help="deadline in milliseconds (default 15 min, max 30 min)")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    argv = args.command[1:] if args.command and args.command[0] == "--" else args.command
    if not argv:
        parser.error("give a command after --")

    computers = request("/v1/local-computers")["computers"]
    if not computers:
        print("No local computer is connected. Pair the Mac and turn on its Computer toggle.",
              file=sys.stderr)
        return 3
    if args.computer:
        matches = [c for c in computers
                   if args.computer == c["device_id"] or args.computer.lower() in c["name"].lower()]
        if not matches:
            print(f"No connected computer matches {args.computer!r}.", file=sys.stderr)
            return 3
        computer = matches[0]
    else:
        computer = next((c for c in computers if "mac" in c["name"].lower()), computers[0])

    payload = {"argv": argv, "timeout_ms": args.timeout_ms}
    if args.cwd:
        payload["cwd"] = os.path.expanduser(args.cwd)
    try:
        result = request(f"/v1/local-computers/{computer['device_id']}/execute", payload)
    except urllib.error.HTTPError as exc:
        print(f"Local computer call failed: {exc.code} {exc.read().decode()}", file=sys.stderr)
        return 4

    sys.stdout.write(base64.b64decode(result.get("stdout", "")).decode("utf-8", "replace"))
    sys.stdout.flush()
    stderr = base64.b64decode(result.get("stderr", "")).decode("utf-8", "replace")
    if stderr:
        sys.stderr.write(stderr)
    if result.get("truncated"):
        print("[local computer output truncated]", file=sys.stderr)
    return int(result.get("exit_code", 1))


if __name__ == "__main__":
    raise SystemExit(main())
