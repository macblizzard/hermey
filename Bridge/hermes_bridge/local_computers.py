"""Local computers: paired Macs that execute commands for bots over an outbound socket.

The desktop app dials the bridge (no SSH, no Remote Login, no inbound port on the Mac). One socket per
device carries heartbeats and command requests; the bridge answers HTTP callers only when that socket
is live. Revocation is persisted beside the bridge's other state and survives a restart.

Prototype limits: commands are plain argv arrays (no shell), output is capped, one operation per
computer at a time, and there is no host path confinement yet — the Mac app owns that policy.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException, Request, WebSocket, WebSocketDisconnect

from . import paths
from .device_auth import is_local_host_request, require_device

log = logging.getLogger("hermes_bridge.local_computers")

DEFAULT_STATE_DIR = paths.STATE_DIR
DEFAULT_TIMEOUT_MS = 900_000
MAX_TIMEOUT_MS = 1_800_000


@dataclass
class _Computer:
    device_id: str
    name: str
    socket: WebSocket
    connected_at: float
    last_seen: float
    pending: dict[str, asyncio.Future] = field(default_factory=dict)
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    def public(self) -> dict[str, Any]:
        return {
            "device_id": self.device_id,
            "name": self.name,
            "connected": True,
            "connected_at": self.connected_at,
            "last_seen": self.last_seen,
        }


class LocalComputers:
    def __init__(self, runtime, state_dir: Path | None = None) -> None:
        self.runtime = runtime
        self.revoked_file = (state_dir or DEFAULT_STATE_DIR) / "revoked-local-computers.json"
        self.computers: dict[str, _Computer] = {}
        self.revoked: set[str] = self._read_revoked()

    def _read_revoked(self) -> set[str]:
        try:
            raw = json.loads(self.revoked_file.read_text(encoding="utf-8"))
            return {str(x) for x in raw["revoked"]} if isinstance(raw, dict) else set()
        except (OSError, ValueError, TypeError):
            return set()

    def _write_revoked(self) -> None:
        self.revoked_file.parent.mkdir(parents=True, exist_ok=True)
        handle = tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=self.revoked_file.parent,
                                              prefix="revoked-local-", delete=False)
        try:
            with handle:
                json.dump({"revoked": sorted(self.revoked)}, handle)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(handle.name, self.revoked_file)
        finally:
            if os.path.exists(handle.name):
                os.unlink(handle.name)

    def is_revoked(self, device_id: str) -> bool:
        return device_id in self.revoked

    async def revoke(self, device_id: str) -> bool:
        if device_id not in self.revoked:
            self.revoked.add(device_id)
            self._write_revoked()
        computer = self.computers.pop(device_id, None)
        if computer:
            await computer.socket.close(code=4403)
        return computer is not None

    def list(self) -> list[dict[str, Any]]:
        return [c.public() for c in sorted(self.computers.values(), key=lambda c: c.name)]

    async def register(self, device_id: str, name: str, socket: WebSocket) -> _Computer:
        previous = self.computers.get(device_id)
        if previous:
            await previous.socket.close(code=4400)
        now = time.time()
        computer = _Computer(device_id=device_id, name=name, socket=socket,
                             connected_at=now, last_seen=now)
        self.computers[device_id] = computer
        return computer

    def unregister(self, device_id: str) -> None:
        computer = self.computers.get(device_id)
        if computer and computer.socket is not None:
            self.computers.pop(device_id, None)
            for future in computer.pending.values():
                if not future.done():
                    # A dropped socket is an ordinary "computer not connected", not a server bug:
                    # dispatch catches LookupError and the route answers 503 instead of a 500 traceback.
                    future.set_exception(LookupError("local computer disconnected"))

    def on_message(self, device_id: str, message: dict[str, Any]) -> None:
        computer = self.computers.get(device_id)
        if not computer:
            return
        computer.last_seen = time.time()
        kind = message.get("type")
        if kind in ("pong", "heartbeat"):
            return
        if kind == "result":
            call_id = message.get("id")
            future = computer.pending.pop(call_id, None) if isinstance(call_id, str) else None
            if future and not future.done():
                future.set_result(message)
            return
        log.warning("local computer %s sent unknown frame %s", device_id, kind)

    async def dispatch(self, device_id: str, request: dict[str, Any],
                       timeout_ms: int = DEFAULT_TIMEOUT_MS) -> dict[str, Any]:
        computer = self.computers.get(device_id)
        if not computer:
            raise LookupError("that computer is not connected")
        call_id = uuid.uuid4().hex
        future = asyncio.get_running_loop().create_future()
        computer.pending[call_id] = future
        try:
            async with computer.send_lock:
                await computer.socket.send_json({"id": call_id, "type": "execute", **request})
            return await asyncio.wait_for(future, timeout=timeout_ms / 1000)
        except (TimeoutError, asyncio.TimeoutError):
            computer.pending.pop(call_id, None)
            raise TimeoutError("the computer did not answer in time") from None
        finally:
            computer.pending.pop(call_id, None)


def create_local_computers_router(runtime, computers: LocalComputers) -> APIRouter:
    router = APIRouter(prefix="/v1/local-computers", tags=["local-computers"])

    def authorize(request: Request, authorization: str | None) -> str:
        # Bots run on this host and reach the bridge over loopback. A tailnet-proxied call is refused
        # even when its peer looks like loopback, so this never becomes a network API.
        if is_local_host_request(request):
            return "host"
        return require_device(runtime, authorization)

    @router.get("")
    def list_computers(request: Request, authorization: str | None = Header(default=None)) -> dict:
        authorize(request, authorization)
        return {"computers": computers.list()}

    @router.post("/{device_id}/execute")
    async def execute(device_id: str, body: dict[str, Any], request: Request,
                      authorization: str | None = Header(default=None)) -> dict:
        caller = authorize(request, authorization)
        if computers.is_revoked(device_id):
            raise HTTPException(status_code=403, detail="this computer was revoked")
        argv = body.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(x, str) for x in argv):
            raise HTTPException(status_code=422, detail="argv must be a non-empty list of strings")
        timeout = body.get("timeout_ms", DEFAULT_TIMEOUT_MS)
        if not isinstance(timeout, int) or not (1_000 <= timeout <= MAX_TIMEOUT_MS):
            raise HTTPException(status_code=422, detail=f"timeout_ms must be 1000..{MAX_TIMEOUT_MS}")
        request: dict[str, Any] = {"argv": argv, "timeout_ms": timeout}
        if isinstance(body.get("cwd"), str):
            request["cwd"] = body["cwd"]
        try:
            result = await computers.dispatch(device_id, request, timeout_ms=timeout + 5_000)
        except LookupError:
            raise HTTPException(status_code=503, detail="that computer is not connected") from None
        except TimeoutError:
            raise HTTPException(status_code=504, detail="the computer did not answer in time") from None
        runtime.audit.emit("local_computer.execute", device_id=caller, method="local_computer",
                           path=f"/v1/local-computers/{device_id}/execute", outcome="finished")
        return result

    @router.post("/{device_id}/observe")
    async def observe(device_id: str, request: Request,
                      authorization: str | None = Header(default=None)) -> dict:
        caller = authorize(request, authorization)
        if computers.is_revoked(device_id):
            raise HTTPException(status_code=403, detail="this computer was revoked")
        try:
            result = await computers.dispatch(device_id, {"type": "observe"}, timeout_ms=30_000)
        except LookupError:
            raise HTTPException(status_code=503, detail="that computer is not connected") from None
        except TimeoutError:
            raise HTTPException(status_code=504, detail="the Mac did not answer in time") from None
        if result.get("error") or result.get("exit_code", 0) != 0:
            raise HTTPException(status_code=409,
                                detail=str(result.get("error") or "screen capture failed"))
        observation = result.get("observation")
        # Swift's JSONEncoder keeps camelCase; older frames used snake_case.
        image = observation.get("image_base64") or observation.get("imageBase64") if isinstance(observation, dict) else None
        if not isinstance(observation, dict) or not image:
            raise HTTPException(status_code=502, detail="the Mac returned no image")
        runtime.audit.emit("local_computer.observe", device_id=caller, method="local_computer",
                           path=f"/v1/local-computers/{device_id}/observe", outcome="finished")
        return observation

    @router.delete("/{device_id}")
    async def revoke_computer(device_id: str, request: Request,
                              authorization: str | None = Header(default=None)) -> dict:
        caller = authorize(request, authorization)
        was_connected = await computers.revoke(device_id)
        runtime.audit.emit("local_computer.revoke", device_id=caller, method="local_computer",
                           path=f"/v1/local-computers/{device_id}", outcome="revoked")
        return {"revoked": device_id, "was_connected": was_connected}

    return router


async def local_computer_socket(websocket: WebSocket, runtime, computers: LocalComputers) -> None:
    """One authenticated Mac, one long-lived socket. The credential is minted per connection."""
    ticket = websocket.query_params.get("ticket") or websocket.headers.get("authorization", "")[7:]
    device_id = runtime.tickets.redeem(ticket) if ticket else None
    if not device_id or not runtime.registry.is_active(device_id):
        await websocket.close(code=4401)
        return
    if computers.is_revoked(device_id):
        await websocket.close(code=4403)
        return

    await websocket.accept()
    name = ""
    try:
        hello = await asyncio.wait_for(websocket.receive_json(), timeout=10)
        if hello.get("type") != "hello":
            raise ValueError("expected hello")
        name = str(hello.get("name") or "Mac")[0:80]
        computer = await computers.register(device_id, name, websocket)
        runtime.audit.emit("local_computer.connected", device_id=device_id, method="socket",
                           path="/v1/local-computers/ws", outcome="connected")
        while True:
            message = await websocket.receive_json()
            if not isinstance(message, dict):
                continue
            if message.get("type") == "ping":
                # URLSessionWebSocketTask has a request timeout: an idle socket can die after ~60 s
                # even while a build is running. Answer the Mac's heartbeat so inbound traffic keeps
                # the task alive. The send lock is shared with command dispatch.
                current = computers.computers.get(device_id)
                if current:
                    async with current.send_lock:
                        await websocket.send_json({"type": "pong"})
                continue
            computers.on_message(device_id, message)
    except (WebSocketDisconnect, ValueError, TimeoutError, asyncio.TimeoutError):
        pass
    except Exception:  # noqa: BLE001 (one bad frame must not take the bridge down)
        log.exception("local computer socket failed for %s", device_id)
    finally:
        computers.unregister(device_id)
        if name:
            runtime.audit.emit("local_computer.disconnected", device_id=device_id,
                               method="socket", path="/v1/local-computers/ws", outcome="closed")
