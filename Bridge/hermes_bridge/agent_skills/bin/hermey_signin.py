#!/usr/bin/env python3
"""Ask the owner for a sign-in, then let the bridge fill it. The bot never sees the secret.

    hermey_signin.py ask --site doctolib.de --kind choice --options "Continue with Google" "Email and password"
    hermey_signin.py ask --site doctolib.de --kind secret --fields username password
    hermey_signin.py ask --site doctolib.de --kind secret --fields "one-time code"
    hermey_signin.py ask --site doctolib.de --kind confirm --options "Google — mo@example.com"

`ask` blocks until the owner answers (or the card expires), then asks the bridge to fill it, and prints
one line: `filled` or `not filled — <reason>`. That line is all a bot ever learns. There is no verb here
that prints a value, because the bridge never returns one.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

import os

# The bridge on this host. The skill's examples do not pass --bridge, and bin scripts are installed
# verbatim (only SKILL.md is rendered), so a placeholder here would be a literal "@@BRIDGE@@" at runtime.
DEFAULT_BRIDGE = "http://" + os.environ.get("HERMES_BRIDGE_HOST", "127.0.0.1") + ":" + \
                 os.environ.get("HERMES_BRIDGE_PORT", "8787")
POLL_SECONDS = 1.5


def _call(bridge: str, method: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f"{bridge}{path}", data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=180) as reply:
        return json.loads(reply.read() or b"{}")


def ask(bridge: str, kind: str, site: str, fields: list[str], options: list[str], note: str) -> int:
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
            print("filled" if outcome.get("ok") else "not filled — no browser could take it")
            return 0
    print("not filled — the owner did not answer in time")
    return 0


CONTINUE_WORDS = ("weiter", "continue", "einloggen", "log in", "anmelden", "sign in", "bestätigen", "verify")


def _act(bridge: str, payload: dict) -> dict:
    try:
        return _call(bridge, "POST", "/v1/browser/act", payload, timeout=40)
    except urllib.error.HTTPError:
        return {}


def _probe(bridge: str) -> dict:
    return (_act(bridge, {"type": "probe"}) or {}).get("page") or {}


def _advance(bridge: str) -> str:
    """Click the page's own continue button. Returns the label it clicked, or an empty string."""
    page = _probe(bridge)
    for label in page.get("buttons", []):
        low = label.lower()
        if any(word in low for word in CONTINUE_WORDS):
            if _act(bridge, {"type": "click", "match": label}).get("ok"):
                return label
    return ""


def cmd_login(bridge: str, url: str, site: str, fields: list[str], otp: str | None, note: str) -> int:
    """Whole login in one call: open, ask once, fill each step, handle a one-time code, report the end.

    One card carries every field, and each step is delivered as a slice — the email first, the password on
    the next screen. Asking three times for one login was the slow part of doing this by hand.
    """
    if url:
        _act(bridge, {"type": "goto", "url": url})
        time.sleep(4)

    wanted = fields or ["username", "password"]
    created = _call(bridge, "POST", "/v1/credentials/cards",
                    {"kind": "secret", "site": site, "fields": wanted, "note": note})
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

    steps = 0
    used: list[str] = []
    while steps < 6:
        steps += 1
        page = _probe(bridge)
        if page.get("passwordFields") and "password" in wanted and "password" not in used:
            _call(bridge, "POST", f"/v1/credentials/cards/{card_id}/consume", {"only": ["password"]})
            used.append("password")
        elif page.get("textFields") and "username" in wanted and "username" not in used:
            _call(bridge, "POST", f"/v1/credentials/cards/{card_id}/consume", {"only": ["username"]})
            used.append("username")
        elif page.get("otpBoxes"):
            if otp:
                _act(bridge, {"type": "fill", "fields": [{"name": "one-time code", "value": otp}]})
            else:
                code_card = _call(bridge, "POST", "/v1/credentials/cards",
                                  {"kind": "secret", "site": site, "fields": ["one-time code"],
                                   "note": "The code the site just sent you."})
                code_id = code_card["id"]
                while time.time() < float(code_card.get("expires_at") or time.time() + 120):
                    if _call(bridge, "GET", f"/v1/credentials/cards/{code_id}").get("state") == "answered":
                        break
                    time.sleep(POLL_SECONDS)
                _call(bridge, "POST", f"/v1/credentials/cards/{code_id}/consume", {})
        label = _advance(bridge)
        time.sleep(3)
        after = _probe(bridge)
        if not label and not after.get("passwordFields") and not after.get("otpBoxes"):
            break
        if "login" not in (after.get("url") or "") and "auth" not in (after.get("url") or ""):
            break

    end = _probe(bridge)
    still_login = any(mark in (end.get("url") or "") for mark in ("/login", "authn", "signin"))
    print(("signed in" if not still_login else "not filled — still on the sign-in page")
          + (f" ({end.get('url', '')[:70]})" if end.get("url") else ""))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Ask the owner to sign in, then have the bridge fill it")
    parser.add_argument("verb", choices=("ask", "login"))
    parser.add_argument("--site", required=True, help="the origin you are on, e.g. doctolib.de")
    parser.add_argument("--kind", default="secret", choices=("choice", "secret", "confirm"))
    parser.add_argument("--fields", nargs="*", default=[], help='e.g. username password, or "one-time code"')
    parser.add_argument("--options", nargs="*", default=[], help="the methods the page offers")
    parser.add_argument("--note", default="", help="one line shown to the owner: what you are doing")
    parser.add_argument("--url", default="", help="login: open this page first")
    parser.add_argument("--otp", default=None,
                        help="login: the one-time code, when the bot already fetched it (e.g. from Gmail)")
    parser.add_argument("--bridge", default=DEFAULT_BRIDGE)
    args = parser.parse_args()
    return ask(args.bridge, args.kind, args.site, args.fields, args.options, args.note)


if __name__ == "__main__":
    sys.exit(main())
