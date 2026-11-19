"""Integrations: connect a Google account to this host through Composio.

The owner taps Connect in the app, the bridge asks Composio for a hosted link, and the browser opens
Composio's own page — sign-in, consent, and "you're connected, close this tab" all happen there. The
project key never leaves this host and never reaches the app, the same rule as the login cards.

Composio's model, which is what makes one key serve many people: an **auth config** is a per-toolkit
blueprint (Composio manages the OAuth app), and a **connected account** is one user's grant, addressed by
``user_id``. So the owner of this host connects their own Gmail under the host's key.
"""

from __future__ import annotations

import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

LOGGER = logging.getLogger(__name__)

API = "https://backend.composio.dev/api/v3.1"

#: What the Integrations screen offers. Ordered as the app shows them: the two that carry most of the
#: value first, then the documents and maps. A toolkit whose slug Composio does not know is reported as
#: unavailable rather than pretending.
CATALOG = (
    ("gmail", "Gmail", "Read, search and send mail"),
    ("googlecalendar", "Google Calendar", "See and change your calendar"),
    ("googledrive", "Google Drive", "Find and open files"),
    ("googledocs", "Google Docs", "Read and write documents"),
    ("googlesheets", "Google Sheets", "Read and edit spreadsheets"),
    ("googlemaps", "Google Maps", "Places, directions and distance"),
)

#: Where an operator puts the project key. A file rather than only an env var because the bridge runs
#: under systemd and a key in a unit file is visible in `systemctl show`.
KEY_FILE = Path("/etc/hermey/composio.key")

REQUEST_TIMEOUT = 20


class ComposioError(RuntimeError):
    """A call Composio refused or could not be reached for. Never contains the key."""


def api_key() -> str | None:
    """The project key, from the environment or the key file. Neither is ever logged."""
    from_env = os.environ.get("COMPOSIO_API_KEY", "").strip()
    if from_env:
        return from_env
    try:
        text = KEY_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return text or None


def user_id() -> str:
    """Who a connected account belongs to. One owner per host; stable across restarts."""
    return os.environ.get("COMPOSIO_USER_ID", "").strip() or "hermey-owner"


@dataclass
class Integration:
    slug: str
    name: str
    blurb: str
    connected: bool
    account_id: str | None = None
    available: bool = True


class ComposioClient:
    """The three calls the app needs, and nothing that hands out the key."""

    def __init__(self, key: str | None = None, api: str = API, timeout: float = REQUEST_TIMEOUT) -> None:
        self._key = key
        self.api = api.rstrip("/")
        self.timeout = timeout

    @property
    def configured(self) -> bool:
        return bool(self._key or api_key())

    def _request(self, method: str, path: str, body: dict | None = None) -> dict:
        key = self._key or api_key()
        if not key:
            raise ComposioError("no Composio key on this host")
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(f"{self.api}{path}", data=data, method=method)
        request.add_header("x-api-key", key)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as reply:
                raw = reply.read()
        except urllib.error.HTTPError as exc:
            # The body can echo the request back; report the status only.
            raise ComposioError(f"Composio refused the request ({exc.code})") from None
        except urllib.error.URLError as exc:
            raise ComposioError(f"Composio unreachable: {exc.reason}") from None
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            raise ComposioError("Composio returned something that is not JSON") from None

    def connected_accounts(self, slug: str | None = None) -> list[dict]:
        query = {"user_id": user_id()}
        if slug:
            query["toolkit_slug"] = slug
        rows = self._request("GET", f"/connected_accounts?{urllib.parse.urlencode(query)}")
        items = rows.get("items") if isinstance(rows, dict) else rows
        return [row for row in (items or []) if isinstance(row, dict)]

    def auth_config_id(self, slug: str) -> str | None:
        """The blueprint for one toolkit. Composio manages the OAuth app behind it."""
        rows = self._request("GET", f"/auth_configs?{urllib.parse.urlencode({'toolkit_slug': slug})}")
        items = rows.get("items") if isinstance(rows, dict) else rows
        for row in items or []:
            if not isinstance(row, dict):
                continue
            if str(row.get("toolkit_slug") or row.get("toolkit", "")).lower() != slug:
                continue
            if row.get("status") not in (None, "ENABLED", "enabled"):
                continue
            identifier = row.get("id") or row.get("nanoid")
            if identifier:
                return str(identifier)
        return None

    def ensure_auth_config(self, slug: str) -> str:
        """The toolkit's blueprint, created with Composio-managed auth if the project has none.

        A project starts with zero auth configs, and asking someone to create one per service in a
        dashboard before Connect works is exactly the setup friction this feature exists to remove.
        Composio's managed auth means no OAuth client of ours is involved, so creating it is safe and
        idempotent: we only ever create when a lookup finds nothing.
        """
        existing = self.auth_config_id(slug)
        if existing:
            return existing
        reply = self._request("POST", "/auth_configs", {"toolkit": {"slug": slug}})
        created = reply.get("auth_config") if isinstance(reply, dict) else None
        identifier = (created or {}).get("id") if isinstance(created, dict) else None
        if not identifier:
            # Some projects answer with the config at the top level instead of nested.
            identifier = reply.get("id") if isinstance(reply, dict) else None
        if not identifier:
            raise ComposioError(f"Composio would not create an auth config for {slug}")
        LOGGER.info("integrations: created a managed auth config for %s", slug)
        return str(identifier)

    def connect_link(self, slug: str) -> str:
        """A hosted sign-in page for this toolkit. The user finishes there; nothing comes back to us."""
        config = self.ensure_auth_config(slug)
        reply = self._request("POST", "/connected_accounts/link",
                             {"auth_config_id": config, "user_id": user_id()})
        url = reply.get("redirect_url") if isinstance(reply, dict) else None
        if not url:
            raise ComposioError("Composio did not return a link")
        return str(url)

    def disconnect(self, account_id: str) -> None:
        self._request("DELETE", f"/connected_accounts/{urllib.parse.quote(account_id, safe='')}")


def _toolkit_of(row: dict) -> str:
    """The row's toolkit, whichever shape Composio used: nested object or flat key."""
    nested = row.get("toolkit")
    slug = nested.get("slug") if isinstance(nested, dict) else None
    return str(slug or row.get("toolkit_slug") or "").strip().lower()


def _active(accounts: list[dict], slug: str | None = None) -> dict | None:
    """One usable account, for ``slug`` only.

    The filter is applied here rather than trusted from the request: asking Composio for
    ``toolkit_slug=googlecalendar`` returns the Gmail account too, which made every service on the screen
    read "Connected" the moment one of them was connected.

    ``ACTIVE`` is the only status that means usable. ``INITIALIZING`` is a link mid-flow — showing that as
    connected would claim a sign-in that has not happened.
    """
    for row in accounts:
        if slug and _toolkit_of(row) != slug:
            continue
        if str(row.get("status") or "").upper() == "ACTIVE":
            return row
    return None


def integrations(client: ComposioClient) -> list[Integration]:
    """The catalog with each service's state. A Composio outage marks everything unavailable, not broken."""
    out: list[Integration] = []
    for slug, name, blurb in CATALOG:
        try:
            account = _active(client.connected_accounts(slug), slug)
        except ComposioError as exc:
            LOGGER.info("integrations: %s unknown (%s)", slug, exc)
            out.append(Integration(slug, name, blurb, connected=False, available=False))
            continue
        out.append(Integration(slug, name, blurb, connected=account is not None,
                               account_id=str(account.get("id")) if account and account.get("id") else None))
    return out


def create_integrations_router(runtime, client: ComposioClient | None = None):
    """What the app's Integrations screen talks to."""
    from fastapi import APIRouter, HTTPException

    router = APIRouter(prefix="/v1/integrations", tags=["integrations"])
    api = client or ComposioClient()

    def _audit(outcome: str, slug: str, note: str = "") -> None:
        try:
            runtime.audit.emit("integration", method="integrations", path=f"/v1/integrations/{slug}",
                               outcome=outcome, reason=note or None)
        except Exception:  # noqa: BLE001 - auditing must not break the call
            pass

    @router.get("")
    def list_integrations() -> dict:
        rows = integrations(api)
        return {
            "configured": api.configured,
            "user": user_id(),
            "services": [
                {"slug": row.slug, "name": row.name, "blurb": row.blurb, "connected": row.connected,
                 "account_id": row.account_id, "available": row.available}
                for row in rows
            ],
        }

    @router.post("/{slug}/connect")
    def connect(slug: str) -> dict:
        if slug not in {entry[0] for entry in CATALOG}:
            raise HTTPException(status_code=404, detail="unknown integration")
        try:
            url = api.connect_link(slug)
        except ComposioError as exc:
            _audit("failed", slug, str(exc))
            raise HTTPException(status_code=409, detail=str(exc)) from None
        _audit("link_created", slug)
        return {"url": url}

    @router.post("/{slug}/disconnect")
    def disconnect(slug: str) -> dict:
        if slug not in {entry[0] for entry in CATALOG}:
            raise HTTPException(status_code=404, detail="unknown integration")
        try:
            account = _active(api.connected_accounts(slug), slug)
        except ComposioError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from None
        if not account or not account.get("id"):
            _audit("not_connected", slug)
            return {"ok": True, "state": "not connected"}
        try:
            api.disconnect(str(account["id"]))
        except ComposioError as exc:
            _audit("failed", slug, str(exc))
            raise HTTPException(status_code=409, detail=str(exc)) from None
        _audit("revoked", slug)
        return {"ok": True, "state": "revoked"}

    return router
