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
    #: Every connected account for this service: {"id", "label"}. One is the common case, two is normal.
    accounts: list[dict] | None = None


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

    def connect_link(self, slug: str, alias: str | None = None) -> str:
        """A hosted sign-in page for this toolkit. The user finishes there; nothing comes back to us.

        ``allow_multiple`` is what makes a second Gmail possible at all: without it Composio refuses the
        second connection for the same user and auth config. The alias is how the owner tells them apart
        afterwards, and it has to be unique per toolkit.
        """
        config = self.ensure_auth_config(slug)
        body: dict = {"auth_config_id": config, "user_id": user_id(), "allow_multiple": True}
        if alias:
            body["alias"] = alias
        reply = self._request("POST", "/connected_accounts/link", body)
        url = reply.get("redirect_url") if isinstance(reply, dict) else None
        if not url:
            raise ComposioError("Composio did not return a link")
        return str(url)

    def list_tools(self, slug: str, limit: int = 50) -> list[dict]:
        """The tools a toolkit offers, by their real slugs.

        A bot that guesses "send_email" wastes a turn and a context window; these are the names the
        Composio session actually accepts.
        """
        rows = self._request("GET", f"/tools?{urllib.parse.urlencode({'toolkit_slug': slug, 'limit': limit})}")
        items = rows.get("items") if isinstance(rows, dict) else rows
        return [{"slug": str(t.get("slug")), "name": str(t.get("name") or "")}
                for t in (items or []) if isinstance(t, dict) and t.get("slug")]

    def run_tool(self, tool_slug: str, arguments: dict | None = None,
                 account_id: str | None = None) -> dict:
        """Run one Composio tool for this owner, on the account named.

        The slug goes in the PATH (/tools/execute/{slug}), which is why probing /tools/execute alone always
        answered 404 — it is not a route without a tool in it. `version: latest` because v3.1 otherwise pins
        the first published definition of the tool.
        """
        body: dict = {"arguments": arguments or {}, "user_id": user_id(), "version": "latest"}
        if account_id:
            body["connected_account_id"] = account_id
        return self._request("POST", f"/tools/execute/{urllib.parse.quote(tool_slug, safe='')}", body)

    def set_alias(self, account_id: str, alias: str) -> None:
        """Rename a connected account. The alias is how the owner tells two Gmails apart."""
        self._request("PATCH", f"/connected_accounts/{urllib.parse.quote(account_id, safe='')}",
                      {"alias": alias})

    def disconnect(self, account_id: str) -> None:
        self._request("DELETE", f"/connected_accounts/{urllib.parse.quote(account_id, safe='')}")


def _toolkit_of(row: dict) -> str:
    """The row's toolkit, whichever shape Composio used: nested object or flat key."""
    nested = row.get("toolkit")
    slug = nested.get("slug") if isinstance(nested, dict) else None
    return str(slug or row.get("toolkit_slug") or "").strip().lower()


def _active_all(accounts: list[dict], slug: str | None = None) -> list[dict]:
    """Every usable account for a toolkit, newest last.

    More than one is normal once the owner adds a second Gmail; showing only the first made the extra one
    invisible and made Disconnect revoke whichever it happened to find.
    """
    out = []
    for row in accounts:
        if slug and _toolkit_of(row) != slug:
            continue
        if str(row.get("status") or "").upper() != "ACTIVE":
            continue
        out.append(row)
    return out


def _label_for(row: dict, index: int) -> str:
    """How the owner recognises an account: its alias, else the address Composio knows, else its position."""
    for key in ("alias", "alias_name"):
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    data = row.get("data")
    if isinstance(data, dict):
        for key in ("email", "emailAddress", "user_email"):
            value = data.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    return f"account {index + 1}"


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
    """The catalog with each service's state. A Composio outage marks everything unavailable, not broken.

    The six lookups run together: serially they were 1.2–2.9 s of wall clock, which a phone on a weak link
    turns into "could not reach the host". They are independent reads of the same account list, so the only
    thing serialising them bought was latency.
    """
    from concurrent.futures import ThreadPoolExecutor

    with ThreadPoolExecutor(max_workers=len(CATALOG)) as pool:
        return list(pool.map(lambda entry: _one(client, entry), CATALOG))


def _one(client: ComposioClient, entry: tuple[str, str, str]) -> Integration:
    """One service's state. Runs on a worker thread, so it returns instead of appending."""
    slug, name, blurb = entry
    try:
        rows = _active_all(client.connected_accounts(slug), slug)
    except ComposioError as exc:
        LOGGER.info("integrations: %s unknown (%s)", slug, exc)
        return Integration(slug, name, blurb, connected=False, available=False, accounts=[])
    accounts = [{"id": str(row.get("id")), "label": _label_for(row, index)}
                for index, row in enumerate(rows) if row.get("id")]
    return Integration(slug, name, blurb, connected=bool(accounts),
                       account_id=accounts[0]["id"] if accounts else None, accounts=accounts)


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
                 "account_id": row.account_id, "available": row.available,
                 "accounts": row.accounts or []}
                for row in rows
            ],
        }

    @router.post("/{slug}/connect")
    def connect(slug: str, body: dict | None = None) -> dict:
        if slug not in {entry[0] for entry in CATALOG}:
            raise HTTPException(status_code=404, detail="unknown integration")
        alias = None
        if isinstance(body, dict) and isinstance(body.get("alias"), str) and body["alias"].strip():
            alias = body["alias"].strip()[:40]
        try:
            url = api.connect_link(slug, alias)
        except ComposioError as exc:
            _audit("failed", slug, str(exc))
            raise HTTPException(status_code=409, detail=str(exc)) from None
        _audit("link_created", slug)
        return {"url": url}

    @router.get("/{slug}/tools")
    def tools(slug: str) -> dict:
        """What a bot may call for this service, in Composio's own names."""
        if slug not in {entry[0] for entry in CATALOG}:
            raise HTTPException(status_code=404, detail="unknown integration")
        try:
            return {"tools": api.list_tools(slug)}
        except ComposioError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from None

    @router.post("/run")
    def run(body: dict | None = None) -> dict:
        """Run one tool against a connected account: what a bot uses to actually read or act.

        The account is named explicitly when a service has more than one, because an unqualified call would
        silently pick one — and with two Gmails that is the wrong mailbox half the time.
        """
        tool = (body or {}).get("tool")
        if not isinstance(tool, str) or not tool.strip():
            raise HTTPException(status_code=400, detail="tool is required")
        account = (body or {}).get("account_id")
        arguments = (body or {}).get("arguments") or {}
        if not isinstance(arguments, dict):
            raise HTTPException(status_code=400, detail="arguments must be an object")
        try:
            result = api.run_tool(tool.strip(), arguments,
                                  account if isinstance(account, str) and account else None)
        except ComposioError as exc:
            _audit("failed", tool[:20], str(exc))
            raise HTTPException(status_code=409, detail=str(exc)) from None
        _audit("ran", tool[:20])
        return {"ok": True, "result": result}

    @router.post("/{slug}/alias")
    def alias(slug: str, body: dict | None = None) -> dict:
        """Give a connected account a name the owner recognises: personal, work, the office."""
        if slug not in {entry[0] for entry in CATALOG}:
            raise HTTPException(status_code=404, detail="unknown integration")
        account_id = body.get("account_id") if isinstance(body, dict) else None
        name = body.get("alias") if isinstance(body, dict) else None
        if not isinstance(account_id, str) or not account_id:
            raise HTTPException(status_code=400, detail="account_id is required")
        if not isinstance(name, str) or not name.strip():
            raise HTTPException(status_code=400, detail="alias is required")
        try:
            api.set_alias(account_id, name.strip()[:40])
        except ComposioError as exc:
            _audit("failed", slug, str(exc))
            raise HTTPException(status_code=409, detail=str(exc)) from None
        _audit("renamed", slug)
        return {"ok": True, "alias": name.strip()[:40]}

    @router.post("/{slug}/disconnect")
    def disconnect(slug: str, body: dict | None = None) -> dict:
        """Revoke ONE account, named by its id.

        By id rather than by service: once there are two Gmails, "disconnect gmail" has no safe meaning and
        would revoke whichever came back first.
        """
        if slug not in {entry[0] for entry in CATALOG}:
            raise HTTPException(status_code=404, detail="unknown integration")
        wanted = body.get("account_id") if isinstance(body, dict) else None
        try:
            found = _active_all(api.connected_accounts(slug), slug)
        except ComposioError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from None
        if wanted:
            found = [row for row in found if str(row.get("id")) == str(wanted)]
        elif len(found) > 1:
            raise HTTPException(status_code=409,
                                detail="more than one account is connected: say which one")
        account = found[0] if found else None
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
