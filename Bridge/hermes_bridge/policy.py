# THREAT MODEL — read before extending the list below.
#
# Refusing `shell.exec` here does not stop a paired client from running commands on the host:
# `prompt.submit` is allowed, the agent can call its own tools, and the approvals those tools raise
# are relayed back to the socket that submitted the prompt. A device ticket is therefore equivalent
# to shell access as the bridge's user. Say that in docs/SECURITY.md rather than treating this list
# as a sandbox; the smallest real improvement is a host-side confirmation for approval/sudo.
"""What the bridge is willing to carry, and nothing more.

The allow-list is the whole security boundary between a paired phone and a Hermes
host that can run shell commands, edit files and read a vault. It is deliberately
a static frozenset: adding a method is a code change with a test, not a config
flag.

Two directions are policed separately:

``CLIENT_METHODS``
    requests the app may send to the gateway. This is the session/prompt surface
    the UI actually needs. ``shell.exec``, ``cli.exec``, ``config.set``,
    ``vault.*``, ``tools.configure`` and friends are *not* on it: a compromised
    client must not be able to escalate through the bridge.

``SERVER_REQUEST_METHODS``
    requests the gateway may send to the app. Everything here is a human
    decision that must reach a screen (an approval, a clarify, a sudo prompt, a
    secret, a vault code, a terminal read). Anything else is answered ``-32601``
    by the bridge so the agent fails fast instead of waiting out a timeout.
"""

from __future__ import annotations

import re
from typing import TypeGuard

#: Requests the app may send. Read-only browsing + the conversation loop.
CLIENT_METHODS = frozenset(
    {
        # liveness / handshake
        "ping",
        "client.capabilities",
        "gateway.capabilities",
        # bots: a Hermes profile is a bot. The app lists them by name, and scopes
        # `session.list` with `profile` so one gateway serves every bot.
        "profiles.list",
        "profiles.describe",
        "profiles.configure",
        # Creating a bot is one gateway call: it writes the name, the description and SOUL.md.
        # Removing one is not on this list on purpose — the gateway has no such method, so the
        # bridge owns it (`bot_admin.py`, which archives before it deletes).
        "profiles.create",
        # The skills hub, read side only — see `is_skills_manage_allowed` for the action check.
        "skills.manage",
        # sessions
        "session.list",
        "session.active_list",
        "session.most_recent",
        "session.create",
        "session.resume",
        "session.info",
        "session.status",
        "session.history",
        "session.events.since",
        "session.events.stats",
        "session.title",
        "session.close",
        "session.archive",
        "session.delete",
        "session.interrupt",
        "session.steer",
        "session.undo",
        "session.branch",
        "session.compress",
        "session.usage",
        "session.control",
        "session.control.read",
        # prompts
        "prompt.submit",
        "prompt.cancel",
        "prompt.background",
        "prompt.btw",
        "prompt.receipt",
        # answers the app gives as *requests* (not responses) in some flows
        "approval.pending",
        "approval.received",
        "approval.respond",
        "clarify.respond",
        "connection.respond",
        # composer / discovery
        "file.attach",
        "image.attach_bytes",
        "complete.slash",
        "complete.path",
        "commands.catalog",
        "model.options",
        "tools.list",
        "toolsets.list",
        "projects.list",
        "agents.list",
        "subagent.list",
    }
)

#: Requests the gateway may send to the app. These must reach the user.
SERVER_REQUEST_METHODS = frozenset(
    {
        "approval",
        "clarify",
        "sudo",
        "secret",
        "vault.code",
        "terminal.read",
    }
)

_METHOD_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$")

#: The only sections of the gateway's broad profile editor the app may write: the model pair, the
#: human-readable description, and — because the owner asked for switches in the app — the two
#: feature lists ``disabled_skills`` and ``enabled_mcp_servers``. Each is a list of *names*, validated
#: below, capped, and never free text. Everything else (``ui_meta``, skills as files, toolsets…)
#: stays host-only.
#: `soul` is here because the owner asked to edit a bot's SOUL.md from the app. It is a text
#: section with a hard ceiling: a SOUL.md is injected into every turn of that bot, so an accidental
#: paste of a megabyte file would be paid for on every message it ever answers.
_ALLOWED_PROFILE_SECTIONS = frozenset(
    {"name", "model", "provider", "confirm_expensive_model", "description", "soul",
     "disabled_skills", "enabled_mcp_servers"}
)

#: A feature list is a list of installed names, not a place to smuggle a path or a shell fragment.
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
MAX_FEATURE_NAMES = 500


def _is_name_list(value: object) -> bool:
    return (isinstance(value, list) and len(value) <= MAX_FEATURE_NAMES
            and all(isinstance(item, str) and _NAME_RE.match(item) for item in value))


def is_skills_manage_allowed(params: object) -> bool:
    """Only the read side of the skills hub: the app lists what a bot has, it does not install.

    ``skills.manage`` also carries ``install``/``browse``/``inspect`` — writes to the profile's own
    skills directory — so presence on the allow-list is not enough; the action is checked.
    """
    return isinstance(params, dict) and params.get("action", "list") == "list" and set(params) <= {"action", "profile"}

MAX_SOUL_CHARS = 64_000


def is_bot_model_configure_allowed(params: object) -> bool:
    """Allow a profile edit only when it is the model pair and/or the description.

    The gateway's ``profiles.configure`` accepts far more (soul, ui_meta, skills, toolsets, MCP),
    so presence on the allow-list is not enough: the params themselves are checked. ``name`` is
    always required; ``model`` and ``provider`` must come together; ``description`` may be an
    empty string (that clears it). Any unknown key rejects the whole request.
    """
    if not isinstance(params, dict):
        return False
    if set(params) - _ALLOWED_PROFILE_SECTIONS:
        return False
    if not (isinstance(params.get("name"), str) and params["name"].strip()):
        return False

    has_description = "description" in params
    has_model = "model" in params or "provider" in params
    has_soul = "soul" in params
    has_features = "disabled_skills" in params or "enabled_mcp_servers" in params
    if not has_description and not has_model and not has_soul and not has_features:
        return False
    if has_description and not isinstance(params["description"], str):
        return False
    if "disabled_skills" in params and not _is_name_list(params["disabled_skills"]):
        return False
    if "enabled_mcp_servers" in params and not _is_name_list(params["enabled_mcp_servers"]):
        return False
    if has_soul and not (isinstance(params["soul"], str) and len(params["soul"]) <= MAX_SOUL_CHARS):
        return False

    if has_model:
        if not all(isinstance(params.get(key), str) and params[key].strip()
                   for key in ("model", "provider")):
            return False
        if "confirm_expensive_model" in params and type(params["confirm_expensive_model"]) is not bool:
            return False
    elif "confirm_expensive_model" in params:
        # A confirmation only means something next to a model change.
        return False
    return True


def is_valid_method_name(method: object) -> TypeGuard[str]:
    return isinstance(method, str) and bool(_METHOD_RE.match(method))


def build_client_allow_list(extra: frozenset[str] | None = None) -> frozenset[str]:
    """Return the effective allow-list, validating operator additions."""
    allowed = set(CLIENT_METHODS)
    for method in extra or frozenset():
        if not is_valid_method_name(method):
            raise ValueError(f"invalid method name in bridge allow-list: {method!r}")
        allowed.add(method)
    return frozenset(allowed)


def is_client_method_allowed(method: object, extra: frozenset[str] | None = None) -> bool:
    return method in build_client_allow_list(extra)


def is_server_request_allowed(method: object) -> bool:
    return method in SERVER_REQUEST_METHODS
