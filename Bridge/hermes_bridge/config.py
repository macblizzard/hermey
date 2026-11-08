"""Bridge configuration, read once from the environment.

Two invariants are enforced here rather than in the request path:

* the bridge binds loopback only -- ``tailscale serve`` is what terminates TLS and
  puts it on the tailnet, so a bridge listening on ``0.0.0.0`` would be an
  unauthenticated public endpoint;
* the upstream gateway URL is also loopback. The gateway token is a full-authority
  credential; sending it across a network from this process would defeat the
  point of the bridge.

Anything that fails either check raises :class:`ConfigError` at startup.
"""

from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from .policy import is_valid_method_name

DEFAULT_FRAME_CAP = 1024 * 1024
# An 8 MiB attachment arrives base64-encoded inside one JSON frame (~10.7 MiB), so the
# ceiling has to clear that or uvicorn closes the socket before attachment validation runs.
MAX_FRAME_CAP = 16 * 1024 * 1024
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "localhost"})


class ConfigError(RuntimeError):
    """Raised when the configured bridge would violate a security invariant."""


def default_db_path() -> Path:
    override = os.environ.get("HERMES_BRIDGE_DB")
    if override:
        return Path(override).expanduser()
    state_home = os.environ.get("XDG_STATE_HOME")
    base = Path(state_home).expanduser() if state_home else Path.home() / ".local" / "state"
    return base / "hermes-bridge" / "bridge.db"


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return int(raw, 10)
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer") from exc


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be a number") from exc


def is_loopback_host(host: str) -> bool:
    value = (host or "").strip().lower().strip("[]")
    if value in LOOPBACK_HOSTS:
        return True
    try:
        return ipaddress.ip_address(value).is_loopback
    except ValueError:
        return False


@dataclass(frozen=True)
class BridgeConfig:
    """Everything the app needs, with no secret ever rendered into a response."""

    bind_host: str = "127.0.0.1"
    bind_port: int = 8787
    gateway_url: str = "ws://127.0.0.1:8080/api/ws"
    gateway_token: Optional[str] = None
    db_path: Path = field(default_factory=default_db_path)
    # The default has to clear an 8 MiB image in base64 (~10.7 MiB): at 1 MiB every large photo
    # closed the socket with 1009 instead of attaching, so the ceiling is the documented maximum.
    frame_cap: int = MAX_FRAME_CAP
    connect_timeout: float = 5.0
    max_pending_requests: int = 256
    audit_logger_name: str = "hermes_bridge.audit"
    extra_client_methods: frozenset[str] = frozenset()

    @classmethod
    def from_env(cls) -> "BridgeConfig":
        extra = frozenset(
            item.strip()
            for item in os.environ.get("HERMES_BRIDGE_EXTRA_METHODS", "").split(",")
            if item.strip()
        )
        return cls(
            bind_host=os.environ.get("HERMES_BRIDGE_HOST", "127.0.0.1"),
            bind_port=_env_int("HERMES_BRIDGE_PORT", 8787),
            gateway_url=os.environ.get("HERMES_BRIDGE_GATEWAY_URL", "ws://127.0.0.1:8080/api/ws"),
            gateway_token=os.environ.get("HERMES_BRIDGE_GATEWAY_TOKEN") or None,
            db_path=default_db_path(),
            frame_cap=_env_int("HERMES_BRIDGE_FRAME_CAP", MAX_FRAME_CAP),
            connect_timeout=_env_float("HERMES_BRIDGE_CONNECT_TIMEOUT", 5.0),
            max_pending_requests=_env_int("HERMES_BRIDGE_MAX_PENDING", 256),
            extra_client_methods=extra,
        )

    def with_overrides(self, **changes: object) -> "BridgeConfig":
        return replace(self, **changes)

    def validate(self) -> None:
        if not is_loopback_host(self.bind_host):
            raise ConfigError(
                f"refusing to bind {self.bind_host!r}: the bridge is loopback-only; "
                "expose it with `tailscale serve`, which terminates TLS"
            )
        if not (1 <= self.bind_port <= 65535):
            raise ConfigError("bind_port must be between 1 and 65535")
        if self.frame_cap <= 0 or self.frame_cap > MAX_FRAME_CAP:
            raise ConfigError(f"frame_cap must be between 1 and {MAX_FRAME_CAP} bytes")
        if self.connect_timeout <= 0:
            raise ConfigError("connect_timeout must be positive")
        if self.max_pending_requests <= 0:
            raise ConfigError("max_pending_requests must be positive")
        parts = urlsplit(self.gateway_url)
        if parts.scheme not in {"ws", "wss"}:
            raise ConfigError("gateway_url must be a ws:// or wss:// URL")
        if not is_loopback_host(parts.hostname or ""):
            raise ConfigError(
                "gateway_url must point at loopback: the gateway token never leaves this host"
            )
        if not parts.path:
            raise ConfigError("gateway_url must include a path (for example /api/ws)")
        for method in self.extra_client_methods:
            if not is_valid_method_name(method):
                raise ConfigError(f"invalid method in HERMES_BRIDGE_EXTRA_METHODS: {method!r}")

    # -- upstream credential handling -------------------------------------

    def upstream_url(self) -> str:
        """The real dial URI, token included. Never log or return this."""
        parts = urlsplit(self.gateway_url)
        query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k != "token"]
        if self.gateway_token:
            query.append(("token", self.gateway_token))
        return urlunsplit(
            (parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment)
        )

    def safe_gateway_url(self) -> str:
        """Scheme/host/path only: safe for logs, health output and error strings."""
        parts = urlsplit(self.gateway_url)
        host = parts.hostname or ""
        if ":" in host:
            host = f"[{host}]"
        netloc = f"{host}:{parts.port}" if parts.port else host
        return urlunsplit((parts.scheme, netloc, parts.path, "", ""))
