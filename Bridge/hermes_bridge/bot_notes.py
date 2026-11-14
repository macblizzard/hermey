"""A bot's own notes: the owner's scratch pad for what to do with *this* bot.

The description says what a bot is; the notes say what is planned for it — the next errand, the
thing to pick up next week, the questions to ask when there is time. That is a different kind of
text: the owner writes it, nobody else reads it into a turn, and it changes far more often than a
description does.

It lives at ``<profile>/NOTES.md``, inside the bot's own directory, on purpose:

* **It is created with the bot and removed with the bot.** Creating a profile creates the
  directory; deleting a profile deletes everything inside it. No second list to keep in step, and no
  way to leave a note behind pointing at a bot that is gone.
* **It is not injected into any turn.** ``SOUL.md`` and ``memories/*.md`` are read by the agent;
  this file is not on that list, so a note cannot change how the bot answers or cost tokens.
* **It is one file, so two devices editing it are editing the same thing.** The host is the only
  writer; every device reads before it writes and sends the whole text, and last write wins — which
  is what a notes field should do.

Routes:

    GET /v1/bots/<profile>/notes -> {"profile", "notes": {text, chars, present, updated_at}}
    PUT /v1/bots/<profile>/notes  {"text": "..."} -> the same document

A profile that has never had a note answers with an empty document rather than a 404: "nothing
written yet" is a real answer, and a screen that shows an error for it sends the owner looking for
a fault that is not there.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from . import paths
from .device_auth import require_device

#: A profile name is a directory name; the CLI enforces the same shape.
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

#: The file itself. Named in caps beside SOUL.md so it is obvious it is the bot's, not the owner's.
NOTES_NAME = "NOTES.md"

#: A note is prose typed by a person, not an attachment. 64 KB is a long plan, and past it the
#: textarea in the app stops being a place anyone can edit.
MAX_NOTES_CHARS = 64_000


class NotesWrite(BaseModel):
    text: str


def _profile_dir(profile: str) -> Path:
    if not PROFILE_RE.match(profile):
        raise HTTPException(status_code=422, detail="invalid profile name")
    directory = paths.profiles_root() / profile
    if not directory.is_dir():
        raise HTTPException(status_code=404, detail="no such bot")
    return directory


def _document(path: Path, profile: str) -> dict[str, Any]:
    """The note as the sheet draws it.

    A missing file is an empty note. A symlink is refused rather than followed — the agent can write
    inside its own profile, so a link named ``NOTES.md`` must not be able to hand a device any host
    file it likes (the same rule `bot_memory` and `workspace` apply).
    """
    document: dict[str, Any] = {"profile": profile, "name": NOTES_NAME, "text": "", "chars": 0,
                                "present": False, "updated_at": None}
    if not path.is_file():
        return document
    if path.is_symlink():
        document["error"] = "this is a symlink, not a notes file"
        return document
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
        stamp = path.stat().st_mtime
    except OSError as error:
        document["error"] = f"unreadable: {error.strerror or 'unknown error'}"
        return document
    document["present"] = True
    document["text"] = text
    document["chars"] = len(text)
    document["updated_at"] = datetime.fromtimestamp(stamp, tz=timezone.utc).isoformat()
    return document


def create_bot_notes_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1/bots", tags=["bots-notes"])

    @router.get("/{profile}/notes")
    def read_notes(profile: str,
                   authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        directory = _profile_dir(profile)
        return {"profile": profile, "notes": _document(directory / NOTES_NAME, profile)}

    @router.put("/{profile}/notes")
    def write_notes(profile: str, body: NotesWrite,
                    authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        directory = _profile_dir(profile)
        text = body.text
        if len(text) > MAX_NOTES_CHARS:
            raise HTTPException(status_code=413,
                                detail=f"a note is capped at {MAX_NOTES_CHARS} characters")
        path = directory / NOTES_NAME
        if path.is_symlink():
            raise HTTPException(status_code=409, detail="this is a symlink, not a notes file")
        # Written whole and then moved into place: a device that lost the wire mid-write leaves the
        # previous note intact rather than half of a new one.
        temporary = path.with_suffix(".md.writing")
        try:
            temporary.write_text(text, encoding="utf-8")
            temporary.replace(path)
        except OSError as error:
            raise HTTPException(status_code=500,
                                detail=f"could not write the note: {error.strerror or error}") from error
        return {"profile": profile, "notes": _document(path, profile)}

    return router
