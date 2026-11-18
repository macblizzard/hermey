#!/usr/bin/env python3
"""Run commands or take a screenshot on the paired Mac through Hermey's local-computer executor.

Bots run on the hermes host, so they reach the bridge over loopback (no device ticket needed). The
bridge refuses the same call through tailscale serve. Examples:

    python3 Tools/local_computer.py -- sw_vers
    python3 Tools/local_computer.py --cwd ~/hermey-build -- Tools/release/build_on_mac.sh 0.1.567 567
    python3 Tools/local_computer.py --stream -- xcodebuild -project Hermey.xcodeproj -scheme Hermey
    python3 Tools/local_computer.py observe
    python3 Tools/local_computer.py observe --save /tmp/screen.jpg
    python3 Tools/local_computer.py ask cody "Should I keep going?"
    python3 Tools/local_computer.py resume

The Mac must be paired and the "Let bots use this computer" switch on. Command output is base64 on
the wire; this script prints it and exits with the Mac command's exit code. `observe` saves the JPEG
and prints JSON metadata including the path, so a bot can feed it straight to vision.
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


def request_stream(path: str, payload: dict | None = None, timeout: float = 1800):
    """Open an NDJSON response and hand back the raw HTTP object, line by line."""
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        BRIDGE + path,
        data=data,
        method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/x-ndjson"},
    )
    return urllib.request.urlopen(req, timeout=timeout)


def pick_computer(name: str | None = None) -> dict:
    computers = request("/v1/local-computers")["computers"]
    if not computers:
        raise RuntimeError("no local computer is connected; pair the Mac and turn on Computer use")
    if name:
        matches = [c for c in computers
                   if name == c["device_id"] or name.lower() in c["name"].lower()]
        if not matches:
            raise RuntimeError(f"no connected computer matches {name!r}")
        return matches[0]
    return next((c for c in computers if "mac" in c["name"].lower()), computers[0])


def save_observation(observation: dict, save: str | None) -> dict:
    # Swift's JSONEncoder emits camelCase; accept both spellings so older and newer Macs work.
    image_b64 = observation.get("image_base64") or observation.get("imageBase64")
    if not image_b64:
        raise RuntimeError("the Mac returned no image")
    frame_id = observation.get("frameID") or observation.get("frame_id") or "screen"
    image = base64.b64decode(image_b64)
    path = save or f"/tmp/hermey-observe-{frame_id}.jpg"
    with open(path, "wb") as handle:
        handle.write(image)
    width = observation.get("width")
    height = observation.get("height")
    if width is None or height is None:
        raise RuntimeError("the Mac returned no image metadata")
    metadata = {
        "path": path,
        "frame_id": frame_id,
        "width": width,
        "height": height,
        "format": observation.get("format", "jpeg"),
        "bytes": len(image),
        "active_window": observation.get("activeWindow") or observation.get("active_window"),
        "captured_at": observation.get("capturedAt") or observation.get("captured_at"),
    }
    print(json.dumps(metadata, ensure_ascii=False))
    return metadata


def do_observe(computer_name: str | None, save: str | None) -> int:
    device = pick_computer(computer_name)
    save_observation(request(f"/v1/local-computers/{device['device_id']}/observe", {}), save)
    return 0


def do_browser(computer_name: str | None, op: str, value: str | None) -> int:
    device = pick_computer(computer_name)
    payload: dict = {"op": op}
    if op == "navigate":
        payload["url"] = value
    elif op == "act":
        payload["actions"] = json.loads(value or "[]")
    result = request(f"/v1/local-computers/{device['device_id']}/browser", payload)
    print(json.dumps(result, ensure_ascii=False))
    return 0


def do_files(computer_name: str | None, op: str, path: str, local: str | None,
             save: str | None) -> int:
    device = pick_computer(computer_name)
    payload: dict = {"op": op, "path": path}
    if op == "write":
        if not local:
            raise RuntimeError("files write needs a local file to send")
        with open(local, "rb") as handle:
            payload["content_base64"] = base64.b64encode(handle.read()).decode()
    result = request(f"/v1/local-computers/{device['device_id']}/file", payload)
    if op == "read":
        data = base64.b64decode(result["content_base64"])
        out = save or f"/tmp/hermey-file-{os.path.basename(path)}"
        with open(out, "wb") as handle:
            handle.write(data)
        print(json.dumps({"path": out, "remote": path, "bytes": len(data)}))
    else:
        print(json.dumps(result, ensure_ascii=False))
    return 0


def do_ask(profile: str, question: str, sender: str, timeout: float) -> int:
    result = request(f"/v1/bots/{profile}/ask",
                     {"question": question, "from": sender, "timeout": timeout})
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("answered") else 5


def do_resume(computer_name: str | None) -> int:
    device = pick_computer(computer_name)
    result = request(f"/v1/local-computers/{device['device_id']}/resume", {})
    print(json.dumps(result, ensure_ascii=False))
    return 0


def do_execute_stream(computer_name: str | None, argv: list[str], cwd: str | None,
                      timeout_ms: int) -> int:
    device = pick_computer(computer_name)
    payload: dict = {"argv": argv, "timeout_ms": timeout_ms}
    if cwd:
        payload["cwd"] = os.path.expanduser(cwd)
    response = request_stream(
        f"/v1/local-computers/{device['device_id']}/execute-stream", payload,
        timeout=timeout_ms / 1000 + 30)
    exit_code = 1
    with response:
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            frame = json.loads(line)
            if frame.get("type") == "progress":
                stdout = base64.b64decode(frame.get("stdout", ""))
                stderr = base64.b64decode(frame.get("stderr", ""))
                if stdout:
                    sys.stdout.write(stdout.decode("utf-8", "replace"))
                    sys.stdout.flush()
                if stderr:
                    sys.stderr.write(stderr.decode("utf-8", "replace"))
                    sys.stderr.flush()
            elif frame.get("type") == "result":
                exit_code = int(frame.get("exit_code", 1))
                # An older Mac app sends no progress frames; the whole answer rides in this line.
                if frame.get("stdout"):
                    sys.stdout.write(base64.b64decode(frame["stdout"]).decode("utf-8", "replace"))
                    sys.stdout.flush()
                if frame.get("stderr"):
                    sys.stderr.write(base64.b64decode(frame["stderr"]).decode("utf-8", "replace"))
                    sys.stderr.flush()
                if frame.get("truncated"):
                    print("[local computer output truncated]", file=sys.stderr)
    return exit_code


def do_act(computer_name: str | None, actions_json: str, bot: str, save: str | None) -> int:
    device = pick_computer(computer_name)
    actions = json.loads(actions_json)
    if not isinstance(actions, list) or not (1 <= len(actions) <= 24):
        raise RuntimeError("actions must be a JSON list of 1..24 objects")
    result = request(f"/v1/local-computers/{device['device_id']}/act",
                     {"actions": actions, "bot": bot})
    save_observation(result, save)
    return 0


def main() -> int:
    raw = sys.argv[1:]
    if raw and raw[0] == "browser":
        browser = argparse.ArgumentParser(description="Drive the Mac's private browser surface")
        browser.add_argument("op", choices=("navigate", "snapshot", "act", "downloads"))
        browser.add_argument("value", nargs="?", help="URL for navigate, JSON array for act")
        browser.add_argument("--computer")
        args = browser.parse_args(raw[1:])
        try:
            return do_browser(args.computer, args.op, args.value)
        except (RuntimeError, urllib.error.HTTPError, json.JSONDecodeError, KeyError) as exc:
            print(f"Browser failed: {exc}", file=sys.stderr)
            return 4

    if raw and raw[0] == "files":
        files = argparse.ArgumentParser(description="Work in the Mac's shared Hermey workspace")
        files.add_argument("op", choices=("list", "read", "write", "mkdir"))
        files.add_argument("path", help="remote path inside the workspace")
        files.add_argument("local", nargs="?", help="local file for `write`")
        files.add_argument("--save", help="where `read` writes the file locally")
        files.add_argument("--computer")
        args = files.parse_args(raw[1:])
        try:
            return do_files(args.computer, args.op, args.path, args.local, args.save)
        except (RuntimeError, urllib.error.HTTPError, OSError) as exc:
            print(f"Files failed: {exc}", file=sys.stderr)
            return 4

    if raw and raw[0] == "act":
        act = argparse.ArgumentParser(description="Run a batch of desktop actions on the Mac")
        act.add_argument("actions", help='JSON array of 1..24 action objects')
        act.add_argument("--bot", default="cody")
        act.add_argument("--computer")
        act.add_argument("--save")
        args = act.parse_args(raw[1:])
        try:
            return do_act(args.computer, args.actions, args.bot, args.save)
        except (RuntimeError, urllib.error.HTTPError, json.JSONDecodeError, KeyError) as exc:
            print(f"Act failed: {exc}", file=sys.stderr)
            return 4

    if raw and raw[0] == "ask":
        ask = argparse.ArgumentParser(description="Ask the owner a question in a bot's chat")
        ask.add_argument("profile", help="the bot whose conversation the owner is reading")
        ask.add_argument("question")
        ask.add_argument("--from", default="cody", help="the bot doing the asking")
        ask.add_argument("--timeout", type=float, default=300.0)
        args = ask.parse_args(raw[1:])
        try:
            return do_ask(args.profile, args.question, getattr(args, "from"), args.timeout)
        except (RuntimeError, urllib.error.HTTPError, json.JSONDecodeError, KeyError) as exc:
            print(f"Ask failed: {exc}", file=sys.stderr)
            return 4

    if raw and raw[0] == "resume":
        resume = argparse.ArgumentParser(description="Hand control back to the bot after a takeover")
        resume.add_argument("--computer", help="device id or a substring of the Mac's name")
        args = resume.parse_args(raw[1:])
        try:
            return do_resume(args.computer)
        except (RuntimeError, urllib.error.HTTPError, KeyError) as exc:
            print(f"Resume failed: {exc}", file=sys.stderr)
            return 4

    if raw and raw[0] == "observe":
        obs = argparse.ArgumentParser(description="Capture the Mac's screen")
        obs.add_argument("--computer", help="device id or a substring of the Mac's name")
        obs.add_argument("--save", help="where to write the JPEG")
        args = obs.parse_args(raw[1:])
        try:
            return do_observe(args.computer, args.save)
        except (RuntimeError, urllib.error.HTTPError, KeyError, ValueError) as exc:
            print(f"Observe failed: {exc}", file=sys.stderr)
            return 4

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--computer", help="device id or a substring of the Mac's name")
    parser.add_argument("--cwd", help="working directory on the Mac")
    parser.add_argument("--timeout-ms", type=int, default=900_000,
                        help="deadline in milliseconds (default 15 min, max 30 min)")
    parser.add_argument("--stream", action="store_true",
                        help="print the command's output live, line by line")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(raw)
    argv = args.command[1:] if args.command and args.command[0] == "--" else args.command
    if not argv:
        parser.error("give a command after --")

    if args.stream:
        try:
            return do_execute_stream(args.computer, argv, args.cwd, args.timeout_ms)
        except (RuntimeError, urllib.error.HTTPError, json.JSONDecodeError, KeyError) as exc:
            print(f"Local computer call failed: {exc}", file=sys.stderr)
            return 4

    payload: dict = {"argv": argv, "timeout_ms": args.timeout_ms}
    if args.cwd:
        payload["cwd"] = os.path.expanduser(args.cwd)
    try:
        device = pick_computer(args.computer)
        result = request(f"/v1/local-computers/{device['device_id']}/execute", payload)
    except (RuntimeError, urllib.error.HTTPError) as exc:
        print(f"Local computer call failed: {exc}", file=sys.stderr)
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
