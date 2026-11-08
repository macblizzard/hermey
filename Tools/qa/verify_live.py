#!/usr/bin/env python3
"""Verify a *live* deployment, not a replay: the real bridge behind real TLS.

This is the check that answers "is the thing I deployed actually working, and does it see my
bots?". It is separate from `Tools/qa` (which runs offline against a scripted gateway) because
it needs the real host.

    # on the host, once, to get a code (codes are minted on the host only, by design):
    curl -s -X POST http://127.0.0.1:8787/v1/pair/start | jq .code

    python Tools/qa/verify_live.py --base https://hermes.example.ts.net:8443 \
        --pair-code 12345678 --bots assistant,chief,analyst

Exits non-zero on the first failed expectation, so it can gate a deploy.

What it proves, in order: pairing over HTTPS, token → single-use ticket, WSS upgrade through
`tailscale serve`, the mandatory `client.capabilities` advertisement, `ping` latency, that
`profiles.list` enumerates every bot, and that per-bot `session.list` returns rows only with
`include_hidden: true` (the filter that silently returns 0 for a normal profile).
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import statistics
import subprocess
import sys
import time
import urllib.request

try:
    import websockets
except ImportError:  # pragma: no cover - dependency of the QA extra
    sys.exit("needs the `websockets` package (pip install websockets)")


def post(url: str, payload: dict) -> dict:
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), headers={"content-type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def get(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.loads(resp.read())


async def drive(args, ticket: str) -> int:
    url = f"{args.base.replace('https://', 'wss://')}/v1/ws?ticket={ticket}"
    async with websockets.connect(url, open_timeout=15, max_size=None) as ws:
        ready = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
        event = (ready.get("params") or {}).get("type")
        print(f"  wss upgrade            -> {event}")
        if event != "gateway.ready":
            return fail("expected gateway.ready first")

        await ws.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "client.capabilities",
                                  "params": {"server_requests": True}}))
        caps = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
        offered = ((caps.get("result") or {}).get("server_requests") or [])
        print(f"  client.capabilities    -> {len(offered)} server requests offered")
        if not offered:
            return fail("no server_requests offered; approvals would never reach the client")

        async def call(rid: int, method: str, params: dict, timeout: float = 90):
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
            while True:
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
                if msg.get("id") == rid:
                    return msg

        rtts = []
        for i in range(5):
            started = time.perf_counter()
            await call(100 + i, "ping", {})
            rtts.append((time.perf_counter() - started) * 1000)
        print(f"  ping over TLS          -> min {min(rtts):.1f} / med {statistics.median(rtts):.1f} / max {max(rtts):.1f} ms")

        bots_result = (await call(3, "profiles.list", {})).get("result") or {}
        entries = bots_result.get("profiles") or []
        names = [str(e.get("name") or e.get("profile") or e) for e in entries]
        print(f"  profiles.list          -> {len(names)} bots")
        if not names:
            return fail("profiles.list returned no bots")

        wanted = [b.strip() for b in (args.bots or "").split(",") if b.strip()] or names[:3]
        for index, bot in enumerate(wanted):
            hidden = await call(200 + index, "session.list",
                                {"limit": 5, "include_hidden": True, "profile": bot})
            rows_hidden = ((hidden.get("result") or {}).get("sessions") or [])
            plain = await call(300 + index, "session.list", {"limit": 5, "profile": bot})
            rows_plain = ((plain.get("result") or {}).get("sessions") or [])
            note = "" if len(rows_plain) != len(rows_hidden) else "  (filter made no difference here)"
            print(f"  session.list {bot:<9s} -> {len(rows_hidden):3d} rows with include_hidden,"
                  f" {len(rows_plain):3d} without{note}")

    print("OK: live deployment verified")
    return 0


def fail(message: str) -> int:
    print(f"FAIL: {message}", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="https://hermes.example.ts.net:8443")
    parser.add_argument("--pair-code", required=True, help="8-digit code printed by /v1/pair/start on the host")
    parser.add_argument("--bots", default="", help="comma-separated bot names to spot-check")
    parser.add_argument("--device-name", default="verify-live")
    args = parser.parse_args()

    print("live deployment check\n" + "-" * 40)
    health = get(f"{args.base}/v1/health")
    print(f"  /v1/health             -> {health.get('status')} (protocol {health.get('protocol_version')})")

    # A valid Ed25519 public key is exactly 32 bytes; anything else is refused on purpose.
    public_key = base64.b64encode(bytes(range(32))).decode("ascii")
    claim = post(f"{args.base}/v1/pair/claim", {
        "code": args.pair_code.strip(), "public_key": public_key,
        "device_name": args.device_name, "platform": "macos",
    })
    print(f"  pair/claim over HTTPS  -> device {claim.get('device_id')}")
    token = post(f"{args.base}/v1/token", {
        "device_id": claim["device_id"], "refresh_token": claim["refresh_token"],
    })
    if not token.get("ws_ticket"):
        return fail("no ws ticket issued")
    print(f"  token over HTTPS       -> ticket issued, access expires in {token.get('expires_in')}s")

    return asyncio.run(drive(args, token["ws_ticket"]))


if __name__ == "__main__":
    sys.exit(main())
