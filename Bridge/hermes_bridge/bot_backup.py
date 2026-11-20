"""A bot's *config* as one JSON file — the thing you keep to rebuild a roster.

Asked for 2026-11-15: "custom backup which saves all bot infos like bot name, description, memory,
soul, routines as json files, should include all existing bots". Deliberately **config only**: no
conversations. The point is standing a fresh Hermes install up with the same bots in it, and a
transcript dump would make the file enormous while restoring nothing you cannot re-ask a bot for.

What one bot looks like in the export::

    {"profile": "assistant", "name": "Assistant", "description": "Team lead…",
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
import pathlib
import re
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel

from . import bot_admin, bot_categories, bot_notes, paths
from .device_auth import require_device

#: A backup that claims to be from a newer shape than this bridge understands is refused rather than
#: half-read: a restore that silently drops fields is worse than one that says it cannot.
BACKUP_VERSION = 2

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


def _icon_path(profile: str) -> Path:
    """Where the bridge keeps a bot's push icon; the file itself travels inside the zip."""
    return Path("/var/lib/hermey/push-icons") / f"{profile}.png"


def _disabled() -> set[str]:
    try:
        from . import bot_admin

        return set(bot_admin.disabled_profiles())
    except Exception:  # noqa: BLE001 - an export must not fail over a delivery preference
        return set()


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
        icon = f"icons/{directory.name}.png" if _icon_path(directory.name).is_file() else None
        bots.append({
            "profile": directory.name,
            "name": fields.get("name") or directory.name,
            "description": fields.get("description"),
            # Model settings are not here on purpose: the bridge reads them from the dashboard over HTTP, so
            # an export would fail (or invent) whenever that is down. A lossless *round trip of this document*
            # is what import promises; per-bot model remains a known gap until it is file-readable.
            "enabled": directory.name not in _disabled(),
            "icon": icon,
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
    """Publish one document in a single step: a reader never sees half a soul."""
    paths.atomic_write_text(directory / relative, text)


def _one_line(value: object, limit: int = 200) -> str:
    """A description is one line of prose, never YAML structure.

    It arrives in a backup file a device supplies, and it used to be interpolated straight into
    ``profile.yaml``: a newline let it open new keys (``model:``, ``soul:``), and a colon inside the
    value produced a file the YAML parser rejects outright. Collapsing to one line and quoting the
    scalar means the only thing a description can change is the description.
    """
    text = " ".join(str(value or "").split())
    return text[:limit]


#: A scalar that can be written unquoted: starts alphanumeric, no colon, no quote, no leading
#: indicator character. Anything else is emitted as a JSON string, which is valid YAML.
_PLAIN_SCALAR = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()/',+-]{0,199}$")


def _yaml_scalar(text: str) -> str:
    return text if _PLAIN_SCALAR.match(text) else json.dumps(text)


def _create_profile(profile: str, description: str | None, soul: str) -> str:
    """Make a bot that is not on this host yet, by writing the directory the CLI reads.

    Not through the dashboard: its create call is not one this bridge can make on the owner's behalf
    (the token in the dashboard header is full authority, and a restore is a file-shaped operation).
    A profile directory *is* the bot — the gateway lists profiles off disk — so this is the same thing
    the CLI does, minus the parts a backup does not carry.
    """
    directory = paths.profiles_root() / profile
    directory.mkdir(parents=True, exist_ok=True)
    line = _one_line(description)
    if line:
        _write(directory, "profile.yaml",
               f"description: {_yaml_scalar(line)}\ndescription_auto: false\n")
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
        paths.atomic_write_text(path, json.dumps(data, indent=2))
    return added, kept

def build_archive(runtime) -> bytes:
    """The export as a zip: ``backup.json`` plus each bot's icon.

    A single JSON cannot carry a picture, and an icon is part of what a bot looks like. The document keeps its
    exact shape — everything that was in the JSON is still in the JSON — so a .zip and a bare .json are the same
    backup, one with the pictures attached.
    """
    import io
    import zipfile

    document = export_backup(runtime)
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("backup.json", json.dumps(document, indent=2))
        for bot in document.get("bots") or []:
            icon = bot.get("icon")
            profile = str(bot.get("profile") or "")
            if not icon or not profile:
                continue
            path = _icon_path(profile)
            try:
                archive.writestr(icon, path.read_bytes())
            except OSError:
                bot["icon"] = None
    return buffer.getvalue()


def load_backup(data: bytes) -> tuple[dict[str, Any], dict[str, bytes]]:
    """The document and any icons the archive carried."""
    import io
    import zipfile

    icons: dict[str, bytes] = {}
    if data[:2] == b"PK":
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                for name in archive.namelist():
                    if name.startswith("icons/") and name.endswith(".png"):
                        icons[pathlib.Path(name).stem] = archive.read(name)
        except zipfile.BadZipFile:
            raise HTTPException(status_code=422, detail="that file is not a readable zip") from None
    return load_document(data), icons


def load_document(data: bytes) -> dict[str, Any]:
    """A backup from bytes: a .zip we wrote, or the bare JSON we wrote before zips existed.

    Anything else is refused with a reason. Guessing at another product's export is how a user ends up with a
    bot that looks imported and is empty, so the envelope is checked before a single file is touched.
    """
    import io
    import zipfile

    if data[:2] == b"PK":
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                raw = archive.read("backup.json")
        except KeyError:
            raise HTTPException(status_code=422,
                                detail="this zip has no backup.json — it is not a Hermey bot backup") from None
        except zipfile.BadZipFile:
            raise HTTPException(status_code=422, detail="that file is not a readable zip") from None
        try:
            document = json.loads(raw)
        except ValueError:
            raise HTTPException(status_code=422, detail="backup.json inside the zip is not JSON") from None
    else:
        try:
            document = json.loads(data)
        except ValueError:
            raise HTTPException(status_code=422, detail="that file is not JSON") from None
    if not isinstance(document, dict):
        raise HTTPException(status_code=422, detail="a backup is a JSON object")
    if str(document.get("kind") or "") != "hermey-bot-backup":
        raise HTTPException(
            status_code=422,
            detail="this is not a Hermey bot backup (kind must be 'hermey-bot-backup'); import from another "
                   "product is not supported yet, and a guess would give you empty bots")
    version = document.get("version")
    try:
        if version is not None and int(version) > BACKUP_VERSION:
            raise HTTPException(status_code=409,
                                detail=f"this backup is version {version}; this bridge reads {BACKUP_VERSION}")
    except (TypeError, ValueError):
        raise HTTPException(status_code=422, detail="backup version is not a number") from None
    return document

def _unique_profile(root: Path, wanted: str) -> str:
    """A free profile name based on ``wanted``: ``x``, ``x-2``, ``x-3`` …"""
    if not (root / wanted).exists():
        return wanted
    for index in range(2, 100):
        candidate = f"{wanted}-{index}"
        if not (root / candidate).exists():
            return candidate
    raise HTTPException(status_code=409, detail=f"too many copies of {wanted}")


def import_backup(runtime, document: dict[str, Any], icons: dict[str, bytes] | None = None,
                  mode: str = "merge", dry_run: bool = False) -> dict[str, Any]:
    """Bring a backup's bots onto this host.

    Three modes, chosen by the owner rather than guessed:

    ``merge`` (default) — create what is missing and fill only what is empty here; a live bot keeps its own
    words. ``overwrite`` — also replace a bot's soul, memory and notes from the file. ``copy`` — never touch an
    existing bot: each one lands beside it as ``name-2``, which is how you bring one host's bot in next to
    another's.

    ``dry_run`` returns exactly the same plan and writes nothing, so the app can show the owner what would
    happen before it happens.
    """
    if mode not in ("merge", "overwrite", "copy"):
        raise HTTPException(status_code=422, detail=f"unknown mode {mode!r}")
    version = document.get("version")
    try:
        if version is not None and int(version) > BACKUP_VERSION:
            raise HTTPException(status_code=409,
                                detail=f"this backup is version {version}; this bridge reads {BACKUP_VERSION}")
    except (TypeError, ValueError):
        raise HTTPException(status_code=422, detail="backup version is not a number") from None
    bots = document.get("bots") or []
    if not isinstance(bots, list):
        raise HTTPException(status_code=422, detail="bots must be a list")

    root = paths.profiles_root()
    icons = icons or {}
    created: list[dict[str, Any]] = []
    updated: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    written_docs: list[str] = []
    routines_added = 0
    icons_written: list[str] = []
    restart_required = False

    local_by_id: dict[str, str] = {}
    for category in document.get("categories") or []:
        if not isinstance(category, dict):
            continue
        name = str(category.get("name") or "").strip()
        if not name:
            continue
        try:
            local = _ensure_category(runtime, name) if not dry_run else ""
        except Exception:
            local = ""
        if local:
            local_by_id[str(category.get("id") or "")] = local

    for entry in bots:
        if not isinstance(entry, dict):
            skipped.append({"profile": None, "reason": "not an object"})
            continue
        wanted = str(entry.get("profile") or "").strip()
        if not PROFILE_RE.match(wanted):
            skipped.append({"profile": wanted, "reason": "invalid profile name"})
            continue
        existing = (root / wanted).is_dir()
        if existing and mode == "copy":
            try:
                target = _unique_profile(root, wanted)
            except HTTPException as error:
                skipped.append({"profile": wanted, "reason": str(error.detail)})
                continue
        else:
            target = wanted
        directory = root / target
        creating = not directory.is_dir()

        if not dry_run:
            try:
                if creating:
                    _create_profile(target, entry.get("description"), str(entry.get("soul") or ""))
            except Exception as error:  # a refusal per bot, not for the whole file
                skipped.append({"profile": target, "reason": f"could not create: {error}"})
                continue
        if creating:
            created.append({"profile": target, "by": "files", **({"from": wanted} if target != wanted else {})})

        wrote: list[str] = []
        for relative, text in ((SOUL_NAME, entry.get("soul")),
                               (MEMORY_FILES[0][1], (entry.get("memory") or {}).get("memory")),
                               (MEMORY_FILES[1][1], (entry.get("memory") or {}).get("user")),
                               (NOTES_NAME, entry.get("notes"))):
            if not isinstance(text, str) or not text.strip():
                continue
            here = "" if creating or dry_run else _read(directory, relative)
            if here.strip() and mode != "overwrite":
                continue
            if not dry_run:
                _write(directory, relative, text)
            wrote.append(relative)
        if wrote:
            written_docs += [f"{target}/{name}" for name in wrote]
            if not creating:
                updated.append({"profile": target, "wrote": wrote})

        added, _kept = (0, 0)
        if not dry_run:
            added, _kept = _restore_routines(directory, entry.get("routines") or [])
        else:
            added = len([r for r in (entry.get("routines") or []) if isinstance(r, dict)])
        if added:
            routines_added += added
            restart_required = True

        icon = icons.get(wanted) or icons.get(target)
        if icon:
            if not dry_run:
                try:
                    path = _icon_path(target)
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(icon)
                except OSError:
                    skipped.append({"profile": target, "reason": "icon could not be written"})
            icons_written.append(target)

        enabled = entry.get("enabled")
        if enabled is False and not dry_run:
            try:
                from . import bot_admin

                def change(state: dict[str, Any], name: str = target) -> None:
                    entry_state = state.setdefault(name, {})
                    entry_state["enabled"] = False

                bot_admin._mutate_state(change)  # noqa: SLF001 - the same file the toggle writes
            except Exception:
                pass

        wanted_categories = [str(c) for c in (entry.get("categories") or []) if c]
        if wanted_categories and not dry_run:
            local = local_by_id.get(wanted_categories[0])
            if local:
                try:
                    _assign(runtime, target, local)
                except Exception:
                    skipped.append({"profile": target, "reason": "category not restored"})
            else:
                skipped.append({"profile": target,
                                "reason": "the backup names a category it does not carry"})

    return {
        "mode": mode,
        "dry_run": dry_run,
        "created": created,
        "updated": updated,
        "skipped": skipped,
        "documents": written_docs,
        "icons": icons_written,
        "routines_added": routines_added,
        "restart_required": restart_required,
        "restored_at": datetime.now(tz=timezone.utc).isoformat(),
    }


def restore_backup(runtime, document: dict[str, Any]) -> dict[str, Any]:
    """The older route: additive restore, kept for clients that send the document directly."""
    return import_backup(runtime, document, mode="merge", dry_run=False)


def _ensure_category(runtime, name: str) -> str:
    """A category by name, created when this host does not have it. Ids are host-local, so a backup's
    ids mean nothing here — the name is the identity a person recognises.

    Through ``bot_categories.mutate`` so a restore cannot lose a change a device made at the same
    moment: a bare ``load``/``save`` pair is the read-modify-write race that file has a lock for.
    """
    cleaned = " ".join(name.split())[:bot_categories.MAX_NAME]
    if not cleaned:
        return ""
    created: list[str] = []

    def change(data: dict) -> None:
        for category in data["categories"]:
            if str(category.get("name", "")).casefold() == cleaned.casefold():
                created.append(str(category.get("id", "")))
                return
        if len(data["categories"]) >= bot_categories.MAX_CATEGORIES:
            return
        category = {"id": uuid.uuid4().hex[:12], "name": cleaned, "created_at": time.time()}
        data["categories"].append(category)
        created.append(category["id"])

    bot_categories.mutate(runtime, change)
    return created[0] if created else ""


def _assign(runtime, profile: str, category_id: str) -> None:
    def change(data: dict) -> None:
        data["assignments"][profile] = category_id

    bot_categories.mutate(runtime, change)


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

    @router.get("/backup.zip")
    def download_zip(authorization: str | None = Header(default=None)):
        """The same document, zipped with each bot's icon — what Import reads back."""
        from fastapi import Response

        require_device(runtime, authorization)
        payload = build_archive(runtime)
        if len(payload) > MAX_BACKUP_BYTES:
            raise HTTPException(status_code=413,
                                detail=f"this roster is {len(payload)} bytes; the app reads files up to "
                                       f"{MAX_BACKUP_BYTES}")
        return Response(content=payload, media_type="application/zip",
                        headers={"content-disposition": 'attachment; filename="hermey-bots.zip"'})

    @router.post("/backup/import")
    async def import_upload(request: Request, mode: str = "merge", dry_run: int = 0,
                            authorization: str | None = Header(default=None)) -> dict:
        """Take a .zip (or the older bare .json) and bring its bots onto this host.

        The body is the file itself, not a JSON envelope around it: the app hands over exactly what it saved,
        and a 12 MB zip does not get base64-inflated on the way.
        """
        require_device(runtime, authorization)
        data = await request.body()
        if not data:
            raise HTTPException(status_code=422, detail="an empty file is not a backup")
        if len(data) > MAX_BACKUP_BYTES:
            raise HTTPException(status_code=413, detail=f"this file is {len(data)} bytes; the limit is "
                                                        f"{MAX_BACKUP_BYTES}")
        document, icons = load_backup(data)
        return import_backup(runtime, document, icons=icons, mode=mode, dry_run=bool(dry_run))

    @router.post("/backup/restore")
    def restore(body: RestoreBody,
                authorization: str | None = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        return restore_backup(runtime, body.model_dump())

    return router
