"""Persistent device registry (SQLite).

The M0 bridge kept devices in a dict, so a restart silently unpaired every phone
-- and with it revoked state and refresh-token hashes. Devices now live in SQLite:

* only a SHA-256 of the refresh token is stored, never the token itself;
* ``revoked`` is a column, so revoking survives a restart;
* ``public_key`` is the Ed25519 key the device registered at pairing;
* every connection opens its own short-lived connection, guarded by a lock, so
  sync FastAPI handlers running on the threadpool cannot interleave writes.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import sqlite3
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Optional

SCHEMA_VERSION = 2

_SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    device_id           TEXT PRIMARY KEY,
    name                TEXT NOT NULL,
    platform            TEXT NOT NULL,
    public_key          TEXT NOT NULL,
    refresh_token_hash  TEXT NOT NULL,
    created_at          REAL NOT NULL,
    last_seen_at        REAL NOT NULL,
    revoked             INTEGER NOT NULL DEFAULT 0,
    revoked_at          REAL
);
CREATE INDEX IF NOT EXISTS devices_revoked_idx ON devices (revoked);
-- The one conversation both apps mean by "this bot". A row is only rewritten,
-- never deleted: a device that knows no session yet reads NULL.
CREATE TABLE IF NOT EXISTS bot_sessions (
    profile            TEXT PRIMARY KEY,
    stored_session_id  TEXT NOT NULL,
    updated_at         REAL NOT NULL
);
"""


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def token_matches(stored_hash: str, presented: str) -> bool:
    return hmac.compare_digest(stored_hash, hash_token(presented))


@dataclass(frozen=True)
class Device:
    device_id: str
    name: str
    platform: str
    public_key: str
    refresh_token_hash: str
    created_at: float
    last_seen_at: float
    revoked: bool = False

    @classmethod
    def from_row(cls, row: sqlite3.Row) -> "Device":
        return cls(
            device_id=row["device_id"],
            name=row["name"],
            platform=row["platform"],
            public_key=row["public_key"],
            refresh_token_hash=row["refresh_token_hash"],
            created_at=row["created_at"],
            last_seen_at=row["last_seen_at"],
            revoked=bool(row["revoked"]),
        )


class DeviceRegistry:
    def __init__(self, path: Path | str) -> None:
        self.path = str(path)
        self._lock = threading.RLock()
        self._memory = self.path == ":memory:"
        self._memory_conn: Optional[sqlite3.Connection] = None
        if not self._memory:
            parent = Path(self.path).expanduser().parent
            parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._init_schema()

    # -- connection handling ----------------------------------------------

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        if self._memory:
            with self._lock:
                if self._memory_conn is None:
                    self._memory_conn = self._open()
                yield self._memory_conn
            return
        conn = self._open()
        try:
            yield conn
        finally:
            conn.close()

    def _open(self) -> sqlite3.Connection:
        if self._memory:
            conn = sqlite3.connect(":memory:", check_same_thread=False, timeout=5.0)
        else:
            conn = sqlite3.connect(self.path, timeout=5.0)
            try:
                os.chmod(self.path, 0o600)
            except OSError:
                pass
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        if not self._memory:
            conn.execute("PRAGMA journal_mode = WAL")
            conn.execute("PRAGMA synchronous = NORMAL")
        return conn

    def _init_schema(self) -> None:
        with self._connect() as conn:
            conn.executescript(_SCHEMA)
            version = conn.execute("PRAGMA user_version").fetchone()[0]
            if version < SCHEMA_VERSION:
                conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
            conn.commit()

    def close(self) -> None:
        with self._lock:
            if self._memory_conn is not None:
                self._memory_conn.close()
                self._memory_conn = None

    # -- devices -----------------------------------------------------------

    def add_device(
        self,
        *,
        device_id: str,
        name: str,
        platform: str,
        public_key: str,
        refresh_token: str,
        now: Optional[float] = None,
    ) -> Device:
        timestamp = time.time() if now is None else now
        with self._lock, self._connect() as conn:
            conn.execute(
                "INSERT INTO devices (device_id, name, platform, public_key, "
                "refresh_token_hash, created_at, last_seen_at, revoked) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, 0)",
                (
                    device_id,
                    name,
                    platform,
                    public_key,
                    hash_token(refresh_token),
                    timestamp,
                    timestamp,
                ),
            )
            conn.commit()
        device = self.get(device_id)
        if device is None:  # pragma: no cover - insert just succeeded
            raise RuntimeError("device insert vanished")
        return device

    def get(self, device_id: str) -> Optional[Device]:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM devices WHERE device_id = ?", (device_id,)
            ).fetchone()
        return Device.from_row(row) if row else None

    def is_active(self, device_id: str) -> bool:
        device = self.get(device_id)
        return device is not None and not device.revoked

    def list_devices(self) -> list[Device]:
        with self._connect() as conn:
            rows = conn.execute("SELECT * FROM devices ORDER BY created_at").fetchall()
        return [Device.from_row(row) for row in rows]

    def count_active(self) -> int:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT COUNT(*) AS n FROM devices WHERE revoked = 0"
            ).fetchone()
        return int(row["n"])

    def revoke(self, device_id: str, now: Optional[float] = None) -> bool:
        timestamp = time.time() if now is None else now
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                "UPDATE devices SET revoked = 1, revoked_at = ? "
                "WHERE device_id = ? AND revoked = 0",
                (timestamp, device_id),
            )
            conn.commit()
            changed = cur.rowcount > 0
        if not changed:
            # Already revoked is still a success for the caller; unknown is not.
            return self.get(device_id) is not None
        return True

    def touch(self, device_id: str, now: Optional[float] = None) -> None:
        timestamp = time.time() if now is None else now
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE devices SET last_seen_at = ? WHERE device_id = ?",
                (timestamp, device_id),
            )
            conn.commit()

    def delete_revoked(self, device_id: str) -> str:
        """Atomically delete a revoked row; return deleted, active, or missing."""
        with self._lock, self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            cur = conn.execute(
                "DELETE FROM devices WHERE device_id = ? AND revoked = 1", (device_id,)
            )
            if cur.rowcount:
                result = "deleted"
            else:
                row = conn.execute("SELECT 1 FROM devices WHERE device_id = ?", (device_id,)).fetchone()
                result = "active" if row else "missing"
            conn.commit()
            return result

    def verify_refresh(self, device_id: str, presented: str) -> Optional[Device]:
        """Return the device when the refresh token matches and it is not revoked."""
        device = self.get(device_id)
        if device is None or device.revoked:
            return None
        if not token_matches(device.refresh_token_hash, presented):
            return None
        return device

    def rotate_refresh(self, device_id: str, new_token: str) -> bool:
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                "UPDATE devices SET refresh_token_hash = ? WHERE device_id = ? AND revoked = 0",
                (hash_token(new_token), device_id),
            )
            conn.commit()
            return cur.rowcount > 0

    # -- shared per-bot session pointer ------------------------------------

    def get_bot_session(self, profile: str) -> Optional[str]:
        """The stored session id for ``profile``, or ``None`` when unset."""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT stored_session_id FROM bot_sessions WHERE profile = ?",
                (profile,),
            ).fetchone()
        return row["stored_session_id"] if row else None

    def set_bot_session(
        self,
        *,
        profile: str,
        stored_session_id: str,
        now: Optional[float] = None,
    ) -> float:
        """Upsert the pointer; last write wins. Returns ``updated_at``."""
        timestamp = time.time() if now is None else now
        with self._lock, self._connect() as conn:
            conn.execute(
                "INSERT INTO bot_sessions (profile, stored_session_id, updated_at) "
                "VALUES (?, ?, ?) "
                "ON CONFLICT(profile) DO UPDATE SET "
                "stored_session_id = excluded.stored_session_id, "
                "updated_at = excluded.updated_at",
                (profile, stored_session_id, timestamp),
            )
            conn.commit()
        return timestamp
