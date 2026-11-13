"""The genui plugin's boards, for the native apps.

The plugin draws its cards in the Hermes desktop app: the model calls ``show_blocks``, the plugin
stores a JSON board, and the reply carries one line — ``::blocks{id="7f3a09bc"}`` — which the
desktop replaces with the drawn blocks. A native client has neither the plugin's React bundle nor a
route to it, so this module is the two halves it is missing:

* ``GET /v1/genui/host`` — a one-card page that loads the plugin's own bundle and draws one board.
  The app puts it in a ``WKWebView``, so the cards are the plugin's cards, not a re-drawing of them.
* ``GET /v1/genui/assets/<name>`` and ``GET /v1/genui/plugin.js`` — React and the plugin bundle.
  React is vendored (``genui_assets/``, MIT, built by ``Tools/genui/build_assets.mjs``); the plugin
  bundle is read from the installed plugin on every request, so a plugin update reaches the apps
  without rebuilding them.
* ``GET /v1/genui/blocks/<id>``, plus ``/state`` — the plugin's own REST door, which is what a
  checklist saves its ticks through.

Auth: a webview cannot put a header on the module requests its page makes, so these routes accept
the device token as a query parameter as well as a bearer header. That is the same shape the
dashboard's gateway socket already uses, and the routes are otherwise identical to the rest of the
bridge: loopback only, behind ``tailscale serve``.

Contract::

    GET  /v1/genui/host?block=<id>&bot=<profile>&token=<t>&ink=..&bg=..&accent=..
    GET  /v1/genui/blocks/<id>?bot=<profile>          -> {"blocks": [...]}
    GET  /v1/genui/blocks/<id>/state?bot=<profile>    -> {"state": {...}} | {}
    PUT  /v1/genui/blocks/<id>/state?bot=<profile>    body {"state": {...}} -> 204
"""

from __future__ import annotations

import json
import re
import secrets
import threading
import time
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Header, Request
from fastapi.responses import JSONResponse, Response

from .device_auth import require_device
from .paths import profiles_root

#: A board id is eight lowercase hex characters; anything else never touches the disk.
ID_PATTERN = re.compile(r"^[0-9a-f]{8}$")

#: Where this profile keeps its boards, from the plugin's own store layout.
BOARDS_DIR = ("plugin-data", "hermes-genui", "blocks")

#: The plugin ships one bundle for the desktop half; it is the whole renderer.
PLUGIN_BUNDLE = ("plugins", "hermes-genui", "desktop", "plugin.js")

#: React and the shell. Vendored, because a webview cannot install npm packages.
ASSET_DIR = Path(__file__).resolve().parent / "genui_assets"

#: The only asset names served. A path parameter that reaches outside this set is a 404, not a
#: filesystem read: the directory is inside an installed package and must stay read-only.
ASSETS = {
    "app.mjs": "text/javascript; charset=utf-8",
    "jsx.mjs": "text/javascript; charset=utf-8",
    "sdk.mjs": "text/javascript; charset=utf-8",
    "host.html": "text/html; charset=utf-8",
}

#: The most a stored board may be (the plugin's own BOARD_LIMIT), and the most a state may be.
BOARD_LIMIT = 256 * 1024
STATE_LIMIT = 20 * 1024
BODY_LIMIT = 32 * 1024

NO_BOARD = {"error": "not found"}
TOO_BIG = {"error": "state too big"}

#: How long a card session lives. One card load is five requests (the page, three modules and the
#: board) plus whatever a tap needs; two minutes covers a slow phone and nothing else.
SESSION_TTL = 120.0

#: A session is a capability, not a credential: it reads genui boards and nothing else, it expires,
#: and it is forgotten when the process restarts. The cap is there so a looping client cannot grow
#: this dict without bound.
MAX_SESSIONS = 512

_sessions: dict[str, tuple[float, str]] = {}
_sessions_lock = threading.Lock()


def _new_session(device_id: str) -> str:
    """Mint a card session: 32 hex characters, good for SESSION_TTL seconds."""
    now = time.monotonic()
    value = secrets.token_hex(16)
    with _sessions_lock:
        if len(_sessions) >= MAX_SESSIONS:
            for key, (expires, _) in list(_sessions.items()):
                if expires <= now:
                    _sessions.pop(key, None)
            if len(_sessions) >= MAX_SESSIONS:
                _sessions.clear()
        _sessions[value] = (now + SESSION_TTL, device_id)
    return value


def _session_device(session: Optional[str]) -> Optional[str]:
    """The device a live session belongs to, or None."""
    if not session:
        return None
    with _sessions_lock:
        entry = _sessions.get(session)
        if entry is None:
            return None
        if entry[0] <= time.monotonic():
            _sessions.pop(session, None)
            return None
        return entry[1]


def _token(authorization: Optional[str], token: Optional[str]) -> Optional[str]:
    """The credential, from a header or from the query string.

    ``_token("Bearer abc", None) -> "Bearer abc"``;  ``_token(None, "abc") -> "Bearer abc"``;
    ``_token(None, None) -> None`` (and the caller answers 401).
    """
    if authorization:
        return authorization
    if token:
        return f"Bearer {token}"
    return None


def _hermes_home() -> Path:
    """The install home the plugins live under, beside the profiles this bridge reports on."""
    root = profiles_root()
    return root.parent if root.name == "profiles" else root


def _board_path(profile: str, block_id: str) -> Path:
    return profiles_root() / profile / Path(*BOARDS_DIR) / f"{block_id}.json"


def create_genui_router(runtime) -> APIRouter:
    router = APIRouter(prefix="/v1/genui", tags=["genui"])

    def refuse(
        authorization: Optional[str],
        token: Optional[str],
        session: Optional[str],
    ):
        """None when the caller may have this, otherwise the response to send instead.

        Two doors, and both are checked here rather than in each route: a **card session** (a
        capability minted by `/session`, good for SESSION_TTL and only for these routes), or a
        device **ticket**. A webview cannot mint a ticket per subresource, which is why the session
        exists; a native caller with a ticket needs no session at all.
        """
        if session:
            if _session_device(session) is not None:
                return None
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        credential = _token(authorization, token)
        if credential is None:
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        try:
            require_device(runtime, credential)
        except Exception:  # noqa: BLE001 — every failure here is "not a paired device"
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        return None

    def bot_or_404(profile: str) -> Optional[Path]:
        """A profile name is a directory name: it may not be a path."""
        if not profile or "/" in profile or "\\" in profile or profile in {".", ".."}:
            return None
        return profiles_root() / profile

    @router.post("/session")
    async def mint_session(
        bot: str = "",
        authorization: Optional[str] = Header(default=None),
        token: Optional[str] = None,
    ):
        """Trade one device ticket for a card session the webview can use for every subresource."""
        credential = _token(authorization, token)
        if credential is None:
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        try:
            device_id = require_device(runtime, credential)
        except Exception:  # noqa: BLE001
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        if bot_or_404(bot) is None:
            return JSONResponse(NO_BOARD, status_code=404)
        return {"session": _new_session(device_id), "ttl": int(SESSION_TTL)}

    @router.get("/host")
    async def host(
        block: str = "",
        bot: str = "",
        token: Optional[str] = None,
        session: Optional[str] = None,
        authorization: Optional[str] = Header(default=None),
    ):
        denied = refuse(authorization, token, session)
        if denied is not None:
            return denied
        page = ASSET_DIR / "host.html"
        if not page.is_file():
            return JSONResponse({"error": "the genui shell is not installed"}, status_code=503)
        return Response(page.read_bytes(), media_type=ASSETS["host.html"])

    @router.get("/assets/{name}")
    async def asset(
        name: str,
        token: Optional[str] = None,
        session: Optional[str] = None,
        authorization: Optional[str] = Header(default=None),
    ):
        denied = refuse(authorization, token, session)
        if denied is not None:
            return denied
        media_type = ASSETS.get(name)
        if media_type is None:
            return JSONResponse(NO_BOARD, status_code=404)
        path = ASSET_DIR / name
        if not path.is_file():
            return JSONResponse({"error": "asset missing"}, status_code=503)
        return Response(path.read_bytes(), media_type=media_type)

    @router.get("/plugin.js")
    async def plugin_bundle(
        token: Optional[str] = None,
        session: Optional[str] = None,
        authorization: Optional[str] = Header(default=None),
    ):
        """The installed plugin's own bundle: a plugin update reaches the apps with no rebuild."""
        denied = refuse(authorization, token, session)
        if denied is not None:
            return denied
        path = _hermes_home() / Path(*PLUGIN_BUNDLE)
        if not path.is_file():
            return JSONResponse({"error": "the genui plugin is not installed"}, status_code=503)
        return Response(path.read_bytes(), media_type=ASSETS["app.mjs"])

    @router.get("/blocks/{block_id}")
    async def board(
        block_id: str,
        bot: str = "",
        token: Optional[str] = None,
        session: Optional[str] = None,
        authorization: Optional[str] = Header(default=None),
    ):
        denied = refuse(authorization, token, session)
        if denied is not None:
            return denied
        if not ID_PATTERN.match(block_id) or bot_or_404(bot) is None:
            return JSONResponse(NO_BOARD, status_code=404)
        path = _board_path(bot, block_id)
        if not path.is_file():
            return JSONResponse(NO_BOARD, status_code=404)
        try:
            stored = json.loads(path.read_text(encoding="utf-8"))
        except (ValueError, UnicodeDecodeError):
            return JSONResponse(NO_BOARD, status_code=404)
        # The plugin's route answers {"blocks": [...]}; a file written by an older tool may hold the
        # bare list, so both shapes are handed over in the one shape the renderer reads.
        blocks = stored.get("blocks") if isinstance(stored, dict) else stored
        if not isinstance(blocks, list):
            return JSONResponse(NO_BOARD, status_code=404)
        return {"blocks": blocks}

    @router.get("/blocks/{block_id}/state")
    async def board_state(
        block_id: str,
        bot: str = "",
        token: Optional[str] = None,
        session: Optional[str] = None,
        authorization: Optional[str] = Header(default=None),
    ):
        denied = refuse(authorization, token, session)
        if denied is not None:
            return denied
        if not ID_PATTERN.match(block_id) or bot_or_404(bot) is None:
            return JSONResponse(NO_BOARD, status_code=404)
        if not _board_path(bot, block_id).is_file():
            return JSONResponse(NO_BOARD, status_code=404)
        state_path = _board_path(bot, block_id).with_name(f"{block_id}.state.json")
        if not state_path.is_file():
            return {}
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}
        return {"state": state} if isinstance(state, dict) and state else {}

    @router.put("/blocks/{block_id}/state")
    async def save_board_state(
        block_id: str,
        request: Request,
        bot: str = "",
        token: Optional[str] = None,
        session: Optional[str] = None,
        authorization: Optional[str] = Header(default=None),
    ):
        denied = refuse(authorization, token, session)
        if denied is not None:
            return denied
        if not ID_PATTERN.match(block_id) or bot_or_404(bot) is None:
            return JSONResponse(NO_BOARD, status_code=404)
        board = _board_path(bot, block_id)
        if not board.is_file():
            return JSONResponse(NO_BOARD, status_code=404)
        raw = await request.body()
        if len(raw) > BODY_LIMIT:
            return JSONResponse(TOO_BIG, status_code=413)
        try:
            body = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            body = None
        state = body.get("state") if isinstance(body, dict) else None
        if not isinstance(state, dict):
            return JSONResponse({"error": 'body must be {"state": {...}}'}, status_code=400)
        text = json.dumps(state, ensure_ascii=False)
        if len(text.encode("utf-8")) > STATE_LIMIT:
            return JSONResponse(TOO_BIG, status_code=413)
        # Same one-step write the plugin uses: a reader sees the old file or the new one.
        tmp = board.with_name(f"{block_id}.state.json.tmp")
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(board.with_name(f"{block_id}.state.json"))
        return Response(status_code=204)

    return router
