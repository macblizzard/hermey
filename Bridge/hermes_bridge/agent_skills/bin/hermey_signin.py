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

DEFAULT_BRIDGE = "@@BRIDGE@@"
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


def main() -> int:
    parser = argparse.ArgumentParser(description="Ask the owner to sign in, then have the bridge fill it")
    parser.add_argument("verb", choices=("ask",))
    parser.add_argument("--site", required=True, help="the origin you are on, e.g. doctolib.de")
    parser.add_argument("--kind", default="secret", choices=("choice", "secret", "confirm"))
    parser.add_argument("--fields", nargs="*", default=[], help='e.g. username password, or "one-time code"')
    parser.add_argument("--options", nargs="*", default=[], help="the methods the page offers")
    parser.add_argument("--note", default="", help="one line shown to the owner: what you are doing")
    parser.add_argument("--bridge", default=DEFAULT_BRIDGE)
    args = parser.parse_args()
    return ask(args.bridge, args.kind, args.site, args.fields, args.options, args.note)


if __name__ == "__main__":
    sys.exit(main())
