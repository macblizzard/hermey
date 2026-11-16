"""Paired-device-only shared bot faces.

Mount with ``app.include_router(create_bot_icons_router(runtime))``. Each HTTP
request consumes a fresh /v1/token ws_ticket in its Authorization bearer header;
never reuse the ticket intended for a websocket. All paired devices share this
host's settings. Only opaque gallery IDs, not images or paths, are stored.

A face is now **one string**, ``#RRGGBB::shape_N`` — what the web app stores in
``bots.color`` (``packages/contracts/src/bot-avatar.ts``), and what makes a bot look the same on
every surface that draws it. The pair of fields this route used to take (``shape`` + ``color``) is
still accepted, and a row written that way still reads back exactly as it did: it is the *stored*
value the client migrates, because only the client knows which shipped body an old index lands on.

Three spellings arrive, and the newest wins:

* ``avatar`` — ``#RRGGBB::shape_N`` (or ``#RRGGBB``), written by the current app,
* ``shape`` + ``color`` — the pair, read back as ``shape=<name>``, ``color=<name>`` for an old app,
* ``icon`` — the original single id, read back as the colour it was drawn in.
"""
from __future__ import annotations

import re
from typing import Literal, Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from .device_auth import require_device

#: Sixteen silhouettes: the ten original ids (kept so every stored face still reads) and six that
#: only exist as shapes. Nothing new is written in this vocabulary — `avatar` is.
Icon = Literal['ember', 'nova', 'cobalt', 'orbit', 'moss', 'dusk', 'beacon', 'pixel', 'rover',
              'prism', 'lump', 'mushroom', 'blob', 'capsule', 'droplet', 'scallop']
Color = Literal['orange', 'amber', 'lime', 'mint', 'teal', 'cyan', 'blue', 'indigo', 'purple',
                'pink', 'ruby', 'slate']

#: The colour each of the ten original portraits was drawn in.
LEGACY = {
    'ember': 'orange', 'nova': 'pink', 'cobalt': 'cyan', 'orbit': 'purple',
    'moss': 'lime', 'dusk': 'indigo', 'beacon': 'amber', 'pixel': 'mint',
    'rover': 'blue', 'prism': 'ruby',
    # Nothing can have stored these yet; they are here so the map stays total.
    'lump': 'slate', 'mushroom': 'teal', 'blob': 'indigo',
    'capsule': 'blue', 'droplet': 'cyan', 'scallop': 'pink',
}

#: ``#RGB``, ``#RRGGBB``, optionally with ``::shape_N``. Deliberately strict: a value nothing can
#: draw is worse than a refused request, and the client writes the canonical form.
AVATAR = re.compile(r'^#[0-9a-fA-F]{3}(?:[0-9a-fA-F]{3})?(?:::shape_[0-9]+)?$')


def split_avatar(value: str) -> tuple[str, Optional[str]]:
    """``#A97EFE::shape_3`` -> ``('#A97EFE', 'shape_3')``.

    The body comes back with its ``shape_`` prefix: it is stored in the same column an old build
    wrote body *names* to, and a bare ``3`` there would read as a name rather than as an index.
    """
    head, separator, tail = value.partition('::shape_')
    return head, (f'shape_{tail}' if separator else None)


class IconChange(BaseModel):
    """Every spelling of the same request.

    ``avatar`` is what the current apps send; ``shape``/``color`` is what the app before this one
    sent, and ``icon`` is what the app before *that* one sent. Sending none of them clears the face.
    """
    avatar: Optional[str] = None
    shape: Optional[Icon] = None
    color: Optional[Color] = None
    icon: Optional[Icon] = None

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
                     '(bot_id TEXT PRIMARY KEY, icon TEXT, shape TEXT, color TEXT, avatar TEXT)')
        columns = {row[1] for row in conn.execute('PRAGMA table_info(bot_icons)').fetchall()}
        # A host upgraded from an icon-only schema: the columns are added and the old ids are read
        # back through LEGACY, so no row is rewritten and no face moves.
        if 'shape' not in columns:
            conn.execute('ALTER TABLE bot_icons ADD COLUMN shape TEXT')
        if 'color' not in columns:
            conn.execute('ALTER TABLE bot_icons ADD COLUMN color TEXT')
        if 'avatar' not in columns:
            conn.execute('ALTER TABLE bot_icons ADD COLUMN avatar TEXT')
        conn.commit()

    def authenticate(authorization) -> str:
        return require_device(runtime, authorization)

    @router.get('')
    def list_icons(authorization: Optional[str] = Header(default=None)) -> dict:
        authenticate(authorization)
        with runtime.registry._connect() as conn:
            rows = conn.execute(
                'SELECT bot_id, icon, shape, color, avatar FROM bot_icons ORDER BY bot_id'
            ).fetchall()
        faces = {}
        legacy = {}
        for row in rows:
            if row['avatar']:
                # One string, plus the two fields a device that has not been updated still reads.
                # It will not know the new body names and passes that bot over; it does not fail
                # the whole map, which is the reason both keys are always present.
                colour, shape = split_avatar(row['avatar'])
                faces[row['bot_id']] = {'avatar': row['avatar'],
                                        'shape': shape or '',
                                        'color': colour}
            else:
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
        if (body.shape is None) != (body.color is None) and body.icon is None and body.avatar is None:
            raise HTTPException(status_code=422, detail='shape and color go together')

        if body.avatar is not None:
            if not AVATAR.match(body.avatar):
                raise HTTPException(status_code=422,
                                    detail='avatar must be #RRGGBB or #RRGGBB::shape_N')
            colour, shape = split_avatar(body.avatar)
            with runtime.registry._lock, runtime.registry._connect() as conn:
                conn.execute(
                    'INSERT INTO bot_icons (bot_id, icon, shape, color, avatar) VALUES (?, ?, ?, ?, ?) '
                    'ON CONFLICT(bot_id) DO UPDATE SET icon = excluded.icon, '
                    'shape = excluded.shape, color = excluded.color, avatar = excluded.avatar',
                    (bot_id, None, shape or '', colour, body.avatar))
                conn.commit()
            return {'bot_id': bot_id, 'face': {'avatar': body.avatar}}

        shape, color = body.face()
        with runtime.registry._lock, runtime.registry._connect() as conn:
            if shape is None or color is None:
                conn.execute('DELETE FROM bot_icons WHERE bot_id = ?', (bot_id,))
            else:
                conn.execute(
                    'INSERT INTO bot_icons (bot_id, icon, shape, color, avatar) VALUES (?, ?, ?, ?, ?) '
                    'ON CONFLICT(bot_id) DO UPDATE SET icon = excluded.icon, '
                    'shape = excluded.shape, color = excluded.color, avatar = excluded.avatar',
                    (bot_id, shape, shape, color, None))
            conn.commit()
        return {'bot_id': bot_id, 'face': {'shape': shape, 'color': color} if shape else None}

    return router
