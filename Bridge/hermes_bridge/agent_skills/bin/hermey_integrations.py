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

# The bridge on this host. The skill's examples do not pass --bridge, and bin scripts are installed
# verbatim (only SKILL.md is rendered), so a placeholder here would be a literal "@@BRIDGE@@" at runtime.
DEFAULT_BRIDGE = "http://" + os.environ.get("HERMES_BRIDGE_HOST", "127.0.0.1") + ":" + \
                 os.environ.get("HERMES_BRIDGE_PORT", "8787")
POLL_SECONDS = 2.0
CONNECT_TIMEOUT = 180


def _call(bridge: str, method: str, path: str, body: dict | None = None, timeout: float = 60) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f"{bridge}{path}", data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=timeout) as reply:
        return json.loads(reply.read() or b"{}")


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
        print("the bridge did not return a link", file=sys.stderr)
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
    parser.add_argument("--bridge", default=DEFAULT_BRIDGE)
    args = parser.parse_args()
    if args.verb in ("tools", "connect") and not args.slug:
        parser.error(f"{args.verb} needs a service, e.g. {args.verb} gmail")
    if args.verb == "run":
        if not args.tool:
            parser.error("run needs --tool, e.g. --tool GMAIL_FETCH_EMAILS")
        return cmd_run(args.bridge, args.tool, args.account, args.args)
    if args.verb == "list":
        return cmd_list(args.bridge)
    if args.verb == "tools":
        return cmd_tools(args.bridge, args.slug)
    return cmd_connect(args.bridge, args.slug, args.alias)


if __name__ == "__main__":
    sys.exit(main())
