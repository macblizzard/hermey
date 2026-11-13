"""Paired-device-only shared bot faces.

Mount with ``app.include_router(create_bot_icons_router(runtime))``. Each HTTP
request consumes a fresh /v1/token ws_ticket in its Authorization bearer header;
never reuse the ticket intended for a websocket. All paired devices share this
host's settings. Only opaque gallery IDs, not images or paths, are stored.

A face is a **shape** and a **colour**, stored separately, because they are separate choices: a
person who likes the beacon's antenna should not have to give up the colour it is drawn in to keep
it. The ten original portraits were ten drawings with a colour baked into each one, so ``LEGACY``
names the colour each of them already wore — a row that only has an ``icon`` reads back as that
pair, and no bot's face moves when a host is upgraded.
"""
from __future__ import annotations

from typing import Literal, Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from .device_auth import require_device

Icon = Literal['ember', 'nova', 'cobalt', 'orbit', 'moss', 'dusk', 'beacon', 'pixel', 'rover', 'prism']
Color = Literal['orange', 'amber', 'lime', 'mint', 'teal', 'cyan', 'blue', 'indigo', 'purple',
                'pink', 'ruby', 'slate']

#: The colour each of the ten original portraits was drawn in.
LEGACY = {
    'ember': 'orange', 'nova': 'pink', 'cobalt': 'cyan', 'orbit': 'purple',
    'moss': 'lime', 'dusk': 'indigo', 'beacon': 'amber', 'pixel': 'mint',
    'rover': 'blue', 'prism': 'ruby',
}


class IconChange(BaseModel):
    """Both spellings of the same request.

    ``shape``/``color`` is what the current apps send; ``icon`` is what a device that has not been
    updated yet sends, and it is read as its legacy pair. Sending none of them clears the face.
    """
    shape: Icon | None = None
    color: Color | None = None
    icon: Icon | None = None

    def face(self) -> tuple[Icon | None, Color | None]:
        if self.shape is not None and self.color is not None:
            return self.shape, self.color
        if self.icon is not None:
            return self.icon, LEGACY[self.icon]
        return None, None


def create_bot_icons_router(runtime) -> APIRouter:
    router = APIRouter(prefix='/v1/bot-icons', tags=['bot-icons'])
    with runtime.registry._lock, runtime.registry._connect() as conn:
        conn.execute('CREATE TABLE IF NOT EXISTS bot_icons '
                     '(bot_id TEXT PRIMARY KEY, icon TEXT, shape TEXT, color TEXT)')
        columns = {row[1] for row in conn.execute('PRAGMA table_info(bot_icons)').fetchall()}
        # A host upgraded from the icon-only schema: the columns are added and the old ids are read
        # back through LEGACY, so no row is rewritten and no face moves.
        if 'shape' not in columns:
            conn.execute('ALTER TABLE bot_icons ADD COLUMN shape TEXT')
        if 'color' not in columns:
            conn.execute('ALTER TABLE bot_icons ADD COLUMN color TEXT')
        conn.commit()

    def authenticate(authorization) -> str:
        return require_device(runtime, authorization)

    @router.get('')
    def list_icons(authorization: Optional[str] = Header(default=None)) -> dict:
        authenticate(authorization)
        with runtime.registry._connect() as conn:
            rows = conn.execute('SELECT bot_id, icon, shape, color FROM bot_icons ORDER BY bot_id').fetchall()
        faces = {}
        legacy = {}
        for row in rows:
            shape = row['shape'] or row['icon']
            color = row['color'] or (LEGACY.get(shape) if shape else None)
            if shape and color:
                faces[row['bot_id']] = {'shape': shape, 'color': color}
            if row['icon']:
                # Devices that have not been updated read this map and know nothing about `faces`:
                # keeping it means an old phone shows the bot's original face, not a stock one.
                legacy[row['bot_id']] = row['icon']
        return {'faces': faces, 'icons': legacy}

    @router.put('/{bot_id}')
    def set_icon(bot_id: str, body: IconChange,
                 authorization: Optional[str] = Header(default=None)) -> dict:
        authenticate(authorization)
        if not bot_id.strip() or len(bot_id) > 256:
            raise HTTPException(status_code=422, detail='invalid bot id')
        # Half a pair is a malformed request, not a request to clear the face: a client that sends
        # only a shape would otherwise wipe a choice it never meant to touch.
        if (body.shape is None) != (body.color is None) and body.icon is None:
            raise HTTPException(status_code=422, detail='shape and color go together')
        shape, color = body.face()
        with runtime.registry._lock, runtime.registry._connect() as conn:
            if shape is None or color is None:
                conn.execute('DELETE FROM bot_icons WHERE bot_id = ?', (bot_id,))
            else:
                conn.execute(
                    'INSERT INTO bot_icons (bot_id, icon, shape, color) VALUES (?, ?, ?, ?) '
                    'ON CONFLICT(bot_id) DO UPDATE SET icon = excluded.icon, '
                    'shape = excluded.shape, color = excluded.color',
                    (bot_id, shape, shape, color))
            conn.commit()
        return {'bot_id': bot_id, 'face': {'shape': shape, 'color': color} if shape else None}

    return router
