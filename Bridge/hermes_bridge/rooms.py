"""Group chats: Hermes' hosted rooms, reachable from a paired phone or Mac.

Hermes already has the hard part — a hosted "Discussion room" with a server-owned, monotonic event
log and a driver that dispatches a user's message to the members it names. This module does not
re-invent any of it. It gives the apps a small HTTP surface over `groups.*`, because those methods
live on the gateway's websocket and a client that is *reading* a room wants a request it can retry
rather than a socket it must keep open.

Two shapes matter:

* A room's transcript is a **log of events**, not a list of messages. `message.user` is the owner
  speaking; `message.member` is a bot answering, with its own `discussion_event_id` naming the user
  event it answers; `turn.settled` / `turn.cancelled` say which members ran and which did not.
  The apps render the two message kinds and ignore the bookkeeping — but they ignore it here, in
  the bridge, so a client cannot mistake a turn marker for something somebody said.
* `groups.send` needs an `event_id` from the caller in this build (without one the gateway answers
  `invalid_params`), so the bridge mints one per request and lets the app retry safely: the same
  text twice in a second is two messages, but a retried *request* is one, because the id is reused
  only when the caller supplies it.

Contract::

    GET  /v1/rooms                        -> {"rooms": [{room_id, name, members[], updated_at, latest_seq}]}
    POST /v1/rooms  {name, members[]}     -> {"room": {...}}
    GET  /v1/rooms/{room_id}/log?since=N  -> {"events": [{seq, kind, actor, text, at}], "latest_seq": N}
    POST /v1/rooms/{room_id}/send {text}  -> {"event": {...}}

Every route is device-authenticated like the rest of ``/v1``; the gateway call is made on this
host over loopback with the token the gateway was started with.
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
import os
import urllib.parse
import re
import time
import uuid
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from .attachment_validation import MAX_ATTACHMENT_BYTES
from .device_auth import require_device
from . import paths
from .config import is_loopback_host

log = logging.getLogger("hermes_bridge.rooms")

#: Hermes' own identifier rule (`gateway/hosted_rooms_common.py::IDENTIFIER_RE`).
ROOM_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

#: A Discussion roster is 2–6 local profiles; anything else the gateway refuses, so it is refused
#: here with a sentence instead of a JSON-RPC error the app would have to decode.
MIN_MEMBERS, MAX_MEMBERS = 2, 6

#: One message, measured the way the host measures it.
MAX_TEXT_BYTES = 16_000

#: The gateway's loopback socket, and the token it was started with (see secrets.env).
#: Validated like every other upstream: a ws:// or wss:// URL off this box would ship the gateway
#: token to whoever the environment variable names.
GATEWAY_WS = os.environ.get("HERMES_BRIDGE_GATEWAY_WS", "ws://127.0.0.1:9120/api/ws")
GATEWAY_TOKEN = os.environ.get("HERMES_BRIDGE_GATEWAY_TOKEN", "")


def _validated_gateway_ws() -> str:
    parts = urllib.parse.urlsplit(GATEWAY_WS)
    if parts.scheme not in ("ws", "wss") or not is_loopback_host(parts.hostname or ""):
        raise HTTPException(status_code=500, detail="gateway socket must be loopback")
    return GATEWAY_WS

RPC_TIMEOUT = 90


class RoomMemberIn(BaseModel):
    profile: str
    handle: str | None = None
    display_name: str | None = None


class RoomCreate(BaseModel):
    name: str
    members: list[RoomMemberIn]


class RenameIn(BaseModel):
    name: str


class RoomAttachmentIn(BaseModel):
    name: str
    data_base64: str
    is_image: bool = False


class MessageIn(BaseModel):
    text: str = ""
    event_id: str | None = None
    attachments: list[RoomAttachmentIn] = []


#: Where a room's files are written. Inside the bridge's one writable path, and readable by the
#: bots' own tools because they run as root on this host — the reference in the message text is a
#: real absolute path, not a promise.
ATTACHMENT_ROOT = paths.ROOM_ATTACHMENT_ROOT
MAX_ATTACHMENTS = 4


async def _rpc(method: str, params: dict) -> dict:
    """One gateway call on a short-lived socket.

    Deliberately not pooled: a room read must not be able to hold a socket the conversation loop
    depends on, and the gateway is on loopback, so connect cost is a local handshake.
    """
    import websockets

    socket_url = _validated_gateway_ws()
    url = f"{socket_url}?token={GATEWAY_TOKEN}" if GATEWAY_TOKEN else socket_url
    try:
        async with websockets.connect(url, open_timeout=10, max_size=None, proxy=None) as ws:
            await asyncio.wait_for(ws.recv(), timeout=10)  # hello
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))
            while True:
                frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=RPC_TIMEOUT))
                if frame.get("id") == 1:
                    if frame.get("error"):
                        error = frame["error"]
                        detail = (error.get("data") or {}).get("detail") or error.get("message")
                        raise HTTPException(status_code=502,
                                            detail=f"{method} refused: {str(detail)[:240]}")
                    return frame.get("result") or {}
    except HTTPException:
        raise
    except (OSError, asyncio.TimeoutError):
        # Exception text here can contain the dial URL, which contains the token.
        log.warning("rooms rpc %s failed against %s", method, GATEWAY_WS.split("?")[0])
        raise HTTPException(status_code=503, detail="gateway unavailable") from None


def _member_payload(member: RoomMemberIn) -> dict:
    profile = member.profile.strip()
    if not PROFILE_RE.match(profile):
        raise HTTPException(status_code=422, detail=f"invalid bot name: {member.profile!r}")
    handle = (member.handle or profile).strip()[:64]
    payload = {"member_id": profile, "profile": profile, "handle": handle}
    if member.display_name and member.display_name.strip():
        payload["display_name"] = member.display_name.strip()[:64]
    return payload


def _store_attachments(room_id: str, items: list[RoomAttachmentIn]) -> list[tuple[str, Path]]:
    """Write the picked files beside the bridge's database and return `(name, path)` pairs.

    A room's messages are plain text on the host, so a file cannot travel as a file: it travels as
    a path the bots can open. That is honest about what happened — the agent reads the file from
    disk, and the transcript shows where it is.
    """
    if not items:
        return []
    if len(items) > MAX_ATTACHMENTS:
        raise HTTPException(status_code=413, detail=f"at most {MAX_ATTACHMENTS} files per message")
    folder = ATTACHMENT_ROOT / room_id
    folder.mkdir(parents=True, exist_ok=True)
    written: list[tuple[str, Path]] = []
    for item in items:
        try:
            payload = base64.b64decode(item.data_base64, validate=True)
        except (ValueError, binascii.Error) as error:
            raise HTTPException(status_code=422, detail="attachment is not valid base64") from error
        if not payload:
            raise HTTPException(status_code=422, detail="attachment is empty")
        if len(payload) > MAX_ATTACHMENT_BYTES:
            raise HTTPException(status_code=413, detail="attachment is too large")
        safe = re.sub(r"[^A-Za-z0-9._-]+", "-", item.name).strip("-") or "file"
        target = folder / f"{uuid.uuid4().hex[:8]}-{safe}"
        target.write_bytes(payload)
        written.append((item.name, target))
    return written


def _actor_label(actor: dict) -> str:
    """Who spoke, in one word the app can render: `you`, a bot's profile, or the host."""
    kind = actor.get("kind")
    if kind == "user":
        return "you"
    if kind == "member":
        return str(actor.get("profile") or actor.get("id") or "bot")
    return str(actor.get("id") or kind or "host")


def _event_view(event: dict) -> dict:
    """One log row reduced to what a chat window draws.

    `turn.*` and `room.*` rows are dropped: they are the driver's bookkeeping, and a transcript
    that showed "ops turn cancelled" would read like something Ops said.
    """
    payload = event.get("payload") or {}
    kind = event.get("kind")
    text = ""
    if kind in ("message.user", "message.member"):
        text = str(payload.get("text") or "")
    actor = event.get("actor") or {}
    return {
        "seq": event.get("seq"),
        "event_id": event.get("event_id"),
        "kind": kind,
        "actor": {"kind": actor.get("kind"), "id": actor.get("id"),
                  "profile": actor.get("profile"), "label": _actor_label(actor)},
        "text": text,
        "in_reply_to": payload.get("discussion_event_id"),
        "at": event.get("created_at"),
        "spoken": kind in ("message.user", "message.member") and bool(text.strip()),
    }



def _last_spoken(room: dict) -> dict:
    """Who spoke last in a room, and when — the two things a list row needs.

    Read from the room's own log rather than from `updated_at`, because a turn marker updates the
    room without anybody having said anything; a row that said "delta" for a cancelled turn would be
    lying about who spoke.
    """
    room_id = room.get("room_id")
    latest = room.get("latest_seq") or 0
    if not room_id or not latest:
        return {}
    try:
        result = asyncio.run(_rpc("groups.log", {"room_id": room_id,
                                                 "since_seq": max(0, int(latest) - 8),
                                                 "limit": 20}))
    except HTTPException:
        return {}
    spoken = [e for e in result.get("events") or []
              if e.get("kind") in ("message.user", "message.member")
              and str((e.get("payload") or {}).get("text") or "").strip()]
    if not spoken:
        return {}
    last = spoken[-1]
    actor = last.get("actor") or {}
    return {
        "last_speaker": _actor_label(actor),
        "last_from_owner": actor.get("kind") == "user",
        "last_text": str((last.get("payload") or {}).get("text") or ""),
        "last_at": last.get("created_at"),
    }


def create_rooms_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1/rooms", tags=["rooms"])

    def authenticate(authorization) -> str:
        return require_device(runtime, authorization)

    @router.get("")
    def list_rooms(authorization: str | None = Header(default=None)) -> dict:
        caller = authenticate(authorization)
        result = asyncio.run(_rpc("groups.list", {"limit": 50}))
        rooms = []
        for room in result.get("rooms") or []:
            entry = {
                "room_id": room.get("room_id"),
                "name": room.get("name") or room.get("room_id"),
                "members": [{"profile": m.get("profile"), "handle": m.get("handle"),
                             "display_name": m.get("display_name") or m.get("profile")}
                            for m in room.get("members") or []],
                "updated_at": room.get("updated_at"),
                "latest_seq": room.get("latest_seq"),
                "disbanded_at": room.get("disbanded_at"),
            }
            entry.update(_last_spoken(room))
            rooms.append(entry)
        runtime.audit.emit("rooms.list", device_id=caller, method="rooms.list",
                           path="/v1/rooms", nbytes=0, outcome="ok")
        return {"rooms": rooms}

    @router.post("")
    def create_room(body: RoomCreate, authorization: str | None = Header(default=None)) -> dict:
        caller = authenticate(authorization)
        if not (MIN_MEMBERS <= len(body.members) <= MAX_MEMBERS):
            raise HTTPException(status_code=422,
                                detail=f"a group chat has {MIN_MEMBERS}–{MAX_MEMBERS} bots")
        name = body.name.strip() or "Group chat"
        if len(name) > 80:
            raise HTTPException(status_code=422, detail="name is too long")
        seen: set[str] = set()
        members = []
        for member in body.members:
            payload = _member_payload(member)
            if payload["profile"] in seen:
                raise HTTPException(status_code=422, detail="a bot is in the list twice")
            seen.add(payload["profile"])
            members.append(payload)

        # The room id is derived from the name and made unique by a suffix, so a second "Morning
        # sync" does not collide with the first: `groups.create` is idempotent on room_id, and a
        # collision would silently reopen the older room.
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:40] or "room"
        room_id = f"{slug}-{uuid.uuid4().hex[:8]}"
        result = asyncio.run(_rpc("groups.create", {"room_id": room_id, "name": name,
                                                    "members": members}))
        room = result.get("room") or {}
        runtime.audit.emit("rooms.create", device_id=caller, method="rooms.create",
                           path="/v1/rooms", nbytes=len(room_id), outcome="ok")
        return {"room": {"room_id": room.get("room_id", room_id),
                         "name": room.get("name", name),
                         "members": [{"profile": m["profile"], "handle": m["handle"],
                                      "display_name": m.get("display_name") or m["profile"]}
                                     for m in members]}}

    @router.get("/{room_id}/log")
    def room_log(room_id: str, since_seq: int | None = None,
                 authorization: str | None = Header(default=None)) -> dict:
        authenticate(authorization)
        if not ROOM_ID_RE.match(room_id):
            raise HTTPException(status_code=422, detail="invalid room id")
        params: dict[str, Any] = {"room_id": room_id, "limit": 200}
        if since_seq:
            params["since_seq"] = int(since_seq)
        result = asyncio.run(_rpc("groups.log", params))
        events = [_event_view(e) for e in result.get("events") or []]
        return {"events": [e for e in events if e["spoken"] or e["kind"] == "message.user"],
                "latest_seq": result.get("latest_seq") or result.get("cursor") or 0}

    @router.post("/{room_id}/send")
    def send(room_id: str, body: MessageIn, authorization: str | None = Header(default=None)) -> dict:
        caller = authenticate(authorization)
        if not ROOM_ID_RE.match(room_id):
            raise HTTPException(status_code=422, detail="invalid room id")
        text = body.text
        files = _store_attachments(room_id, body.attachments)
        if not text.strip() and not files:
            raise HTTPException(status_code=422, detail="text is required")
        if files:
            listing = "\n".join(f"- {name}: {path}" for name, path in files)
            text = (text.strip() + "\n\n" if text.strip() else "") + "📎 Attached files:\n" + listing
        if len(text.encode("utf-8")) > MAX_TEXT_BYTES:
            raise HTTPException(status_code=413, detail="text is too long")
        event_id = (body.event_id or "").strip() or f"app-{uuid.uuid4().hex}"
        result = asyncio.run(_rpc("groups.send", {
            "room_id": room_id,
            "event_id": event_id,
            "payload": {"thread_id": "main", "text": text.strip()},
        }))
        runtime.audit.emit("rooms.send", device_id=caller, method="rooms.send",
                           path=f"/v1/rooms/{room_id}/send", nbytes=len(text.encode()), outcome="ok")
        return {"event": _event_view(result.get("event") or {}),
                "event_id": result.get("client_event_id") or event_id,
                "at": time.time()}

    @router.post("/{room_id}/rename")
    def rename(room_id: str, body: RenameIn, authorization: str | None = Header(default=None)) -> dict:
        """Rename a room on the host.

        `groups.rename` is the host's own verb, so the name lives where the room lives: every
        device, every member's view, and the log's own metadata agree.
        """
        caller = authenticate(authorization)
        if not ROOM_ID_RE.match(room_id):
            raise HTTPException(status_code=422, detail="invalid room id")
        name = body.name.strip()
        if not name:
            raise HTTPException(status_code=422, detail="a name is required")
        if len(name) > 80:
            raise HTTPException(status_code=422, detail="name is too long")
        # `groups.rename` writes an event like `groups.send` does, and the gateway demands an
        # `event_id` for it in this build — without one it answers a bare `invalid_params`.
        asyncio.run(_rpc("groups.rename", {"room_id": room_id, "name": name,
                                          "event_id": f"rename-{uuid.uuid4().hex}"}))
        runtime.audit.emit("rooms.rename", device_id=caller, method="rooms.rename",
                           path=f"/v1/rooms/{room_id}/rename", nbytes=len(name), outcome="ok")
        return {"room_id": room_id, "name": name}

    @router.post("/{room_id}/disband")
    def disband(room_id: str, authorization: str | None = Header(default=None)) -> dict:
        """Remove a group chat for good.

        A room is host state, so removal is `groups.disband` — the log stays on the host (auditable,
        and the transcript a member already read is still explainable) but the room leaves every
        list. Nothing here can un-disband, which is why the app asks before calling.
        """
        caller = authenticate(authorization)
        if not ROOM_ID_RE.match(room_id):
            raise HTTPException(status_code=422, detail="invalid room id")
        asyncio.run(_rpc("groups.disband", {"room_id": room_id}))
        runtime.audit.emit("rooms.disband", device_id=caller, method="rooms.disband",
                           path=f"/v1/rooms/{room_id}/disband", nbytes=0, outcome="ok")
        return {"room_id": room_id, "disbanded": True}

    return router
