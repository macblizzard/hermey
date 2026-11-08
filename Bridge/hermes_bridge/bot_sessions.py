"""Bridge-owned shared session pointer, one per bot profile.

The iPhone and the Mac each used to keep "which session is this bot" in local
``UserDefaults``, so opening the same bot on both minted two conversations.
This router is the single place they can agree: a small row in the registry DB
(``bot_sessions``), read on bot open and written after ``session.create``.

Contract:

* ``GET  /v1/bots/{profile}/session`` -> ``{"profile", "stored_session_id"}``
  where the value is ``null`` until a device has stored one. Unknown bots are
  not 404s -- "no conversation yet" is a normal, expected answer.
* ``PUT  /v1/bots/{profile}/session`` body ``{"stored_session_id": "<stored id>"}``
  -> the same shape with the stored value. Last write wins. There is no delete:
  an empty or malformed body is rejected with 422 and the row is untouched.

Both routes authenticate a paired device with a single-use ticket, exactly like
``/v1/devices`` and ``/v1/bot-icons``, and audit only who/what, never the value.
"""
from __future__ import annotations

import re
from typing import Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, ConfigDict

from .device_auth import require_device

#: A stored session key is ``%Y%m%d_%H%M%S_`` + six hex
#: (``tui_gateway/session_registry.py``). Accept the general shape, refuse
#: anything that could be read as a path: no slash, no backslash, no dot.
_SESSION_ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')

#: Profile names are directory names on the host; a dot is allowed but a
#: separator is not, so this can never escape a route segment.
_PROFILE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$')


class SessionPointer(BaseModel):
    # A body with anything else in it is malformed, not "close enough".
    model_config = ConfigDict(extra='forbid')

    stored_session_id: str


def _path(profile: str) -> str:
    return f'/v1/bots/{profile}/session'


def create_bot_sessions_router(runtime) -> APIRouter:
    router = APIRouter(prefix='/v1/bots', tags=['bot-sessions'])

    def authenticate(authorization: Optional[str]) -> str:
        return require_device(runtime, authorization)

    def check_profile(profile: str, *, device_id: str, method: str) -> None:
        if not _PROFILE.match(profile):
            runtime.audit.emit('session_pointer', device_id=device_id, method=method,
                               path=_path(profile), profile=profile,
                               outcome='rejected', reason='invalid_profile')
            raise HTTPException(status_code=422, detail='invalid profile')

    @router.get('/{profile}/session')
    def get_session(profile: str,
                    authorization: Optional[str] = Header(default=None)) -> dict:
        device_id = authenticate(authorization)
        check_profile(profile, device_id=device_id, method='GET')
        stored = runtime.registry.get_bot_session(profile)
        runtime.audit.emit('session_pointer', device_id=device_id, method='GET',
                           path=_path(profile), profile=profile,
                           outcome='found' if stored else 'missing')
        return {'profile': profile, 'stored_session_id': stored}

    @router.put('/{profile}/session')
    def put_session(profile: str, body: SessionPointer,
                    authorization: Optional[str] = Header(default=None)) -> dict:
        device_id = authenticate(authorization)
        check_profile(profile, device_id=device_id, method='PUT')
        value = body.stored_session_id
        if not _SESSION_ID.match(value):
            # Never a delete: an unusable value leaves the previous pointer in place.
            runtime.audit.emit('session_pointer', device_id=device_id, method='PUT',
                               path=_path(profile), profile=profile,
                               outcome='rejected', reason='invalid_session_id')
            raise HTTPException(
                status_code=422,
                detail='stored_session_id must be 1-128 chars of [A-Za-z0-9_-]',
            )
        runtime.registry.set_bot_session(profile=profile, stored_session_id=value)
        runtime.audit.emit('session_pointer', device_id=device_id, method='PUT',
                           path=_path(profile), profile=profile, outcome='stored')
        return {'profile': profile, 'stored_session_id': value}

    return router
