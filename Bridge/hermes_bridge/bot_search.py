"""Search inside every bot's conversation, on the host.

The bot list's search box used to filter names. What a person actually remembers is something they
said or were told — "the one where we talked about the CrowdSec rules" — so the search has to read
the transcripts, and it has to read *all* of them, because the memory of which bot said it is the
thing that failed.

Each profile keeps its own ``state.db`` with a ``messages`` table, so one query per bot is enough
and no gateway round-trip is needed. Three rules keep it cheap and honest:

* **read-only connections**, opened per profile with a short timeout: a search must never block a
  bot's own writes, and a transcript being written *now* must not make the search fail;
* **a cap per bot and a cap overall**, newest first, so one chatty bot cannot bury the rest;
* **a snippet, not the message**: ±80 characters around the match, so the answer is a *finding*
  (which bot, when, what was said) rather than a transcript dump over the wire.

Contract::

    GET /v1/search?q=crowdsec&limit=50&offset=0
    -> {"query": "crowdsec", "total": 3, "more": false,
        "results": [{"profile", "session_id", "role", "at", "snippet", "match"}]}

A query shorter than two characters is answered with an empty result rather than an error: the app
fires this as the person types, and one keystroke is not a search.
"""
from __future__ import annotations

import os
import sqlite3
from pathlib import Path
from typing import Any, Optional
from urllib.parse import quote

from fastapi import APIRouter, Header, Query

from .device_auth import require_device
from .paths import profiles_root

#: Below this, a query matches everything and costs a full scan to prove it.
MIN_QUERY = 2

#: A sentence can be long; the app draws one line per finding.
MAX_QUERY = 120

#: Per bot: enough to be useful, few enough that one busy profile cannot fill the page.
PER_BOT = 20

#: Overall page size, and its ceiling.
DEFAULT_LIMIT = 50
MAX_LIMIT = 100

#: Characters of context on each side of the match.
SNIPPET_PAD = 80


def _profiles_root() -> Path:
    """Where the bots live — the one resolver the whole bridge uses (``paths.profiles_root``).

    The copy that used to live here ignored ``HERMES_PROFILES_ROOT``, which is what the installer
    sets, so a correct install could answer an empty search against a full roster.
    """
    return profiles_root()


def _snippet(text: str, needle: str) -> tuple[str, str]:
    """The line around the first match, and the matched text as it was written."""
    flat = " ".join(text.split())
    index = flat.casefold().find(needle.casefold())
    if index < 0:
        return flat[: SNIPPET_PAD * 2], ""
    start = max(0, index - SNIPPET_PAD)
    end = min(len(flat), index + len(needle) + SNIPPET_PAD)
    body = flat[start:end]
    if start > 0:
        body = "…" + body
    if end < len(flat):
        body = body + "…"
    return body, flat[index:index + len(needle)]


def _search_one(database: Path, profile: str, needle: str) -> list[dict]:
    """This bot's newest matching messages, or nothing at all if its database is not readable."""
    uri = f"file:{quote(str(database))}?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=1.0)
    except sqlite3.Error:
        return []
    try:
        rows = conn.execute(
            "SELECT session_id, role, content, timestamp FROM messages "
            "WHERE role IN ('user', 'assistant') AND content IS NOT NULL "
            "AND content LIKE ? ORDER BY timestamp DESC, id DESC LIMIT ?",
            (f"%{needle}%", PER_BOT),
        ).fetchall()
    except sqlite3.Error:
        # A profile mid-migration, or a database this process may not read: it is not this bot's
        # turn to be in the answer, and it is not an error either.
        return []
    finally:
        conn.close()

    found: list[dict] = []
    for session_id, role, content, timestamp in rows:
        snippet, matched = _snippet(str(content), needle)
        found.append({
            "profile": profile,
            "session_id": str(session_id),
            "role": str(role),
            "at": float(timestamp or 0.0),
            "snippet": snippet,
            "match": matched,
        })
    return found


def search_all(needle: str, limit: int, offset: int) -> dict:
    """Every bot's matches, newest first, paged by `offset`."""
    root = _profiles_root()
    results: list[dict] = []
    for directory in sorted(root.iterdir()) if root.is_dir() else []:
        if not directory.is_dir():
            continue
        database = directory / "state.db"
        if not database.is_file():
            continue
        results.extend(_search_one(database, directory.name, needle))

    results.sort(key=lambda item: item["at"], reverse=True)
    total = len(results)
    page = results[offset:offset + limit]
    return {
        "query": needle,
        "total": total,
        "more": offset + limit < total,
        "results": page,
    }


def create_bot_search_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1", tags=["bots-search"])

    @router.get("/search")
    def search(q: str = Query(default=""), limit: int = Query(default=DEFAULT_LIMIT),
               offset: int = Query(default=0),
               authorization: Optional[str] = Header(default=None)) -> dict[str, Any]:
        require_device(runtime, authorization)
        needle = q.strip()
        if len(needle) < MIN_QUERY:
            return {"query": needle, "total": 0, "more": False, "results": []}
        needle = needle[:MAX_QUERY]
        return search_all(needle, max(1, min(limit, MAX_LIMIT)), max(0, offset))

    return router
