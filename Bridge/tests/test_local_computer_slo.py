"""SLOs for the local-computer surface, measured against a fake Mac.

These are the bridge's share of the parity plan's numbers: the Mac app's own work still has to be
measured on real hardware, but the bridge must not be the reason a number is missed.
"""

from __future__ import annotations

import asyncio
import json
import time
import urllib.parse

from websockets.asyncio.client import connect


def _url(bridge, device_id: str) -> str:
    return f"ws://127.0.0.1:{bridge.port}/v1/local-computers/ws?" + urllib.parse.urlencode(
        {"ticket": bridge.mint_ticket(device_id)})


def test_shell_start_is_under_200_ms(bridge):
    pair = bridge.pair(name="Mac", platform="macos")
    device_id = pair["device_id"]

    async def scenario() -> None:
        async with connect(_url(bridge, device_id)) as ws:
            await ws.send(json.dumps({"type": "hello", "name": "Mac"}))
            await asyncio.sleep(0.1)

            async def fake_computer() -> None:
                frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
                await ws.send(json.dumps({"id": frame["id"], "type": "result",
                                          "exit_code": 0, "stdout": "", "stderr": "",
                                          "truncated": False}))

            worker = asyncio.create_task(fake_computer())
            started = time.perf_counter()
            result = await asyncio.to_thread(
                bridge.client().post,
                f"/v1/local-computers/{device_id}/execute",
                json={"argv": ["/usr/bin/true"]},
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)},
            )
            elapsed = time.perf_counter() - started
            await asyncio.wait_for(worker, timeout=5)
            assert result.status_code == 200
            assert elapsed < 0.2, f"bridge added {elapsed * 1000:.0f} ms to a shell start"

    asyncio.run(asyncio.wait_for(scenario(), timeout=10))


def test_observe_is_under_one_second(bridge):
    pair = bridge.pair(name="Mac", platform="macos")
    device_id = pair["device_id"]

    async def scenario() -> None:
        async with connect(_url(bridge, device_id)) as ws:
            await ws.send(json.dumps({"type": "hello", "name": "Mac"}))
            await asyncio.sleep(0.1)

            async def fake_computer() -> None:
                frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
                await ws.send(json.dumps({
                    "id": frame["id"], "type": "result", "exit_code": 0,
                    "observation": {"image_base64": "aGk=", "width": 1, "height": 1,
                                    "format": "jpeg", "active_window": None,
                                    "captured_at": time.time()},
                    "stderr": "", "truncated": False,
                }))

            worker = asyncio.create_task(fake_computer())
            started = time.perf_counter()
            result = await asyncio.to_thread(
                bridge.client().post,
                f"/v1/local-computers/{device_id}/observe",
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)},
            )
            elapsed = time.perf_counter() - started
            await asyncio.wait_for(worker, timeout=5)
            assert result.status_code == 200
            assert elapsed < 1.0, f"observe took {elapsed:.2f} s through the bridge"

    asyncio.run(asyncio.wait_for(scenario(), timeout=10))


def test_act_is_under_half_a_second(bridge):
    pair = bridge.pair(name="Mac", platform="macos")
    device_id = pair["device_id"]

    async def scenario() -> None:
        async with connect(_url(bridge, device_id)) as ws:
            await ws.send(json.dumps({"type": "hello", "name": "Mac"}))
            await asyncio.sleep(0.1)

            async def fake_computer() -> None:
                frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
                await ws.send(json.dumps({
                    "id": frame["id"], "type": "result", "exit_code": 0,
                    "observation": {"image_base64": "aGk=", "width": 1, "height": 1,
                                    "format": "jpeg", "active_window": None,
                                    "captured_at": time.time()},
                    "stderr": "", "truncated": False,
                }))

            worker = asyncio.create_task(fake_computer())
            started = time.perf_counter()
            result = await asyncio.to_thread(
                bridge.client().post,
                f"/v1/local-computers/{device_id}/act",
                json={"actions": [{"kind": "wait", "milliseconds": 10}], "bot": "cody"},
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)},
            )
            elapsed = time.perf_counter() - started
            await asyncio.wait_for(worker, timeout=5)
            assert result.status_code == 200
            assert elapsed < 0.5, f"act took {elapsed * 1000:.0f} ms through the bridge"

    asyncio.run(asyncio.wait_for(scenario(), timeout=10))


def test_two_bots_are_serialized_not_interleaved(bridge):
    """Two simultaneous commands on one Mac both finish, and neither loses its answer."""
    pair = bridge.pair(name="Mac", platform="macos")
    device_id = pair["device_id"]

    async def scenario() -> None:
        async with connect(_url(bridge, device_id)) as ws:
            await ws.send(json.dumps({"type": "hello", "name": "Mac"}))
            await asyncio.sleep(0.1)

            async def fake_computer() -> None:
                for _ in range(2):
                    frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
                    which = frame["argv"][0]
                    await ws.send(json.dumps({
                        "id": frame["id"], "type": "result", "exit_code": 0,
                        "stdout": which.encode().decode(), "stderr": "", "truncated": False,
                    }))

            worker = asyncio.create_task(fake_computer())

            async def one(argv: str) -> str:
                result = await asyncio.to_thread(
                    bridge.client().post,
                    f"/v1/local-computers/{device_id}/execute",
                    json={"argv": [argv]},
                    headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)},
                )
                assert result.status_code == 200, result.text
                return result.json()["stdout"]

            first, second = await asyncio.gather(one("first"), one("second"))
            await asyncio.wait_for(worker, timeout=5)
            assert {first, second} == {"first", "second"}

    asyncio.run(asyncio.wait_for(scenario(), timeout=10))
