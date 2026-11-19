"""Fill login cards through a browser extension, so no debugging port is needed.

The CDP path (`credentials_fill`) only works when Hermey launched the browser itself
(`--remote-debugging-port=0`). That covers the bot screen when it is opened from the dock, and nothing
else — not a hand-started browser, and never the owner's browser on their own Mac.

So a browser joins as a **fill target**: an extension connects to this bridge over loopback, and the
bridge sends it a fill. The values travel bridge → extension → page; the bot is never a party to it.

Why loopback and not native messaging: the bridge already trusts loopback (`is_local_host_request`),
so there is no second credential to distribute or lose, and no per-browser host manifest to install.
The extension is loaded into the bot screen's browser by the launcher, and installed normally on the
owner's Mac later.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional

LOGGER = logging.getLogger(__name__)

#: A fill must be quick: the card expires in two minutes and a human is watching the page.
FILL_TIMEOUT_SECONDS = 10


@dataclass
class Browser:
    """One connected browser tab-set, by its own id."""

    id: str
    label: str
    socket: Any
    pending: dict[str, asyncio.Future] = field(default_factory=dict)


class BrowserRegistry:
    """Who is available to receive a fill. Empty is a normal state, not an error."""

    def __init__(self) -> None:
        self.browsers: dict[str, Browser] = {}

    def register(self, label: str, socket: Any) -> Browser:
        browser = Browser(id=uuid.uuid4().hex[:12], label=label, socket=socket)
        self.browsers[browser.id] = browser
        return browser

    def unregister(self, browser_id: str, socket: Any) -> None:
        """Only the socket that owns the entry may remove it (a reconnect must not evict its replacement)."""
        current = self.browsers.get(browser_id)
        if current is not None and current.socket is socket:
            self.browsers.pop(browser_id, None)
            for future in current.pending.values():
                if not future.done():
                    future.set_exception(LookupError("browser disconnected"))

    def on_message(self, browser_id: str, message: dict[str, Any]) -> None:
        browser = self.browsers.get(browser_id)
        if browser is None:
            return
        call_id = message.get("id")
        future = browser.pending.pop(call_id, None) if isinstance(call_id, str) else None
        if future is not None and not future.done():
            future.set_result(bool(message.get("ok")))

    def any(self) -> Optional[Browser]:
        return next(iter(self.browsers.values()), None)

    async def fill(self, values: dict[str, str], *, site: str) -> bool:
        """Ask an extension to put ``values`` on the page. False when nobody is listening."""
        browser = self.any()
        if browser is None:
            LOGGER.info("credentials: no browser extension connected; cannot fill %s", site)
            return False
        call_id = uuid.uuid4().hex
        future: asyncio.Future = asyncio.get_running_loop().create_future()
        browser.pending[call_id] = future
        try:
            await browser.socket.send_json(
                {"id": call_id, "type": "fill", "site": site,
                 "fields": [{"name": name, "value": value} for name, value in values.items()]})
            return await asyncio.wait_for(future, timeout=FILL_TIMEOUT_SECONDS)
        except (asyncio.TimeoutError, LookupError):
            return False
        finally:
            browser.pending.pop(call_id, None)


async def browser_socket(websocket, runtime, registry: BrowserRegistry) -> None:
    """One browser's socket. Registered on the app, beside the computer-use socket.

    Declared on the app rather than on a sub-router on purpose: the sockets that work on this host are
    all `@app.websocket`, and a router-created one closed before accepting (the server answers 403 and
    the browser never connects).
    """
    from fastapi import WebSocketDisconnect

    await websocket.accept()
    try:
        hello = await websocket.receive_json()
    except Exception:  # noqa: BLE001 - a socket that cannot say hello is not a browser
        await websocket.close(code=4400)
        return
    label = str(hello.get("label") or "browser")[:60]
    browser = registry.register(label, websocket)
    runtime.audit.emit("browser.connected", method="browser", path="/v1/browser/ws",
                       outcome="connected", profile=label)
    try:
        while True:
            message = await websocket.receive_json()
            registry.on_message(browser.id, message)
    except WebSocketDisconnect:
        pass
    except Exception:  # noqa: BLE001 - any other end of the socket is the same event
        pass
    finally:
        registry.unregister(browser.id, websocket)
        runtime.audit.emit("browser.disconnected", method="browser", path="/v1/browser/ws",
                           outcome="closed", profile=label)


def create_browser_router(runtime, registry: BrowserRegistry):
    """The HTTP side: what the app asks to know whether a browser is available."""
    from fastapi import APIRouter, Header

    router = APIRouter(prefix="/v1/browser", tags=["browser"])

    @router.get("/targets")
    def targets(authorization: str | None = Header(default=None)) -> dict:
        """What the app shows: is a browser available to receive a sign-in?"""
        return {"browsers": [{"id": b.id, "label": b.label} for b in registry.browsers.values()]}

    return router
