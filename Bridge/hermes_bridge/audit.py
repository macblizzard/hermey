"""Structured audit log with no way to log a payload.

The requirement is blunt: the bridge may record *who* did *what*, for how long and
how many bytes -- never prompt text, never tool output, never a token. Rather than
relying on discipline at every call site, :meth:`AuditLog.emit` only accepts a
fixed set of scalar fields, and every free-form one is matched against a strict
token pattern. A call site cannot pass ``params`` even by accident: there is no
parameter for it.

Each record is one JSON object on one line, so ``journalctl``/``tail`` output stays
machine-readable.
"""

from __future__ import annotations

import json
import logging
import re
import time
from typing import Any, Optional

#: Event names are a closed set -- a typo fails a test instead of shipping silently.
EVENTS = frozenset(
    {
        "ws_open",
        "ws_close",
        "ticket_rejected",
        "client_request",
        "client_response",
        "client_response_dropped",
        "client_request_rejected",
        "server_request",
        "server_request_declined",
        "server_response",
        "notification",
        "unmatched_response",
        "capabilities_sent",
        "frame_too_large",
        "protocol_error",
        "upstream_error",
        "request_abandoned",
        "session_pointer",
        "bot_message", "bots.purge", "bots.routine_state", "rooms.list", "rooms.create", "rooms.send", "rooms.disband", "rooms.rename", "bots.state",
        "display_open", "display_close",
        "history_page", "history_page_miss", "history_paged",
        "http",
    }
)

_SAFE_TOKEN = re.compile(r"^[A-Za-z0-9_.:-]{1,96}$")
_SAFE_PATH = re.compile(r"^/[A-Za-z0-9/_.-]{1,96}$")
_SAFE_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def _token(value: object, fallback: str) -> str:
    if isinstance(value, str) and _SAFE_TOKEN.match(value):
        return value
    return fallback


def _device(value: Optional[str]) -> str:
    if isinstance(value, str) and _SAFE_ID.match(value):
        return value
    return "unknown"


def _millis(value: Optional[float]) -> Optional[float]:
    if value is None:
        return None
    try:
        return round(max(0.0, float(value)) * 1000.0, 1)
    except (TypeError, ValueError):
        return None


class AuditLog:
    """One-line JSON records; an in-memory mirror for assertions in tests."""

    def __init__(self, logger: Optional[logging.Logger] = None, keep: int = 500) -> None:
        self._logger = logger or logging.getLogger("hermes_bridge.audit")
        self._keep = max(0, keep)
        self.records: list[dict[str, Any]] = []

    def emit(
        self,
        event: str,
        *,
        device_id: Optional[str] = None,
        method: object = None,
        path: Optional[str] = None,
        duration_ms: Optional[float] = None,
        nbytes: Optional[int] = None,
        direction: Optional[str] = None,
        outcome: Optional[str] = None,
        reason: Optional[str] = None,
        close_code: Optional[int] = None,
        profile: Optional[str] = None,
    ) -> dict[str, Any]:
        if event not in EVENTS:
            raise ValueError(f"unknown audit event: {event!r}")
        record: dict[str, Any] = {"ts": round(time.time(), 3), "event": event}
        record["device"] = _device(device_id)
        if path is not None:
            record["path"] = path if _SAFE_PATH.match(path) else "invalid"
        if method is not None:
            record["method"] = _token(method, "invalid")
        if duration_ms is not None:
            record["duration_ms"] = _millis(duration_ms)
        if nbytes is not None:
            try:
                record["bytes"] = max(0, int(nbytes))
            except (TypeError, ValueError):
                pass
        if direction is not None:
            record["direction"] = _token(direction, "unknown")
        if outcome is not None:
            record["outcome"] = _token(outcome, "unknown")
        if reason is not None:
            record["reason"] = _token(reason, "other")
        if close_code is not None:
            try:
                record["close_code"] = int(close_code)
            except (TypeError, ValueError):
                pass
        if profile is not None:
            # A profile name is not a secret, but it is still caller-supplied:
            # it goes through the same closed character set as a token.
            record["profile"] = profile if _SAFE_TOKEN.match(profile) else "invalid"

        line = json.dumps(record, separators=(",", ":"), ensure_ascii=True)
        self._logger.info(line)
        if self._keep:
            self.records.append(record)
            if len(self.records) > self._keep:
                del self.records[: len(self.records) - self._keep]
        return record

    # -- test helpers ------------------------------------------------------

    def last(self, event: str) -> Optional[dict[str, Any]]:
        for record in reversed(self.records):
            if record["event"] == event:
                return record
        return None

    def all(self, event: str) -> list[dict[str, Any]]:
        return [r for r in self.records if r["event"] == event]

    def clear(self) -> None:
        self.records.clear()
