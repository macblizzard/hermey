"""Notifications that arrive while the app is shut: a relay, because APNs is not ours to use.

Push to a sideloaded app needs a credential for the *team that signed it*. This host has none —
the signing certificate belongs to a resale team, and no reseller hands out its APNs key (see the
profile's own `application-identifier`: `TJ27FT3Y2M.…`). So the delivery goes through an app that
already holds such a credential and sells the service as a product: **Bark**.

Bark is an App Store client plus a self-hosted server. The phone shows a URL like
`http://your-host:8081/AbCdEf123`; POSTing JSON to it makes a real banner appear on the lock
screen, through Bark's own APNs key. Tap-through is a `url` in the payload, so the banner opens
Hermey on the bot that spoke.

What the bridge adds:

    POST /v1/push/register   {"url": "http://…/AbCdEf"}      this device's relay endpoint
    POST /v1/push/presence   {"bot": "cody" | null}          what this device is looking at
    POST /v1/push/test                                       one banner, now

…and a watcher that reads each bot's conversation on a timer and pushes what is new. The timer is
the honest part: the relay cannot be told "a reply arrived" by a process that does not exist, so the
host looks for itself. Twenty seconds is fast enough to feel immediate and slow enough that reading
every profile's `state.db` costs nothing.

A device is never pushed about the bot it says it is looking at, and a reply the *reader* wrote is
never pushed at all. Both rules exist so a banner never announces something already on screen.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional
from urllib.parse import urlsplit

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from .device_auth import require_device

#: How often the host looks for new replies. Bigger than the app's own 25 s sweep? Slightly less —
#: a banner that arrives before the row would be strange, one that arrives after is just late.
WATCH_SECONDS = 20.0

#: A banner body is a notification, not a message: two lines, then the app itself.
MAX_BODY_CHARS = 140

#: Bark accepts a whole notification as JSON; a payload bigger than this is a mistake, not a note.
MAX_URL_CHARS = 512

_PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


class PushRegister(BaseModel):
    #: The whole URL the Bark app shows, key included. The bridge splits it, so the app sends one
    #: field and a person can paste what is on their screen.
    url: str


class Presence(BaseModel):
    #: The bot whose conversation is on screen right now, or null when the app is not in a chat.
    bot: Optional[str] = None


def _split_bark_url(raw: str) -> tuple[str, str]:
    """`http://host:port/KEY` -> (`http://host:port`, `KEY`). Anything else is refused.

    Parsed rather than split on the last slash: `rpartition` accepted `http://host/` as server
    `http:/` and key `host`, which would have made a typo look like a working registration.
    """
    url = raw.strip()
    if not url or len(url) > MAX_URL_CHARS:
        raise HTTPException(status_code=422, detail="a Bark URL is required")
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        raise HTTPException(status_code=422, detail="a Bark URL starts with http:// or https://")
    segments = [segment for segment in parts.path.split("/") if segment]
    if len(segments) < 1:
        raise HTTPException(status_code=422,
                            detail="a Bark URL ends in the device key, e.g. http://host:8080/AbCdEf")
    key = segments[-1]
    if not re.match(r"^[A-Za-z0-9_-]{1,128}$", key):
        raise HTTPException(status_code=422,
                            detail="a Bark URL ends in the device key, e.g. http://host:8080/AbCdEf")
    prefix = "/".join(segments[:-1])
    endpoint = f"{parts.scheme}://{parts.netloc}" + (f"/{prefix}" if prefix else "")
    return endpoint, key


def _profiles_root() -> Path:
    candidates: list[Path] = []
    home = os.environ.get("HERMES_HOME")
    if home:
        base = Path(home)
        candidates.append(base / "profiles")
        if base.parent.name == "profiles":
            candidates.append(base.parent)
    candidates.append(Path.home() / ".hermes" / "profiles")
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    return candidates[-1]


# MARK: - The relay client


class BarkRelay:
    """One POST per banner. Bark's server takes the JSON and does the APNs work."""

    def __init__(self, timeout: float = 8.0) -> None:
        self.timeout = timeout

    def send(self, base: str, key: str, *, title: str, body: str, group: str = "",
             url: str = "", icon: str = "") -> bool:
        payload: dict[str, object] = {"title": title[:120], "body": body[:MAX_BODY_CHARS]}
        if group:
            payload["group"] = group
        if url:
            payload["url"] = url
        if icon:
            payload["icon"] = icon
        request = urllib.request.Request(
            f"{base.rstrip('/')}/{key}",
            data=json.dumps(payload).encode("utf-8"),
            headers={"content-type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return 200 <= response.status < 300
        except (urllib.error.URLError, OSError, ValueError):
            return False


# MARK: - The watcher


class ReplyWatcher:
    """Reads every bot's conversation on a timer and pushes the replies it has not seen.

    Deliberately dumb and self-contained: a thread, a sleep, and the same read-only `state.db` query
    the bot list's previews use. It never writes to a profile, never opens a socket to a bot, and a
    failure on one profile is not allowed to stop the others.
    """

    def __init__(self, runtime, relay: BarkRelay, interval: float = WATCH_SECONDS) -> None:
        self.runtime = runtime
        self.relay = relay
        self.interval = interval
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        #: First pass only records what exists, so an install with a year of history does not fire
        #: a hundred banners when the bridge restarts.
        self._primed = False

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="reply-watcher", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    def _run(self) -> None:
        while not self._stop.wait(self.interval):
            try:
                self.tick()
            except Exception:  # a watcher must not die of one bad profile
                continue

    # -- one pass ----------------------------------------------------------

    def tick(self) -> None:
        targets = self.runtime.registry.push_targets()
        if not targets:
            return
        for profile in self._profiles():
            reply = self._newest_reply(profile)
            if reply is None:
                continue
            stamp = reply["at"]
            previous = self.runtime.registry.push_watch(profile)
            if self._primed and previous is not None and stamp <= previous:
                continue
            self.runtime.registry.set_push_watch(profile, stamp)
            if not self._primed:
                continue
            self._push(profile, reply, targets)
        self._primed = True

    def _push(self, profile: str, reply: dict, targets) -> None:
        title = profile.capitalize()
        body = reply["text"][:MAX_BODY_CHARS]
        for target in targets:
            # The bot this device is reading is not news to it.
            if target.get("preset_bot") == profile:
                continue
            self.relay.send(target["endpoint"], target["key"], title=title, body=body,
                            group=profile, url=f"hermey://bot/{profile}")

    def _profiles(self) -> list[str]:
        root = _profiles_root()
        if not root.is_dir():
            return []
        return sorted(p.name for p in root.iterdir()
                      if p.is_dir() and _PROFILE_RE.match(p.name) and (p / "state.db").is_file())

    def _newest_reply(self, profile: str) -> Optional[dict]:
        """The newest assistant message of the conversation the app opens."""
        db_path = _profiles_root() / profile / "state.db"
        pointer = self.runtime.registry.stored_session(profile)
        try:
            conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2.0)
        except sqlite3.Error:
            return None
        try:
            row = None
            if pointer:
                row = conn.execute(
                    "SELECT content, timestamp FROM messages WHERE session_id = ? "
                    "AND role = 'assistant' AND content IS NOT NULL AND TRIM(content) <> '' "
                    "ORDER BY timestamp DESC, id DESC LIMIT 1", (pointer,)).fetchone()
            if row is None:
                row = conn.execute(
                    "SELECT content, timestamp FROM messages WHERE role = 'assistant' "
                    "AND content IS NOT NULL AND TRIM(content) <> '' "
                    "ORDER BY timestamp DESC, id DESC LIMIT 1").fetchone()
            if row is None:
                return None
            text = _plain(row[0])
            if not text:
                return None
            return {"text": text, "at": float(row[1] or 0)}
        except sqlite3.Error:
            return None
        finally:
            conn.close()


_MARKUP = re.compile(r"\*\*|__|`+|^#{1,6}\s+", re.MULTILINE)


def _plain(raw: Optional[str]) -> str:
    """The first line of a reply, without the markdown that would show up as literal stars."""
    if not raw:
        return ""
    line = raw.strip().splitlines()[0] if raw.strip() else ""
    return _MARKUP.sub("", line).strip()


def create_push_router(runtime, relay: BarkRelay) -> APIRouter:
    router = APIRouter(prefix="/v1/push", tags=["push"])

    @router.post("/register")
    def register(body: PushRegister,
                 authorization: str | None = Header(default=None)) -> dict:
        device = require_device(runtime, authorization)
        endpoint, key = _split_bark_url(body.url)
        runtime.registry.set_push_target(device, provider="bark", endpoint=endpoint, key=key)
        return {"device": device, "provider": "bark", "endpoint": endpoint}

    @router.post("/presence")
    def presence(body: Presence,
                 authorization: str | None = Header(default=None)) -> dict:
        device = require_device(runtime, authorization)
        bot = body.bot if body.bot and _PROFILE_RE.match(body.bot) else None
        runtime.registry.set_push_presence(device, bot)
        return {"device": device, "bot": bot}

    @router.post("/test")
    def test(authorization: str | None = Header(default=None)) -> dict:
        device = require_device(runtime, authorization)
        target = runtime.registry.push_target(device)
        if not target:
            raise HTTPException(status_code=404, detail="no relay registered for this device")
        delivered = relay.send(target["endpoint"], target["key"],
                               title="Hermey", body="Notifications are working.",
                               group="hermey", url="hermey://bot")
        if not delivered:
            raise HTTPException(status_code=502, detail="the relay did not accept the banner")
        return {"delivered": True}

    return router
