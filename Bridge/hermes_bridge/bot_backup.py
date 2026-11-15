"""A bot's *config* as one JSON file — the thing you keep to rebuild a roster.

Asked for 2026-11-15: "custom backup which saves all bot infos like bot name, description, memory,
soul, routines as json files, should include all existing bots". Deliberately **config only**: no
conversations. The point is standing a fresh Hermes install up with the same bots in it, and a
transcript dump would make the file enormous while restoring nothing you cannot re-ask a bot for.

What one bot looks like in the export::

    {"profile": "cody", "name": "Cody", "description": "Lead Developer…",
     "soul": "…", "memory": {"memory": "…", "user": "…"}, "notes": "…",
     "categories": ["sec-mw0thzic-h9tz0"],
     "routines": [{"id": "fbc2fb0f324d", "name": "hermey-nightly-audit",
                   "schedule": {...}, "prompt": "…", "enabled": true}]}

Every document is read from the bot's own directory, which is where the agent reads it from:
``profile.yaml`` (name, description), ``SOUL.md``, ``memories/MEMORY.md``, ``memories/USER.md``,
``NOTES.md`` and ``cron/jobs.json``. Nothing is asked of the gateway, so an export works on a host
whose gateway is down — and it cannot disagree with what the bot actually reads.

Routes:

    GET  /v1/backup              -> the document above, with every bot
    POST /v1/backup/restore      <- that document; creates what is missing, writes what differs

Restore is additive on purpose: a bot that already exists keeps its description and soul unless the
backup's copy is non-empty and the file on this host is missing or empty. Overwriting a live bot's
soul from a stale backup is not something to do behind the owner's back; the app shows the diff and
this route declines to guess.
"""

from __future__ import annotations

import json
import os
import re
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from . import bot_admin, bot_categories, bot_notes, paths
from .device_auth import require_device

#: A backup that claims to be from a newer shape than this bridge understands is refused rather than
#: half-read: a restore that silently drops fields is worse than one that says it cannot.
BACKUP_VERSION = 1

#: The document names, and where each lives inside the profile directory.
SOUL_NAME = "SOUL.md"
MEMORY_FILES = (("memory", "memories/MEMORY.md"), ("user", "memories/USER.md"))
NOTES_NAME = bot_notes.NOTES_NAME

PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

#: One file has to stay openable in a text editor.
MAX_BACKUP_BYTES = 8 * 1024 * 1024


class RestoreBody(BaseModel):
    version: int | None = None
    bots: list[dict[str, Any]] = []
    categories: list[dict[str, Any]] = []


def _profile_yaml(directory: Path) -> dict[str, Any]:
    """The two fields of ``profile.yaml`` this needs, without a YAML dependency."""
    path = directory / "profile.yaml"
    if not path.is_file() or path.is_symlink():
        return {}
    fields: dict[str, Any] = {}
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            match = re.match(r"^(name|description|description_auto):\s*(.+?)\s*$", line)
            if not match:
                continue
            value = match.group(2).strip().strip("\"'")
            fields[match.group(1)] = value if value not in ("", "null", "~") else None
    except OSError:
        return {}
    return fields


def _read(directory: Path, relative: str) -> str:
    """One document, or empty. A symlink is refused, not followed: the agent can write inside its own
    profile, so a link named ``SOUL.md`` must not be able to hand a backup any host file it likes."""
    path = directory / relative
    if not path.is_file() or path.is_symlink():
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _routines(directory: Path) -> list[dict[str, Any]]:
    """The bot's scheduled jobs, as the scheduler keeps them."""
    path = directory / "cron" / "jobs.json"
    if not path.is_file() or path.is_symlink():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return []
    jobs = data.get("jobs") if isinstance(data, dict) else None
    if not isinstance(jobs, list):
        return []
    rows: list[dict[str, Any]] = []
    for job in jobs:
        if not isinstance(job, dict):
            continue
        rows.append({key: job.get(key) for key in
                     ("id", "name", "prompt", "skills", "schedule", "enabled", "deliver")
                     if key in job})
    return rows


def export_backup(runtime) -> dict[str, Any]:
    """Every bot's config, plus the roster's categories, in one document."""
    root = paths.profiles_root()
    categories = bot_categories.load(runtime)
    assignments = categories.get("assignments", {})
    bots: list[dict[str, Any]] = []
    for directory in sorted(root.iterdir() if root.is_dir() else []):
        if not directory.is_dir() or not PROFILE_RE.match(directory.name):
            continue
        fields = _profile_yaml(directory)
        bots.append({
            "profile": directory.name,
            "name": fields.get("name") or directory.name,
            "description": fields.get("description"),
            "soul": _read(directory, SOUL_NAME),
            "memory": {key: _read(directory, relative) for key, relative in MEMORY_FILES},
            "notes": _read(directory, NOTES_NAME),
            "categories": [assignments[directory.name]] if directory.name in assignments else [],
            "routines": _routines(directory),
        })
    return {
        "version": BACKUP_VERSION,
        "kind": "hermey-bot-backup",
        "exported_at": datetime.now(tz=timezone.utc).isoformat(),
        "host": getattr(runtime.config, "host_name", None) or os.uname().nodename,
        "bots": bots,
        "categories": [{"id": c.get("id"), "name": c.get("name")}
                       for c in categories.get("categories", [])],
    }


def _write(directory: Path, relative: str, text: str) -> None:
    path = directory / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(text, encoding="utf-8")
    temp.replace(path)


def _create_profile(profile: str, description: str | None, soul: str) -> str:
    """Make a bot that is not on this host yet, by writing the directory the CLI reads.

    Not through the dashboard: its create call is not one this bridge can make on the owner's behalf
    (the token in the dashboard header is full authority, and a restore is a file-shaped operation).
    A profile directory *is* the bot — the gateway lists profiles off disk — so this is the same thing
    the CLI does, minus the parts a backup does not carry.
    """
    directory = paths.profiles_root() / profile
    directory.mkdir(parents=True, exist_ok=True)
    if description:
        _write(directory, "profile.yaml", f"description: {description}\ndescription_auto: false\n")
    if soul:
        _write(directory, SOUL_NAME, soul)
    return "files"


def _restore_routines(directory: Path, routines: list[dict[str, Any]]) -> tuple[int, int]:
    """Put back the jobs this host does not have. Returns (added, kept).

    Written into ``cron/jobs.json`` beside the ones already there, keyed by id: a backup restored
    twice must not double a bot's schedule, and a job the owner has since edited is left alone.
    """
    if not routines:
        return 0, 0
    path = directory / "cron" / "jobs.json"
    data: dict[str, Any] = {"jobs": []}
    if path.is_file() and not path.is_symlink():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8", errors="replace"))
            if isinstance(loaded, dict) and isinstance(loaded.get("jobs"), list):
                data = loaded
        except (OSError, ValueError):
            pass
    known = {str(job.get("id")) for job in data["jobs"] if isinstance(job, dict)}
    added = kept = 0
    for routine in routines:
        job_id = str(routine.get("id") or "")
        if job_id and job_id in known:
            kept += 1
            continue
        data["jobs"].append(routine)
        added += 1
    if added:
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(path.suffix + ".tmp")
        temp.write_text(json.dumps(data, indent=2), encoding="utf-8")
        temp.replace(path)
    return added, kept


def restore_backup(runtime, document: dict[str, Any]) -> dict[str, Any]:
    """Create what the backup has and this host does not. Additive: nothing live is overwritten."""
    version = document.get("version")
    if version is not None and int(version) > BACKUP_VERSION:
        raise HTTPException(status_code=409,
                            detail=f"this backup is version {version}; this bridge reads {BACKUP_VERSION}")
    bots = document.get("bots") or []
    if not isinstance(bots, list):
        raise HTTPException(status_code=422, detail="bots must be a list")
    root = paths.profiles_root()
    created: list[dict[str, Any]] = []
    updated: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    routines_added = 0
    restart_required = False

    for entry in bots:
        if not isinstance(entry, dict):
            skipped.append({"profile": None, "reason": "not an object"})
            continue
        profile = str(entry.get("profile") or "").strip()
        if not PROFILE_RE.match(profile):
            skipped.append({"profile": profile, "reason": "invalid profile name"})
            continue
        directory = root / profile
        existed = directory.is_dir()
        try:
            if not existed:
                how = _create_profile(profile, entry.get("description"),
                                      str(entry.get("soul") or ""))
                created.append({"profile": profile, "by": how})
        except Exception as error:  # a refusal per bot, not for the whole file
            skipped.append({"profile": profile, "reason": f"could not create: {error}"})
            continue

        # Documents: written only where this host has nothing. A live bot's own words are its own.
        wrote: list[str] = []
        for relative, text in ((SOUL_NAME, entry.get("soul")),
                               (MEMORY_FILES[0][1], (entry.get("memory") or {}).get("memory")),
                               (MEMORY_FILES[1][1], (entry.get("memory") or {}).get("user")),
                               (NOTES_NAME, entry.get("notes"))):
            if not isinstance(text, str) or not text.strip():
                continue
            if _read(directory, relative).strip():
                continue
            _write(directory, relative, text)
            wrote.append(relative)
        if wrote and existed:
            updated.append({"profile": profile, "wrote": wrote})

        added, _kept = _restore_routines(directory, entry.get("routines") or [])
        if added:
            routines_added += added
            restart_required = True

        wanted = [str(c) for c in (entry.get("categories") or []) if c]
        if wanted:
            try:
                _assign(runtime, profile, wanted[0])
            except Exception:
                skipped.append({"profile": profile,
                                "reason": f"category {wanted[0]} not restored"})

    # Categories themselves, by name: an id from another host means nothing here.
    for category in document.get("categories") or []:
        name = str((category or {}).get("name") or "").strip()
        if not name:
            continue
        try:
            _ensure_category(runtime, name)
        except Exception:
            pass

    return {
        "created": created,
        "updated": updated,
        "skipped": skipped,
        "routines_added": routines_added,
        "restart_required": restart_required,
        "restored_at": datetime.now(tz=timezone.utc).isoformat(),
    }


def _ensure_category(runtime, name: str) -> str:
    """A category by name, created when this host does not have it. Ids are host-local, so a backup's
    ids mean nothing here — the name is the identity a person recognises."""
    data = bot_categories.load(runtime)
    for category in data["categories"]:
        if str(category.get("name", "")).casefold() == name.casefold():
            return str(category.get("id", ""))
    category = {"id": uuid.uuid4().hex[:12], "name": name, "created_at": time.time()}
    data["categories"].append(category)
    bot_categories.save(runtime, data)
    return category["id"]


def _assign(runtime, profile: str, category_id: str) -> None:
    data = bot_categories.load(runtime)
    data["assignments"][profile] = category_id
    bot_categories.save(runtime, data)


def create_backup_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1", tags=["backup"])

    @router.get("/backup")
    def download(authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        document = export_backup(runtime)
        size = len(json.dumps(document, indent=2).encode("utf-8"))
        if size > MAX_BACKUP_BYTES:
            raise HTTPException(status_code=413,
                                detail=f"this roster is {size} bytes; the app reads files up to "
                                       f"{MAX_BACKUP_BYTES}")
        return document

    @router.post("/backup/restore")
    def restore(body: RestoreBody,
                authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        return restore_backup(runtime, body.model_dump())

    return router
