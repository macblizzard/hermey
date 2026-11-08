import asyncio
import json

from test_proxy import open_ws, recv_frame


def test_only_the_editable_sections_are_forwarded(bridge, fake_gateway):
    """Model, description and soul reach the gateway; every other section is refused here.

    The stub gateway answers -32601 to `profiles.configure` (it has no profiles), so the assertion
    is about *forwarding*, not about the reply: a frame it never received is a frame the bridge
    refused, which is what the policy is for.
    """
    ticket = bridge.pair()["ticket"]

    async def scenario():
        async with open_ws(bridge.ws_url(ticket)) as ws:
            await recv_frame(ws)
            good = {"name": "test-bot", "model": "test-model", "provider": "test-provider"}
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 77, "method": "profiles.configure", "params": {**good, "soul": "# Soul"}}))
            await recv_frame(ws)
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 78, "method": "profiles.configure", "params": good}))
            await recv_frame(ws)
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 79, "method": "profiles.configure", "params": {"name": "test-bot", "description": "Lead Developer"}}))
            await recv_frame(ws)
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 80, "method": "profiles.configure", "params": {"name": "test-bot", "description": "Lead Developer", "ui_meta": {}}}))
            reply = await recv_frame(ws)
            assert reply["error"]["code"] == -32601
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 81, "method": "profiles.configure", "params": {"name": "test-bot", "soul": "x" * 64_001}}))
            reply = await recv_frame(ws)
            assert reply["error"]["code"] == -32601

    asyncio.run(scenario())
    forwarded = fake_gateway.wait_for(lambda f: f.get("id") == 78)
    assert forwarded["params"] == {"name": "test-bot", "model": "test-model", "provider": "test-provider"}
    described = fake_gateway.wait_for(lambda f: f.get("id") == 79)
    assert described["params"] == {"name": "test-bot", "description": "Lead Developer"}
    souled = fake_gateway.wait_for(lambda f: f.get("id") == 77)
    assert souled["params"]["soul"] == "# Soul"
    assert not any(frame.get("id") in (80, 81) for frame in fake_gateway.received)
