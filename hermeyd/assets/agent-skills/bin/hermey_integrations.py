#!/usr/bin/env python3
"""What the owner has connected, and what a bot may call for it.

    hermey_integrations.py list
    hermey_integrations.py tools gmail
    hermey_integrations.py connect gmail

`list` says which services the owner has connected. `tools` gives the real tool slugs for one of them —
the names a Composio session accepts, so a bot does not guess `send_email` when the tool is
`GMAIL_SEND_EMAIL`. `connect` asks the owner to connect one: it prints a link for *them*, and waits until
the connection appears.

Acting, not asking: to read mail or create an event, call the Composio tools (this host exposes them to
Hermes). This script tells you which ones exist and whether the account behind them is connected.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

import os


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


POLL_SECONDS = 2.0
CONNECT_TIMEOUT = 180


def _call(bridge: str, method: str, path: str, body: dict | None = None, timeout: float = 60) -> dict:
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


def _connected(bridge: str, slug: str) -> bool:
    state = _call(bridge, "GET", "/v1/integrations")
    for service in state.get("services", []):
        if service.get("slug") == slug:
            return bool(service.get("connected"))
    return False


def cmd_list(bridge: str) -> int:
    state = _call(bridge, "GET", "/v1/integrations")
    if not state.get("configured"):
        print("integrations are not set up on this host: no Composio key")
        return 0
    # A host that could not ask Composio knows nothing about what is connected. Saying "nothing
    # connected yet" here was the lie that made this look like the owner's fault.
    error = state.get("error")
    if error:
        print(f"could not ask Composio ({error}) — this says nothing about what is connected; "
              f"check the key and this host's network, then run list again", file=sys.stderr)
        return 2
    rows = state.get("services", [])
    connected = [r for r in rows if r.get("connected")]
    if not connected:
        print("nothing connected yet — the owner can connect services in Settings → Integrations")
        return 0
    for row in connected:
        accounts = row.get("accounts") or []
        if len(accounts) > 1:
            for account in accounts:
                print(f"{row['slug']}\t{account.get('label') or account.get('id')}")
        else:
            print(f"{row['slug']}\t{row['name']}")
    return 0


def cmd_tools(bridge: str, slug: str) -> int:
    try:
        reply = _call(bridge, "GET", f"/v1/integrations/{slug}/tools")
    except urllib.error.HTTPError as exc:
        print(f"could not list tools: HTTP {exc.code}", file=sys.stderr)
        return 2
    tools = reply.get("tools", [])
    if not tools:
        print(f"no tools listed for {slug}")
        return 0
    connected = _connected(bridge, slug)
    if not connected:
        print(f"note: {slug} is not connected yet — ask the owner, or run: connect {slug}")
    for tool in tools:
        print(f"{tool['slug']}\t{tool.get('name', '')}")
    return 0


def cmd_connect(bridge: str, slug: str, alias: str | None = None) -> int:
    if _connected(bridge, slug):
        print(f"{slug} is already connected")
        return 0
    try:
        body = {"alias": alias} if alias else {}
        reply = _call(bridge, "POST", f"/v1/integrations/{slug}/connect", body, timeout=90)
    except urllib.error.HTTPError as exc:
        print(f"could not start the connection: HTTP {exc.code}", file=sys.stderr)
        return 2
    url = reply.get("url")
    if not url:
        print("the service did not return a link", file=sys.stderr)
        return 2
    print(f"Ask the owner to open this and approve {slug}:")
    print(url)
    print("waiting…", file=sys.stderr)
    waited = 0.0
    while waited < CONNECT_TIMEOUT:
        time.sleep(POLL_SECONDS)
        waited += POLL_SECONDS
        if _connected(bridge, slug):
            print(f"{slug} connected")
            return 0
    print(f"not connected after {int(CONNECT_TIMEOUT)}s — ask the owner, then run list")
    return 0


def cmd_run(bridge: str, tool: str, account: str | None, arguments: str | None) -> int:
    """Run one tool and print its result. This is how a bot actually reads or acts."""
    try:
        args = json.loads(arguments) if arguments else {}
    except json.JSONDecodeError as exc:
        print(f"--args is not JSON: {exc}", file=sys.stderr)
        return 2
    body = {"tool": tool, "arguments": args}
    if account:
        body["account_id"] = account
    try:
        reply = _call(bridge, "POST", "/v1/integrations/run", body, timeout=120)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:200]
        print(f"could not run {tool}: HTTP {exc.code} {detail}", file=sys.stderr)
        return 2
    print(json.dumps(reply.get("result"), indent=2)[:4000])
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Connected integrations and their tool names")
    parser.add_argument("verb", choices=("list", "tools", "connect", "run"))
    parser.add_argument("slug", nargs="?", help="gmail, googlecalendar, googledrive, googledocs, googlesheets, googlemaps")
    parser.add_argument("--alias", default=None, help="connect: a name for this account, e.g. work")
    parser.add_argument("--tool", default=None, help="run: tool slug, e.g. GMAIL_FETCH_EMAILS")
    parser.add_argument("--account", default=None, help="run: which connected account")
    parser.add_argument("--args", default=None, help="run: JSON arguments")
    parser.add_argument("--bridge", default=None,
                        help="main API base URL; only needed to reach a host other than this one")
    args = parser.parse_args()
    bridge, _browser = endpoints(args.bridge)
    if args.verb in ("tools", "connect") and not args.slug:
        parser.error(f"{args.verb} needs a service, e.g. {args.verb} gmail")
    if args.verb == "run":
        if not args.tool:
            parser.error("run needs --tool, e.g. --tool GMAIL_FETCH_EMAILS")
        return cmd_run(bridge, args.tool, args.account, args.args)
    if args.verb == "list":
        return cmd_list(bridge)
    if args.verb == "tools":
        return cmd_tools(bridge, args.slug)
    return cmd_connect(bridge, args.slug, args.alias)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AuthError as exc:
        print(f"hermey_integrations: {exc}", file=sys.stderr)
        sys.exit(3)
