"""The soul a new bot starts from.

A profile's ``SOUL.md`` is where its instructions live, and the app can already rewrite one in place
(`bot_admin` / `profiles.configure`). What was missing is the *starting* text: every new bot began
from whatever Hermes ships, so the owner re-typed the same paragraph each time (asked for
2026-11-15).

The default lives on the **host**, not in either app, for the same reason bot categories do: a bot
created on the phone and one created on the Mac must begin with the same instructions.

Routes:

    GET /v1/bot-defaults        -> {"soul": {text, chars, present, updated_at}, "built_in": "…"}
    PUT /v1/bot-defaults/soul   {"text": "..."} -> the same document

An empty `text` **removes** the override and hands the job back to Hermes's own default — that is the
reset, and it is deliberately the same call as setting one, so a device does not need a second verb.

`built_in` is not this host's opinion: it is the text a profile starts from when no override exists,
read from the Hermes install the bridge is running against. When it cannot be read the field is
``null`` and the app says "Hermes's default" rather than inventing a paragraph.
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from . import paths
from .device_auth import require_device

#: Beside the bridge database, with the categories and the transfer record.
FILENAME = "default-soul.txt"

#: A soul is instructions, not a corpus. 64 KB is already far more than one bot needs to be itself,
#: and past it the editor in the settings screen stops being a place a person can read.
MAX_SOUL_CHARS = 64_000


class SoulWrite(BaseModel):
    text: str


def _path(runtime) -> Path:
    return Path(runtime.config.db_path).parent / FILENAME


def _document(path: Path) -> dict[str, Any]:
    document: dict[str, Any] = {"text": "", "chars": 0, "present": False, "updated_at": None}
    if not path.is_file() or path.is_symlink():
        return document
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
        stamp = path.stat().st_mtime
    except OSError as error:
        document["error"] = f"unreadable: {error.strerror or 'unknown error'}"
        return document
    document.update(text=text, chars=len(text), present=True,
                    updated_at=datetime.fromtimestamp(stamp, tz=timezone.utc).isoformat())
    return document


def built_in_soul() -> str | None:
    """What Hermes itself puts in a new profile's SOUL.md.

    Read from the running install rather than copied into this file: a paragraph of the vendor's
    wording that drifts out of date here is worse than no paragraph at all.
    """
    try:
        from hermes.profiles import DEFAULT_SOUL  # type: ignore[import-not-found]
    except Exception:
        return None
    return DEFAULT_SOUL if isinstance(DEFAULT_SOUL, str) and DEFAULT_SOUL.strip() else None


def create_bot_defaults_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1", tags=["bot-defaults"])

    def payload() -> dict[str, Any]:
        return {"soul": _document(_path(runtime)), "built_in": built_in_soul()}

    @router.get("/bot-defaults")
    def read_defaults(authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        return payload()

    @router.put("/bot-defaults/soul")
    def write_soul(body: SoulWrite,
                   authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        if len(body.text) > MAX_SOUL_CHARS:
            raise HTTPException(status_code=422,
                                detail=f"a soul is at most {MAX_SOUL_CHARS} characters")
        path = _path(runtime)
        # Empty text is the reset: remove the file, and a new bot starts from Hermes's own default
        # again. Nothing else is written, so there is no half-cleared state to explain.
        if not body.text.strip():
            path.unlink(missing_ok=True)
            return payload()
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(path.suffix + ".tmp")
        temp.write_text(body.text, encoding="utf-8")
        temp.replace(path)
        return payload()

    return router
