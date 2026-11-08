"""One bot speaking to another bot, in the conversation the owner actually sees.

The owner asked for two things this file exists to make true:

* a message addressed to a bot must land in **that bot's own chat** — the same stored session the
  apps open, not a side session in a terminal. The first attempt used `hermes -p ops -z ...`,
  which ran ops in a *new CLI session*, so the exchange was invisible in the app while the user
  read his chat with ops and found nothing. The pointer in `bot_sessions` is the shared answer to
  "which conversation is this bot", so that is what gets resumed here;
* the exchange must be **labelled**, because the target bot's transcript renders every user row as
  if the owner typed it. `Assistant → Ops:` in front of the text tells ops, and the owner reading
  over its shoulder, who is actually talking.

Contract:

``POST /v1/bots/{profile}/message`` body ``{"text": "...", "from": "assistant"}``
    -> ``{"profile", "from", "session_id", "text", "reply", "delivered"}``

Loopback only, like ``/v1/pair/start``: this is an operator-side command (the agent on the host
running it through its shell), not something a paired phone may do — a phone can already type into
the chat itself, and a device that could impersonate another bot would be a privilege it does not
need. No ticket is minted and no device row is written.

Delivery is *queued semantics*, not a promise of a reply: the gateway answers a busy session by
steering or queuing. A timeout returns ``delivered: true, reply: null`` so the caller reports "sent,
no answer yet" rather than "failed".
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from typing import Optional

import websockets
from fastapi import APIRouter, HTTPException, Request

from .device_auth import is_local_host_request

logger = logging.getLogger("hermes_bridge.bot_message")

#: Same shape the session pointer accepts: never a path, never a separator.
_PROFILE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$')

#: A bot may name itself; anything with a newline or a colon would break the label the owner reads.
_FROM = re.compile(r'^[A-Za-z0-9 ._-]{1,40}$')

MAX_TEXT = 32_000  # a cron report can be long (the daily changelog is ~16k); clip only the absurd

#: How long to wait for the target bot's turn to finish. A bot answering with tools can take a
#: while; past this the caller is told it was delivered without an answer.
REPLY_TIMEOUT_S = 150.0


def _is_loopback(request: Request) -> bool:
    # Delegated on purpose: a proxy makes every caller look like 127.0.0.1, and this route lets the
    # caller write into a real bot conversation.
    return is_local_host_request(request)


def _labelled(sender: str, target: str, text: str) -> str:
    return f"{sender.title()} → {target.title()}: {text.strip()}"


def create_bot_message_router(runtime) -> APIRouter:
    router = APIRouter(prefix='/v1/bots', tags=['bot-message'])

    @router.post('/{profile}/message')
    async def send(profile: str, body: dict, request: Request) -> dict:
        if not _is_loopback(request):
            # Deliberately the same answer as an unknown route: an operator command is not a
            # thing to advertise to the network.
            raise HTTPException(status_code=404, detail='not found')
        if not _PROFILE.match(profile):
            raise HTTPException(status_code=422, detail='invalid profile')
        if _disabled(profile):
            # The owner turned this bot off. A peer writing into its chat would be a way to make a
            # disabled bot answer, so the route says plainly that the bot is off.
            raise HTTPException(status_code=409, detail=f'{profile} is disabled')

        text = body.get('text')
        sender = body.get('from', 'assistant')
        if not isinstance(text, str) or not text.strip():
            raise HTTPException(status_code=422, detail='text is required')
        if len(text) > MAX_TEXT:
            raise HTTPException(status_code=413, detail=f'text longer than {MAX_TEXT} characters')
        if not isinstance(sender, str) or not _FROM.match(sender):
            raise HTTPException(status_code=422, detail='invalid from')

        stored = runtime.registry.get_bot_session(profile)
        if not stored:
            raise HTTPException(
                status_code=409,
                detail=f'{profile} has no conversation yet: open it in the app once, then send',
            )

        message = _labelled(sender, profile, text)
        session_id, reply = await _deliver(runtime, stored, message, profile)
        # The audit log records who spoke to whom and whether an answer came back; the words
        # themselves are the owner's conversation, not an audit artefact.
        runtime.audit.emit(
            'bot_message',
            profile=profile,
            method=sender,
            path=f'/v1/bots/{profile}/message',
            nbytes=len(message.encode('utf-8')),
            outcome='replied' if reply is not None else 'sent',
        )
        return {
            'profile': profile,
            'from': sender,
            'session_id': session_id,
            'text': message,
            'reply': reply,
            'delivered': True,
        }

    return router


def _disabled(profile: str) -> bool:
    """A disabled bot has its schedules paused; a peer's message must not be the way around that."""
    from .bot_admin import disabled_profiles

    return profile in disabled_profiles()


async def _deliver(runtime, stored: str, message: str, profile: str) -> tuple[str, Optional[str]]:
    """Resume the stored session *within its profile*, submit, and wait for that session's completion.

    The profile is not optional and not decoration: a multiplexed gateway resolves a stored id in
    the caller's default profile unless told otherwise, and a stored id can exist in more than one
    home. Without it the message landed in a session the apps never open — the bot answered, the
    owner saw nothing.
    

    Returns ``(runtime_session_id, reply_text)``. The reply is the *assistant* text of the
    completion event, which is exactly the row the apps will render under the message.
    """
    config = runtime.config
    deadline = time.monotonic() + REPLY_TIMEOUT_S
    try:
        upstream = await websockets.connect(
            config.upstream_url(),
            open_timeout=config.connect_timeout,
            close_timeout=5,
            max_size=None,
            proxy=None,
            logger=logging.getLogger("hermes_bridge.upstream"),
        )
    except Exception:
        # No exception text: it can carry the dial URI, which carries the token.
        raise HTTPException(status_code=503, detail='gateway unavailable')

    try:
        await upstream.send(json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "client.capabilities",
            # No approvals: a bot speaking to a bot must never pick up a pending request meant
            # for the owner's device.
            "params": {"server_requests": False},
        }))
        await upstream.send(json.dumps({
            "jsonrpc": "2.0", "id": 2, "method": "session.resume",
            "params": {"session_id": stored, "profile": profile},
        }))
        runtime_id: Optional[str] = None
        while runtime_id is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise HTTPException(status_code=504, detail='gateway did not resume the session')
            frame = json.loads(await asyncio.wait_for(upstream.recv(), timeout=remaining))
            if frame.get("id") == 2:
                if "error" in frame:
                    error = frame.get("error") or {}
                    # -32001 is the gateway's "session not found"; the pointer is stale.
                    if error.get("code") == -32001:
                        raise HTTPException(
                            status_code=409,
                            detail='the stored session no longer exists; open the bot in the app',
                        )
                    raise HTTPException(status_code=502, detail='gateway refused the session')
                runtime_id = (frame.get("result") or {}).get("session_id")

        await upstream.send(json.dumps({
            "jsonrpc": "2.0", "id": 3, "method": "prompt.submit",
            "params": {"session_id": runtime_id, "profile": profile, "text": message},
        }))

        reply: Optional[str] = None
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                frame = json.loads(await asyncio.wait_for(upstream.recv(), timeout=remaining))
            except asyncio.TimeoutError:
                break
            if frame.get("id") == 3 and "error" in frame:
                raise HTTPException(status_code=502, detail='gateway refused the message')
            params = frame.get("params") if isinstance(frame.get("params"), dict) else {}
            payload = params.get("payload") if isinstance(params.get("payload"), dict) else params
            # The event name sits on `params.type` (the bridge keys `gateway.ready` off it) and, on
            # some events, again inside the payload. Read every place it may be rather than guess.
            name = params.get("type") or params.get("event") or payload.get("event") or payload.get("type")
            # The gateway nests events as {"method":"event","params":{"type":"event","payload":…}}
            # today, and the older shape put the event name at the top of `params`. Accept both;
            # only one of them is ever true.
            if name == "message.complete" and payload.get("session_id") in (None, runtime_id):
                reply = payload.get("text")
                break
        return runtime_id, reply
    finally:
        try:
            await upstream.close()
        except Exception:
            pass
