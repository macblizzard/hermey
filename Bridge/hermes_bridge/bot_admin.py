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
from typing import Any, Callable, Optional

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


class RoutineCreate(BaseModel):
    """A new routine for one bot — what the phone's "New Routine" form sends.

    `schedule` is the host's own schedule string, not a parsed one: the app builds it from a picker
    ("daily at 09:00" becomes a cron expression, "repeat" becomes an interval) and the dashboard is
    the only place that decides whether it is valid. At least one of `prompt`, `skills` and `script`
    is required — a routine with none of them has nothing to do — and that rule is enforced here as
    well as in the form, because a second client or a replayed request must not be able to create a
    job that can never run.
    """

    schedule: str
    name: str = ""
    prompt: str = ""
    skills: list[str] = []
    script: str = ""
    # "local" keeps the result for the history; "bot-chat:<profile>" posts it into a bot's chat.
    deliver: str = "local"
    paused: bool = False
    timezone: str | None = None


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


def _model_settings_from(config: dict) -> dict:
    """The four fields the model sheet draws, out of a dashboard config document.

    `reasoning_effort` may be `False` in the host's own file, which means "thinking disabled" rather
    than "unset" — so it is reported as `none`, the spelling `PUT` accepts back. A missing aux block
    reports `auto` + an empty model, which is exactly what the host does with it: inherit the main
    model.
    """
    agent_cfg = config.get("agent") if isinstance(config.get("agent"), dict) else {}
    raw_effort = agent_cfg.get("reasoning_effort", "")
    if raw_effort is False:
        effort = "none"
    elif isinstance(raw_effort, dict):
        effort = "none" if raw_effort.get("enabled") is False else str(raw_effort.get("effort") or "")
    else:
        effort = str(raw_effort or "")

    auxiliary = config.get("auxiliary") if isinstance(config.get("auxiliary"), dict) else {}
    vision = auxiliary.get("vision") if isinstance(auxiliary.get("vision"), dict) else {}
    return {
        "profile": None,  # filled by the route, which knows it
        "effort": effort,
        "efforts": list(REASONING_EFFORTS),
        "vision": {
            "provider": str(vision.get("provider") or "auto"),
            "model": str(vision.get("model") or ""),
        },
    }


def _dashboard_url() -> str:
    """The dashboard URL, checked: plain http on loopback, or nothing.

    The token in the header is full authority over the agent, so where it is sent must not be
    something an environment variable can point off the box.
    """
    parts = urllib.parse.urlsplit(DASHBOARD_URL)
    if parts.scheme != "http" or not is_loopback_host(parts.hostname or ""):
        raise HTTPException(status_code=500, detail="dashboard url must be loopback http")
    return DASHBOARD_URL.rstrip("/")


def _dashboard(method: str, path: str, body: dict | None = None) -> tuple[int, Any]:
    """One call to the loopback dashboard, with the token it was started with.

    `body` is JSON-encoded here rather than by the caller: every write in this module goes through
    this one function, so the content type and the encoding cannot drift between routes.
    """
    token = os.environ.get("HERMES_DASHBOARD_SESSION_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="dashboard token is not configured")
    headers = {"Authorization": f"Bearer {token}"}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(f"{_dashboard_url()}{path}", method=method,
                                     headers=headers, data=data)
    try:
        with _OPENER.open(request, timeout=REQUEST_TIMEOUT) as response:
            body = response.read()
            return response.status, json.loads(body) if body.strip() else None
    except urllib.error.HTTPError as error:
        # The body can echo the request; the device gets a fixed sentence instead. A 422 is the
        # exception: that is the scheduler rejecting the *form* (an unparseable schedule, an unknown
        # timezone), and a person needs to know which field to change rather than that something
        # went wrong.
        log.warning("dashboard refused %s %s: %s", method, path, error.code)
        if error.code in (400, 422):
            raise HTTPException(status_code=422,
                                detail="The scheduler rejected this routine's schedule.") from None
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


#: The levels the host accepts for `agent.reasoning_effort` (`hermes_constants.VALID_REASONING_EFFORTS`),
#: with the empty string first because "" means "whatever the provider does by default". `none` is the
#: host's own spelling for thinking switched off entirely.
REASONING_EFFORTS = ("", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "none")

#: The host's own approval modes (`hermes_cli.approval_mode.VALID_APPROVAL_MODES`). The app's labels
#: are "always ask" / "auto" / "never ask", but the wire keeps the host's spelling so a client cannot
#: invent a mode the terminal guard would ignore.
APPROVAL_MODES = ("manual", "smart", "off")


class ApprovalModeUpdate(BaseModel):
    mode: str


def _served_profiles() -> list[str]:
    """Every bot profile on this host, not just the ones currently paired with a device."""
    try:
        return sorted(path.name for path in _profiles_root().iterdir()
                      if path.is_dir() and PROFILE_RE.match(path.name) and path.name not in PROTECTED)
    except OSError:
        return []


def _approval_mode_from(config: object) -> str:
    if not isinstance(config, dict):
        return "manual"
    approvals = config.get("approvals")
    raw = approvals.get("mode", "manual") if isinstance(approvals, dict) else "manual"
    return raw if isinstance(raw, str) and raw in APPROVAL_MODES else "manual"


class ModelSettingsUpdate(BaseModel):
    """What a bot's model sheet may change beyond the model itself.

    Three independent knobs, all of them the *profile's own* config, which is why this route is
    per-bot: `effort` is `agent.reasoning_effort`, and the aux pair is `auxiliary.vision.provider` /
    `auxiliary.vision.model` — the model that looks at pictures when the main model cannot. An
    unset field means "leave it alone"; `""` means "back to the host's default", which for the aux
    provider is the literal string `auto` (inherit the main model).
    """

    effort: Optional[str] = None
    vision_provider: Optional[str] = None
    vision_model: Optional[str] = None


def create_bot_admin_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1/bots", tags=["bots-admin"])

    def authenticate(authorization) -> str:
        return require_device(runtime, authorization)



    @router.get("/approvals")
    def read_approvals(authorization: str | None = Header(default=None)) -> dict:
        """The approval mode of every served bot, read from the configs the next turn will use."""
        authenticate(authorization)
        states: dict[str, str] = {}
        for profile in _served_profiles():
            status, config = _dashboard("GET", f"/api/config?profile={urllib.parse.quote(profile)}")
            states[profile] = _approval_mode_from(config) if status == 200 else "manual"
        approx = set(states.values())
        return {"mode": approx.pop() if len(approx) == 1 else "mixed",
                "profiles": states,
                "available": list(APPROVAL_MODES)}

    @router.put("/approvals")
    def write_approvals(body: ApprovalModeUpdate,
                        authorization: str | None = Header(default=None)) -> dict:
        """Set one approval mode for every bot. A failed profile is reported, never papered over."""
        caller = authenticate(authorization)
        if body.mode not in APPROVAL_MODES:
            raise HTTPException(status_code=422, detail=f"unknown approval mode '{body.mode}'")
        updated: list[str] = []
        failed: dict[str, str] = {}
        for profile in _served_profiles():
            status, _ = _dashboard("PUT", f"/api/config?profile={urllib.parse.quote(profile)}",
                                   {"config": {"approvals": {"mode": body.mode}}, "profile": profile})
            if status != 200:
                failed[profile] = "the dashboard refused the config write"
                continue
            status, config = _dashboard("GET", f"/api/config?profile={urllib.parse.quote(profile)}")
            if status != 200 or _approval_mode_from(config) != body.mode:
                failed[profile] = "the config did not retain the mode"
                continue
            updated.append(profile)
        runtime.audit.emit("bots.approval_mode", device_id=caller,
                           method="bots.approval_mode", path="/v1/bots/approvals",
                           nbytes=0, outcome="written" if updated and not failed else "partial")
        return {"mode": body.mode, "updated": updated, "failed": failed}

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

    @router.get("/{profile}/model-settings")
    def read_model_settings(profile: str,
                            authorization: str | None = Header(default=None)) -> dict:
        """This bot's effort level and aux/vision model, read from the host's own config.

        Read through the dashboard's `/api/config`, which is the same document `hermes config` edits
        and the same one the next turn reads, so the sheet shows what will actually be used instead of
        a copy kept here. Keys the host has not set answer as empty strings — "the provider decides",
        not a guess at a default.
        """
        authenticate(authorization)
        _profile_dir(profile)
        status, config = _dashboard("GET", f"/api/config?profile={urllib.parse.quote(profile)}")
        if status != 200 or not isinstance(config, dict):
            raise HTTPException(status_code=502, detail="the dashboard did not answer with a config")
        return {**_model_settings_from(config), "profile": profile}

    @router.put("/{profile}/model-settings")
    def write_model_settings(profile: str, body: ModelSettingsUpdate,
                             authorization: str | None = Header(default=None)) -> dict:
        """Change the effort level and/or the aux/vision model, in the profile's own config.

        `PUT /api/config` deep-merges what it is sent over what is on disk, so the patch below carries
        only the keys this route owns — a save from this sheet can never rewrite a section it did not
        touch. The response is re-read after the write for the same reason the model sheet re-reads the
        catalogue: what the host stored is the answer, not what was sent.
        """
        caller = authenticate(authorization)
        _profile_dir(profile)
        if body.effort is not None and body.effort not in REASONING_EFFORTS:
            raise HTTPException(status_code=422, detail=f"unknown effort '{body.effort}'")

        patch: dict[str, Any] = {}
        if body.effort is not None:
            patch.setdefault("agent", {})["reasoning_effort"] = (
                False if body.effort == "none" else body.effort)
        if body.vision_provider is not None or body.vision_model is not None:
            vision: dict[str, Any] = {}
            if body.vision_provider is not None:
                vision["provider"] = body.vision_provider.strip() or "auto"
            if body.vision_model is not None:
                vision["model"] = body.vision_model.strip()
            patch["auxiliary"] = {"vision": vision}

        if patch:
            status, _ = _dashboard("PUT", f"/api/config?profile={urllib.parse.quote(profile)}",
                                   {"config": patch, "profile": profile})
            if status != 200:
                raise HTTPException(status_code=502, detail="the dashboard refused the config write")
            runtime.audit.emit("bots.model_settings", device_id=caller,
                               method="bots.model_settings",
                               path=f"/v1/bots/{profile}/model-settings", nbytes=0,
                               outcome="written")

        status, config = _dashboard("GET", f"/api/config?profile={urllib.parse.quote(profile)}")
        if status != 200 or not isinstance(config, dict):
            raise HTTPException(status_code=502, detail="the dashboard did not answer with a config")
        return {**_model_settings_from(config), "profile": profile}

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

    @router.post("/{profile}/routines")
    def create_routine(profile: str, body: RoutineCreate,
                       authorization: str | None = Header(default=None)) -> dict:
        """Create one of this bot's routines, through the dashboard that owns the scheduler.

        Nothing is written here: the job is posted to `/api/cron/jobs`, so the host's own validation,
        defaults, timezone handling and `next_run_at` are the ones that apply. One rule is checked
        first because it is the form's rule too — a routine needs a prompt, a skill or a script —
        and a job with none of them would sit in the list forever doing nothing.
        """
        caller = authenticate(authorization)
        _profile_dir(profile)

        schedule = body.schedule.strip()
        if not schedule:
            raise HTTPException(status_code=422, detail="This routine needs a schedule.")

        skills = [skill.strip() for skill in body.skills if skill.strip()]
        prompt = body.prompt.strip()
        script = body.script.strip()
        if not (prompt or skills or script):
            # The same words the official app shows, so the message a person sees in the app is the
            # message the server would have given them.
            raise HTTPException(status_code=422,
                                detail="This routine needs a prompt, a skill, or a script.")

        payload: dict = {"schedule": schedule, "deliver": body.deliver or "local"}
        if body.name.strip():
            payload["name"] = body.name.strip()
        if prompt:
            payload["prompt"] = prompt
        if skills:
            payload["skills"] = skills
        if script:
            payload["script"] = script
            # A script with no prompt is the host's script-only shape: stdout is delivered verbatim
            # and no agent runs. Sending `no_agent: false` there would pay for a model call that the
            # routine never asked for.
            if not prompt:
                payload["no_agent"] = True
        if body.paused:
            payload["paused"] = True
        if body.timezone:
            payload["timezone"] = body.timezone

        _status, created = _dashboard("POST", f"/api/cron/jobs?profile={profile}", body=payload)
        if not isinstance(created, dict) or not created.get("id"):
            raise HTTPException(status_code=502, detail="the scheduler did not return the new routine")

        runtime.audit.emit("bots.routine_create", device_id=caller, method="bots.routine_create",
                           path=f"/v1/bots/{profile}/routines", nbytes=len(prompt) + len(script),
                           outcome="created")
        return {"routine": _routine_row(created)}

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
