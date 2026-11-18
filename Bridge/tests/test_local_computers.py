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
                                   headers={"X-Forwarded-For": "100.64.0.1"})
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



def test_disconnect_during_a_call_is_a_503_not_a_500(bridge):
    pair = bridge.pair(name="Mac", platform="macos")
    device_id = pair["device_id"]

    async def scenario() -> None:
        url = f"ws://127.0.0.1:{bridge.port}/v1/local-computers/ws?" + urllib.parse.urlencode(
            {"ticket": bridge.mint_ticket(device_id)})
        async with connect(url) as ws:
            await ws.send(json.dumps({"type": "hello", "name": "Mac"}))
            await asyncio.sleep(0.2)
            await ws.close()

            for _ in range(50):
                listed = bridge.client().get(
                    "/v1/local-computers",
                    headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)})
                if not listed.json()["computers"]:
                    break
                time.sleep(0.02)
            response = bridge.client().post(
                f"/v1/local-computers/{device_id}/execute",
                json={"argv": ["/bin/echo", "no"]},
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)})
            assert response.status_code == 503, response.text

    asyncio.run(asyncio.wait_for(scenario(), timeout=15))



def test_heartbeat_gets_a_pong(bridge):
    pair = bridge.pair(name="Mac", platform="macos")
    device_id = pair["device_id"]

    async def scenario() -> None:
        url = f"ws://127.0.0.1:{bridge.port}/v1/local-computers/ws?" + urllib.parse.urlencode(
            {"ticket": bridge.mint_ticket(device_id)})
        async with connect(url) as ws:
            await ws.send(json.dumps({"type": "hello", "name": "Mac"}))
            await asyncio.sleep(0.2)
            await ws.send(json.dumps({"type": "ping"}))
            reply = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
            assert reply == {"type": "pong"}

    asyncio.run(asyncio.wait_for(scenario(), timeout=10))



def test_observe_returns_the_mac_screenshot(bridge):
    pair = bridge.pair(name="Mac", platform="macos")
    device_id = pair["device_id"]

    async def scenario() -> None:
        url = f"ws://127.0.0.1:{bridge.port}/v1/local-computers/ws?" + urllib.parse.urlencode(
            {"ticket": bridge.mint_ticket(device_id)})
        async with connect(url) as ws:
            await ws.send(json.dumps({"type": "hello", "name": "Mac"}))
            await asyncio.sleep(0.2)

            async def fake_observer() -> None:
                frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
                assert frame["type"] == "observe"
                observation = {
                    "frameID": "abc", "capturedAt": 1.0, "width": 1440, "height": 900,
                    "format": "jpeg", "imageBase64": base64.b64encode(b"jpeg").decode(),
                    "activeWindow": {"title": "Finder", "owner": "Finder", "bundleID": None,
                                     "bounds": {"x": 0, "y": 0, "width": 1440, "height": 900}},
                }
                await ws.send(json.dumps({"id": frame["id"], "type": "result", "exit_code": 0,
                                          "observation": observation}))

            worker = asyncio.create_task(fake_observer())
            result = await asyncio.to_thread(
                bridge.client().post,
                f"/v1/local-computers/{device_id}/observe",
                json={},
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)})
            await asyncio.wait_for(worker, timeout=5)
            assert result.status_code == 200, result.text
            assert base64.b64decode(result.json()["imageBase64"]) == b"jpeg"
            assert result.json()["activeWindow"]["title"] == "Finder"

    asyncio.run(asyncio.wait_for(scenario(), timeout=15))



def test_act_dispatches_an_action_batch(bridge):
    pair = bridge.pair(name="Mac", platform="macos")
    device_id = pair["device_id"]

    async def scenario() -> None:
        url = f"ws://127.0.0.1:{bridge.port}/v1/local-computers/ws?" + urllib.parse.urlencode(
            {"ticket": bridge.mint_ticket(device_id)})
        async with connect(url) as ws:
            await ws.send(json.dumps({"type": "hello", "name": "Mac"}))
            await asyncio.sleep(0.2)

            async def fake_actor() -> None:
                frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
                assert frame["type"] == "act"
                assert frame["actions"] == [{"kind": "move", "x": 10, "y": 20}]
                assert frame["bot"] == "cody"
                observation = {"frameID": "post", "width": 100, "height": 100, "format": "jpeg",
                               "imageBase64": base64.b64encode(b"after").decode(),
                               "activeWindow": None, "capturedAt": 2.0}
                await ws.send(json.dumps({"id": frame["id"], "type": "result", "exit_code": 0,
                                          "observation": observation}))

            worker = asyncio.create_task(fake_actor())
            result = await asyncio.to_thread(
                bridge.client().post,
                f"/v1/local-computers/{device_id}/act",
                json={"actions": [{"kind": "move", "x": 10, "y": 20}], "bot": "cody"},
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)})
            await asyncio.wait_for(worker, timeout=5)
            assert result.status_code == 200, result.text
            assert base64.b64decode(result.json()["imageBase64"]) == b"after"
            too_many = bridge.client().post(
                f"/v1/local-computers/{device_id}/act",
                json={"actions": [{"kind": "wait"}] * 25},
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)})
            assert too_many.status_code == 422

    asyncio.run(asyncio.wait_for(scenario(), timeout=15))



def test_file_route_confines_paths(bridge):
    pair = bridge.pair(name="Mac", platform="macos")
    device_id = pair["device_id"]
    headers = {"Authorization": "Bearer " + bridge.mint_ticket(device_id)}
    for payload in ({"op": "read", "path": "../secrets"},
                    {"op": "read", "path": "/etc/passwd"},
                    {"op": "write", "path": "x.txt", "content_base64": "not base64"}):
        response = bridge.client().post(f"/v1/local-computers/{device_id}/file",
                                        json=payload, headers=headers)
        assert response.status_code == 422, response.text


def test_secret_redaction_applies_to_text_streams():
    from hermes_bridge.local_computers import redact_result
    import base64 as b64
    raw = "token sk-canarycanarycanary1 and ghp_canarycanarycanary12"
    result = redact_result({"stdout": b64.b64encode(raw.encode()).decode()})
    out = b64.b64decode(result["stdout"]).decode()
    assert "sk-canarycanarycanary1" not in out
    assert "ghp_canarycanarycanary12" not in out
    assert out.count("[redacted]") == 2



def test_reconnect_keeps_the_new_registration(bridge):
    """The old socket's disconnect must not erase the replacement registered after it."""
    pair = bridge.pair(name="Mac", platform="macos")
    device_id = pair["device_id"]

    async def scenario() -> None:
        def ws_url() -> str:
            return f"ws://127.0.0.1:{bridge.port}/v1/local-computers/ws?" + urllib.parse.urlencode(
                {"ticket": bridge.mint_ticket(device_id)})

        first = await connect(ws_url())
        await first.send(json.dumps({"type": "hello", "name": "Mac 1"}))
        second = await connect(ws_url())
        await second.send(json.dumps({"type": "hello", "name": "Mac 2"}))
        await asyncio.sleep(0.2)
        await first.close()

        for _ in range(50):
            listed = bridge.client().get(
                "/v1/local-computers",
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)})
            computers = listed.json().get("computers", [])
            if computers and computers[0]["name"] == "Mac 2":
                break
            time.sleep(0.02)
        assert computers, "replacement registration vanished"
        assert computers[0]["name"] == "Mac 2"

        async def answer() -> None:
            frame = json.loads(await asyncio.wait_for(second.recv(), timeout=5))
            assert frame["type"] == "observe"
            observation = {"frameID": "fresh", "width": 10, "height": 10, "format": "jpeg",
                           "imageBase64": base64.b64encode(b"fresh").decode(),
                           "activeWindow": None, "capturedAt": 3.0}
            await second.send(json.dumps({"id": frame["id"], "type": "result", "exit_code": 0,
                                          "observation": observation}))

        worker = asyncio.create_task(answer())
        result = await asyncio.to_thread(
            bridge.client().post,
            f"/v1/local-computers/{device_id}/observe",
            json={},
            headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)})
        await asyncio.wait_for(worker, timeout=5)
        assert result.status_code == 200, result.text
        await second.close()

    asyncio.run(asyncio.wait_for(scenario(), timeout=15))


def test_caller_cannot_override_protected_frame_keys(bridge):
    pair = bridge.pair(name="Mac", platform="macos")
    device_id = pair["device_id"]

    async def scenario() -> None:
        url = f"ws://127.0.0.1:{bridge.port}/v1/local-computers/ws?" + urllib.parse.urlencode(
            {"ticket": bridge.mint_ticket(device_id)})
        async with connect(url) as ws:
            await ws.send(json.dumps({"type": "hello", "name": "Mac"}))
            await asyncio.sleep(0.2)

            async def attacker_wants_a_shell() -> None:
                frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
                assert frame["type"] == "file"
                assert "argv" not in frame
                assert frame["id"] != "caller-chosen"
                assert frame["op"] == "read"
                assert frame["path"] == "ok.txt"
                await ws.send(json.dumps({"id": frame["id"], "type": "result", "exit_code": 0,
                                          "file": {"op": "read", "path": "ok.txt",
                                                   "size": 0, "content_base64": ""}}))

            worker = asyncio.create_task(attacker_wants_a_shell())
            result = await asyncio.to_thread(
                bridge.client().post,
                f"/v1/local-computers/{device_id}/file",
                json={"op": "read", "path": "ok.txt", "type": "execute",
                      "id": "caller-chosen", "argv": ["/bin/sh", "-c", "id"],
                      "timeout_ms": 60_000},
                headers={"Authorization": "Bearer " + bridge.mint_ticket(device_id)})
            await asyncio.wait_for(worker, timeout=5)
            assert result.status_code == 200, result.text
            assert result.json()["path"] == "ok.txt"

    asyncio.run(asyncio.wait_for(scenario(), timeout=15))
