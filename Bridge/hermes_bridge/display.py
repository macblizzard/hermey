"""The Bot Computer for paired devices: status, control lease, a thumbnail, and **raw RFB**.

The host runs one headless Xfce desktop that every bot drives, and the gateway exposes it as
``display.*`` JSON-RPC over ``/api/ws`` plus a raw RFB splice on ``/api/display/ws``. Neither is
reachable from a phone: the first needs a dashboard token, and the second refuses a browser Origin
(a ``file://`` shell sends ``Origin: null``). So this module is the door:

* ``GET  /v1/display/status?profile=``  — the gateway's status, unchanged, plus the viewer path
* ``POST /v1/display/start|stop``       — start/stop the one screen
* ``GET  /v1/display/thumbnail?profile=`` — one JPEG data URL (null while a human holds control)
* ``POST /v1/display/lease``            — ``{action: acquire|release, viewer_id}`` (Take over / Hand back)
* ``POST /v1/display/observe``          — mints a *bridge* ticket and returns the WS path
* ``WS   /v1/display/ws?display_ticket=`` — splice to ``/api/display/ws``

Two credentials, on purpose, and neither is a session:

* the **device ticket** (``Authorization: Bearer …``) is the existing 30 s single-use ``ws_ticket``,
  consumed by each HTTP call exactly like every other paired-device route;
* the **display ticket** is minted here, carries the *gateway* display ticket inside it, and is
  single-use for 60 s. The gateway's ticket never leaves this process. It rides in the query string
  because ``noVNC`` owns its ``WebSocket`` and cannot set a header — the same reason the gateway puts
  its own ticket there, and it is spent by the time anyone reads a log.

The control lease is the gateway's, not ours: it drops keyboard/pointer/clipboard from anyone who
does not hold it, and refuses ``computer_use`` while a human is in control. With one shared screen
that means a takeover locks out **every** bot, which is the intended behaviour.

Audit records who watched and how much moved, never frame content: a screen shows passwords.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import secrets
import time
from typing import Any, Awaitable, Callable, Optional
from urllib.parse import quote, urlsplit, urlunsplit

import websockets
from fastapi import APIRouter, Header, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel

from .device_auth import require_device

logger = logging.getLogger("hermes_bridge.display")

#: Same profile shape the session pointer accepts: never a path, never a separator.
_PROFILE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")

#: Long enough for a WKWebView to load a local page and dial; short enough that a leaked URL is spent.
DISPLAY_TICKET_TTL_S = 60.0
#: RFB frames are bigger than control frames: a full-screen JPEG-quality update can pass 1 MiB. The
#: JSON-RPC relay's own cap stays at 1 MiB; this route has its own.
MAX_FRAME_BYTES = 8 * 1024 * 1024
#: The gateway's display ws close codes, passed through so the app can say the right thing.
CLOSE_CONTROL_TAKEN = 4000
CLOSE_DESKTOP_GONE = 4001
CLOSE_BAD_TICKET = 4401
CLOSE_NOT_ALLOWED = 4403

STATUS_TIMEOUT_S = 20.0
START_TIMEOUT_S = 120.0
LEASE_TIMEOUT_S = 20.0

#: An in-flight observe whose viewer never dials must not accumulate server-side state.
MAX_PENDING_TICKETS = 32


class GatewayError(RuntimeError):
    """The gateway refused or never answered. Its message is safe to show; it never has a token."""


class _Tickets:
    """Single-use display tickets, in this process only (the bridge is a single process).

    Keyed by the ticket string itself: it is 32 random bytes, so there is no index worth hashing and
    nothing to reverse. Entries are dropped on redeem, on expiry, and when the pending cap is hit so
    a client that asks for viewers in a loop cannot grow this dict without bound.
    """

    def __init__(self, ttl: float = DISPLAY_TICKET_TTL_S, cap: int = MAX_PENDING_TICKETS) -> None:
        self._ttl = ttl
        self._cap = cap
        self._items: dict[str, dict[str, Any]] = {}

    def mint(self, *, device_id: str, profile: str, viewer_id: str,
             gateway_ticket: str) -> tuple[str, float]:
        now = time.monotonic()
        self._purge(now)
        while len(self._items) >= self._cap:
            self._items.pop(next(iter(self._items)))
        ticket = secrets.token_urlsafe(32)
        expires_at = now + self._ttl
        self._items[ticket] = {
            "device_id": device_id,
            "profile": profile,
            "viewer_id": viewer_id,
            "gateway_ticket": gateway_ticket,
            "expires_at": expires_at,
        }
        return ticket, self._ttl

    def redeem(self, ticket: str) -> Optional[dict[str, Any]]:
        if not ticket:
            return None
        item = self._items.pop(ticket, None)  # single use whether or not it is still fresh
        if item is None:
            return None
        if item["expires_at"] <= time.monotonic():
            return None
        return item

    def _purge(self, now: float) -> None:
        for key in [k for k, v in self._items.items() if v["expires_at"] <= now]:
            self._items.pop(key, None)

    def __len__(self) -> int:
        self._purge(time.monotonic())
        return len(self._items)


def _profile_or_422(value: object) -> str:
    name = str(value or "").strip()
    if not _PROFILE.match(name):
        raise HTTPException(status_code=422, detail="invalid profile")
    return name


def _gateway_display_ws(config, gateway_ticket: str) -> str:
    """Where the gateway serves this profile's RFB, with the ticket the gateway minted for us."""
    parts = urlsplit(config.gateway_url)
    scheme = "wss" if parts.scheme in ("wss", "https") else "ws"
    return urlunsplit((scheme, parts.netloc, "/api/display/ws",
                       "display_ticket=" + quote(gateway_ticket), ""))


class GatewayClient:
    """One long-lived authenticated JSON-RPC client to the local gateway.

    It is long-lived for a reason that only shows up live: the gateway scopes a ``viewer_id`` to the
    connection that minted it (``display.lease.acquire`` refuses an id from another socket), so an
    observe and the takeover that follows it must ride the **same** socket. A per-call connection
    streams video fine and then fails takeover with ``viewer_mismatch``.

    Requests are matched by id on a reader task; a dropped socket fails everything pending and the
    next call reconnects (the viewer's id then needs re-minting — see the lease route).
    """

    def __init__(self, config) -> None:
        self._config = config
        self._ws = None
        self._pending: dict[int, asyncio.Future] = {}
        self._next_id = 0
        self._lock = asyncio.Lock()
        self._reader: Optional[asyncio.Task] = None

    async def _connect(self) -> None:
        try:
            ws = await websockets.connect(
                self._config.upstream_url(),
                open_timeout=self._config.connect_timeout,
                close_timeout=5,
                max_size=None,          # 1 MiB frames are for JSON-RPC text; events can be big
                max_queue=128,
                proxy=None,
            )
        except Exception as exc:  # never echo the dial URI: it carries the token
            raise GatewayError("gateway unavailable") from exc
        self._ws = ws
        self._reader = asyncio.create_task(self._read(ws), name="display-gateway-reader")

    async def _read(self, ws) -> None:
        try:
            async for raw in ws:
                if isinstance(raw, bytes):
                    raw = raw.decode("utf-8", "replace")
                for line in raw.splitlines():
                    if not line.strip():
                        continue
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    future = self._pending.pop(message.get("id"), None)
                    if future is None or future.done():
                        continue        # gateway.ready and unsolicited events
                    if message.get("error"):
                        future.set_exception(
                            GatewayError(str(message["error"].get("message") or "gateway error")))
                    else:
                        result = message.get("result")
                        future.set_result(result if isinstance(result, dict) else {})
        except Exception:
            pass
        finally:
            if self._ws is ws:
                self._ws = None
            for future in list(self._pending.values()):
                if not future.done():
                    future.set_exception(GatewayError("gateway connection lost"))
            self._pending.clear()

    async def call(self, method: str, params: dict, timeout: float = STATUS_TIMEOUT_S) -> dict:
        async with self._lock:
            if self._ws is None:
                await self._connect()
            if self._ws is None:
                raise GatewayError("gateway unavailable")
            self._next_id += 1
            rid = self._next_id
            future: asyncio.Future = asyncio.get_running_loop().create_future()
            self._pending[rid] = future
            try:
                await self._ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method,
                                                "params": params}))
                return await asyncio.wait_for(future, timeout)
            except asyncio.TimeoutError as exc:
                self._pending.pop(rid, None)
                raise GatewayError(f"{method} timed out") from exc
            except GatewayError:
                raise
            except Exception as exc:
                self._pending.pop(rid, None)
                raise GatewayError("gateway unavailable") from exc

    async def close(self) -> None:
        if self._ws is not None:
            await self._ws.close()


class _ProfileBody(BaseModel):
    profile: str
    confirm: bool = False


class _LeaseBody(BaseModel):
    profile: str
    action: str
    viewer_id: str


class _ObserveBody(BaseModel):
    profile: str
    viewer_id: Optional[str] = None


def create_display_router(
    runtime,
    gateway_call: Optional[Callable[..., Awaitable[dict]]] = None,
    display_ws_url: Optional[Callable[[str], str]] = None,
) -> APIRouter:
    """Mount with ``app.include_router(create_display_router(runtime))``.

    ``gateway_call`` / ``display_ws_url`` are injection points for tests; production uses the
    gateway this bridge is configured against.
    """
    router = APIRouter(prefix="/v1/display", tags=["display"])
    tickets = _Tickets()
    call = gateway_call or GatewayClient(runtime.config).call
    ws_url = display_ws_url or (lambda ticket: _gateway_display_ws(runtime.config, ticket))

    def _auth(authorization) -> str:
        return require_device(runtime, authorization)

    async def _ask(method: str, params: dict, timeout: float = STATUS_TIMEOUT_S) -> dict:
        try:
            return await call(method, params, timeout=timeout)
        except GatewayError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc

    @router.get("/status")
    async def status(profile: str, authorization=Header(default=None)) -> dict:
        _auth(authorization)
        result = await _ask("display.status", {"profile": _profile_or_422(profile)})
        return {**result, "viewer_path": "/v1/display/ws"}

    @router.get("/thumbnail")
    async def thumbnail(profile: str, authorization=Header(default=None)) -> dict:
        _auth(authorization)
        result = await _ask("display.thumbnail", {"profile": _profile_or_422(profile)})
        # data_url is null while stopped or while a human holds the lease (it may show what they type).
        return {"data_url": result.get("data_url"), "suppressed": result.get("suppressed")}

    @router.post("/start")
    async def start(body: _ProfileBody, authorization=Header(default=None)) -> dict:
        _auth(authorization)
        name = _profile_or_422(body.profile)
        result = await _ask("display.start", {"profile": name}, timeout=START_TIMEOUT_S)
        return result

    @router.post("/stop")
    async def stop(body: _ProfileBody, authorization=Header(default=None)) -> dict:
        _auth(authorization)
        name = _profile_or_422(body.profile)
        # `confirm` is the "I know a human may be holding it" flag; without it the gateway refuses,
        # which is the behaviour we want to surface rather than override.
        result = await _ask("display.stop", {"profile": name, "force": bool(body.confirm)})
        return result

    @router.post("/lease")
    async def lease(body: _LeaseBody, authorization=Header(default=None)) -> dict:
        _auth(authorization)
        name = _profile_or_422(body.profile)
        action = (body.action or "").strip().lower()
        if action not in ("acquire", "release"):
            raise HTTPException(status_code=422, detail="action must be acquire or release")
        if not body.viewer_id.strip():
            raise HTTPException(status_code=422, detail="viewer_id is required")
        method = f"display.lease.{action}"
        params: dict[str, Any] = {"profile": name, "viewer_id": body.viewer_id.strip()}
        if action == "release":
            params["force"] = False
        try:
            return await _ask(method, params, timeout=LEASE_TIMEOUT_S)
        except HTTPException as exc:
            # The gateway binds a viewer id to the socket that minted it. After a gateway restart or
            # a reconnect the id is no longer ours on the new socket, and a takeover would fail with
            # "was not minted" while the viewer is otherwise perfectly healthy. Observing again with
            # the SAME id re-mints it on this connection without changing who the viewer is.
            if action != "acquire" or "minted" not in str(exc.detail):
                raise
            await _ask("display.observe", {"profile": name, "viewer_id": params["viewer_id"]})
            return await _ask(method, params, timeout=LEASE_TIMEOUT_S)

    @router.post("/observe")
    async def observe(body: _ObserveBody, authorization=Header(default=None)) -> dict:
        device_id = _auth(authorization)
        name = _profile_or_422(body.profile)
        params: dict[str, Any] = {"profile": name}
        if body.viewer_id and body.viewer_id.strip():
            params["viewer_id"] = body.viewer_id.strip()
        result = await _ask("display.observe", params)
        gateway_ticket = str(result.get("ticket") or "")
        viewer_id = str(result.get("viewer_id") or "")
        if not gateway_ticket or not viewer_id:
            raise HTTPException(status_code=502, detail="gateway did not mint a display ticket")
        ticket, ttl = tickets.mint(device_id=device_id, profile=name, viewer_id=viewer_id,
                                   gateway_ticket=gateway_ticket)
        return {
            "ticket": ticket,
            "path": "/v1/display/ws",
            "expires_in": ttl,
            "viewer_id": viewer_id,
            "status": {k: v for k, v in result.items() if k != "ticket"},
        }

    @router.websocket("/ws")
    async def stream(ws: WebSocket) -> None:
        # Accept first: a close *after* accept carries a code and reason the client can act on,
        # while a refusal before accept is an opaque HTTP 403 (noVNC shows "failed to connect").
        await ws.accept()
        presented = ws.query_params.get("display_ticket", "")
        if not presented:
            header = ws.headers.get("authorization", "")
            parts = header.split()
            if len(parts) == 2 and parts[0].lower() == "bearer":
                presented = parts[1]
        record = tickets.redeem(presented)
        if record is None:
            await ws.close(code=CLOSE_BAD_TICKET, reason="display ticket missing, expired or used")
            return
        device_id = record["device_id"]
        if not runtime.registry.is_active(device_id):
            await ws.close(code=CLOSE_BAD_TICKET, reason="this device was removed")
            return

        profile = record["profile"]
        started = time.monotonic()
        try:
            upstream = await websockets.connect(
                ws_url(record["gateway_ticket"]),
                open_timeout=10,
                close_timeout=5,
                max_size=MAX_FRAME_BYTES,
                proxy=None,
            )
        except Exception as exc:
            logger.info("display ws: cannot dial the gateway for %s: %s", profile, exc)
            await ws.close(code=CLOSE_DESKTOP_GONE, reason="Bot Desktop is not running")
            runtime.audit.emit("display_open", device_id=device_id, path="/v1/display/ws",
                               outcome="unavailable", reason="gateway_dial_failed", profile=profile)
            return

        moved = {"to_screen": 0, "to_viewer": 0}

        async def viewer_to_screen() -> None:
            while True:
                message = await ws.receive()
                kind = message.get("type")
                if kind == "websocket.disconnect":
                    return
                if kind != "websocket.receive":
                    continue
                data = message.get("bytes")
                if data is None:
                    text = message.get("text")
                    if text is None:
                        continue
                    data = text.encode()
                    if len(data) > MAX_FRAME_BYTES:
                        raise _TooBig()
                    await upstream.send(text)
                else:
                    if len(data) > MAX_FRAME_BYTES:
                        raise _TooBig()
                    await upstream.send(data)
                moved["to_screen"] += len(data)

        async def screen_to_viewer() -> None:
            while True:
                frame = await upstream.recv()
                if isinstance(frame, str):
                    await ws.send_text(frame)
                    moved["to_viewer"] += len(frame)
                else:
                    await ws.send_bytes(frame)
                    moved["to_viewer"] += len(frame)

        tasks = [asyncio.create_task(viewer_to_screen(), name="display-viewer-pump"),
                 asyncio.create_task(screen_to_viewer(), name="display-screen-pump")]
        code, reason = 1000, ""
        try:
            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            for task in done:
                exc = task.exception()
                if exc is not None:
                    raise exc
        except _TooBig:
            code, reason = 1009, "frame too large"
        except WebSocketDisconnect:
            code, reason = 1001, "viewer left"
        except websockets.ConnectionClosed as exc:  # the gateway's verdict, forwarded
            code, reason = (exc.rcvd.code if exc.rcvd else 1001), (exc.rcvd.reason if exc.rcvd else "")
        except Exception:
            logger.debug("display ws failed for %s", profile, exc_info=True)
            code, reason = 1011, "display stream failed"
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await upstream.close()
            try:
                await ws.close(code=code, reason=reason[:120])
            except Exception:
                pass
            runtime.audit.emit(
                "display_close",
                device_id=device_id,
                path="/v1/display/ws",
                outcome="closed",
                reason=reason[:40] or None,
                close_code=code,
                duration_ms=round((time.monotonic() - started) * 1000, 1),
                nbytes=moved["to_viewer"],
                direction="to_viewer",
                profile=profile,
            )

    return router


class _TooBig(Exception):
    """One RFB message exceeded the route's frame cap."""
