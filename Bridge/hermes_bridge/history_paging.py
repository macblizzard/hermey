"""Bounded transcript pages: keep a long conversation openable on a phone.

`session.resume` answers with the WHOLE conversation in one JSON-RPC frame. cody's bot chat is
1450 rows / 3.4 MB, and `URLSessionWebSocketTask` will not deliver a message that size: the app
reports "Message too long" (EMSGSIZE) and the conversation never opens — then every reconnect
retries the same oversized frame, which is the "reconnecting 5" banner in the screenshot that
started this. The gateway's own resume guard counts *messages*, not bytes, so a long-but-legal
session slips through it.

So the bridge pages the transcript it already relays:

* the resume result keeps only its newest page (`plan_newest`) and gains
  ``history: {total, shown, cursor}``, where ``cursor`` is the raw offset of the page's oldest row
  (``None`` once the page is the whole conversation);
* the app asks for older rows with ``session.history {session_id, profile, cursor, limit}``, which
  the bridge answers from the copy it kept of THAT connection's resume (``HistoryCache``) — the
  gateway's own projection, so a page is the same rows, in the same order, as the resume was;
* the copy dies with the socket. A reconnect re-resumes and re-fills it, so nothing here is
  persisted, shared between devices, or visible to the audit log.

Why not page with the gateway's `session.history`: it runs off the live session's MODEL history
(measured: 157 rows for that same session, because compacted rows are dropped), while the resume
returns the display lineage (1450 rows). Serving older pages from it would silently skip the
history the user is scrolling.
"""

from __future__ import annotations

import json
from collections import OrderedDict
from typing import Any, Iterable, Optional

#: Rows per page. A page is also capped by bytes, so this is a ceiling, not a target: 200 plain
#: chat rows is ~150 KB, while 200 tool rows can be megabytes.
DEFAULT_PAGE_MESSAGES = 200

#: Bytes per page. Comfortably under what iOS accepts (3.4 MB measurably fails) and still several
#: screens of conversation.
DEFAULT_PAGE_BYTES = 512 * 1024

#: Total bytes of relayed transcripts one connection may keep for paging. One long conversation is
#: a few megabytes; four live sockets per device stay well inside this.
DEFAULT_CACHE_BYTES = 64 * 1024 * 1024


def encoded_size(message: Any) -> int:
    """UTF-8 size of one message as it will travel in the frame."""
    return len(json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def plan_newest(
    messages: list,
    max_messages: int = DEFAULT_PAGE_MESSAGES,
    max_bytes: int = DEFAULT_PAGE_BYTES,
) -> tuple[list, Optional[int]]:
    """``(page, cursor)`` for the newest rows that fit — always at least one row.

    ``cursor`` is the index of the page's first row in *messages*, or ``None`` when the page is the
    whole transcript (so the client can tell "nothing older" from "one row, offset 0").
    """
    total = len(messages)
    if total == 0:
        return [], None
    kept = 0
    used = 0
    for message in reversed(messages):
        size = encoded_size(message)
        # The newest row always ships, however large: an empty resume would look like a lost
        # conversation, which is the bug this whole module exists to prevent.
        if kept and (kept >= max_messages or used + size > max_bytes):
            break
        used += size
        kept += 1
    cursor = total - kept
    return messages[cursor:], (cursor or None)


def plan_before(
    messages: list,
    cursor: int,
    limit: int = DEFAULT_PAGE_MESSAGES,
    max_bytes: int = DEFAULT_PAGE_BYTES,
) -> tuple[list, Optional[int]]:
    """``(page, next_cursor)`` for rows older than *cursor*, newest-of-those last.

    The page is contiguous and ends exactly where the caller's oldest row starts, so prepending it
    cannot leave a gap. ``next_cursor`` is ``None`` when the page reaches the start of the
    conversation.
    """
    total = len(messages)
    end = max(0, min(int(cursor), total))
    if end == 0 or limit <= 0:
        return [], (None if end == 0 else end)
    start = end
    used = 0
    while start > 0 and (end - start) < limit:
        size = encoded_size(messages[start - 1])
        # At least one row per page, for the same reason plan_newest always keeps one.
        if start < end and used + size > max_bytes:
            break
        start -= 1
        used += size
    return messages[start:end], (start or None)


class HistoryCache:
    """The transcripts this connection relayed, bounded and least-recently-used.

    Keyed by ``(session_id, profile)`` — the id and bot the *client* resumed with — so a paging
    request from the app finds the copy of the resume it was handed, and two bots that happen to
    share a session id cannot read each other's rows.
    """

    def __init__(self, max_bytes: int = DEFAULT_CACHE_BYTES) -> None:
        self._max_bytes = max(0, int(max_bytes))
        self._messages: "OrderedDict[tuple, list]" = OrderedDict()
        self._sizes: dict[tuple, int] = {}
        self._total = 0

    @staticmethod
    def key(session_id: object, profile: object) -> tuple:
        sid = session_id if isinstance(session_id, str) else ""
        prof = profile if isinstance(profile, str) else ""
        return (sid, prof)

    @property
    def total_bytes(self) -> int:
        return self._total

    def remember(self, key: tuple, messages: Iterable) -> None:
        """Keep *messages* for *key*, dropping the least recently used entries if over budget."""
        rows = list(messages)
        size = sum(encoded_size(message) for message in rows)
        self.forget(key)
        # A single transcript larger than the whole budget is still worth caching: without it every
        # "load earlier" would need a fresh resume, which is the round trip this avoids. It is
        # admitted alone and the next `remember` evicts it.
        self._messages[key] = rows
        self._sizes[key] = size
        self._total += size
        while self._total > self._max_bytes and len(self._messages) > 1:
            oldest = next(iter(self._messages))
            self.forget(oldest)

    def get(self, key: tuple) -> Optional[list]:
        rows = self._messages.get(key)
        if rows is None:
            return None
        self._messages.move_to_end(key)
        return rows

    def forget(self, key: tuple) -> None:
        if self._messages.pop(key, None) is not None:
            self._total -= self._sizes.pop(key, 0)
