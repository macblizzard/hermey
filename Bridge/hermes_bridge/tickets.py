"""Short-lived pairing codes and single-use WebSocket tickets.

Both are bearer secrets with a tiny lifetime, so they are stored as SHA-256
digests: a heap dump, a debug endpoint or an accidental ``repr`` cannot replay
one. The ticket store is also where "single use" and "bound to a device" are
enforced -- redemption pops the entry under a lock, so two concurrent upgrades
cannot both win.

``AttemptThrottle`` slows down guessing of the 8-digit pairing code, which is the
one unauthenticated endpoint that accepts a secret.
"""

from __future__ import annotations

import hashlib
import secrets
import threading
import time
from collections import OrderedDict, deque
from typing import Callable, Deque, Dict, Optional, Tuple


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


class PairingCodes:
    """Mint/redeem 8-digit pairing codes; hashed at rest, single use, TTL'd."""

    def __init__(
        self,
        ttl: float = 120.0,
        max_outstanding: int = 64,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.ttl = ttl
        self.max_outstanding = max_outstanding
        self._clock = clock
        self._lock = threading.Lock()
        self._codes: Dict[str, float] = {}

    def mint(self) -> Tuple[str, float]:
        self.purge()
        with self._lock:
            if len(self._codes) >= self.max_outstanding:
                # Evict the soonest-to-expire outstanding code rather than grow.
                oldest = min(self._codes, key=self._codes.__getitem__)
                self._codes.pop(oldest, None)
            code = f"{secrets.randbelow(10**8):08d}"
            expires = self._clock() + self.ttl
            self._codes[_digest(code)] = expires
        return code, expires

    def redeem(self, code: str) -> bool:
        if not isinstance(code, str) or not code.strip():
            return False
        key = _digest(code.strip())
        with self._lock:
            expires = self._codes.pop(key, None)
        return expires is not None and expires >= self._clock()

    def purge(self) -> int:
        now = self._clock()
        with self._lock:
            expired = [key for key, exp in self._codes.items() if exp < now]
            for key in expired:
                self._codes.pop(key, None)
        return len(expired)

    def __len__(self) -> int:
        return len(self._codes)


class TicketStore:
    """Single-use, 30 s WS tickets bound to exactly one device."""

    def __init__(
        self,
        ttl: float = 30.0,
        max_pending: int = 1024,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.ttl = ttl
        self.max_pending = max_pending
        self._clock = clock
        self._lock = threading.Lock()
        # digest -> (expires_at, device_id); insertion ordered for eviction
        self._tickets: "OrderedDict[str, Tuple[float, str]]" = OrderedDict()

    def mint(self, device_id: str) -> str:
        ticket = secrets.token_urlsafe(32)
        now = self._clock()
        with self._lock:
            self._purge_locked(now)
            while len(self._tickets) >= self.max_pending:
                self._tickets.popitem(last=False)
            self._tickets[_digest(ticket)] = (now + self.ttl, device_id)
        return ticket

    def redeem(self, ticket: str) -> Optional[str]:
        if not isinstance(ticket, str) or not ticket:
            return None
        key = _digest(ticket)
        with self._lock:
            entry = self._tickets.pop(key, None)
        if entry is None:
            return None
        expires, device_id = entry
        if expires < self._clock():
            return None
        return device_id

    def revoke_device(self, device_id: str) -> int:
        with self._lock:
            doomed = [key for key, (_, dev) in self._tickets.items() if dev == device_id]
            for key in doomed:
                self._tickets.pop(key, None)
        return len(doomed)

    def _purge_locked(self, now: float) -> None:
        expired = [key for key, (exp, _) in self._tickets.items() if exp < now]
        for key in expired:
            self._tickets.pop(key, None)

    def purge(self) -> int:
        with self._lock:
            before = len(self._tickets)
            self._purge_locked(self._clock())
            return before - len(self._tickets)

    def __len__(self) -> int:
        return len(self._tickets)


class AttemptThrottle:
    """Sliding-window limiter, keyed by client host."""

    def __init__(
        self,
        limit: int = 10,
        window: float = 60.0,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.limit = limit
        self.window = window
        self._clock = clock
        self._lock = threading.Lock()
        self._hits: Dict[str, Deque[float]] = {}

    def check(self, key: str) -> Tuple[bool, int]:
        """Record an attempt. Returns (allowed, retry_after_seconds)."""
        now = self._clock()
        with self._lock:
            # One entry per distinct key, and the key is a header a caller controls: without a
            # bound, a rotating `X-Forwarded-For` turns the limiter into the leak.
            if len(self._hits) > 4096:
                cutoff = now - self.window
                for stale in [k for k, v in self._hits.items() if not v or v[-1] < cutoff][:2048]:
                    self._hits.pop(stale, None)
                while len(self._hits) > 4096:
                    self._hits.pop(next(iter(self._hits)))
            bucket = self._hits.setdefault(key, deque())
            cutoff = now - self.window
            while bucket and bucket[0] < cutoff:
                bucket.popleft()
            if len(bucket) >= self.limit:
                retry = max(1, int(self.window - (now - bucket[0])) + 1)
                return False, retry
            bucket.append(now)
            return True, 0

    def reset(self) -> None:
        with self._lock:
            self._hits.clear()
