"""The Bot Computer routes: device auth, the two-ticket handshake, and the RFB splice.

The gateway is faked at exactly two seams — the JSON-RPC call and the display WebSocket URL — because
those are the only places this module touches the host. Everything else (tickets, close codes,
revocation, frame forwarding) is the real code.
"""

import asyncio
import threading

import pytest
import websockets
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from hermes_bridge.app import create_app
from hermes_bridge.config import BridgeConfig

BANNER = b"RFB 003.008\n"


class FakeDesktop:
    """A local RFB endpoint: greets with the banner, then echoes whatever it receives."""

    def __init__(self):
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._loop.run_forever, daemon=True)
        self._thread.start()
        self._server = None
        asyncio.run_coroutine_threadsafe(self._serve(), self._loop).result(10)

    async def _serve(self):
        self._server = await websockets.serve(self._handler, "127.0.0.1", 0)
        self.port = self._server.sockets[0].getsockname()[1]

    async def _handler(self, connection):
        await connection.send(BANNER)
        async for message in connection:
            payload = message if isinstance(message, bytes) else message.encode()
            await connection.send(b"echo:" + payload)

    def url(self, ticket: str) -> str:
        return f"ws://127.0.0.1:{self.port}/api/display/ws?display_ticket={ticket}"

    async def _close_server(self):
        self._server.close()          # websockets' asyncio Server closes synchronously
        await self._server.wait_closed()

    def stop(self):
        if self._server is not None:
            asyncio.run_coroutine_threadsafe(self._close_server(), self._loop).result(5)
        self._loop.call_soon_threadsafe(self._loop.stop)


def paired_app(tmp_path, calls, ws_url):
    app = create_app(BridgeConfig(db_path=tmp_path / "bridge.db"),
                     display_gateway_call=calls, display_ws_url=ws_url)
    runtime = app.state.bridge
    runtime.registry.add_device(device_id="phone", name="phone", platform="ios",
                                public_key="test", refresh_token="secret-phone")
    runtime.registry.add_device(device_id="mac", name="mac", platform="macos",
                                public_key="test", refresh_token="secret-mac")
    return app


def headers(client, device="phone"):
    ticket = client.post("/v1/token", json={"device_id": device,
                                            "refresh_token": f"secret-{device}"}).json()["ws_ticket"]
    return {"Authorization": f"Bearer {ticket}"}


def recorder(result=None):
    """A stand-in for the gateway: records every call, answers with one fixed body."""
    calls = []

    async def call(method, params, timeout=None):
        calls.append((method, params))
        body = result(method, params) if callable(result) else (result or {})
        if isinstance(body, Exception):
            raise body
        return body

    return calls, call


def test_every_route_needs_a_fresh_device_ticket(tmp_path):
    calls, call = recorder({"running": True})
    app = paired_app(tmp_path, call, lambda t: "ws://127.0.0.1:1/none")
    with TestClient(app) as client:
        assert client.get("/v1/display/status", params={"profile": "cody"}).status_code == 401
        used = headers(client)
        assert client.get("/v1/display/status", params={"profile": "cody"},
                          headers=used).status_code == 200
        # single use: the same ticket cannot open a second call
        assert client.get("/v1/display/status", params={"profile": "cody"},
                          headers=used).status_code == 401
        for path, body in (("/v1/display/start", {"profile": "cody"}),
                           ("/v1/display/stop", {"profile": "cody"}),
                           ("/v1/display/observe", {"profile": "cody"}),
                           ("/v1/display/lease", {"profile": "cody", "action": "acquire",
                                                  "viewer_id": "v"})):
            assert client.post(path, json=body).status_code == 401
        assert client.get("/v1/display/thumbnail", params={"profile": "cody"}).status_code == 401
    # only the one authenticated call reached the gateway; every refusal stopped at the door
    assert calls == [("display.status", {"profile": "cody"})]


def test_status_passes_the_gateway_body_through_and_validates_the_profile(tmp_path):
    calls, call = recorder({"running": True, "display": ":20", "lease": {"holder": "agent", "epoch": 0}})
    app = paired_app(tmp_path, call, lambda t: "ws://127.0.0.1:1/none")
    with TestClient(app) as client:
        body = client.get("/v1/display/status", params={"profile": "atlas"},
                          headers=headers(client)).json()
        assert body["display"] == ":20"
        assert body["lease"]["holder"] == "agent"
        assert body["viewer_path"] == "/v1/display/ws"
        assert calls == [("display.status", {"profile": "atlas"})]
        # a profile is a directory name: path separators never reach the gateway
        bad = client.get("/v1/display/status", params={"profile": "../etc"},
                         headers=headers(client))
        assert bad.status_code == 422
        assert len(calls) == 1


def test_force_is_only_sent_when_the_client_confirms_a_human_may_hold_it(tmp_path):
    calls, call = recorder({"stopped": True})
    app = paired_app(tmp_path, call, lambda t: "ws://127.0.0.1:1/none")
    with TestClient(app) as client:
        client.post("/v1/display/stop", json={"profile": "cody"}, headers=headers(client))
        client.post("/v1/display/stop", json={"profile": "cody", "confirm": True},
                    headers=headers(client))
    assert calls == [("display.stop", {"profile": "cody", "force": False}),
                     ("display.stop", {"profile": "cody", "force": True})]


def test_lease_action_and_viewer_are_required_and_forwarded(tmp_path):
    calls, call = recorder({"lease": {"holder": "human", "epoch": 1}})
    app = paired_app(tmp_path, call, lambda t: "ws://127.0.0.1:1/none")
    with TestClient(app) as client:
        assert client.post("/v1/display/lease",
                           json={"profile": "cody", "action": "steal", "viewer_id": "v"},
                           headers=headers(client)).status_code == 422
        assert client.post("/v1/display/lease",
                           json={"profile": "cody", "action": "acquire", "viewer_id": " "},
                           headers=headers(client)).status_code == 422
        ok = client.post("/v1/display/lease",
                         json={"profile": "cody", "action": "acquire", "viewer_id": "v-1"},
                         headers=headers(client))
        assert ok.status_code == 200 and ok.json()["lease"]["holder"] == "human"
    assert calls == [("display.lease.acquire", {"profile": "cody", "viewer_id": "v-1"})]


def test_observe_to_rfb_splice_and_single_use_display_ticket(tmp_path):
    desktop = FakeDesktop()
    seen = {}

    async def call(method, params, timeout=None):
        assert method == "display.observe"
        return {"ticket": "gateway-ticket", "viewer_id": "viewer-7",
                "path": "/api/display/ws", "running": True}

    def ws_url(ticket):
        seen["ticket"] = ticket
        return desktop.url(ticket)

    app = paired_app(tmp_path, call, ws_url)
    try:
        with TestClient(app) as client:
            observed = client.post("/v1/display/observe", json={"profile": "cody"},
                                   headers=headers(client)).json()
            # the gateway's ticket never leaves the bridge; what the app gets is its own
            assert observed["ticket"] != "gateway-ticket"
            assert observed["viewer_id"] == "viewer-7"
            assert observed["path"] == "/v1/display/ws"
            assert observed["status"]["running"] is True

            with client.websocket_connect(
                    f"/v1/display/ws?display_ticket={observed['ticket']}") as ws:
                assert ws.receive_bytes() == BANNER
                ws.send_bytes(b"pointer")
                assert ws.receive_bytes() == b"echo:pointer"
            assert seen["ticket"] == "gateway-ticket"

            # the display ticket is spent by the first connection
            with pytest.raises(WebSocketDisconnect) as closed:
                with client.websocket_connect(
                        f"/v1/display/ws?display_ticket={observed['ticket']}") as again:
                    again.receive_bytes()
            assert closed.value.code == 4401
    finally:
        desktop.stop()


def test_a_revoked_device_cannot_stream_with_a_ticket_it_still_holds(tmp_path):
    desktop = FakeDesktop()

    async def call(method, params, timeout=None):
        return {"ticket": "gw", "viewer_id": "v", "path": "/api/display/ws", "running": True}

    app = paired_app(tmp_path, call, desktop.url)
    try:
        with TestClient(app) as client:
            observed = client.post("/v1/display/observe", json={"profile": "cody"},
                                   headers=headers(client)).json()
            app.state.bridge.registry.revoke("phone")
            with pytest.raises(WebSocketDisconnect) as closed:
                with client.websocket_connect(
                        f"/v1/display/ws?display_ticket={observed['ticket']}") as ws:
                    ws.receive_bytes()
            assert closed.value.code == 4401
    finally:
        desktop.stop()


def test_a_dead_desktop_closes_the_viewer_with_4001(tmp_path):
    async def call(method, params, timeout=None):
        return {"ticket": "gw", "viewer_id": "v", "path": "/api/display/ws", "running": False}

    app = paired_app(tmp_path, call, lambda ticket: "ws://127.0.0.1:1/dead")
    with TestClient(app) as client:
        observed = client.post("/v1/display/observe", json={"profile": "cody"},
                               headers=headers(client)).json()
        with pytest.raises(WebSocketDisconnect) as closed:
            with client.websocket_connect(
                    f"/v1/display/ws?display_ticket={observed['ticket']}") as ws:
                ws.receive_bytes()
        assert closed.value.code == 4001


def test_a_gateway_refusal_is_a_502_with_its_message_not_a_token(tmp_path):
    from hermes_bridge.display import GatewayError

    async def call(method, params, timeout=None):
        raise GatewayError("this profile's Bot Desktop is not running; call display.start first")

    app = paired_app(tmp_path, call, lambda ticket: "ws://127.0.0.1:1/none")
    with TestClient(app) as client:
        response = client.post("/v1/display/observe", json={"profile": "cody"},
                               headers=headers(client))
        assert response.status_code == 502
        assert "display.start" in response.json()["detail"]
