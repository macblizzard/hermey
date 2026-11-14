"""What a bot has remembered about the owner and about itself.

Hermes keeps a profile's long-term memory in two markdown files beside its config:

    <profile>/memories/MEMORY.md   the agent's own notes (environment, conventions, lessons)
    <profile>/memories/USER.md     who the owner is, and what they prefer

They are injected into every turn of that profile, which makes them the one part of a bot's
behaviour a person cannot see anywhere in the apps — the transcript shows what it *said*, never what
it is carrying into the next turn. This route hands them to a paired device read-only:

    GET /v1/bots/<profile>/memory -> {"memory": {...}, "user": {...}}

Read-only on purpose. These files are maintained by the agent's own memory tool, append-vs-replace
has rules the app does not model, and a text editor in a viewer is the wrong place to break them.

Neither file is required. A profile that has never remembered anything answers with two empty
documents rather than a 404 — "nothing remembered yet" is a real answer, and a screen that shows an
error for it would send the owner looking for a fault that is not there.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException

from . import paths
from .device_auth import require_device

#: A profile name is a directory name; the CLI enforces the same shape.
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

#: The two documents, in the order the sheet shows them.
DOCUMENTS = (("memory", "MEMORY.md", "What it noted for itself"),
             ("user", "USER.md", "What it knows about you"))

#: Refuse to hand over something that is not a memory file any more: a runaway agent can write
#: megabytes into a file that is replayed into every turn, and a phone should not be asked to render
#: it. The cap is generous — a full budget is a few thousand characters.
MAX_DOCUMENT_BYTES = 256 * 1024


def _profile_dir(profile: str) -> Path:
    if not PROFILE_RE.match(profile):
        raise HTTPException(status_code=422, detail="invalid profile name")
    directory = paths.profiles_root() / profile
    if not directory.is_dir():
        raise HTTPException(status_code=404, detail="no such bot")
    return directory


def _document(path: Path, label: str) -> dict[str, Any]:
    """One memory file as the sheet draws it: the text, its size, and where it lives.

    A missing file is an empty document. An unreadable one is *reported* rather than silently
    blanked, because "the file is there and I cannot read it" and "there is nothing in it" are
    different facts and only one of them needs the owner to do something.
    """
    document: dict[str, Any] = {"name": path.name, "label": label, "text": "", "chars": 0}
    if not path.is_file():
        document["present"] = False
        return document
    # A symlink is refused rather than followed, for the reason `workspace.py` refuses one: the agent
    # can write inside its own profile, so a link named `MEMORY.md` must not be able to hand a device
    # any host file it likes.
    if path.is_symlink():
        document["present"] = False
        document["error"] = "this is a symlink, not a memory file"
        return document
    document["present"] = True
    try:
        size = path.stat().st_size
        if size > MAX_DOCUMENT_BYTES:
            document["error"] = f"larger than the {MAX_DOCUMENT_BYTES // 1024} KB a phone will draw"
            return document
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        document["error"] = f"unreadable: {error.strerror or 'unknown error'}"
        return document
    document["text"] = text
    document["chars"] = len(text)
    return document


def create_bot_memory_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1/bots", tags=["bots-memory"])

    @router.get("/{profile}/memory")
    def read_memory(profile: str, authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        directory = _profile_dir(profile)
        memories = directory / "memories"
        payload = {key: _document(memories / name, label) for key, name, label in DOCUMENTS}
        return {"profile": profile, **payload}

    return router
