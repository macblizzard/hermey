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
from typing import Any, Optional

from fastapi import APIRouter, Header, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import StreamingResponse

from . import paths
from .agent_skills import install as install_agent_skills
from .agent_skills import status as skill_report
from .device_auth import is_local_host_request, require_device

log = logging.getLogger("hermes_bridge.local_computers")

# Liveness of the Mac's socket, checked from this side. The interval has to be well under the stale
# window so a single lost frame is not read as a dead machine, and the stale window has to be short
# enough that a caller waiting on a shoved-asleep Mac fails fast instead of hanging on a 30-minute
# timeout.
PING_INTERVAL_SECONDS = 20
STALE_AFTER_SECONDS = 55

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
    progress: dict[str, asyncio.Queue] = field(default_factory=dict)
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

    def allow(self, device_id: str) -> bool:
        """Lift a revoke, so the Mac's own switch can undo the trash button.

        Revoking used to be a one-way door: the id went into `revoked` and nothing ever took it
        out, so after "remove this computer" the Mac reconnected forever into a rejected
        handshake and the owner had no way back except editing a file on the host. Removing a
        computer is a decision about *this moment*, and turning computer use back on is the
        opposite decision — reported after the trash button left a Mac stuck on "Reconnecting".

        Returns whether anything changed, so the route can say whether a revoke was lifted.
        """
        if device_id not in self.revoked:
            return False
        self.revoked.discard(device_id)
        self._write_revoked()
        return True

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


    def touch(self, device_id: str) -> None:
        """Record that the Mac is alive, whatever it sent.

        `last_seen` in the listing only moved when a *command* arrived, because the socket loop
        handles ping/pong with `continue` before `on_message`. The stale check uses the loop's own
        clock, so health was never wrong — but `/v1/local-computers` reported a connection as
        minutes-old while it was answering pings, which reads as a dead Mac to anything watching it.
        """
        computer = self.computers.get(device_id)
        if computer:
            computer.last_seen = time.time()

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
        if kind == "progress":
            call_id = message.get("id")
            queue = computer.progress.get(call_id) if isinstance(call_id, str) else None
            if queue is not None:
                queue.put_nowait(message)
            return
        log.warning("local computer %s sent unknown frame %s", device_id, kind)

    async def dispatch(self, device_id: str, request: dict[str, Any],
                       timeout_ms: int = DEFAULT_TIMEOUT_MS,
                       progress_queue: asyncio.Queue | None = None) -> dict[str, Any]:
        computer = self.computers.get(device_id)
        if not computer:
            raise LookupError("that computer is not connected")
        call_id = uuid.uuid4().hex
        future = asyncio.get_running_loop().create_future()
        computer.pending[call_id] = future
        if progress_queue is not None:
            computer.progress[call_id] = progress_queue
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
            computer.progress.pop(call_id, None)


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

    @router.post("/{device_id}/execute-stream")
    async def execute_stream(device_id: str, body: dict[str, Any], request: Request,
                             authorization: str | None = Header(default=None)):
        """One command, answered as NDJSON: progress lines as they arrive, then the final result.

        The Mac coalesces its own output, so the socket is never the bottleneck; this route only
        has to keep up with the queue it is handed. A caller that does not read still gets its
        answer, because the queue is bounded by the command's own output cap.
        """
        caller = authorize(request, authorization)
        if computers.is_revoked(device_id):
            raise HTTPException(status_code=403, detail="this computer was revoked")
        argv = body.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(x, str) for x in argv):
            raise HTTPException(status_code=422, detail="argv must be a non-empty list of strings")
        timeout = body.get("timeout_ms", DEFAULT_TIMEOUT_MS)
        if not isinstance(timeout, int) or not (1_000 <= timeout <= MAX_TIMEOUT_MS):
            raise HTTPException(status_code=422, detail=f"timeout_ms must be 1000..{MAX_TIMEOUT_MS}")
        payload: dict[str, Any] = {"argv": argv, "timeout_ms": timeout}
        if isinstance(body.get("cwd"), str):
            payload["cwd"] = body["cwd"]

        queue: asyncio.Queue = asyncio.Queue()
        task = asyncio.create_task(
            computers.dispatch(device_id, payload, timeout_ms=timeout + 5_000,
                               progress_queue=queue))

        async def lines():
            saw_progress = False
            while not task.done() or not queue.empty():
                try:
                    item = await asyncio.wait_for(queue.get(), timeout=0.2)
                except (TimeoutError, asyncio.TimeoutError):
                    continue
                saw_progress = True
                yield json.dumps(item) + "\n"
            result = await task
            if saw_progress:
                # The caller already saw every byte through the progress lines; repeating the whole
                # stream in the final frame would print the build twice.
                final = {key: value for key, value in redact_result(result).items()
                         if key not in ("stdout", "stderr")}
            else:
                # An older Mac app sends no progress frames; the whole answer is the final frame.
                final = redact_result(result)
            yield json.dumps(final) + "\n"

        runtime.audit.emit("local_computer.execute", device_id=caller, method="local_computer",
                           path=f"/v1/local-computers/{device_id}/execute-stream",
                           outcome="streaming")
        return StreamingResponse(lines(), media_type="application/x-ndjson")

    @router.post("/{device_id}/resume")
    async def resume(device_id: str, request: Request,
                     authorization: str | None = Header(default=None)) -> dict:
        """Hand control back to the bot after a takeover.

        The Mac pauses on physical input and waits; this is the explicit release the parity plan
        calls for. It is deliberately not an approval — the owner is already looking at the machine.
        """
        caller = authorize(request, authorization)
        if computers.is_revoked(device_id):
            raise HTTPException(status_code=403, detail="this computer was revoked")
        try:
            result = await computers.dispatch(device_id, {"type": "resume"}, timeout_ms=10_000)
        except LookupError:
            raise HTTPException(status_code=503, detail="that computer is not connected") from None
        except TimeoutError:
            raise HTTPException(status_code=504, detail="the computer did not answer in time") from None
        if result.get("error") or result.get("exit_code", 0) != 0:
            raise HTTPException(status_code=409,
                                detail=str(result.get("error") or "the computer refused to resume"))
        runtime.audit.emit("local_computer.resume", device_id=caller, method="local_computer",
                           path=f"/v1/local-computers/{device_id}/resume", outcome="resumed")
        return {"resumed": True}

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

    @router.get("/skill")
    async def skill_status(request: Request,
                           authorization: str | None = Header(default=None)) -> dict:
        """Where the bot instructions are, and whether they are current — read-only.

        Settings → Computer shows one row from this. It is a separate route from the install because
        asking must never write to the host.
        """
        authorize(request, authorization)
        return skill_report()

    @router.post("/skill")
    async def install_skill(request: Request,
                            authorization: Optional[str] = Header(default=None)) -> dict:
        """Re-write the Mac skill into the bots' skills dirs, on demand.

        A bridge start already does this, but an owner who just installed Hermey should not have to
        restart a service — and after an upgrade this is the cheap way to pick up new instructions.
        """
        caller = authorize(request, authorization)
        result = install_agent_skills()
        runtime.audit.emit("local_computer.skill", device_id=caller, method="local_computer",
                           path="/v1/local-computers/skill",
                           outcome="installed" if result.get("installed") else "refused")
        return result

    @router.delete("/{device_id}")
    async def revoke_computer(device_id: str, request: Request,
                              authorization: str | None = Header(default=None)) -> dict:
        caller = authorize(request, authorization)
        was_connected = await computers.revoke(device_id)
        runtime.audit.emit("local_computer.revoke", device_id=caller, method="local_computer",
                           path=f"/v1/local-computers/{device_id}", outcome="revoked")
        return {"revoked": device_id, "was_connected": was_connected}

    @router.post("/{device_id}/enable")
    async def enable_computer(device_id: str, request: Request,
                              authorization: str | None = Header(default=None)) -> dict:
        """Undo a revoke. The Mac calls this when its own computer-use switch goes back on.

        Same per-call ticket as the revoke beside it, so only the paired device can ask for its
        own access back — and the owner still has to turn the switch on, on the Mac itself.
        """
        caller = authorize(request, authorization)
        was_revoked = computers.allow(device_id)
        runtime.audit.emit("local_computer.allow", device_id=caller, method="local_computer",
                           path=f"/v1/local-computers/{device_id}/enable",
                           outcome="allowed" if was_revoked else "already allowed")
        return {"allowed": device_id, "was_revoked": was_revoked}

    return router


async def _refuse(websocket: WebSocket, code: int) -> None:
    """Complete the handshake, then close with a status the client can actually read.

    Closing a websocket *before* `accept()` makes the server answer the upgrade with a bare HTTP
    403. URLSession reports that as "a bad response from the server" (-1011) — indistinguishable
    from a network fault — so a revoked Mac retried forever and the app could not say what was
    wrong. Accepting first costs one empty socket and delivers 4401/4403 to the client's close
    handler, where the reason lives.
    """
    await websocket.accept()
    await websocket.close(code=code)


async def local_computer_socket(websocket: WebSocket, runtime, computers: LocalComputers) -> None:
    """One authenticated Mac, one long-lived socket. The credential is minted per connection."""
    ticket = websocket.query_params.get("ticket") or websocket.headers.get("authorization", "")[7:]
    # A handshake rejected before accept() reaches the client as a bare HTTP error, which URLSession
    # reports as "a bad response from the server" (-1011) — with no hint of which check failed. The
    # bridge logged nothing at all on this path, so a Mac stuck on "Reconnecting" was
    # indistinguishable from a Mac that was never dialling. Each branch says which one it is; the
    # ticket value itself is never recorded.
    if not ticket:
        runtime.audit.emit("local_computer.rejected", device_id="unknown", method="socket",
                           path="/v1/local-computers/ws", outcome="no ticket")
        await _refuse(websocket, 4401)
        return
    device_id = runtime.tickets.redeem(ticket)
    if not device_id:
        # Unknown, expired (30 s), or already redeemed — tickets are single use, so a second dial
        # with the same one lands here.
        runtime.audit.emit("local_computer.rejected", device_id="unknown", method="socket",
                           path="/v1/local-computers/ws", outcome="ticket not redeemable")
        await _refuse(websocket, 4401)
        return
    if not runtime.registry.is_active(device_id):
        runtime.audit.emit("local_computer.rejected", device_id=device_id, method="socket",
                           path="/v1/local-computers/ws", outcome="device not active")
        await _refuse(websocket, 4401)
        return
    if computers.is_revoked(device_id):
        runtime.audit.emit("local_computer.rejected", device_id=device_id, method="socket",
                           path="/v1/local-computers/ws", outcome="revoked")
        await _refuse(websocket, 4403)
        return

    await websocket.accept()
    name = ""
    reader: asyncio.Task | None = None
    try:
        hello = await asyncio.wait_for(websocket.receive_json(), timeout=10)
        if hello.get("type") != "hello":
            raise ValueError("expected hello")
        name = str(hello.get("name") or "Mac")[0:80]
        computer = await computers.register(device_id, name, websocket)
        runtime.audit.emit("local_computer.connected", device_id=device_id, method="socket",
                           path="/v1/local-computers/ws", outcome="connected")
        last_seen = time.monotonic()
        inbox: asyncio.Queue = asyncio.Queue()

        async def read_frames() -> None:
            """Read continuously, so the main loop can time out without cancelling a receive.

            Nothing here closes the socket: closing belongs to the loop that owns the receive side,
            which is the only place Starlette allows it.
            """
            try:
                while True:
                    inbox.put_nowait(await websocket.receive_json())
            except Exception:  # noqa: BLE001 - a dead peer is a message, not a crash
                inbox.put_nowait(None)

        reader = asyncio.create_task(read_frames())
        while True:
            try:
                message = await asyncio.wait_for(inbox.get(), timeout=PING_INTERVAL_SECONDS)
            except asyncio.TimeoutError:
                # Idle: either the Mac has gone away, or it is simply quiet. Only unanswered pings
                # decide that. The bridge used to answer the Mac's pings and never send one, so a Mac
                # that slept mid-connection stayed registered and every caller hung on a socket that
                # could not answer — the 504s after a sleep.
                if time.monotonic() - last_seen > STALE_AFTER_SECONDS:
                    runtime.audit.emit("local_computer.timeout", device_id=device_id,
                                       method="socket", path="/v1/local-computers/ws",
                                       outcome="stale")
                    # Stop reading first: a parked `receive` would be cancelled by the close anyway,
                    # and cancelling it here is the difference between a leaked task and a clean exit.
                    # The client may still observe 1006 rather than 1001 — uvicorn aborts the handshake
                    # when the receive side is being torn down — which is why the test asserts that the
                    # link ends and the Mac is unregistered, not the exact close code.
                    if reader is not None:
                        reader.cancel()
                        reader = None
                    await websocket.close(code=1001)
                    return
                current = computers.computers.get(device_id)
                if current is None:
                    return
                async with current.send_lock:
                    await websocket.send_json({"type": "ping"})
                continue
            if message is None:
                return
            last_seen = time.monotonic()
            if not isinstance(message, dict):
                continue
            if message.get("type") == "ping":
                # URLSessionWebSocketTask has a request timeout: an idle socket can die after ~60 s
                # even while a build is running. Answer the Mac's heartbeat so inbound traffic keeps
                # the task alive. The send lock is shared with command dispatch.
                current = computers.computers.get(device_id)
                if current:
                    computers.touch(device_id)
                    async with current.send_lock:
                        await websocket.send_json({"type": "pong"})
                continue
            if message.get("type") == "pong":
                # Liveness only. The loop's own clock already moved, but the value the listing
                # reports has to move too — an answering Mac that reads as minutes old is a dead Mac
                # to whatever is watching it.
                computers.touch(device_id)
                continue
            computers.on_message(device_id, message)
    except (WebSocketDisconnect, ValueError, TimeoutError, asyncio.TimeoutError):
        pass
    except Exception:  # noqa: BLE001 (one bad frame must not take the bridge down)
        log.exception("local computer socket failed for %s", device_id)
    finally:
        if reader is not None:
            reader.cancel()
        computers.unregister(device_id, websocket)
        if name:
            runtime.audit.emit("local_computer.disconnected", device_id=device_id,
                               method="socket", path="/v1/local-computers/ws", outcome="closed")
