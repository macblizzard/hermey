#!/usr/bin/env python3
"""End-to-end: pair a device, mint a ticket, open /v1/ws through hermeyd, and run a real turn.

Proves the full path an app takes:
    POST /v1/pair/start -> /v1/pair/claim -> /v1/token -> ws /v1/ws?ws_ticket=…
    -> JSON-RPC (profiles.list, session.create, prompt.submit) -> engine -> message.complete

Also proves the ticket is worthless twice: a second connect with the same ticket is refused,
which is what makes a leaked ticket safe.

Exit 0 only if every check passed.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import urllib.error
import urllib.request

import websockets

HOST = os.environ.get("HERMEYD", "127.0.0.1:8788")
HTTP = f"http://{HOST}"
# Plaintext on purpose: this is a smoke test against a hermeyd on this machine's loopback, before
# any TLS front end is in the picture. `HERMEYD` is the operator's own host, not a user's.
# nosemgrep: javascript.lang.security.detect-insecure-websocket.detect-insecure-websocket
WS = f"ws://{HOST}/v1/ws"
PROFILE = os.environ.get("SMOKE_PROFILE", "scratch")
PROMPT = os.environ.get("SMOKE_PROMPT", "Reply with exactly: RELAY-OK")

fails: list[str] = []


def ok(name: str, detail: str = "") -> None:
    print(f"  PASS  {name}{(' — ' + detail) if detail else ''}")


def bad(name: str, detail: str) -> None:
    fails.append(f"{name}: {detail}")
    print(f"  FAIL  {name} — {detail}")


def post(path: str, body: dict) -> tuple[int, dict]:
    req = urllib.request.Request(
        HTTP + path, data=json.dumps(body).encode(),
        headers={"content-type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


async def rpc(ws, rid: int, method: str, params: dict | None = None, timeout: float = 30):
    await ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}))
    while True:
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout))
        if msg.get("id") == rid:
            return msg


async def main() -> int:
    status, body = post("/v1/pair/start", {})
    if status != 200:
        bad("pair/start", f"{status} {body}")
        return 1
    code = body["code"]
    ok("pair/start", f"code {code}")

    status, body = post("/v1/pair/claim", {
        "code": code, "public_key": "k" * 44, "device_name": "relay-smoke", "platform": "cli"})
    if status != 200:
        bad("pair/claim", f"{status} {body}")
        return 1
    device_id, refresh = body["device_id"], body["refresh_token"]
    ok("pair/claim", f"device {device_id[:8]}…")

    status, body = post("/v1/token", {"device_id": device_id, "refresh_token": refresh})
    if status != 200:
        bad("token", f"{status} {body}")
        return 1
    ticket = body["ws_ticket"]
    ok("token", f"ws_ticket {len(ticket)} chars, expires_in={body['expires_in']}s")

    url = f"{WS}?ws_ticket={ticket}"
    try:
        async with websockets.connect(url, open_timeout=15, max_size=None, ping_interval=20) as ws:
            ok("ws upgrade through relay")

            msg = await rpc(ws, 1, "profiles.list")
            if "error" in msg:
                bad("profiles.list", json.dumps(msg["error"])[:200])
            else:
                res = msg.get("result") or {}
                bots = res.get("profiles") or res.get("bots") or res
                ok("profiles.list via relay", f"{len(bots) if isinstance(bots, (list, dict)) else '?'} bot(s)")

            msg = await rpc(ws, 2, "session.create", {"profile": PROFILE})
            if "error" in msg:
                bad("session.create", json.dumps(msg["error"])[:200])
                return 1
            runtime_id = msg["result"]["session_id"]
            ok("session.create via relay", f"runtime {runtime_id}")

            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 3, "method": "prompt.submit",
                                      "params": {"session_id": runtime_id, "text": PROMPT}}))
            text = ""
            while True:
                msg = json.loads(await asyncio.wait_for(ws.recv(), 180))
                if msg.get("method") != "event":
                    continue
                payload = (msg.get("params") or {}).get("payload") or {}
                if (msg.get("params") or {}).get("type") == "message.complete":
                    text = (payload.get("text") or "").strip()
                    break
            if text and "ENGINE" not in text.upper() and "RELAY" not in text.upper():
                bad("turn", f"unexpected answer: {text[:120]}")
            elif text:
                ok("real turn through relay", text[:80])
            else:
                bad("turn", "empty completion")
    except Exception as exc:  # noqa: BLE001
        bad("relay session", f"{type(exc).__name__}: {exc}")
        return 1

    # Ticket must be worthless now: single use is the whole point.
    try:
        async with websockets.connect(url, open_timeout=10):
            bad("ticket reuse", "second connect was ACCEPTED — ticket is not single-use")
    except Exception as exc:  # noqa: BLE001
        ok("ticket is single-use", type(exc).__name__)

    try:
        async with websockets.connect(f"{WS}?ws_ticket=not-a-real-ticket", open_timeout=10):
            bad("bad ticket", "bogus ticket accepted")
    except Exception as exc:  # noqa: BLE001
        ok("bogus ticket refused", type(exc).__name__)

    print()
    if fails:
        print(f"RELAY SMOKE FAILED ({len(fails)})")
        for f in fails:
            print(f"  - {f}")
        return 1
    print("RELAY SMOKE OK — pair → ticket → socket → turn")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
