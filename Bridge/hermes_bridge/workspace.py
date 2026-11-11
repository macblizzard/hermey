"""The bot's workspace: the documents it prepared, and enough bytes to read them.

Nothing on the host keeps a register of "files this bot made". The agent writes where it writes, and
until now the only way to see the result was to ssh in. This gives a paired device the two things a
viewer needs:

    GET /v1/workspace/<profile>                 -> {"files": [...], "roots": [...]}
    GET /v1/workspace/<profile>/file?path=<rel> -> the bytes, with a content type and byte ranges

Two places are searched, both inside the profile:

* ``workspace/`` — where a bot is told its files belong. Created on first write by the bot itself; a
  missing directory is an empty list, not an error.
* ``attachments/`` — what the user sent that bot. Uploads persist there already, so "the deck I gave
  it" and "the deck it wrote" sit in one list.

Everything is resolved and required to stay inside those two roots, and a symlink is refused rather
than followed: the agent can write into its own workspace, so a link named ``report.pdf`` must not be
able to hand a device any host file it likes.
"""
from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Optional

from fastapi import APIRouter, Header, HTTPException, Request, Response

from .device_auth import require_device

#: A viewer is not a file manager: enough to find the document, not the whole disk.
MAX_FILES = 400
MAX_DEPTH = 4
#: One document over a phone's wrist-band connection; anything larger is refused with 413 so the
#: client can say "too big to preview" instead of hanging.
MAX_VIEW_BYTES = 64 * 1024 * 1024

TYPE_BY_EXTENSION = {
    'pdf': 'application/pdf',
    'txt': 'text/plain; charset=utf-8',
    'md': 'text/markdown; charset=utf-8',
    'markdown': 'text/markdown; charset=utf-8',
    'json': 'application/json',
    'csv': 'text/csv; charset=utf-8',
    'tsv': 'text/tab-separated-values; charset=utf-8',
    'log': 'text/plain; charset=utf-8',
    'yaml': 'text/yaml; charset=utf-8',
    'yml': 'text/yaml; charset=utf-8',
    'html': 'text/html; charset=utf-8',
    'xml': 'application/xml',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'svg': 'image/svg+xml',
    'zip': 'application/zip',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
}

#: What the viewer can draw itself. Everything else is offered as "open on the host".
PREVIEWABLE = {'pdf', 'txt', 'md', 'markdown', 'json', 'csv', 'tsv', 'log', 'yaml', 'yml', 'html',
               'xml', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'svg'}


def _profiles_root() -> Path:
    hermes_home = os.environ.get('HERMES_HOME') or str(Path.home() / '.hermes')
    return Path(hermes_home) / 'profiles'


def _safe_component(value: str) -> Optional[str]:
    if not value or len(value) > 255:
        return None
    if any(char in value for char in ('/', '\\', '\x00', '\n', '\r')) or value.startswith('.'):
        return None
    return value


def _kind(path: Path) -> str:
    return path.suffix.lower().lstrip('.') or 'file'


def _entry(path: Path, root: Path, source: str) -> dict:
    stat = path.stat()
    extension = _kind(path)
    return {
        'name': path.name,
        'path': str(path.relative_to(root)),
        'source': source,
        'kind': extension,
        'size': stat.st_size,
        'modified': datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat(),
        'previewable': extension in PREVIEWABLE,
    }


def _walk(root: Path, source: str, base: Optional[Path] = None, depth: int = 0) -> Iterator[dict]:
    """Recursive, bounded, and quiet about anything unreadable — a workspace is not a filesystem.

    ``base`` is the searched root the relative path is measured from; ``path`` in the payload is
    therefore always relative to ``workspace/`` or ``attachments/``, which is what the byte route
    resolves against.
    """
    base = base or root
    if depth > MAX_DEPTH or not root.is_dir():
        return
    try:
        entries = sorted(root.iterdir(), key=lambda item: item.name.lower())
    except OSError:
        return
    for item in entries:
        if item.name.startswith('.'):
            continue
        try:
            if item.is_symlink():
                continue          # never follow: the agent can write here
            if item.is_dir():
                yield from _walk(item, source, base, depth + 1)
            elif item.is_file():
                yield _entry(item, base, source)
        except OSError:
            continue


def _roots(profile_dir: Path) -> list[tuple[Path, str]]:
    return [(profile_dir / 'workspace', 'workspace'), (profile_dir / 'attachments', 'attachments')]


def _resolve_inside(profile_dir: Path, relative: str) -> tuple[Path, str]:
    if not relative or relative.startswith('/') or '\x00' in relative:
        raise HTTPException(status_code=400, detail='invalid workspace path')
    for root, source in _roots(profile_dir):
        candidate = (root / relative).resolve()
        try:
            inside = candidate.is_relative_to(root.resolve())
        except (OSError, ValueError):
            inside = False
        if not inside or not candidate.is_file():
            continue
        if (root / relative).is_symlink():
            raise HTTPException(status_code=400, detail='refusing to follow a link')
        return candidate, source
    raise HTTPException(status_code=404, detail='no such file in this workspace')


def create_workspace_router(runtime) -> APIRouter:
    router = APIRouter(prefix='/v1/workspace', tags=['workspace'])

    @router.get('/{profile}')
    def listing(profile: str, authorization: str = Header(default='')) -> dict:
        require_device(runtime, authorization)
        safe_profile = _safe_component(profile)
        if safe_profile is None:
            raise HTTPException(status_code=400, detail='invalid profile')
        profile_dir = _profiles_root() / safe_profile

        files: list[dict] = []
        for root, source in _roots(profile_dir):
            for item in _walk(root, source):
                files.append(item)
                if len(files) >= MAX_FILES:
                    break
            if len(files) >= MAX_FILES:
                break
        files.sort(key=lambda item: item['modified'], reverse=True)
        return {
            'profile': safe_profile,
            'files': files,
            'truncated': len(files) >= MAX_FILES,
        }

    @router.get('/{profile}/file')
    def file_bytes(profile: str, path: str, request: Request,
                   authorization: str = Header(default='')) -> Response:
        require_device(runtime, authorization)
        safe_profile = _safe_component(profile)
        if safe_profile is None:
            raise HTTPException(status_code=400, detail='invalid profile')
        resolved, _source = _resolve_inside(_profiles_root() / safe_profile, path)
        size = resolved.stat().st_size
        if size > MAX_VIEW_BYTES:
            raise HTTPException(status_code=413, detail='file too large to view')

        media_type = TYPE_BY_EXTENSION.get(_kind(resolved), 'application/octet-stream')
        data = resolved.read_bytes()
        # Ranges matter for a PDF: the phone's viewer asks for pages, not the whole document.
        range_header = request.headers.get('range', '')
        if range_header.startswith('bytes='):
            try:
                spec = range_header[6:].split(',')[0].strip()
                first, _, last = spec.partition('-')
                start = int(first) if first else 0
                end = int(last) if last else size - 1
                end = min(end, size - 1)
                if start <= end:
                    chunk = data[start:end + 1]
                    return Response(
                        content=chunk, status_code=206, media_type=media_type,
                        headers={
                            'Content-Range': f'bytes {start}-{end}/{size}',
                            'Accept-Ranges': 'bytes',
                            'Content-Length': str(len(chunk)),
                        })
            except ValueError:
                pass
        return Response(content=data, media_type=media_type,
                        headers={'Accept-Ranges': 'bytes', 'Content-Length': str(size)})

    return router
