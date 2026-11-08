"""A real WebSocket gateway, in a thread, for the proxy tests.

Not a mock: the bridge dials this over TCP with ``websockets.connect``, so the
tests exercise the actual handshake, NDJSON splitting, close codes and
backpressure paths. It speaks the observed wire format from ``fixtures/NOTES.md``:
``gateway.ready`` first, ``event`` notifications with ``params.type``, and
``client.capabilities`` answered with the real capability list.

Tests can push server->client requests with :meth:`FakeGateway.push` and inspect
everything the bridge sent with :attr:`FakeGateway.received`.
"""

from __future__ import annotations

import asyncio
import json
import threading
import time
from typing import Any, Callable, Optional
from urllib.parse import parse_qs, urlsplit

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

SERVER_CAPABILITIES = [
    "approval",
    "clarify",
    "display.install.sudo",
    "preview.act",
    "preview.read",
    "secret",
    "setup_beat",
    "sudo",
    "terminal.read",
    "theme.apply",
    "theme.pick",
    "tour",
    "vault.code",
    "vault.save_login",
    "vault.unlock_prompt",
    "window.read",
]

READY_FRAME = {
    "jsonrpc": "2.0",
    "method": "event",
    "params": {
        "type": "gateway.ready",
        "payload": {"skin": {"name": "default"}, "change_events": True, "replay_epoch": "test"},
    },
}


def line(frame: Any) -> str:
    # The real gateway's WS transport sends one serialized frame per message with
    # no trailing newline (stdio adds it; WS does not). Mirror that here so the
    # proxy is tested against the actual wire shape, not a friendlier one.
    return json.dumps(frame, separators=(",", ":"))


class FakeGateway:
    def __init__(self) -> None:
        self.url = ""
        self.received: list[dict] = []
        self.responses: list[dict] = []
        self.connections = 0
        self.auth_tokens: list[Optional[str]] = []
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread: Optional[threading.Thread] = None
        self._ready = threading.Event()
        self._stop: Optional[asyncio.Event] = None
        self._conn = None
        self._lock = threading.Lock()
        self.auto_respond = True

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> "FakeGateway":
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run, name="fake-gateway", daemon=True)
        self._thread.start()
        if not self._ready.wait(10):
            raise RuntimeError("fake gateway did not start")
        return self

    def _run(self) -> None:
        assert self._loop is not None
        asyncio.set_event_loop(self._loop)
        try:
            self._loop.run_until_complete(self._serve())
        finally:
            self._loop.close()

    async def _serve(self) -> None:
        self._stop = asyncio.Event()
        async with serve(self._handler, "127.0.0.1", 0) as server:
            sock = server.sockets[0]
            port = sock.getsockname()[1]
            self.url = f"ws://127.0.0.1:{port}/api/ws"
            self._ready.set()
            await self._stop.wait()

    def stop(self) -> None:
        if self._loop is None:
            return
        if self._stop is not None:
            self._loop.call_soon_threadsafe(self._stop.set)
        if self._thread is not None:
            self._thread.join(10)
        self._thread = None

    # -- server ------------------------------------------------------------

    async def _handler(self, conn) -> None:
        self._conn = conn
        self.connections += 1
        query = parse_qs(urlsplit(conn.request.path).query)
        self.auth_tokens.append((query.get("token") or [None])[0])
        await conn.send(line(READY_FRAME))
        try:
            async for raw in conn:
                for chunk in raw.splitlines():
                    chunk = chunk.strip()
                    if not chunk:
                        continue
                    try:
                        frame = json.loads(chunk)
                    except json.JSONDecodeError:
                        continue
                    with self._lock:
                        self.received.append(frame)
                    if isinstance(frame, dict) and "method" not in frame:
                        with self._lock:
                            self.responses.append(frame)
                    reply = self._auto_reply(frame) if self.auto_respond else None
                    if reply is not None:
                        await conn.send(line(reply))
        except ConnectionClosed:
            pass
        finally:
            if self._conn is conn:
                self._conn = None

    def _auto_reply(self, frame: dict) -> Optional[dict]:
        method = frame.get("method")
        request_id = frame.get("id")
        if method is None or request_id is None:
            return None
        if method == "ping":
            return {"jsonrpc": "2.0", "id": request_id, "result": {"pong": True}}
        if method == "client.capabilities":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "server_requests": SERVER_CAPABILITIES,
                    "declines_not_shown": True,
                    "canonical_clarify_batch": True,
                },
            }
        if method == "gateway.capabilities":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"per_session_exclusive_submit": True},
            }
        if method == "session.list":
            return {"jsonrpc": "2.0", "id": request_id, "result": {"sessions": []}}
        if method == "prompt.submit":
            return {"jsonrpc": "2.0", "id": request_id, "result": {"turn_id": "turn-1"}}
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {
                "code": -32601,
                "message": f"unknown method: {method} — not available on this Hermes backend",
            },
        }

    # -- test controls -----------------------------------------------------

    def wait_connected(self, timeout: float = 5.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self._conn is not None:
                return
            time.sleep(0.01)
        raise AssertionError("client never connected to the fake gateway")

    def wait_disconnected(self, timeout: float = 5.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self._conn is None:
                return
            time.sleep(0.01)
        raise AssertionError("bridge never closed its upstream connection")

    def push(self, frame: dict, timeout: float = 5.0) -> None:
        self.wait_connected(timeout)
        assert self._loop is not None
        future = asyncio.run_coroutine_threadsafe(self._conn.send(line(frame)), self._loop)
        future.result(timeout)

    def push_raw(self, payload: str, timeout: float = 5.0) -> None:
        self.wait_connected(timeout)
        assert self._loop is not None
        future = asyncio.run_coroutine_threadsafe(self._conn.send(payload), self._loop)
        future.result(timeout)

    def close_connection(self) -> None:
        if self._conn is None or self._loop is None:
            return
        asyncio.run_coroutine_threadsafe(self._conn.close(), self._loop).result(5)

    def wait_for(
        self, predicate: Callable[[dict], bool], timeout: float = 5.0
    ) -> dict:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for frame in self.received:
                    if predicate(frame):
                        return frame
            time.sleep(0.01)
        with self._lock:
            seen = [frame.get("method") for frame in self.received]
        raise AssertionError(f"frame not seen; received methods={seen}")

    def methods(self) -> list[str]:
        with self._lock:
            return [str(frame.get("method")) for frame in self.received if frame.get("method")]
