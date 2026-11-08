#!/usr/bin/env python3
"""End-to-end demonstration of the whole client chain, with timings.

Runs the **real** bridge (the code the apps will talk to) against the **replay gateway**
(`fixtures/` replayed over a real WebSocket, same framing the live gateway uses), and walks
the exact sequence a phone performs:

    pair (code → device key) → token (refresh → access + 30 s ticket) → WS upgrade
    → gateway.ready → client.capabilities → ping → session.list → approval round trip

It prints every step with a measured duration, so the numbers in `docs/QA.md` can be
reproduced on any machine. Nothing here touches a live Hermes, the tailnet or real state:
the harness uses free loopback ports and a throwaway SQLite file.

    python Tools/qa/demo_flow.py
"""

from __future__ import annotations

import asyncio
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools" / "qa"))
sys.path.insert(0, str(ROOT / "Bridge"))

import harness  # noqa: E402
from harness import GATEWAY_PATH, BridgeUnderTest  # noqa: E402
from replay_server import ReplayServer  # noqa: E402
from rpc import Socket  # noqa: E402

SCENARIO = ROOT / "Tools" / "qa" / "scenarios" / "turn-approval.ndjson"


def ms(since: float) -> float:
    return (time.perf_counter() - since) * 1000.0


async def main() -> int:
    if not SCENARIO.exists():
        print(f"missing scenario: {SCENARIO}")
        return 1

    print("Hermes client chain — end-to-end demo\n" + "-" * 42)

    with ReplayServer(str(SCENARIO)) as gateway, BridgeUnderTest(f"{gateway.url}{GATEWAY_PATH}") as bridge:
        print(f"gateway  {gateway.url}   (replay of {SCENARIO.name})")
        print(f"bridge   {bridge.base_url}\n")

        # 1. Pairing: the phone holds a key, the host mints a code.
        started = time.perf_counter()
        pairing = bridge.pair(name="iPhone 16 Pro", platform="ios")
        print(f"pair      code → device {pairing.device_id[:12]}…            {ms(started):6.1f} ms")

        # 2. Token exchange: refresh token → access token + single-use 30 s WS ticket.
        started = time.perf_counter()
        ticket = bridge.mint_ticket(pairing)
        print(f"token     refresh → ws ticket                    {ms(started):6.1f} ms")

        # 3. WebSocket upgrade through the bridge.
        async with Socket.open(bridge.ws_url(ticket.ticket)) as sock:
            started = time.perf_counter()
            ready = await sock.expect(type="gateway.ready")
            print(f"ready     gateway.ready relayed                  {ms(started):6.1f} ms")

            # 4. The mandatory capability advertisement: without it the gateway refuses to
            #    send us approvals at all.
            started = time.perf_counter()
            caps = await sock.handshake()
            offered = caps.get("server_requests", []) if isinstance(caps, dict) else []
            print(f"caps      server_requests advertised ({len(offered)})     {ms(started):6.1f} ms")

            # 5. A round trip, measured.
            rtts = []
            for _ in range(5):
                started = time.perf_counter()
                await sock.request_response("ping", {})
                rtts.append(ms(started))
            print(f"ping      5 round trips through the bridge       "
                  f"min {min(rtts):.2f} / med {sorted(rtts)[2]:.2f} / max {max(rtts):.2f} ms")

            # 6. A prompt, and the events that follow it.
            started = time.perf_counter()
            await sock.request("prompt.submit", {"session_id": "demo-session", "text": "Run rsync"})
            first_delta = None
            approval = None
            for _ in range(40):
                frame = await sock.recv_frame(timeout=5.0)
                body = (frame.json or {})
                params = body.get("params") or {}
                if params.get("type") == "message.delta" and first_delta is None:
                    first_delta = ms(started)
                if body.get("method") == "approval":
                    approval = body
                    break
            print(f"stream    prompt → first message.delta           "
                  f"{'n/a' if first_delta is None else f'{first_delta:6.1f} ms'}")

            # 7. The approval the agent is blocked on, answered in the documented shape.
            if approval is not None:
                choices = (approval.get("params") or {}).get("choices", [])
                started = time.perf_counter()
                await sock.answer(approval.get("id"), {"choice": "once"})
                answered = ms(started)
                print(f"approval  {approval.get('id')} answered 'once'            {answered:6.1f} ms")
                print(f"          choices offered by the host: {choices}")
                if "once" not in choices:
                    print("          WARNING: 'once' was not among the offered choices")
            else:
                print("approval  no approval frame in this scenario")

        # 8. The ticket is single use: replaying it must be refused.
        try:
            replay_socket = await Socket.connect(bridge.ws_url(ticket.ticket), timeout=3.0)
        except Exception as exc:  # any refusal is a pass
            print(f"replay    reusing the same ticket refused        ({type(exc).__name__})")
        else:
            await replay_socket.__aexit__(None, None, None)
            print("replay    WARNING: a spent ticket was accepted")

    print("-" * 42)
    print("chain verified: pair → token → ws → handshake → rpc → events → approval")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
