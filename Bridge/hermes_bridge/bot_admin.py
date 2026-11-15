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
import logging
import os
import re
import tarfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

from fastapi import APIRouter, Header, HTTPException

from . import paths
from .config import is_loopback_host

log = logging.getLogger("hermes_bridge.bot_admin")
from pydantic import BaseModel

from .device_auth import require_device

#: A profile name is a directory name and an alias; the CLI enforces the same shape.
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

#: The install's own home. Removing it would leave the host without the profile the gateway serves.
PROTECTED = frozenset({"default"})

ARCHIVE_DIR = paths.ARCHIVE_DIR

#: Where "this bot is off" is recorded: beside the bridge's database, not inside the bot's home.
STATE_FILE = paths.DISABLED_STATE_FILE

DASHBOARD_URL = os.environ.get("HERMES_BRIDGE_DASHBOARD_URL", "http://127.0.0.1:9120")

REQUEST_TIMEOUT = 120

#: One lock for the disabled-bots file. Two devices toggling two bots read-modify-write the same
#: document; without this the second save starts from the first request's read and drops its change
#: — the same race the categories file has a lock for. Re-entrant because a mutation writes through
#: ``_write_state``, which is called from inside it.
_STATE_LOCK = threading.RLock()


class EnabledChange(BaseModel):
    enabled: bool


class RoutineStateChange(BaseModel):
    """Pause or resume one of a bot's routines.

    `paused: true` is the only way to say "stop this one"; there is deliberately no `run now` and no
    schedule edit here. A routine's text is the bot's own instructions, and this route is a switch
    beside a row, not an editor.
    """

    paused: bool


def _profiles_root() -> Path:
    return paths.profiles_root()


def _profile_dir(profile: str) -> Path:
    if not PROFILE_RE.match(profile):
        raise HTTPException(status_code=422, detail="invalid profile name")
    path = _profiles_root() / profile
    if not path.is_dir():
        raise HTTPException(status_code=404, detail="no such bot")
    return path


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """urllib re-sends the Authorization header on a redirect, including cross-host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102, ANN001
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _dashboard_url() -> str:
    """The dashboard URL, checked: plain http on loopback, or nothing.

    The token in the header is full authority over the agent, so where it is sent must not be
    something an environment variable can point off the box.
    """
    parts = urllib.parse.urlsplit(DASHBOARD_URL)
    if parts.scheme != "http" or not is_loopback_host(parts.hostname or ""):
        raise HTTPException(status_code=500, detail="dashboard url must be loopback http")
    return DASHBOARD_URL.rstrip("/")


def _dashboard(method: str, path: str) -> tuple[int, Any]:
    """One call to the loopback dashboard, with the token it was started with."""
    token = os.environ.get("HERMES_DASHBOARD_SESSION_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="dashboard token is not configured")
    request = urllib.request.Request(f"{_dashboard_url()}{path}", method=method,
                                     headers={"Authorization": f"Bearer {token}"})
    try:
        with _OPENER.open(request, timeout=REQUEST_TIMEOUT) as response:
            body = response.read()
            return response.status, json.loads(body) if body.strip() else None
    except urllib.error.HTTPError as error:
        # The body can echo the request; the device gets a fixed sentence instead.
        log.warning("dashboard refused %s %s: %s", method, path, error.code)
        raise HTTPException(status_code=502, detail="dashboard refused the request") from None
    except (urllib.error.URLError, TimeoutError):
        raise HTTPException(status_code=503, detail="dashboard unreachable") from None


def _cron_jobs(profile: str) -> list[dict]:
    _status, body = _dashboard("GET", f"/api/cron/jobs?profile={profile}")
    return [job for job in (body or []) if isinstance(job, dict) and job.get("id")]


#: A cron job id is an opaque token the dashboard accepts as a path segment.
JOB_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def _routine_row(job: dict) -> dict:
    """One of a bot's schedules, reduced to what a row on a phone can show.

    The prompt is deliberately absent, and so is every other textual field: a routine's prompt is the
    bot's own instructions (thousands of characters, often naming the owner's private setup), and a
    list of *when this bot runs* never needs to read it back. What a row needs is the name, when it
    next fires, how the last run went, and whether it is switched on.
    """
    state = job.get("state")
    # "Off" has two spellings on the host: `enabled: false`, and `state: paused` (which is what the
    # pause route sets). Reading only one of them would draw a paused routine as running.
    paused = job.get("enabled", True) is False or state == "paused"
    raw_schedule = job.get("schedule")
    schedule = raw_schedule if isinstance(raw_schedule, dict) else {}
    return {
        "id": str(job.get("id")),
        "name": str(job.get("name") or job.get("id")),
        "schedule": str(job.get("schedule_display") or schedule.get("display") or schedule.get("expr") or ""),
        "next_run_at": job.get("next_run_at"),
        "last_run_at": job.get("last_run_at"),
        "last_status": job.get("last_status"),
        "last_error": job.get("last_error"),
        "paused": paused,
        # A one-shot that already ran is not paused, and it is not going to run again either.
        "completed": state == "completed",
    }


def _read_state() -> dict:
    """The disabled markers, or an empty document when the file is absent or unreadable.

    A damaged file is copied aside before it is treated as empty. Silently reading it as "nothing is
    disabled" is the dangerous direction: every bot the owner switched off would quietly come back
    on. Keeping the bytes makes the loss visible and recoverable, the same rule the categories file
    follows.
    """
    try:
        raw = STATE_FILE.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    except OSError:
        return {}
    try:
        data = json.loads(raw)
    except ValueError:
        try:
            STATE_FILE.with_suffix(STATE_FILE.suffix + ".damaged").write_text(raw, encoding="utf-8")
        except OSError:
            pass
        log.warning("disabled-bots state was not valid JSON; kept a .damaged copy")
        return {}
    if not isinstance(data, dict):
        return {}
    return {name: entry for name, entry in data.items() if isinstance(entry, dict)}


def _write_state(state: dict) -> None:
    """Replace the whole document in one step, under the file's lock.

    In-place ``write_text`` is not atomic: a crash or a full disk mid-write leaves JSON that parses
    as nothing, which reads back as "every bot is enabled". The rename is the publish.
    """
    paths.atomic_write_text(STATE_FILE, json.dumps(state, indent=2, sort_keys=True))


def disabled_profiles() -> set[str]:
    """Profiles the owner turned off — a peer's message must not be the way around that."""
    return {name for name, entry in _read_state().items() if entry.get("enabled") is False}


def _mutate_state(change: Callable[[dict], Any]) -> Any:
    """Apply one change to the disabled-bots document, under its lock, and return what it returned.

    Read, change and write are one step for anyone else touching this file, and a change that raises
    (a refusal, an unreachable dashboard) leaves the file exactly as it was.
    """
    with _STATE_LOCK:
        state = _read_state()
        outcome = change(state)
        _write_state(state)
        return outcome


def _known_job_ids(entry: dict) -> list[str]:
    """The job ids a disable recorded, filtered to ids that are safe in a dashboard URL.

    They come back from disk, so they are caller-controllable in the sense that matters: a damaged
    or hand-edited file must not be able to reshape the loopback request this route makes.
    """
    raw = entry.get("paused_jobs")
    if not isinstance(raw, list):
        return []
    return [str(job_id) for job_id in raw if isinstance(job_id, str) and JOB_ID_RE.match(job_id)]


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

        # A deleted bot must not keep a disabled marker that a later bot with the same name inherits.
        _mutate_state(lambda state: state.pop(profile, None))

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

        def change(state: dict) -> dict:
            entry = state.get(profile, {})

            if body.enabled:
                resumed: list[str] = []
                for job_id in _known_job_ids(entry):
                    _dashboard("POST", f"/api/cron/jobs/{job_id}/resume?profile={profile}")
                    resumed.append(job_id)
                state.pop(profile, None)
                return {"profile": profile, "enabled": True, "resumed_jobs": resumed}

            # Only the jobs that were running: resuming later must not wake a job the owner paused.
            running = [str(job["id"]) for job in _cron_jobs(profile) if not job.get("paused")]
            paused: list[str] = []
            for job_id in running:
                _dashboard("POST", f"/api/cron/jobs/{job_id}/pause?profile={profile}")
                paused.append(job_id)
            state[profile] = {"enabled": False, "disabled_at": time.time(), "paused_jobs": paused}
            return {"profile": profile, "enabled": False, "paused_jobs": paused}

        # One locked read-modify-write: two devices toggling two bots must both keep their change.
        outcome = _mutate_state(change)
        runtime.audit.emit("bots.state", device_id=caller,
                           method="bots.state",
                           path=f"/v1/bots/{profile}/state",
                           nbytes=0,
                           outcome="enabled" if body.enabled else "disabled")
        return outcome

    @router.get("/{profile}/routines")
    def list_routines(profile: str,
                      authorization: str | None = Header(default=None)) -> dict:
        """This bot's schedules: name, when it next runs, how the last run went, on or off.

        The rows come from the dashboard, which owns the scheduler, so what the app shows is what
        will actually fire — not a copy of it kept here.
        """
        authenticate(authorization)
        _profile_dir(profile)
        rows = [_routine_row(job) for job in _cron_jobs(profile)]
        # Soonest first, so the row at the top is the one that happens next. A paused routine has no
        # next run; it sorts to the bottom by name rather than jumping around.
        rows.sort(key=lambda row: (row["next_run_at"] or "~", row["name"]))
        return {"routines": rows}

    @router.post("/{profile}/routines/{job_id}/state")
    def set_routine_state(profile: str, job_id: str, body: RoutineStateChange,
                          authorization: str | None = Header(default=None)) -> dict:
        """Pause one routine, or put it back on its schedule."""
        caller = authenticate(authorization)
        _profile_dir(profile)
        # The id becomes a path segment of a dashboard call, so it is checked here rather than
        # trusted: an id with a slash in it would reshape that request.
        if not JOB_ID_RE.match(job_id):
            raise HTTPException(status_code=422, detail="invalid routine id")
        verb = "pause" if body.paused else "resume"
        _dashboard("POST", f"/api/cron/jobs/{job_id}/{verb}?profile={profile}")

        runtime.audit.emit("bots.routine_state", device_id=caller, method="bots.routine_state",
                           path=f"/v1/bots/{profile}/routines/{job_id}/state", nbytes=0,
                           outcome="paused" if body.paused else "resumed")
        return {"profile": profile, "id": job_id, "paused": body.paused}

    return router
