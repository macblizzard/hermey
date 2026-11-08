"""Bot lifecycle: disabling a bot and deleting one.

Why the dashboard API and not the CLI: this process runs under ``ProtectSystem=strict`` with the
install tree read-only, so the `hermes` launcher cannot even take its own lock file there. The
dashboard the gateway already serves on loopback *is* Hermes' management surface, runs unsandboxed,
and knows the parts a naive ``rmtree`` would miss — the tombstone that stops a served profile being
relisted, the multiplexer notification that releases its handles, the wrapper alias, the identity
settlement. Nothing here reimplements that; it asks the process that owns it.

Why the disabled marker lives beside the bridge's database: "disabled" is a delivery decision, not
a profile edit. Keeping it in our own state means the sandbox never has to be widened to let this
process write into every bot's home.

Contract::

    POST /v1/bots/{profile}/purge   -> {"profile": ..., "deleted": true, "archive": "..."}
    POST /v1/bots/{profile}/state   -> {"profile": ..., "enabled": bool, "paused_jobs": [...]}
    GET  /v1/bots/disabled          -> {"disabled": [...]}

All three are device-authenticated like the rest of ``/v1``. Deleting keeps a tar of the profile
first: "delete" is irreversible by design, and a mis-tap should not be.
"""
from __future__ import annotations

import json
import os
import re
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from .device_auth import require_device

#: A profile name is a directory name and an alias; the CLI enforces the same shape.
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

#: The install's own home. Removing it would leave the host without the profile the gateway serves.
PROTECTED = frozenset({"default"})

ARCHIVE_DIR = Path("/var/lib/hermes-bridge/deleted-bots")

#: Where "this bot is off" is recorded: beside the bridge's database, not inside the bot's home.
STATE_FILE = Path("/var/lib/hermes-bridge/disabled-bots.json")

DASHBOARD_URL = os.environ.get("HERMES_BRIDGE_DASHBOARD_URL", "http://127.0.0.1:9120")

REQUEST_TIMEOUT = 120


class EnabledChange(BaseModel):
    enabled: bool


def _profiles_root() -> Path:
    home = Path.home() / ".hermes" / "profiles"
    return home if home.is_dir() else Path.home() / ".hermes" / "profiles"


def _profile_dir(profile: str) -> Path:
    if not PROFILE_RE.match(profile):
        raise HTTPException(status_code=422, detail="invalid profile name")
    path = _profiles_root() / profile
    if not path.is_dir():
        raise HTTPException(status_code=404, detail="no such bot")
    return path


def _dashboard(method: str, path: str) -> tuple[int, Any]:
    """One call to the loopback dashboard, with the token it was started with."""
    token = os.environ.get("HERMES_DASHBOARD_SESSION_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="dashboard token is not configured")
    request = urllib.request.Request(f"{DASHBOARD_URL}{path}", method=method,
                                     headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            body = response.read()
            return response.status, json.loads(body) if body.strip() else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:300]
        raise HTTPException(status_code=502, detail=f"dashboard refused: {detail}") from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise HTTPException(status_code=503, detail=f"dashboard unreachable: {error}") from error


def _cron_jobs(profile: str) -> list[dict]:
    _status, body = _dashboard("GET", f"/api/cron/jobs?profile={profile}")
    return [job for job in (body or []) if isinstance(job, dict) and job.get("id")]


def _read_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return {}


def _write_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2, sort_keys=True))


def disabled_profiles() -> set[str]:
    """Profiles the owner turned off — a peer's message must not be the way around that."""
    return {name for name, entry in _read_state().items() if entry.get("enabled") is False}


def create_bot_admin_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1/bots", tags=["bots-admin"])

    def authenticate(authorization) -> str:
        return require_device(runtime, authorization)

    @router.get("/disabled")
    def list_disabled(authorization: str | None = Header(default=None)) -> dict:
        """Which bots are off, so a list refresh does not ask one bot at a time."""
        authenticate(authorization)
        return {"disabled": sorted(disabled_profiles())}

    @router.post("/{profile}/purge")
    def purge_bot(profile: str, authorization: str | None = Header(default=None)) -> dict:
        """Delete a bot's profile, archiving its bytes first."""
        caller = authenticate(authorization)
        if profile in PROTECTED:
            raise HTTPException(status_code=403, detail="this bot cannot be deleted")
        directory = _profile_dir(profile)

        # The archive is a mistake-catcher, so it has to succeed before the point of no return.
        ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        archive = ARCHIVE_DIR / f"{profile}-{stamp}.tar.gz"
        try:
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(directory, arcname=profile)
        except (OSError, tarfile.TarError) as error:
            # Refuse rather than delete what we could not copy: an archive that silently failed is
            # indistinguishable from no archive, and the delete that follows is irreversible.
            raise HTTPException(status_code=500, detail=f"archive failed: {error}") from error

        _dashboard("DELETE", f"/api/profiles/{profile}")
        if directory.exists():
            raise HTTPException(status_code=500,
                                detail="the host reported success but the profile remains")

        state = _read_state()
        state.pop(profile, None)
        _write_state(state)

        runtime.audit.emit("bots.purge", device_id=caller, method="bots.purge",
                           path=f"/v1/bots/{profile}/purge",
                           nbytes=archive.stat().st_size if archive.exists() else 0, outcome="ok")
        return {"profile": profile, "deleted": True, "archive": str(archive)}

    @router.post("/{profile}/state")
    def set_enabled(profile: str, body: EnabledChange,
                    authorization: str | None = Header(default=None)) -> dict:
        """Disable = pause this bot's schedules; enable = resume the ones we paused."""
        caller = authenticate(authorization)
        _profile_dir(profile)
        state = _read_state()
        entry = state.get(profile, {})

        if body.enabled:
            resumed: list[str] = []
            for job_id in entry.get("paused_jobs", []):
                _dashboard("POST", f"/api/cron/jobs/{job_id}/resume?profile={profile}")
                resumed.append(str(job_id))
            state.pop(profile, None)
            outcome = {"profile": profile, "enabled": True, "resumed_jobs": resumed}
        else:
            # Only the jobs that were running: resuming later must not wake a job the owner paused.
            running = [str(job["id"]) for job in _cron_jobs(profile) if not job.get("paused")]
            paused: list[str] = []
            for job_id in running:
                _dashboard("POST", f"/api/cron/jobs/{job_id}/pause?profile={profile}")
                paused.append(job_id)
            state[profile] = {"enabled": False, "disabled_at": time.time(), "paused_jobs": paused}
            outcome = {"profile": profile, "enabled": False, "paused_jobs": paused}

        _write_state(state)
        runtime.audit.emit("bots.state", device_id=caller,
                           method="bots.state",
                           path=f"/v1/bots/{profile}/state",
                           nbytes=0,
                           outcome="enabled" if body.enabled else "disabled")
        return outcome

    return router
