"""A minimal NDJSON JSON-RPC client, used by tests and by `latency.py`.

It is deliberately dumb: one frame per WebSocket message in each direction,
ids passed through untouched, ids compared by *type and value* (``1`` is not
``"1"``) so a proxy that rewrites ids fails the test instead of hiding.
"""

from __future__ import annotations

import asyncio
import json
from collections import deque
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

#: Frames are newline-delimited; this client tolerates a peer that coalesces
#: several frames into one message (some proxies do) by splitting on lines.
class RpcTimeout(TimeoutError):
    """No matching frame arrived in time."""


class UpgradeRefused(Exception):
    """The socket is not usable: the upgrade failed, or it closed mid-flight.

    Raised both before a connection exists (bad ticket, no endpoint, HTTP 401)
    and when the peer closes while a frame is expected. Tests assert on ``code``
    (WebSocket close code) or ``status`` (HTTP status), whichever applies.
    """

    def __init__(self, reason: str, code: int | None = None, status: int | None = None):
        super().__init__(reason)
        self.code = code
        self.status = status


@dataclass
class Frame:
    at: float          # monotonic, seconds since connect
    raw: str
    json: dict | None
    size: int


@dataclass
class Socket:
    """An open connection plus everything it has received."""

    ws: Any
    opened_at: float = 0.0
    frames: list[Frame] = field(default_factory=list)
    _next_id: int = 1
    #: Frames read from a message that carried more than one line.
    _queued: deque = field(default_factory=deque)

    # -- construction -------------------------------------------------------
    @classmethod
    async def connect(cls, url: str, *, timeout: float = 10.0, **kwargs: Any) -> "Socket":
        try:
            ws = await asyncio.wait_for(
                connect(url, max_size=None, ping_interval=None, open_timeout=timeout, **kwargs),
                timeout,
            )
        except Exception as exc:  # noqa: BLE001 - normalised for assertions
            raise _refusal(url, exc) from exc
        sock = cls(ws=ws)
        sock.opened_at = asyncio.get_running_loop().time()
        return sock

    async def __aenter__(self) -> "Socket":
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.close()

    @classmethod
    @asynccontextmanager
    async def open(cls, url: str, *, timeout: float = 10.0, **kwargs: Any):
        """``async with Socket.open(url) as sock:`` — connect, then always close."""
        sock = await cls.connect(url, timeout=timeout, **kwargs)
        try:
            yield sock
        finally:
            await sock.close()

    # -- sending ------------------------------------------------------------
    async def send_raw(self, text: str) -> None:
        await self.ws.send(text)

    async def send_frame(self, frame: dict) -> None:
        await self.ws.send(json.dumps(frame, ensure_ascii=False) + "\n")

    async def request(self, method: str, params: Any = None, *, request_id: int | None = None) -> int:
        rid = request_id if request_id is not None else self._next_id
        if isinstance(rid, int):
            self._next_id = max(self._next_id, rid + 1)
        frame: dict[str, Any] = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            frame["params"] = params
        await self.send_frame(frame)
        return rid

    async def answer(self, request_id: Any, result: Any = None, error: dict | None = None) -> None:
        frame: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id}
        if error is not None:
            frame["error"] = error
        else:
            frame["result"] = result
        await self.send_frame(frame)

    async def handshake(self, *, timeout: float = 5.0) -> dict:
        """The mandatory opening handshake, in the order the fixture records it.

        ``ping`` is id 1 and ``client.capabilities`` is id 2 in
        ``fixtures/m0-handshake.ndjson``; keeping that order means a scenario can
        be a faithful transcript.
        """
        await self.send_frame({"jsonrpc": "2.0", "id": 1, "method": "ping"})
        await self.response_for(1, timeout=timeout)
        await self.send_frame(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "client.capabilities",
                "params": {"server_requests": True},
            }
        )
        caps = await self.response_for(2, timeout=timeout)
        self._next_id = max(self._next_id, 3)
        return caps

    # -- receiving ----------------------------------------------------------
    async def recv(self, timeout: float = 5.0) -> dict:
        """Next frame as a dict. Raises RpcTimeout, or on close."""
        while True:
            frame = await self.recv_frame(timeout=timeout)
            if frame.json is not None:
                return frame.json

    async def recv_frame(self, timeout: float = 5.0) -> Frame:
        if self._queued:
            return self._queued.popleft()
        return await self._read(timeout)

    async def _read(self, timeout: float) -> Frame:
        try:
            message = await asyncio.wait_for(self.ws.recv(), timeout)
        except (asyncio.TimeoutError, TimeoutError):
            raise RpcTimeout(f"no frame within {timeout:.2f}s") from None
        except ConnectionClosed as exc:
            raise UpgradeRefused(
                f"connection closed while waiting (code {exc.code})", code=exc.code
            ) from exc
        now = asyncio.get_running_loop().time()
        text = message.decode("utf-8", "replace") if isinstance(message, bytes) else message
        lines = [ln for ln in text.split("\n") if ln.strip()]
        if not lines:
            return Frame(at=now - self.opened_at, raw="", json=None, size=0)
        for extra in lines[1:]:
            self._queued.append(
                Frame(at=now - self.opened_at, raw=extra, json=_loads(extra), size=len(extra.encode()))
            )
        line = lines[0]
        frame = Frame(
            at=now - self.opened_at, raw=line, json=_loads(line), size=len(line.encode())
        )
        self.frames.append(frame)
        return frame

    async def expect(self, *, type: str | None = None, method: str | None = None,
                     timeout: float = 5.0) -> dict:
        """Next frame, asserting its kind. ``type`` matches an event's params.type."""
        target = await self.recv(timeout=timeout)
        if type is not None:
            got = (target.get("params") or {}).get("type")
            assert got == type, f"expected event {type!r}, got {got!r} ({target})"
        if method is not None:
            assert target.get("method") == method, f"expected method {method!r}, got {target}"
        return target

    async def request_response(self, method: str, params: Any = None, *, timeout: float = 5.0,
                               request_id: int | None = None) -> dict:
        rid = await self.request(method, params, request_id=request_id)
        return await self.response_for(rid, timeout=timeout)

    async def response_for(self, request_id: Any, *, timeout: float = 5.0) -> dict:
        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise RpcTimeout(f"no response for id {request_id!r} within {timeout:.2f}s")
            frame = await self.recv(timeout=remaining)
            if "method" not in frame and _same_id(frame.get("id"), request_id):
                return frame

    async def silence(self, duration: float = 0.4) -> list[dict]:
        """Read for ``duration`` and return whatever arrived (usually nothing)."""
        seen: list[dict] = []
        deadline = asyncio.get_running_loop().time() + duration
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                return seen
            try:
                seen.append(await self.recv(timeout=remaining))
            except RpcTimeout:
                return seen

    async def close(self) -> None:
        try:
            await self.ws.close()
        except Exception:  # noqa: BLE001 - closing during a failure is best effort
            pass

    # -- views --------------------------------------------------------------
    def events(self, type: str) -> list[dict]:
        return [
            f.json
            for f in self.frames
            if f.json and f.json.get("method") == "event"
            and (f.json.get("params") or {}).get("type") == type
        ]

    def requests(self) -> list[dict]:
        """Server->client requests seen (method + id, i.e. requires an answer)."""
        return [f.json for f in self.frames if f.json and f.json.get("method") and f.json.get("id") is not None]

    def frame_types(self) -> list[str]:
        out = []
        for f in self.frames:
            if not f.json:
                out.append("<unparsed>")
            elif f.json.get("method") == "event":
                out.append((f.json.get("params") or {}).get("type", "<event>"))
            elif f.json.get("method"):
                out.append(f.json["method"])
            else:
                out.append("<response>")
        return out


def _loads(text: str) -> dict | None:
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def _same_id(a: Any, b: Any) -> bool:
    """JSON-RPC ids are typed: 1 != "1". A proxy must not coerce them."""
    if a == b and type(a) is type(b):
        return True
    # int/float equivalence is the one coercion JSON allows (1 vs 1.0).
    return isinstance(a, (int, float)) and isinstance(b, (int, float)) and a == b


def _refusal(url: str, exc: Exception) -> UpgradeRefused:
    status = getattr(exc, "status_code", None) or getattr(
        getattr(exc, "response", None), "status_code", None
    )
    code = getattr(exc, "code", None)
    if status is None and type(exc).__name__ == "InvalidStatus":
        status = getattr(exc, "status_code", None)
    return UpgradeRefused(f"{url}: {type(exc).__name__}: {exc}", code=code, status=status)


async def assert_upgrade_refused(
    url: str,
    *,
    allowed_codes: tuple[int, ...] = (4401, 4403, 1008, 1009, 1011),
    allowed_status: tuple[int, ...] = (401, 403, 404, 400),
) -> UpgradeRefused:
    """Assert the socket is not usable, and return *why* it was refused."""
    try:
        sock = await Socket.connect(url, timeout=5.0)
    except UpgradeRefused as exc:
        if exc.status is not None and exc.status in allowed_status:
            return exc
        if exc.code is not None and exc.code in allowed_codes:
            return exc
        raise AssertionError(f"refused for an unexpected reason: {exc}") from exc
    # Connected: it must at least be closed immediately with no usable frames.
    try:
        await sock.recv(timeout=1.0)
    except (RpcTimeout, UpgradeRefused) as exc:
        await sock.close()
        if isinstance(exc, UpgradeRefused):
            return exc
        raise AssertionError(f"{url} accepted the connection and stayed open") from exc
    await sock.close()
    raise AssertionError(f"{url} accepted the connection and served a frame")
