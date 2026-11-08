"""Give a paired device back a picture it once sent.

An uploaded image lives on the host's disk — the transcript only ever carries its name, inside an
``@image:/…/upload_ab12.png`` reference. That is fine for the device that uploaded it (it still has
the bytes in memory) and useless for everyone else: a reinstalled app, a reaped cache, the Mac
looking at a conversation the phone started. "The thumbnail is gone after a relaunch" is exactly
this hole.

Contract::

    GET /v1/attachments/<profile>/<name>
    -> the file's bytes, with its own content type

Names are the host's own (``upload_<random>.<ext>``); anything that is not a single path component,
or whose extension is not an image, is refused rather than resolved. A missing file is a 404, not an
empty 200 — the client falls back to a named chip and says nothing invented.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Header, HTTPException, Response

from .device_auth import require_device

#: Only what a chat bubble can draw. A reference to anything else stays a file chip.
MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024

IMAGE_TYPES = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'heic': 'image/heic',
    'heif': 'image/heif',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'tiff': 'image/tiff',
    'bmp': 'image/bmp',
}


def _profiles_root() -> Path:
    """Where the bots live, whether this process was given the install home or a profile home."""
    home = os.environ.get('HERMES_HOME')
    candidates = []
    if home:
        base = Path(home)
        candidates.extend([base / 'profiles', base.parent])
    candidates.append(Path.home() / '.hermes' / 'profiles')
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    return candidates[-1]


def _safe_component(value: str) -> Optional[str]:
    """One path component, or ``None``: no separators, no traversal, nothing hidden."""
    if not value or len(value) > 255:
        return None
    if any(char in value for char in ('/', '\\', '\x00', '\n', '\r')):
        return None
    if value in ('.', '..') or value.startswith('.'):
        return None
    return value


def create_attachment_files_router(runtime) -> APIRouter:
    router = APIRouter(prefix='/v1/attachments', tags=['attachments'])
    root = _profiles_root()

    @router.get('/{profile}/{name}')
    def attachment(profile: str, name: str,
                   authorization: str = Header(default='')) -> Response:
        # Same device ticket as every other /v1 route: an image is not public just because its
        # name is random.
        require_device(runtime, authorization)

        safe_profile = _safe_component(profile)
        safe_name = _safe_component(name)
        if safe_profile is None or safe_name is None:
            raise HTTPException(status_code=400, detail='invalid attachment path')

        extension = safe_name.rsplit('.', 1)[-1].lower() if '.' in safe_name else ''
        media_type = IMAGE_TYPES.get(extension)
        if media_type is None:
            raise HTTPException(status_code=400, detail='not an image attachment')

        candidates = [root / safe_profile / 'images' / safe_name]
        home = os.environ.get('HERMES_HOME')
        if home:
            candidates.append(Path(home) / 'images' / safe_name)
        # The name check above stops `../`, but a symlink inside `images/` with a .png name would
        # still follow straight out of the directory: anything that can write to that folder — the
        # agent itself can — could hand any host file to a paired device. Resolve, then require the
        # result to stay under the directory that was searched, and refuse the link itself.
        roots = [root.resolve()]
        if home:
            roots.append(Path(home).resolve())
        for candidate in candidates:
            try:
                if candidate.is_symlink() or not candidate.is_file():
                    continue
                resolved = candidate.resolve()
                if not any(resolved.is_relative_to(base) for base in roots):
                    continue
                size = resolved.stat().st_size
                if size > MAX_ATTACHMENT_BYTES:
                    raise HTTPException(status_code=413, detail='attachment too large')
                return Response(content=resolved.read_bytes(),
                                media_type=media_type,
                                headers={'Cache-Control': 'private, max-age=86400'})
            except HTTPException:
                raise
            except OSError:
                continue
        raise HTTPException(status_code=404, detail='attachment not found')

    return router
