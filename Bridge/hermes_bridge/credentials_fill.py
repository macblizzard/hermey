"""Type a card's values into the bot screen's browser, without telling the bot what they were.

The browser is Chromium running on the bot screen with a DevTools port (`--remote-debugging-port=0`,
which the dock's Browser icon passes and a hand-typed `chrome` does not). This module talks to that
port directly: the value is put into the page by the *bridge*, so it never travels back through the
bot, and the fill returns nothing but whether it worked.

Two hard rules, both learned from this host:

* **A stale `DevToolsActivePort` is normal and must be refused.** The file survives the browser that
  wrote it (this host had one from nine days earlier pointing at a port nothing was listening on).
  So the port is only used after `/json/version` answers.
* **No value is ever logged, raised or returned.** Errors name the *field*, never its content.

The JavaScript uses the native value setter and dispatches `input`/`change`: assigning `.value`
directly leaves React and friends believing the field is still empty, which is a silent failure that
looks like "the site rejected my password".
"""

from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Any, Optional

LOGGER = logging.getLogger(__name__)

#: Where the bot screen's browser keeps its profile, per host.
DEFAULT_PROFILE = Path("/var/lib/hermes/bot-desktop/browser-profile")

#: How long a fill may take, all in. A login form answers in milliseconds; anything slower is a
#: browser that is not really there, and the card is about to expire anyway.
FILL_TIMEOUT_SECONDS = 12

#: Field names a card may carry, mapped to how they are found on the page.
_FIELD_SELECTORS = {
    "password": "input[type=password]",
    "username": "input[type=text], input[type=email], input[name*=user i], input[name*=email i],"
                " input[id*=user i], input[id*=email i]",
    "one-time code": "input[autocomplete*=one-time-code i], input[name*=otp i], input[name*=code i],"
                     " input[id*=otp i], input[id*=code i], input[name*=token i]",
}


def _field_expression(field: str, value: str) -> str:
    """The JavaScript that puts one value into the best matching visible field."""
    selector = _FIELD_SELECTORS.get(field, "input[type=text]")
    literal = json.dumps(value)  # a string literal that cannot break out of the script
    return f"""(function () {{
  const selector = {json.dumps(selector)};
  const value = {literal};
  const visible = el => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const candidates = Array.from(document.querySelectorAll(selector)).filter(visible);
  const el = candidates[0];
  if (!el) return {{filled: false, reason: "no visible field for {field}"}};
  const proto = el instanceof HTMLTextAreaElement
    ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
  setter.call(el, value);
  el.dispatchEvent(new Event("input", {{bubbles: true}}));
  el.dispatchEvent(new Event("change", {{bubbles: true}}));
  el.focus();
  return {{filled: true, field: {json.dumps(field)}}};
}})()"""


def _choice_expression(option: str) -> str:
    """The JavaScript that clicks the sign-in option the owner picked."""
    literal = json.dumps(option.lower())
    return f"""(function () {{
  const wanted = {literal};
  const visible = el => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const nodes = Array.from(document.querySelectorAll('button, a, [role=button], input[type=submit]'));
  const match = nodes.filter(visible).find(el => (el.innerText || el.value || '').toLowerCase().includes(wanted));
  if (!match) return {{clicked: false}};
  match.click();
  return {{clicked: true}};
}})()"""


def devtools_port(profile_dir: Path = DEFAULT_PROFILE) -> Optional[int]:
    """The live DevTools port for the bot screen's browser, or None.

    The file is written by the browser and left behind when it exits, so its presence proves nothing;
    only an answering `/json/version` does.
    """
    try:
        lines = (Path(profile_dir) / "DevToolsActivePort").read_text(encoding="utf-8").splitlines()
        port = int(lines[0].strip())
    except (OSError, ValueError, IndexError):
        return None
    return port if _probe(port) else None


def _probe(port: int) -> bool:
    import urllib.error
    import urllib.request

    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=2) as reply:
            return reply.status == 200
    except (urllib.error.URLError, OSError):
        return False


def _page_socket(port: int) -> Optional[str]:
    """The web socket of the page the owner is looking at (a browser-level socket cannot run JS)."""
    import urllib.request

    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=3) as reply:
            targets = json.loads(reply.read() or b"[]")
    except Exception:  # noqa: BLE001 - an unreadable target list is "no fill", not a crash
        return None
    for target in targets:
        if target.get("type") == "page" and target.get("webSocketDebuggerUrl"):
            return target["webSocketDebuggerUrl"]
    return None


async def _evaluate(socket_url: str, expression: str) -> dict[str, Any]:
    import websockets

    async with websockets.connect(socket_url, open_timeout=4, close_timeout=2) as ws:
        await ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                                  "params": {"expression": expression, "returnByValue": True}}))
        while True:
            raw = await asyncio.wait_for(ws.recv(), timeout=6)
            message = json.loads(raw)
            if message.get("id") == 1:
                result = message.get("result", {}).get("result", {})
                return result.get("value") or {}


async def _fill_async(card, values: dict[str, str], profile_dir: Path) -> bool:
    port = devtools_port(profile_dir)
    if port is None:
        LOGGER.warning("credentials: no live DevTools port; was the browser opened from the dock?")
        return False
    socket_url = _page_socket(port)
    if socket_url is None:
        LOGGER.warning("credentials: no page target to fill")
        return False

    did_something = False
    for field, value in values.items():
        if not value:
            continue
        if field == "choice":
            outcome = await _evaluate(socket_url, _choice_expression(value))
            did_something = did_something or bool(outcome.get("clicked"))
        else:
            outcome = await _evaluate(socket_url, _field_expression(field, value))
            did_something = did_something or bool(outcome.get("filled"))
    return did_something


def fill(card, values: dict[str, str], profile_dir: Path = DEFAULT_PROFILE) -> bool:
    """Fill and return whether anything landed. Never raises with a value in the message."""
    try:
        return asyncio.run(asyncio.wait_for(_fill_async(card, values, profile_dir),
                                            timeout=FILL_TIMEOUT_SECONDS))
    except asyncio.TimeoutError:
        LOGGER.warning("credentials: fill timed out for %s", card.site)
    except Exception as exc:  # noqa: BLE001 - a broken browser must not 500 the card
        LOGGER.warning("credentials: fill failed for %s (%s)", card.site, type(exc).__name__)
    return False
