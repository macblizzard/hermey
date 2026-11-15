"""The record of one bot speaking to another, so the apps can draw it as a person.

A message between bots lands in the *target's* own conversation as a user row, because that is the
session the app opens and the one the bot answers in. The text says who wrote it (`Assistant (cody)
→ Ops: …`), but a line of text is not a face and not a name — and the owner asked to see the
exchange the way the rest of the app draws people.

So the bridge keeps its own record of each exchange. One JSONL file beside the bridge's database,
one line per message, appended (never rewritten), and small on purpose: this is a label, not a
transcript — the words themselves live in the two bots' own conversations.

    {"from_profile": "cody", "from_label": "assistant", "to_profile": "ops",
     "session_id": "…", "text": "…", "at": 1763300000.0}

Routes (device ticket):

    GET /v1/bot-transfers?between=cody,ops&limit=100
    -> {"between": ["cody", "ops"], "entries": [ … oldest first … ]}

Reading back a *pair* is what the app's modal needs: "the conversation between these two bots",
which is every exchange in either direction, in order. The record is append-only and rotated at a
size cap, because a bridge that grows a file forever is a bridge that fills a disk.
"""
from __future__ import annotations

import json
import os
import re
import time
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Header, Query

from .device_auth import require_device

#: The same shape every other profile route accepts.
_PROFILE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")

#: Past this, the file is rotated to `.1` on the next write: a year of label-sized lines.
MAX_BYTES = 4 * 1024 * 1024

#: The modal shows a conversation, not an archive.
DEFAULT_LIMIT = 100
MAX_LIMIT = 400


def _path(runtime) -> Path:
    return Path(runtime.config.db_path).parent / "bot-transfers.jsonl"


def _rotate(path: Path) -> None:
    try:
        if path.is_file() and path.stat().st_size > MAX_BYTES:
            path.replace(path.with_suffix(".jsonl.1"))
    except OSError:
        # A rotation that fails is not a reason to drop the record we are holding.
        pass


def record(runtime, *, from_profile: Optional[str], from_label: str, to_profile: str,
           session_id: Optional[str], text: str, at: Optional[float] = None) -> None:
    """One line, appended. Never raises: a label that could not be written must not fail the send."""
    path = _path(runtime)
    entry = {
        "from_profile": from_profile,
        "from_label": from_label,
        "to_profile": to_profile,
        "session_id": session_id,
        "text": text[:2000],
        "at": at if at is not None else time.time(),
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        _rotate(path)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass


def entries(runtime, first: str, second: str, limit: int = DEFAULT_LIMIT) -> list[dict]:
    """Every exchange between two bots, either direction, oldest first."""
    path = _path(runtime)
    if not path.is_file():
        return []
    found: list[dict] = []
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                pair = {str(entry.get("from_profile") or ""), str(entry.get("to_profile") or "")}
                if {first, second} <= pair:
                    found.append(entry)
    except OSError:
        return []
    found.sort(key=lambda item: float(item.get("at") or 0.0))
    return found[-limit:]


def create_bot_transfers_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1", tags=["bot-transfers"])

    @router.get("/bot-transfers")
    def list_transfers(between: str = Query(default=""),
                       limit: int = Query(default=DEFAULT_LIMIT),
                       authorization: Optional[str] = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        names = [part.strip() for part in between.split(",") if part.strip()]
        if len(names) != 2 or not all(_PROFILE.match(name) for name in names):
            return {"between": names, "entries": []}
        first, second = names
        capped = max(1, min(limit, MAX_LIMIT))
        return {"between": [first, second], "entries": entries(runtime, first, second, capped)}

    return router
