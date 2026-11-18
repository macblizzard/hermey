"""Local computers: paired Macs that execute commands for bots over an outbound socket.

The desktop app dials the bridge (no SSH, no Remote Login, no inbound port on the Mac). One socket per
device carries heartbeats and command requests; the bridge answers HTTP callers only when that socket
is live. Revocation is persisted beside the bridge's other state and survives a restart.

Prototype limits: commands are plain argv arrays (no shell), output is capped, one operation per
computer at a time, and there is no host path confinement yet — the Mac app owns that policy.
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import re
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
SECRET_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9_-]{16,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"Bearer\s+[A-Za-z0-9._-]{16,}"),
)


def redact_text(text: str) -> str:
    for pattern in SECRET_PATTERNS:
        text = pattern.sub("[redacted]", text)
    return text


def redact_result(result: dict[str, Any]) -> dict[str, Any]:
    """Redact token-shaped strings from text streams without touching binary output."""
    redacted = dict(result)
    for key in ("stdout", "stderr"):
        encoded = redacted.get(key)
        if not isinstance(encoded, str):
            continue
        try:
            raw = base64.b64decode(encoded, validate=True).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            continue
        clean = redact_text(raw)
        if clean != raw:
            redacted[key] = base64.b64encode(clean.encode()).decode()
    return redacted


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
            await self._close_bounded(computer.socket, code=4403)
        return computer is not None

    @staticmethod
    async def _close_bounded(socket: WebSocket, code: int) -> None:
        """Close without waiting on the peer's close handshake.

        A hung or malicious client can otherwise stall an operator route on the library's close
        timeout; the registry entry is already gone, so the force-close merely releases the socket.
        """
        try:
            await asyncio.wait_for(asyncio.shield(asyncio.create_task(socket.close(code=code))), 1.0)
        except (TimeoutError, asyncio.TimeoutError):
            pass

    def list(self) -> list[dict[str, Any]]:
        return [c.public() for c in sorted(self.computers.values(), key=lambda c: c.name)]

    async def register(self, device_id: str, name: str, socket: WebSocket) -> _Computer:
        previous = self.computers.pop(device_id, None)
        if previous:
            for future in previous.pending.values():
                if not future.done():
                    future.set_exception(LookupError("local computer disconnected"))
            await self._close_bounded(previous.socket, code=4400)
        now = time.time()
        computer = _Computer(device_id=device_id, name=name, socket=socket,
                             connected_at=now, last_seen=now)
        self.computers[device_id] = computer
        return computer

    def unregister(self, device_id: str, socket: WebSocket) -> None:
        """Only the owning socket may remove its registration.

        A reconnect closes the previous socket with 4400; that socket's handler wakes later and must
        not remove the *new* registration by device id alone.
        """
        computer = self.computers.get(device_id)
        if computer and computer.socket is socket:
            self.computers.pop(device_id, None)
            for future in computer.pending.values():
                if not future.done():
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
                try:
                    await computer.socket.send_json({"id": call_id, "type": "execute", **request})
                except Exception:
                    raise LookupError("local computer disconnected") from None
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
        return redact_result(result)

    @router.post("/{device_id}/browser")
    async def browser(device_id: str, body: dict[str, Any], request: Request,
                      authorization: str | None = Header(default=None)) -> dict:
        caller = authorize(request, authorization)
        if computers.is_revoked(device_id):
            raise HTTPException(status_code=403, detail="this computer was revoked")
        op = body.get("op")
        if op not in ("navigate", "snapshot", "act", "downloads"):
            raise HTTPException(status_code=422, detail="unsupported browser operation")
        if op == "navigate":
            value = body.get("url")
            if not isinstance(value, str) or not value.startswith(("http://", "https://")):
                raise HTTPException(status_code=422, detail="url must be http or https")
        if op == "act":
            actions = body.get("actions")
            if not isinstance(actions, list) or not (1 <= len(actions) <= 10):
                raise HTTPException(status_code=422, detail="actions must be a list of 1..10 objects")
        payload: dict[str, Any] = {"type": "browser", "op": op}
        if op == "navigate":
            payload["url"] = value
        elif op == "act":
            payload["actions"] = actions
        try:
            result = await computers.dispatch(device_id, payload, timeout_ms=60_000)
        except LookupError:
            raise HTTPException(status_code=503, detail="that computer is not connected") from None
        except TimeoutError:
            raise HTTPException(status_code=504, detail="the Mac did not answer in time") from None
        if result.get("error") or result.get("exit_code", 0) != 0:
            raise HTTPException(status_code=409,
                                detail=redact_text(str(result.get("error") or "the browser call failed")))
        runtime.audit.emit("local_computer.browser", device_id=caller, method="local_computer",
                           path=f"/v1/local-computers/{device_id}/browser", outcome="finished")
        return result["browser"]

    @router.post("/{device_id}/file")
    async def file_op(device_id: str, body: dict[str, Any], request: Request,
                      authorization: str | None = Header(default=None)) -> dict:
        caller = authorize(request, authorization)
        if computers.is_revoked(device_id):
            raise HTTPException(status_code=403, detail="this computer was revoked")
        op = body.get("op")
        if op not in ("read", "write", "list", "mkdir"):
            raise HTTPException(status_code=422, detail="op must be read, write, list or mkdir")
        path = body.get("path")
        if not isinstance(path, str) or not path or path.startswith("/") or ".." in path.split("/"):
            raise HTTPException(status_code=422, detail="path must be relative to the workspace")
        if op == "write":
            encoded = body.get("content_base64")
            if not isinstance(encoded, str):
                raise HTTPException(status_code=422, detail="content_base64 is required")
            try:
                size = len(base64.b64decode(encoded, validate=True))
            except (ValueError, TypeError):
                raise HTTPException(status_code=422, detail="content_base64 is not base64") from None
            if size > 4_000_000:
                raise HTTPException(status_code=413, detail="file exceeds 4 MB")
        payload: dict[str, Any] = {"type": "file", "op": op, "path": path}
        if op == "write":
            payload["content_base64"] = encoded
        try:
            result = await computers.dispatch(device_id, payload, timeout_ms=60_000)
        except LookupError:
            raise HTTPException(status_code=503, detail="that computer is not connected") from None
        except TimeoutError:
            raise HTTPException(status_code=504, detail="the Mac did not answer in time") from None
        if result.get("error") or result.get("exit_code", 0) != 0:
            raise HTTPException(status_code=409,
                                detail=redact_text(str(result.get("error") or "the file operation failed")))
        runtime.audit.emit("local_computer.file", device_id=caller, method="local_computer",
                           path=f"/v1/local-computers/{device_id}/file", outcome="finished")
        file = result.get("file")
        if not isinstance(file, dict):
            raise HTTPException(status_code=502, detail="the Mac returned no file payload")
        if isinstance(file.get("content_base64"), str):
            try:
                raw = base64.b64decode(file["content_base64"], validate=True).decode("utf-8")
                clean = redact_text(raw)
                if clean != raw:
                    file = {**file, "content_base64": base64.b64encode(clean.encode()).decode()}
            except (ValueError, UnicodeDecodeError):
                pass
        return file

    @router.post("/{device_id}/act")
    async def act(device_id: str, body: dict[str, Any], request: Request,
                  authorization: str | None = Header(default=None)) -> dict:
        caller = authorize(request, authorization)
        if computers.is_revoked(device_id):
            raise HTTPException(status_code=403, detail="this computer was revoked")
        actions = body.get("actions")
        if not isinstance(actions, list) or not (1 <= len(actions) <= 24) or not all(
                isinstance(action, dict) for action in actions):
            raise HTTPException(status_code=422, detail="actions must be a list of 1..24 objects")
        bot = str(body.get("bot", "unknown"))[:40]
        try:
            result = await computers.dispatch(
                device_id, {"type": "act", "actions": actions, "bot": bot}, timeout_ms=60_000)
        except LookupError:
            raise HTTPException(status_code=503, detail="that computer is not connected") from None
        except TimeoutError:
            raise HTTPException(status_code=504, detail="the Mac did not answer in time") from None
        if result.get("error") or result.get("exit_code", 0) != 0:
            raise HTTPException(status_code=409,
                                detail=redact_text(str(result.get("error") or "the action failed")))
        observation = result.get("observation")
        if not isinstance(observation, dict) or not (
                observation.get("image_base64") or observation.get("imageBase64")):
            raise HTTPException(status_code=502, detail="the Mac returned no screenshot")
        runtime.audit.emit("local_computer.act", device_id=caller, method="local_computer",
                           path=f"/v1/local-computers/{device_id}/act", outcome="finished")
        return observation

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
                                detail=redact_text(str(result.get("error") or "screen capture failed")))
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
        computers.unregister(device_id, websocket)
        if name:
            runtime.audit.emit("local_computer.disconnected", device_id=device_id,
                               method="socket", path="/v1/local-computers/ws", outcome="closed")
