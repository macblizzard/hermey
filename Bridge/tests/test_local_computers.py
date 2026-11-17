"""A paired Mac can register a local executor, take a command and be revoked remotely."""
from __future__ import annotations

import asyncio
import base64
import json
import time
import urllib.parse

import pytest
from websockets.asyncio.client import connect


def test_local_computer_executor_lifecycle(bridge):
    pair = bridge.pair(name="Mo's MacBook Air", platform="macos")
    device_id = pair["device_id"]
    observed: list[dict] = []

    async def scenario() -> None:
        ticket = bridge.mint_ticket(device_id)
        url = f"ws://127.0.0.1:{bridge.port}/v1/local-computers/ws?" + urllib.parse.urlencode(
            {"ticket": ticket})
        async with connect(url) as ws:
            await ws.send(json.dumps({"type": "hello", "name": "Mo's MacBook Air"}))

            # Give the registry a beat to register, then list from a normal authenticated caller.
            for _ in range(50):
                listed = bridge.client().get(
                    "/v1/local-computers",
                    headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)},
                )
                if listed.status_code == 200 and listed.json()["computers"]:
                    break
                time.sleep(0.02)
            assert listed.status_code == 200
            assert listed.json()["computers"][0]["name"] == "Mo's MacBook Air"

            async def fake_computer() -> None:
                frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
                observed.append(frame)
                assert frame["type"] == "execute"
                assert frame["argv"] == ["/bin/echo", "hello local"]
                await ws.send(json.dumps({
                    "id": frame["id"],
                    "type": "result",
                    "exit_code": 0,
                    "stdout": base64.b64encode(b"hello local\n").decode(),
                    "stderr": "",
                    "truncated": False,
                }))

            worker = asyncio.create_task(fake_computer())
            # The blocking HTTP client must run off the event loop: this loop is also driving
            # the Mac's side of the socket, which has to answer the command while we wait.
            result = await asyncio.to_thread(
                bridge.client().post,
                f"/v1/local-computers/{device_id}/execute",
                json={"argv": ["/bin/echo", "hello local"]},
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)},
            )
            await asyncio.wait_for(worker, timeout=5)
            assert result.status_code == 200, result.text
            assert base64.b64decode(result.json()["stdout"]) == b"hello local\n"
            assert result.json()["exit_code"] == 0

            # Revocation closes the live socket and makes the endpoint refuse the device.
            revoked = bridge.client().delete(
                f"/v1/local-computers/{device_id}",
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)},
            )
            assert revoked.status_code == 200
            assert revoked.json()["was_connected"] is True
            offline = bridge.client().post(
                f"/v1/local-computers/{device_id}/execute",
                json={"argv": ["/bin/echo", "nope"]},
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)},
            )
            assert offline.status_code == 403

    asyncio.run(asyncio.wait_for(scenario(), timeout=20))
    assert observed


def test_local_computer_rejects_proxied_callers(bridge):
    # A bot on this host may call over loopback; the same request through tailscale serve may not.
    response = bridge.client().get("/v1/local-computers",
                                   headers={"X-Forwarded-For": "100.86.19.1"})
    assert response.status_code == 401
    local = bridge.client().get("/v1/local-computers")
    assert local.status_code == 200
    bridge_pair = bridge.pair(name="Mac", platform="macos")
    bad = bridge.client().post(
        f"/v1/local-computers/{bridge_pair['device_id']}/execute",
        json={"argv": []},
        headers={"Authorization": "Bearer " + bridge.mint_ticket(bridge_pair["device_id"])},
    )
    assert bad.status_code == 422
