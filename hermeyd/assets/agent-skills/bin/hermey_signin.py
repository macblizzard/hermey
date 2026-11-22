#!/usr/bin/env python3
"""Ask the owner for a sign-in, then let the browser fill it. The bot never sees the secret.

    hermey_signin.py ask --site doctolib.de --kind choice --options "Continue with Google" "Email and password"
    hermey_signin.py ask --site doctolib.de --kind secret --fields username password
    hermey_signin.py ask --site doctolib.de --kind secret --fields "one-time code"
    hermey_signin.py ask --site doctolib.de --kind confirm --options "Google — mo@example.com"

`ask` blocks until the owner answers (or the card expires), wakes the browser, fills the answer into the
page and prints one line: `filled`, or `not filled — <which failure>`. That line is all a bot ever learns:
no verb here prints a value, and nothing logs one.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


# --- where this host is ------------------------------------------------------------------------
#
# hermeyd serves two loopback listeners and the scripts must not confuse them:
#   * the main API (8788) — cards, integrations, local computers — needs a bearer;
#   * the browser channel (8790) — /v1/browser/* only — carries no device credential.
# An explicit --bridge (or HERMES_BRIDGE_URL) still governs both, so a host that still runs the
# Python bridge works with one override.
DEFAULT_API = "http://127.0.0.1:8788"
DEFAULT_BROWSER = "http://127.0.0.1:8790"
#: The service's local bearer. `HERMEYD_LOCAL_TOKEN` wins; otherwise this file, which sits beside
#: `bin/` in the service's state directory (`<state>/local.token`, mode 0600).
TOKEN_FILE = os.environ.get("HERMEYD_LOCAL_TOKEN_FILE") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "local.token")


class AuthError(RuntimeError):
    """No usable local bearer. The message says where we looked, never what was there."""


def local_token() -> str:
    value = os.environ.get("HERMEYD_LOCAL_TOKEN", "").strip()
    if value:
        return value
    try:
        with open(TOKEN_FILE, encoding="utf-8") as handle:
            token = handle.read().strip()
    except OSError as exc:
        raise AuthError(
            f"no local bearer: set HERMEYD_LOCAL_TOKEN, or make {TOKEN_FILE} readable ({exc.strerror})"
        ) from None
    if not token:
        raise AuthError(f"the local bearer file {TOKEN_FILE} is empty")
    return token


def auth_header() -> dict:
    return {"Authorization": f"Bearer {local_token()}"}


def endpoints(bridge: str | None = None, browser: str | None = None) -> tuple[str, str]:
    """(main API, browser channel). `--bridge` governs both, as it did on the Python bridge."""
    api = (bridge or os.environ.get("HERMEYD_API_URL") or os.environ.get("HERMES_BRIDGE_URL")
           or DEFAULT_API).rstrip("/")
    compat = bridge or os.environ.get("HERMES_BRIDGE_URL")
    channel = browser or os.environ.get("HERMEYD_BROWSER_URL") or compat or DEFAULT_BROWSER
    return api, channel.rstrip("/")


POLL_SECONDS = 1.5
#: How long a fill will wait for the sign-in extension after the owner answers. An MV3 worker is
#: suspended between events and its loopback socket goes with it — exactly when an answer arrives. Its
#: own reconnect backoff tops out at 30 s, so the wait is bounded and generous, not instant.
BROWSER_WAIT_SECONDS = float(os.environ.get("HERMEY_BROWSER_WAIT_SECONDS") or 20.0)


def _call(bridge: str, method: str, path: str, body: dict | None = None,
          timeout: float = 180) -> dict:
    """One HTTP call to the main API (`bridge`) or the browser channel, with the local bearer."""
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f"{bridge}{path}", data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    for name, value in auth_header().items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as reply:
            return json.loads(reply.read() or b"{}")
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            raise AuthError(
                f"the service refused the local bearer (401) — restart hermeyd to mint a new one "
                f"at {TOKEN_FILE}") from None
        raise


def ask(bridge: str, channel: str, kind: str, site: str, fields: list[str], options: list[str],
        note: str) -> int:
    try:
        created = _call(bridge, "POST", "/v1/credentials/cards",
                        {"kind": kind, "site": site, "fields": fields,
                         "options": options, "note": note})
    except urllib.error.HTTPError as exc:
        print(f"could not ask: HTTP {exc.code}", file=sys.stderr)
        return 2
    card_id = created["id"]
    expires = float(created.get("expires_at") or (time.time() + 120))
    print(f"asked the owner for {site} ({kind}); waiting…", file=sys.stderr)

    while time.time() < expires:
        time.sleep(POLL_SECONDS)
        try:
            card = _call(bridge, "GET", f"/v1/credentials/cards/{card_id}")
        except urllib.error.HTTPError as exc:
            print(f"not filled — the card vanished (HTTP {exc.code})")
            return 0
        state = card.get("state")
        if state == "cancelled":
            print("not filled — the owner cancelled")
            return 0
        if state == "expired":
            print("not filled — the owner did not answer in time")
            return 0
        if state == "answered":
            try:
                outcome = _call(bridge, "POST", f"/v1/credentials/cards/{card_id}/consume", {})
            except urllib.error.HTTPError as exc:
                print(f"not filled — HTTP {exc.code}")
                return 0
            # `consume` hands the answer over exactly once and keeps nothing; the fill is ours to do.
            # The old code read an `ok` this route never returns, so every answered card ended in
            # "not filled" — that, not a stale page, is why the value never appeared.
            values = outcome.get("values") or {}
            print(_deliver(channel, values, fields or list(values)))
            return 0
    print("not filled — the owner did not answer in time")
    return 0


CONTINUE_WORDS = ("weiter", "continue", "einloggen", "log in", "anmelden", "sign in", "bestätigen", "verify")


def _ping(bridge: str) -> bool:
    """Wake the extension's worker and prove its socket and listener are alive.

    A ping is answered before the worker touches the page, so it separates "nothing is connected" from
    "the page is wrong" — and sending one is what brings a suspended MV3 worker back.
    """
    try:
        reply = _call(bridge, "POST", "/v1/browser/act", {"type": "ping"}, timeout=10)
    except Exception:  # noqa: BLE001 — no browser connected is the ordinary case here
        return False
    return bool(reply.get("ready") or reply.get("ok"))


def _targets(bridge: str) -> list:
    try:
        return _call(bridge, "GET", "/v1/browser/targets", timeout=10).get("browsers") or []
    except Exception:  # noqa: BLE001
        return []


def _await_browser(bridge: str, seconds: float = BROWSER_WAIT_SECONDS) -> bool:
    """Wake the worker and wait for a registered target before every instruction that needs one.

    The worker sleeps between events and its socket closes with it, so `/targets` is empty exactly when
    an answer lands and the fill that follows is refused — `no browser connected`. A ping wakes it and
    polling `/targets` says when it is back. Filling on the first attempt without this is what made the
    owner's answer arrive, get consumed, and go nowhere.
    """
    deadline = time.time() + seconds
    started = time.time()
    announced = False
    while True:
        if _ping(bridge) or _targets(bridge):
            if announced:
                print(f"  the sign-in extension is back after {time.time() - started:.1f}s",
                      file=sys.stderr)
            return True
        if time.time() >= deadline:
            return False
        if not announced:
            print(f"  waiting up to {seconds:.0f}s for the sign-in extension to reconnect…",
                  file=sys.stderr)
            announced = True
        time.sleep(1.5)


def _act(bridge: str, payload: dict, wait: bool = True) -> dict | None:
    """One instruction for the browser. None means no browser took it: asleep, closed, or silent."""
    if wait and not _await_browser(bridge):
        return None
    try:
        return _call(bridge, "POST", "/v1/browser/act", payload, timeout=40)
    except (urllib.error.HTTPError, urllib.error.URLError, OSError):
        # 409 `no browser connected` when the worker slept between our probe and this call; a timeout
        # when it went away mid-instruction. Both mean the same thing to the caller: nothing happened.
        return None


def _acted(bridge: str, payload: dict) -> bool:
    return bool((_act(bridge, payload) or {}).get("ok"))


def _probe(bridge: str) -> dict:
    """The page in front of the browser: field counts and labels, never a value."""
    return (_act(bridge, {"type": "probe"}) or {}).get("page") or {}


# --- what went wrong, said precisely ------------------------------------------------------------
#
# One sentence used to cover three different faults — no browser, no matching field, a fill the page
# threw away — and the bot could do nothing with it. Each now has its own line and its own evidence.

def _href(page: dict, limit: int = 120) -> str:
    return (page.get("url") or "?")[:limit]


def _seen(page: dict, limit: int = 6) -> str:
    """The probe's own words for what the page offered: field names by kind, then its buttons."""
    rows = []
    for field in (page.get("fields") or [])[:limit]:
        kind = field.get("type") or "text"
        if field.get("autocomplete"):
            kind += f"/{field['autocomplete']}"
        rows.append(f"{field.get('name') or '?'} [{kind}]")
    buttons = ", ".join((page.get("buttons") or [])[:4])
    parts = [", ".join(rows) or "no fields"]
    if buttons:
        parts.append(f"buttons: {buttons}")
    if not page:
        parts = ["the page could not be read"]
    return "; ".join(parts)


def _no_browser(channel: str, seconds: float) -> str:
    return (f"not filled — no browser connected: waited {seconds:.0f}s for the sign-in extension and "
            f"{channel} still lists no target (the worker is asleep and its socket is closed); "
            f"nothing was filled")


def _no_field(page: dict, wanted: list[str]) -> str:
    asked = ", ".join(wanted) or "the answer"
    return (f"not filled — a browser is connected but its page has no field matching {asked}: "
            f"{_href(page)} — the probe saw {_seen(page)}")


def _did_not_land(page: dict, name: str, state: str) -> str:
    return (f"not filled — the fill was sent but the value did not land: the {name} field on "
            f"{_href(page, 90)} now reads {state}")


# --- did it land? asked of the page, never of the value ------------------------------------------
#
# The extension answers with counts and never a value, so "the fill was sent but the page dropped it"
# is invisible to a probe. A browser this host started exposes its DevTools endpoint on loopback, and
# one evaluated question — does the field hold anything — answers `set`, `empty` or `absent` and
# nothing else. When no endpoint is discoverable (the extension may live on another machine) the check
# is skipped and the extension's own `ok` stands.

PICKERS = {
    "password": "input[type=password]",
    "username": ("input[type=text], input[type=email], input[name*=user i], input[name*=email i],"
                 " input[id*=user i], input[id*=email i]"),
    "one-time code": ("input[autocomplete*=one-time-code i], input[name*=code i], input[name*=otp i],"
                      " input[id*=token i]"),
}

#: Answers with `set` / `empty` / `absent` per field. Lengths and booleans only — never the text.
_STATE_JS = """
(() => {
  const vis = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const pickers = %s;
  const out = {};
  for (const name of %s) {
    const el = Array.from(document.querySelectorAll(pickers[name] || "input[type=text]"))
      .filter(vis)[0];
    out[name] = !el ? "absent" : (el.value ? "set" : "empty");
  }
  return out;
})()
"""


def _cdp_port_files() -> list[str]:
    """Where browsers on this host wrote their chosen DevTools port.

    `--remote-debugging-port=0` means Chrome picked a port at random and recorded it beside its
    profile, so there is no number to guess at: the process list names the profile directory.
    """
    files: list[str] = []
    try:
        listing = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True,
                                 timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return files
    for line in listing.splitlines():
        if "remote-debugging-port" not in line or "user-data-dir=" not in line:
            continue
        profile = line.split("user-data-dir=", 1)[1].split(" ", 1)[0]
        files.append(os.path.join(profile, "DevToolsActivePort"))
    return files[:4]


def _cdp_base() -> str | None:
    port = os.environ.get("HERMEY_CDP_PORT", "").strip()
    if port.isdigit():
        return f"http://127.0.0.1:{port}"
    explicit = os.environ.get("HERMEY_CDP_FILE", "").strip()
    for path in ([explicit] if explicit else []) + _cdp_port_files():
        try:
            with open(path, encoding="utf-8") as handle:
                first = handle.readline().strip()
        except OSError:
            continue
        if first.isdigit():
            return f"http://127.0.0.1:{first}"
    return None


def _ws_frame(payload: bytes) -> bytes:
    """One masked client text frame — the only thing this needs to send."""
    mask = os.urandom(4)
    head = bytearray([0x81])
    size = len(payload)
    if size < 126:
        head.append(0x80 | size)
    elif size < 65536:
        head.append(0x80 | 126)
        head += struct.pack(">H", size)
    else:
        head.append(0x80 | 127)
        head += struct.pack(">Q", size)
    head += mask
    return bytes(head) + bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))


def _ws_read(sock: socket.socket, buffered: bytes) -> tuple[bytes | None, bytes]:
    """Read whole frames until one carries text; returns (payload, leftover)."""
    while True:
        while len(buffered) < 2:
            chunk = sock.recv(65536)
            if not chunk:
                return None, b""
            buffered += chunk
        first, second = buffered[0], buffered[1]
        offset, size = 2, second & 0x7F
        if size == 126:
            while len(buffered) < 4:
                chunk = sock.recv(65536)
                if not chunk:
                    return None, b""
                buffered += chunk
            size, offset = struct.unpack(">H", buffered[2:4])[0], 4
        elif size == 127:
            while len(buffered) < 10:
                chunk = sock.recv(65536)
                if not chunk:
                    return None, b""
                buffered += chunk
            size, offset = struct.unpack(">Q", buffered[2:10])[0], 10
        while len(buffered) < offset + size:
            chunk = sock.recv(65536)
            if not chunk:
                return None, b""
            buffered += chunk
        payload, rest = buffered[offset:offset + size], buffered[offset + size:]
        if first & 0x0F == 0x1:
            return payload, rest
        buffered = rest  # ping / pong / close / binary: not an answer, keep reading


def _ws_eval(ws_url: str, expression: str, timeout: float = 3.0):
    """One `Runtime.evaluate` over a bare WebSocket: enough for a DevTools question, no dependency."""
    parts = urllib.parse.urlsplit(ws_url)
    host, port = parts.hostname or "127.0.0.1", parts.port or 80
    path = parts.path + (f"?{parts.query}" if parts.query else "")
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
    except OSError:
        return None
    try:
        # No Origin header: Chrome refuses a DevTools handshake that carries one.
        sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
                      f"Connection: Upgrade\r\nSec-WebSocket-Key: {base64.b64encode(os.urandom(16)).decode()}\r\n"
                      f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(4096)
            if not chunk:
                return None
            head += chunk
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            return None
        buffered = head.split(b"\r\n\r\n", 1)[1]
        request = {"id": 1, "method": "Runtime.evaluate",
                   "params": {"expression": expression, "returnByValue": True}}
        sock.sendall(_ws_frame(json.dumps(request).encode()))
        for _ in range(20):
            frame, buffered = _ws_read(sock, buffered)
            if frame is None:
                return None
            if not frame:
                continue
            try:
                message = json.loads(frame)
            except ValueError:
                continue
            if message.get("id") == 1:
                return ((message.get("result") or {}).get("result") or {}).get("value")
        return None
    except (OSError, ValueError):
        return None
    finally:
        sock.close()


def _field_state(page: dict, wanted: list[str]) -> tuple[str | None, str]:
    """('set'|'empty'|None, field) for the fields just filled — never the value behind them."""
    base = _cdp_base()
    if not base:
        return None, ""
    try:
        with urllib.request.urlopen(f"{base}/json/list", timeout=2) as reply:
            tabs = json.loads(reply.read() or b"[]")
    except Exception:  # noqa: BLE001 — no endpoint is not a failure of the fill
        return None, ""
    pages = [t for t in tabs if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
    if not pages:
        return None, ""
    here = (page.get("url") or "").split("?")[0][:80]
    match = next((t for t in pages if (t.get("url") or "").split("?")[0][:80] == here), pages[0])
    names = [name for name in wanted if name in PICKERS] or wanted
    answer = _ws_eval(match["webSocketDebuggerUrl"],
                      _STATE_JS % (json.dumps(PICKERS), json.dumps(names)))
    if not isinstance(answer, dict):
        return None, ""
    if any(answer.get(name) == "empty" for name in names):
        return "empty", next(name for name in names if answer.get(name) == "empty")
    if any(answer.get(name) == "set" for name in names):
        return "set", next(name for name in names if answer.get(name) == "set")
    return None, ""


def _field_matches(page: dict, name: str) -> bool:
    """Would the extension find a field for this name on this page? Same rules it fills by."""
    if name == "password":
        return bool(page.get("passwordFields"))
    if name == "username":
        return bool(page.get("usernameFields"))
    if name == "one-time code":
        return bool(page.get("otpBoxes"))
    if name == "choice":
        return bool(page.get("buttons"))
    return bool(page.get("fields"))


def _fill(bridge: str, values: dict, wanted: list[str]) -> dict | None:
    fields = [{"name": name, "value": values[name]} for name in wanted if values.get(name)]
    return _act(bridge, {"type": "fill", "fields": fields}, wait=False)


def _deliver(channel: str, values: dict, wanted: list[str]) -> str:
    """Wake the browser, fill the answer, and say which of the three things went wrong if it did not.

    `filled` means the value reached the page and, where the page can be asked, it still holds it.
    """
    wanted = [name for name in (wanted or list(values)) if values.get(name)]
    if not wanted:
        return "not filled — the answer came back empty; nothing was filled"
    started = time.time()
    # Two windows, not one: the extension's own reconnect backoff alone can eat 30 s, and a fill that
    # arrives a few seconds later is worth far more than a bot that has to ask the owner again.
    for _ in range(2):
        if _await_browser(channel):
            break
    else:
        return _no_browser(channel, time.time() - started)
    page = _probe(channel)
    if not page:
        # A probe with no page behind it is a browser that left between the wait and the ask.
        if not _await_browser(channel):
            return _no_browser(channel, time.time() - started)
        page = _probe(channel)
    missing = [name for name in wanted if not _field_matches(page, name)]
    if missing:
        # The SPA paints its form a beat after the URL settles: one re-probe covers that race.
        time.sleep(1.5)
        page = _probe(channel) or page
        if [name for name in wanted if not _field_matches(page, name)]:
            return _no_field(page, wanted)
    here = page.get("url") or ""
    reply = None
    for attempt in (1, 2):
        reply = _fill(channel, values, wanted)
        if (reply or {}).get("ok"):
            break
        if attempt == 2:
            break
        time.sleep(1.5)
        after = _probe(channel)
        if not after or (after.get("url") or "") != here:
            # It navigated under us: a second fill would land on a different page, so stop here.
            return _no_field(after or page, wanted)
        page = after
    if reply is None:
        # The socket went away mid-fill: that is the first failure, not the second, and saying "no
        # field matched" here would send the bot looking at a page that was never the problem.
        _await_browser(channel)
        return _no_browser(channel, time.time() - started)
    if not reply.get("ok"):
        return _no_field(page, wanted)
    state, name = _field_state(page, wanted)
    if state == "empty":
        return _did_not_land(page, name, state)
    return "filled"


def _ensure_form(bridge: str, url: str, page: dict) -> dict:
    """Make sure a sign-in form is in front of the browser before filling anything.

    A card can sit unanswered for minutes, and the site does not wait: Doctolib's sign-in step fell back to
    the homepage while the owner was typing, so the fill arrived at a page with no field to fill. Re-entering
    the form at fill time is what makes a human-speed answer possible at all.
    """
    if _looks_like_login(page):
        return page
    if url:
        _act(bridge, {"type": "goto", "url": url})
        time.sleep(4)
    page = _find_login_form(bridge)
    _trace(0, page, "re-entered the sign-in form before filling")
    return page


def _advance(bridge: str) -> str:
    """Advance the form: its own submit control, not a label we guessed at."""
    page = _probe(bridge)
    if page.get("submitLabel"):
        if _acted(bridge, {"type": "submit"}):
            return page["submitLabel"]
    for label in page.get("buttons", []):
        low = label.lower()
        if any(word in low for word in CONTINUE_WORDS):
            if _acted(bridge, {"type": "click", "match": label}):
                return label
    return ""


LOGIN_WORDS = ("log in", "login", "einloggen", "anmelden", "sign in", "connexion", "accedi")

#: A sign-in page is not always "a password box". Keycloak (Doctolib, many others) asks for the email first
#: and shows the password on the NEXT screen — so requiring a password field rejected the real login page.
LOGIN_URL_HINTS = ("auth", "login", "signin", "sign-in", "connexion", "anmelden", "sso", "oauth")


def _looks_like_login(page: dict) -> bool:
    """A sign-in form, judged by its fields rather than its wording.

    Reading the DOM means this works on sites and languages never seen before: a password field, or a
    username/email field on a page that is a form or an auth URL. Text matching was per-site and, on one
    site, filled a search box.
    """
    if page.get("passwordFields"):
        return True
    if not page.get("usernameFields"):
        return False
    url = (page.get("url") or "").lower()
    return bool(page.get("formPresent")) or any(hint in url for hint in LOGIN_URL_HINTS)


def _trace(step: int, page: dict, action: str) -> None:
    """One line per step, on stderr: the url, what the page offered, and what was done about it."""
    print(f"  step {step}: {(page.get('url') or '?')[:60]} "
          f"text={page.get('textFields', 0)} pw={page.get('passwordFields', 0)} "
          f"otp={page.get('otpBoxes', 0)} -> {action}", file=sys.stderr)


def _find_login_form(bridge: str, attempts: int = 3) -> dict:
    """The page's login form, clicking through to it if the site lands you on a homepage first.

    Doctolib's /patient/login redirects to the homepage, which has search boxes and a "Log in" button. Asking
    for a card there filled a SEARCH box with the owner's email — the fill matched "a visible text field" and
    the page had two. So nothing is asked for until a password field exists.
    """
    page = _probe(bridge)
    for attempt in range(attempts):
        if _looks_like_login(page):
            _trace(attempt + 1, page, "this is the sign-in page")
            return page
        # Click the labelled control first: following an href on a choice screen lands on the same page
        # (Doctolib's "Log in" is a self-link), which looked like progress in the trace and moved nothing.
        label = next((b for b in page.get("buttons", [])
                      if any(w in b.lower() for w in LOGIN_WORDS)), None)
        if label:
            _act(bridge, {"type": "click", "match": label})
            time.sleep(4)
            page = _probe(bridge)
            _trace(attempt + 1, page, f"clicked {label!r}")
            continue
        here = (page.get("url") or "").split("?")[0]
        link = next((l for l in (page.get("loginLinks") or [])
                     if l.get("href") and l["href"] not in (here, "#", "")), None)
        if link:
            _act(bridge, {"type": "clickHref", "match": link["href"]})
            time.sleep(4)
            page = _probe(bridge)
            _trace(attempt + 1, page, f"followed {link['href'][:40]!r}")
            continue
        break
    return page


def cmd_login(bridge: str, browser: str, url: str, site: str, fields: list[str], otp: str | None,
              note: str) -> int:
    """Whole login in one call: open, ask once, fill each step, handle a one-time code, report the end.

    One card carries every field, and each step is delivered as a slice — the email first, the password on
    the next screen. Asking three times for one login was the slow part of doing this by hand.
    """
    if url:
        _act(browser, {"type": "goto", "url": url})
        time.sleep(4)

    page = _find_login_form(browser)
    if not _looks_like_login(page):
        shown = page.get("url") or "the page"
        print(f"not filled — no sign-in page at {shown} "
              f"({page.get('textFields', 0)} text field(s), no password field); nothing was asked of you")
        return 0

    wanted = fields or ["username", "password"]
    created = _call(bridge, "POST", "/v1/credentials/cards",
                    {"kind": "secret", "site": site, "fields": wanted, "note": note, "ttl": 600})
    card_id = created["id"]
    expires = float(created.get("expires_at") or (time.time() + 120))
    print(f"asked the owner for {site}: {', '.join(wanted)}", file=sys.stderr)

    def answered() -> bool:
        while time.time() < expires:
            state = _call(bridge, "GET", f"/v1/credentials/cards/{card_id}").get("state")
            if state == "answered":
                return True
            if state in ("cancelled", "expired"):
                return False
            time.sleep(POLL_SECONDS)
        return False

    if not answered():
        print("not filled — the owner did not answer")
        return 0

    # Consume once: the route hands the answer over a single time. Reading it per step — which is what
    # this did — meant every step after the first asked a spent card for its values and filled nothing.
    values = (_call(bridge, "POST", f"/v1/credentials/cards/{card_id}/consume", {})
              .get("values") or {})

    steps = 0
    used: list[str] = []
    while steps < 6:
        steps += 1
        page = _probe(browser)
        if page.get("passwordFields") and "password" in wanted and "password" not in used:
            _await_browser(browser)
            page = _ensure_form(browser, url, _probe(browser))
            print(f"  {_deliver(browser, values, ['password'])}", file=sys.stderr)
            used.append("password")
        elif (page.get("usernameFields") or page.get("textFields")) and "username" in wanted \
                and "username" not in used:
            _await_browser(browser)
            page = _ensure_form(browser, url, _probe(browser))
            print(f"  {_deliver(browser, values, ['username'])}", file=sys.stderr)
            used.append("username")
        elif page.get("otpBoxes"):
            if otp:
                _deliver(browser, {"one-time code": otp}, ["one-time code"])
            else:
                code_card = _call(bridge, "POST", "/v1/credentials/cards",
                                  {"kind": "secret", "site": site, "fields": ["one-time code"],
                                   "note": "The code the site just sent you."})
                code_id = code_card["id"]
                while time.time() < float(code_card.get("expires_at") or time.time() + 120):
                    if _call(bridge, "GET", f"/v1/credentials/cards/{code_id}").get("state") == "answered":
                        break
                    time.sleep(POLL_SECONDS)
                code = _call(bridge, "POST", f"/v1/credentials/cards/{code_id}/consume",
                             {}).get("values") or {}
                _deliver(browser, code, ["one-time code"])
        label = _advance(browser)
        time.sleep(3)
        after = _probe(browser)
        if not label and not after.get("passwordFields") and not after.get("otpBoxes"):
            break
        if "login" not in (after.get("url") or "") and "auth" not in (after.get("url") or ""):
            break

    end = _probe(browser)
    still_login = any(mark in (end.get("url") or "") for mark in ("/login", "authn", "signin"))
    print(("signed in" if not still_login else "not filled — still on the sign-in page")
          + (f" ({end.get('url', '')[:70]})" if end.get("url") else ""))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Ask the owner to sign in, then have the browser fill it")
    parser.add_argument("verb", choices=("ask", "login"))
    parser.add_argument("--site", required=True, help="the origin you are on, e.g. doctolib.de")
    parser.add_argument("--kind", default="secret", choices=("choice", "secret", "confirm"))
    parser.add_argument("--fields", nargs="*", default=[], help='e.g. username password, or "one-time code"')
    parser.add_argument("--options", nargs="*", default=[], help="the methods the page offers")
    parser.add_argument("--note", default="", help="one line shown to the owner: what you are doing")
    parser.add_argument("--url", default="", help="login: open this page first")
    parser.add_argument("--otp", default=None,
                        help="login: the one-time code, when the bot already fetched it (e.g. from Gmail)")
    parser.add_argument("--bridge", default=None,
                        help="main API base URL; only needed to reach a host other than this one")
    parser.add_argument("--browser", default=None,
                        help="browser-channel base URL; defaults to the main API when --bridge is given")
    args = parser.parse_args()
    bridge, browser = endpoints(args.bridge, args.browser)
    if args.verb == "login":
        return cmd_login(bridge, browser, args.url, args.site, args.fields, args.otp, args.note)
    return ask(bridge, browser, args.kind, args.site, args.fields, args.options, args.note)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AuthError as exc:
        print(f"hermey_signin: {exc}", file=sys.stderr)
        sys.exit(3)
