"""Paired-device-only shared bot icon preferences.

Mount with ``app.include_router(create_bot_icons_router(runtime))``. Each HTTP
request consumes a fresh /v1/token ws_ticket in its Authorization bearer header;
never reuse the ticket intended for a websocket. All paired devices share this
host's settings. Only opaque gallery IDs, not images or paths, are stored.
"""
from __future__ import annotations

from typing import Literal, Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from .device_auth import require_device

Icon = Literal['ember', 'nova', 'cobalt', 'orbit', 'moss', 'dusk', 'beacon', 'pixel', 'rover', 'prism']


class IconChange(BaseModel):
    icon: Icon | None


def create_bot_icons_router(runtime) -> APIRouter:
    router = APIRouter(prefix='/v1/bot-icons', tags=['bot-icons'])
    with runtime.registry._lock, runtime.registry._connect() as conn:
        conn.execute('CREATE TABLE IF NOT EXISTS bot_icons (bot_id TEXT PRIMARY KEY, icon TEXT NOT NULL)')
        conn.commit()

    def authenticate(authorization) -> str:
        return require_device(runtime, authorization)

    @router.get('')
    def list_icons(authorization: Optional[str] = Header(default=None)) -> dict:
        authenticate(authorization)
        with runtime.registry._connect() as conn:
            rows = conn.execute('SELECT bot_id, icon FROM bot_icons ORDER BY bot_id').fetchall()
        return {'icons': {row['bot_id']: row['icon'] for row in rows}}

    @router.put('/{bot_id}')
    def set_icon(bot_id: str, body: IconChange,
                 authorization: Optional[str] = Header(default=None)) -> dict:
        authenticate(authorization)
        if not bot_id.strip() or len(bot_id) > 256:
            raise HTTPException(status_code=422, detail='invalid bot id')
        with runtime.registry._lock, runtime.registry._connect() as conn:
            if body.icon is None:
                conn.execute('DELETE FROM bot_icons WHERE bot_id = ?', (bot_id,))
            else:
                conn.execute('INSERT INTO bot_icons (bot_id, icon) VALUES (?, ?) '
                             'ON CONFLICT(bot_id) DO UPDATE SET icon=excluded.icon', (bot_id, body.icon))
            conn.commit()
        return {'bot_id': bot_id, 'icon': body.icon}

    return router
