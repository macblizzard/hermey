"""The ``/v1/ws`` relay: client <-> bridge <-> local Hermes gateway.

Wire format on both legs is newline-delimited JSON-RPC 2.0 (see
``fixtures/NOTES.md``). This module is the only place that sees both sides, so it
owns every security-relevant decision on the socket:

* **frame cap** -- 1 MiB per JSON-RPC frame, measured in UTF-8 bytes, in both
  directions. A frame that does not end within the cap closes the connection
  instead of buffering without bound.
* **method allow-list** -- a client request for anything outside
  ``policy.CLIENT_METHODS`` is answered ``-32601`` and never reaches the gateway.
* **server-request routing** -- ``approval``/``clarify``/``sudo``/``secret``/
  ``vault.code``/``terminal.read`` are forwarded to the app, and the app's
  response is routed back with the gateway's original id. Without this, every
  approval hangs until it times out.
* **handshake** -- once per connection, after ``gateway.ready``, the bridge sends
  ``client.capabilities {server_requests: true}`` itself, because the bridge is
  the party that answers those requests. Its answer is consumed, not leaked to
  the app.
* **audit** -- only device id, method, duration and byte counts. No params, no
  prompt text, no ids.

Frames are relayed one per line even when the gateway coalesces several into a
single WebSocket message (its token stream does exactly that).
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass
from typing import Optional

import websockets

# The paging arithmetic in one line per request: a "load earlier" that returns nothing is either a
# stale cursor or an exhausted transcript, and the numbers say which without a rebuild.
_log = logging.getLogger("hermes_bridge.proxy")
from starlette.websockets import WebSocket, WebSocketDisconnect

from .attachment_validation import ATTACHMENT_METHODS, AttachmentError, validate_attachment_request
from .audit import AuditLog
from .config import BridgeConfig
from .history_paging import HistoryCache, plan_before, plan_newest
from .policy import (
    build_client_allow_list,
    is_server_request_allowed,
    is_valid_method_name,
    is_bot_model_configure_allowed,
    is_skills_manage_allowed,
)

# Close codes: 4401 is "re-authenticate" (bridge-defined), the rest are RFC 6455.
CLOSE_GOING_AWAY = 1001
CLOSE_PROTOCOL_ERROR = 1002
CLOSE_POLICY = 1008
CLOSE_TOO_BIG = 1009
CLOSE_INTERNAL = 1011
CLOSE_REAUTH = 4401
#: The server closed this socket because the device was revoked. Distinct from 4401 so the
#: app can say "this device was removed" instead of "re-pair", and stop retrying.
CLOSE_DEVICE_REVOKED = 4403


#: Reserved id for the bridge's own client.capabilities call.
BRIDGE_CAPABILITIES_ID = "__hermes_bridge_caps__"

_ERROR_PARSE = -32700
_ERROR_INVALID_REQUEST = -32600
_ERROR_METHOD_NOT_FOUND = -32601
_ERROR_INTERNAL = -32603
_ERROR_SERVER_BUSY = -32000
#: The bridge no longer holds the transcript a paging request was cut from (a bridge restart, or a
#: request for a session this connection never resumed). The app reopens the conversation, which
#: re-resumes and re-fills the cache.
_ERROR_HISTORY_UNAVAILABLE = -32001

_JSONRPC = "2.0"


def id_key(value: object) -> Optional[tuple[str, object]]:
    """A hashable, type-preserving key for a JSON-RPC id (1 != "1")."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return ("int", value)
    if isinstance(value, str):
        return ("str", value)
    return None


def _is_cursor(value: object) -> bool:
    """Whether *value* is a transcript cursor (a row offset) rather than a bool/str lookalike."""
    return isinstance(value, int) and not isinstance(value, bool)


def paging_key(params: object) -> "tuple[Optional[str], str]":
    """``(session_id, profile)`` a resume is cached under and a page request is looked up by."""
    if not isinstance(params, dict):
        return None, ""
    session_id = params.get("session_id")
    profile = params.get("profile")
    return (
        session_id if isinstance(session_id, str) and session_id else None,
        profile if isinstance(profile, str) else "",
    )


@dataclass
class _Pending:
    method: str
    started: float
    # The resume's own addressing, kept so its answer can be paged by (session, bot) later.
    session_id: Optional[str] = None
    profile: str = ""


@dataclass
class _ServerRequest:
    original_id: object
    method: str
    started: float


class _RelayError(Exception):
    def __init__(self, code: int, reason: str, audit_reason: str) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason
        self.audit_reason = audit_reason


def split_frames(chunk: bytes, cap: int) -> list[bytes]:
    """Split one WebSocket message into JSON-RPC frames and enforce *cap*.

    A WebSocket message is itself a frame boundary: the gateway's transport
    serializes one frame per ``send_text`` with no trailing newline (stdio adds
    the newline; WS does not). Batches that *do* carry newlines are accepted too,
    because the protocol is documented as newline-delimited and other gateways
    coalesce frames. Both shapes must work, so a message with no newline is one
    frame rather than a partial one.

    Raises ``_RelayError`` when a frame exceeds *cap*.
    """
    frames: list[bytes] = []
    # A 1 MiB message of newline-separated one-byte lines is half a million "frames", each one a
    # JSON parse error and a reply write. Real batches are a handful; the cap bounds the work per
    # message without limiting anything a client does.
    MAX_FRAMES_PER_MESSAGE = 1024
    start = 0
    while True:
        newline = chunk.find(b"\n", start)
        if newline < 0:
            break
        line = chunk[start:newline]
        start = newline + 1
        if line.endswith(b"\r"):
            line = line[:-1]
        if not line.strip():
            continue
        if len(line) > cap:
            raise _RelayError(CLOSE_TOO_BIG, "frame too large", "frame_too_large")
        frames.append(line)
        if len(frames) > MAX_FRAMES_PER_MESSAGE:
            raise _RelayError(CLOSE_TOO_BIG, "too many frames in one message", "frame_batch_too_large")

    tail = chunk[start:]
    if tail.strip():
        if len(tail) > cap:
            raise _RelayError(CLOSE_TOO_BIG, "frame too large", "frame_too_large")
        frames.append(tail)
    return frames


class LiveSessions:
    """Open relays, grouped by device.

    A revoked device must stop talking *now*, not when its next ticket expires. The
    ticket check alone cannot do that: an already-open socket holds a valid upgrade and
    would keep relaying prompts until the client chose to hang up. So revocation tears
    the sockets down from this side.
    """

    #: One ticket could otherwise open hundreds of upstream sockets to the same gateway the TUI
    #: uses. Four is what an app needs (a chat, a voice call, a reconnect, one spare).
    MAX_PER_DEVICE = 4
    MAX_TOTAL = 64

    def __init__(self) -> None:
        self._by_device: dict[str, set["GatewayProxy"]] = {}
        self._lock = asyncio.Lock()

    def _total(self) -> int:
        return sum(len(sockets) for sockets in self._by_device.values())

    def has_room(self, device_id: str) -> bool:
        """Whether one more relay may open. Checked before the upstream connect."""
        return (len(self._by_device.get(device_id, ())) < self.MAX_PER_DEVICE
                and self._total() < self.MAX_TOTAL)

    async def register(self, proxy: "GatewayProxy") -> None:
        async with self._lock:
            self._by_device.setdefault(proxy.device_id, set()).add(proxy)

    async def unregister(self, proxy: "GatewayProxy") -> None:
        async with self._lock:
            live = self._by_device.get(proxy.device_id)
            if not live:
                return
            live.discard(proxy)
            if not live:
                self._by_device.pop(proxy.device_id, None)

    async def close_device(self, device_id: str, reason: str = "device_revoked") -> int:
        """Close every live relay of one device; returns how many were closed."""
        async with self._lock:
            live = list(self._by_device.get(device_id, ()))
        for proxy in live:
            await proxy.close_from_server(reason)
        return len(live)

    def count(self, device_id: str) -> int:
        return len(self._by_device.get(device_id, ()))


class GatewayProxy:
    """One client connection, one upstream connection, two pumps."""

    def __init__(
        self,
        websocket: WebSocket,
        device_id: str,
        config: BridgeConfig,
        audit: AuditLog,
    ) -> None:
        self._ws = websocket
        self._device_id = device_id
        self._config = config
        self._audit = audit
        self._allow = build_client_allow_list(config.extra_client_methods)
        self._cap = config.frame_cap
        # Transcript paging: the resume's full row list, kept per (session, bot) for this
        # connection's "load earlier" requests, plus the limits each page obeys.
        self._history = HistoryCache(config.history_cache_bytes)
        self._page_messages = config.history_page_messages
        self._page_bytes = config.history_page_bytes
        self._upstream = None
        self._pending: dict[tuple[str, object], _Pending] = {}
        self._server_requests: dict[tuple[str, object], _ServerRequest] = {}
        self._server_seq = 0
        self._caps_sent = False
        self._closed = False

    # -- entry point -------------------------------------------------------

    @property
    def device_id(self) -> str:
        return self._device_id

    async def close_from_server(self, reason: str) -> None:
        """Tear this relay down because the server decided so (revocation), not the client."""
        self._audit.emit(
            "ws_close",
            device_id=self._device_id,
            reason=reason,
            outcome="closed",
        )
        await self._safe_close_client(CLOSE_DEVICE_REVOKED, reason)
        await self._safe_close_upstream()

    async def run(self) -> None:
        self._audit.emit("ws_open", device_id=self._device_id)
        close_code = CLOSE_GOING_AWAY
        close_reason = "client_closed"
        try:
            try:
                self._upstream = await websockets.connect(
                    self._config.upstream_url(),
                    open_timeout=self._config.connect_timeout,
                    close_timeout=5,
                    max_size=None,  # per-frame cap is enforced after NDJSON split
                    max_queue=64,
                    proxy=None,  # never route a loopback token through $HTTP_PROXY
                    logger=logging.getLogger("hermes_bridge.upstream"),
                )
            except Exception:
                # Deliberately no exception text: it can contain the dial URI.
                self._audit.emit(
                    "upstream_error",
                    device_id=self._device_id,
                    reason="connect_failed",
                )
                await self._safe_close_client(CLOSE_INTERNAL, "gateway unavailable")
                close_code, close_reason = CLOSE_INTERNAL, "gateway_unavailable"
                return

            client_task = asyncio.create_task(self._pump_client(), name="bridge-client-pump")
            upstream_task = asyncio.create_task(
                self._pump_upstream(), name="bridge-upstream-pump"
            )
            pumps = [client_task, upstream_task]
            try:
                done, _ = await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
                error: Optional[BaseException] = None
                for task in done:
                    exc = task.exception()
                    if exc is not None:
                        error = exc
                if error is not None:
                    if isinstance(error, _RelayError):
                        close_code, close_reason = error.code, error.audit_reason
                        self._audit.emit(
                            "frame_too_large"
                            if error.code == CLOSE_TOO_BIG
                            else "protocol_error",
                            device_id=self._device_id,
                            reason=error.audit_reason,
                        )
                    elif isinstance(error, (WebSocketDisconnect, asyncio.CancelledError)):
                        close_code, close_reason = CLOSE_GOING_AWAY, "client_closed"
                    else:
                        self._audit.emit(
                            "upstream_error",
                            device_id=self._device_id,
                            reason="relay_failed",
                        )
                        close_code, close_reason = CLOSE_INTERNAL, "relay_failed"
                    await self._safe_close_client(close_code, close_reason.replace("_", " "))
                elif upstream_task in done:
                    # The gateway hung up cleanly; the app must not sit on an
                    # open socket that no longer has a pump behind it.
                    close_code, close_reason = CLOSE_INTERNAL, "gateway_closed"
                    await self._safe_close_client(CLOSE_INTERNAL, "gateway closed")
            finally:
                for task in pumps:
                    task.cancel()
                await asyncio.gather(*pumps, return_exceptions=True)
        finally:
            for key in list(self._pending):
                self._pending.pop(key, None)
                self._audit.emit(
                    "request_abandoned",
                    device_id=self._device_id,
                    direction="client_to_gateway",
                )
            await self._safe_close_upstream()
            self._audit.emit(
                "ws_close",
                device_id=self._device_id,
                outcome="closed",
                reason=close_reason,
                close_code=close_code,
            )

    # -- client -> gateway -------------------------------------------------

    async def _pump_client(self) -> None:
        while True:
            message = await self._ws.receive()
            if message.get("type") == "websocket.disconnect":
                return
            text = message.get("text")
            data = message.get("bytes")
            chunk = text.encode("utf-8") if isinstance(text, str) else data
            if not chunk:
                continue
            for frame in split_frames(chunk, self._cap):
                await self._handle_client_frame(frame)

    async def _handle_client_frame(self, raw: bytes) -> None:
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            await self._send_error_to_client(None, _ERROR_PARSE, "parse error")
            self._audit.emit(
                "client_request_rejected", device_id=self._device_id, reason="parse_error",
                nbytes=len(raw), direction="client_to_gateway",
            )
            return

        if not isinstance(parsed, dict):
            await self._send_error_to_client(None, _ERROR_INVALID_REQUEST, "invalid request")
            self._audit.emit(
                "client_request_rejected", device_id=self._device_id,
                reason="not_an_object", nbytes=len(raw), direction="client_to_gateway",
            )
            return

        if parsed.get("jsonrpc") not in (None, _JSONRPC):
            await self._send_error_to_client(
                parsed.get("id"), _ERROR_INVALID_REQUEST, "invalid jsonrpc version"
            )
            self._audit.emit(
                "client_request_rejected", device_id=self._device_id,
                reason="bad_version", nbytes=len(raw), direction="client_to_gateway",
            )
            return

        method = parsed.get("method")
        if method is not None:
            await self._handle_client_request(parsed, method, raw)
            return
        await self._handle_client_response(parsed, raw)

    async def _handle_client_request(self, frame: dict, method: object, raw: bytes) -> None:
        request_id = frame.get("id")
        key = id_key(request_id)
        if key is None:
            await self._send_error_to_client(None, _ERROR_INVALID_REQUEST, "id required")
            self._audit.emit(
                "client_request_rejected", device_id=self._device_id,
                reason="missing_id", nbytes=len(raw), direction="client_to_gateway",
            )
            return

        if (not is_valid_method_name(method) or method not in self._allow
                or (method in {"image.attach", "pdf.attach", "clipboard.paste", "image.detach"})
                or (method == "profiles.configure"
                    and not is_bot_model_configure_allowed(frame.get("params")))
                or (method == "skills.manage"
                    and not is_skills_manage_allowed(frame.get("params")))):
            shown = method if is_valid_method_name(method) else None
            await self._send_error_to_client(
                request_id,
                _ERROR_METHOD_NOT_FOUND,
                f"method not allowed by bridge: {shown}" if shown else "invalid method",
            )
            self._audit.emit(
                "client_request_rejected",
                device_id=self._device_id,
                method=shown if shown else None,
                reason="method_not_allowed",
                nbytes=len(raw),
                direction="client_to_gateway",
            )
            return

        if method in ATTACHMENT_METHODS:
            try:
                validate_attachment_request(method, frame.get("params"))
            except AttachmentError:
                await self._send_error_to_client(request_id, -32602, "invalid attachment")
                return

        if key in self._pending:
            await self._send_error_to_client(
                request_id, _ERROR_INVALID_REQUEST, "duplicate request id"
            )
            return
        if key in self._server_requests:
            # The gateway is waiting on a response under this id; a client
            # request reusing it would make the answer ambiguous.
            await self._send_error_to_client(
                request_id, _ERROR_INVALID_REQUEST, "id is in use by a pending request"
            )
            self._audit.emit(
                "client_request_rejected",
                device_id=self._device_id,
                method=method,
                reason="id_in_use",
                nbytes=len(raw),
                direction="client_to_gateway",
            )
            return
        if len(self._pending) >= self._config.max_pending_requests:
            await self._send_error_to_client(
                request_id, _ERROR_SERVER_BUSY, "too many in-flight requests"
            )
            self._audit.emit(
                "client_request_rejected",
                device_id=self._device_id,
                method=method,
                reason="too_many_pending",
            )
            return

        # The bridge owns server-request delivery, so a client that declares a
        # narrower capability set must not disable approvals for everyone.
        if method == "client.capabilities":
            params = frame.get("params")
            if not isinstance(params, dict):
                params = {}
            params = dict(params)
            params["server_requests"] = True
            frame["params"] = params

        params = frame.get("params")
        if method == "session.history" and isinstance(params, dict) and _is_cursor(params.get("cursor")):
            # An older-transcript page: served from this connection's own resume copy, never
            # forwarded (the gateway answers `session.history` from the live MODEL history, which
            # is a different, shorter row set than the display transcript the resume returned).
            await self._serve_history_page(request_id, params)
            return

        session_id, profile = paging_key(params)
        self._pending[key] = _Pending(
            method=method,
            started=time.monotonic(),
            session_id=session_id,
            profile=profile,
        )
        try:
            await self._send_upstream(self._encode(frame))
        except Exception:
            self._pending.pop(key, None)
            raise
        self._audit.emit(
            "client_request",
            device_id=self._device_id,
            method=method,
            nbytes=len(raw),
            direction="client_to_gateway",
        )

    async def _handle_client_response(self, frame: dict, raw: bytes) -> None:
        key = id_key(frame.get("id"))
        pending = self._server_requests.pop(key, None) if key is not None else None
        if pending is None:
            self._audit.emit(
                "client_response_dropped",
                device_id=self._device_id,
                reason="unknown_request_id",
                nbytes=len(raw),
                direction="client_to_gateway",
            )
            return
        restored = dict(frame)
        restored["id"] = pending.original_id
        await self._send_upstream(self._encode(restored))
        self._audit.emit(
            "server_response",
            device_id=self._device_id,
            method=pending.method,
            duration_ms=time.monotonic() - pending.started,
            nbytes=len(raw),
            direction="client_to_gateway",
        )

    async def _serve_history_page(self, request_id: object, params: dict) -> None:
        """Answer one older-transcript page from this connection's own resume copy.

        Never forwarded: the gateway's `session.history` reads the live session's MODEL history
        (compacted rows dropped — measured 157 rows for a resume that carried 1450), so using it
        would hand the app a different transcript from the one it is scrolling.
        """
        session_id, profile = paging_key(params)
        known = self._history.get(HistoryCache.key(session_id, profile))
        if known is None:
            await self._send_error_to_client(
                request_id, _ERROR_HISTORY_UNAVAILABLE, "history page unavailable"
            )
            self._audit.emit(
                "history_page_miss",
                device_id=self._device_id,
                method="session.history",
                reason="no_cached_resume",
                direction="client_to_gateway",
            )
            return
        raw_cursor = params.get("cursor")
        raw_limit = params.get("limit")
        cursor = raw_cursor if isinstance(raw_cursor, int) and not isinstance(raw_cursor, bool) else 0
        limit = (raw_limit if isinstance(raw_limit, int) and not isinstance(raw_limit, bool)
                 and raw_limit > 0 else self._page_messages)
        page, next_cursor = plan_before(known, cursor, limit, self._page_bytes)
        _log.info("history page: cursor=%s rows=%s next=%s total=%s",
                  cursor, len(page), next_cursor, len(known))
        await self._send_to_client(
            self._encode(
                {
                    "jsonrpc": _JSONRPC,
                    "id": request_id,
                    "result": {
                        "messages": page,
                        "count": len(page),
                        "cursor": next_cursor,
                        "total": len(known),
                    },
                }
            )
        )
        self._audit.emit(
            "history_page",
            device_id=self._device_id,
            method="session.history",
            direction="gateway_to_client",
            profile=profile or None,
        )

    def page_resume(self, frame: dict, pending: "_Pending") -> dict:
        """Replace a resume's whole transcript with its newest page, keeping the rest here.

        A long conversation arrives as one multi-megabyte JSON-RPC frame and iOS refuses to deliver
        a message that size (`Message too long`/EMSGSIZE), so the app could never open the bot at
        all. The result gains `history: {total, shown, cursor}`; `cursor` is the row offset of the
        page's oldest message and is what the app sends back to load earlier ones.
        """
        result = frame.get("result")
        if not isinstance(result, dict):
            return frame
        messages = result.get("messages")
        if not isinstance(messages, list) or not messages:
            return frame
        key = HistoryCache.key(pending.session_id, pending.profile)
        self._history.remember(key, messages)
        page, cursor = plan_newest(messages, self._page_messages, self._page_bytes)
        out = dict(result)
        out["messages"] = page
        out["history"] = {"total": len(messages), "shown": len(page), "cursor": cursor}
        replaced = dict(frame)
        replaced["result"] = out
        self._audit.emit(
            "history_paged",
            device_id=self._device_id,
            method=pending.method,
            direction="gateway_to_client",
            profile=pending.profile or None,
        )
        return replaced

    # -- gateway -> client -------------------------------------------------

    async def _pump_upstream(self) -> None:
        assert self._upstream is not None
        async for message in self._upstream:
            chunk = message.encode("utf-8") if isinstance(message, str) else message
            for frame in split_frames(chunk, self._cap):
                await self._handle_upstream_frame(frame)

    async def _handle_upstream_frame(self, raw: bytes) -> None:
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise _RelayError(CLOSE_PROTOCOL_ERROR, "bad upstream frame", "bad_gateway_frame")
        if not isinstance(parsed, dict):
            raise _RelayError(CLOSE_PROTOCOL_ERROR, "bad upstream frame", "bad_gateway_frame")

        method = parsed.get("method")
        if method is not None:
            if id_key(parsed.get("id")) is not None:
                await self._handle_server_request(parsed, method, raw)
            else:
                await self._handle_notification(parsed, method, raw)
            return

        await self._handle_upstream_response(parsed, raw)

    async def _handle_notification(self, frame: dict, method: object, raw: bytes) -> None:
        await self._send_to_client(self._encode(frame))
        self._audit.emit(
            "notification",
            device_id=self._device_id,
            method=method,
            nbytes=len(raw),
            direction="gateway_to_client",
        )
        params = frame.get("params")
        if (
            method == "event"
            and isinstance(params, dict)
            and params.get("type") == "gateway.ready"
        ):
            await self._send_capabilities()

    async def _send_capabilities(self) -> None:
        if self._caps_sent:
            return
        self._caps_sent = True
        frame = {
            "jsonrpc": _JSONRPC,
            "id": BRIDGE_CAPABILITIES_ID,
            "method": "client.capabilities",
            "params": {"server_requests": True},
        }
        payload = self._encode(frame)
        await self._send_upstream(payload)
        self._audit.emit(
            "capabilities_sent",
            device_id=self._device_id,
            method="client.capabilities",
            nbytes=len(payload.encode("utf-8")),
            direction="client_to_gateway",
        )

    async def _handle_server_request(self, frame: dict, method: object, raw: bytes) -> None:
        request_id = frame.get("id")
        if not is_server_request_allowed(method):
            # Answer upstream immediately so the agent fails fast instead of
            # waiting for an approval nobody can render.
            shown = method if is_valid_method_name(method) else None
            await self._send_upstream(
                self._encode(
                    {
                        "jsonrpc": _JSONRPC,
                        "id": request_id,
                        "error": {
                            "code": _ERROR_METHOD_NOT_FOUND,
                            "message": (
                                f"method not supported by client: {shown}"
                                if shown
                                else "method not supported by client"
                            ),
                        },
                    }
                )
            )
            self._audit.emit(
                "server_request_declined",
                device_id=self._device_id,
                method=shown if shown else None,
                reason="method_not_supported",
                nbytes=len(raw),
                direction="gateway_to_client",
            )
            return

        outgoing = frame
        key = id_key(request_id)
        # A server request id that collides with an in-flight client request (or
        # another server request) is remapped for the app and restored on the
        # way back; the app never has to reason about whose id it holds.
        if key is None or key in self._pending or key in self._server_requests:
            self._server_seq += 1
            replacement = f"brq-{self._server_seq}"
            key = id_key(replacement)
            outgoing = dict(frame)
            outgoing["id"] = replacement

        assert key is not None
        self._server_requests[key] = _ServerRequest(
            original_id=request_id, method=str(method), started=time.monotonic()
        )
        await self._send_to_client(self._encode(outgoing))
        self._audit.emit(
            "server_request",
            device_id=self._device_id,
            method=method,
            nbytes=len(raw),
            direction="gateway_to_client",
        )

    async def _handle_upstream_response(self, frame: dict, raw: bytes) -> None:
        key = id_key(frame.get("id"))
        if key == id_key(BRIDGE_CAPABILITIES_ID):
            return  # the bridge's own handshake answer
        pending = self._pending.pop(key, None) if key is not None else None
        if pending is not None:
            self._audit.emit(
                "client_response",
                device_id=self._device_id,
                method=pending.method,
                duration_ms=time.monotonic() - pending.started,
                nbytes=len(raw),
                outcome="error" if frame.get("error") else "ok",
                direction="gateway_to_client",
            )
        else:
            self._audit.emit(
                "unmatched_response",
                device_id=self._device_id,
                nbytes=len(raw),
                direction="gateway_to_client",
            )
        if pending is not None and pending.method == "profiles.configure" and frame.get("error"):
            frame = dict(frame)
            frame["error"] = {"code": -32603, "message": "profile update failed"}
        if pending is not None and pending.method == "session.resume":
            # Page the transcript the app receives; the full copy stays here for "load earlier".
            frame = self.page_resume(frame, pending)
        if pending is not None and pending.method in ATTACHMENT_METHODS:
            frame = dict(frame)
            if frame.get("error"):
                frame["error"] = {"code": -32603, "message": "attachment failed"}
            elif isinstance(frame.get("result"), dict):
                result = dict(frame["result"])
                result.pop("path", None)
                ref = result.get("ref_path")
                if isinstance(ref, str) and (ref.startswith(("/", "\\\\")) or (len(ref) > 1 and ref[1] == ":")):
                    frame.pop("result", None)
                    frame["error"] = {"code": -32603, "message": "attachment reference unavailable"}
                else:
                    frame["result"] = result
        await self._send_to_client(self._encode(frame))

    # -- transport helpers -------------------------------------------------

    @staticmethod
    def _encode(frame: dict) -> str:
        return json.dumps(frame, separators=(",", ":"), ensure_ascii=False) + "\n"

    async def _send_upstream(self, payload: str) -> None:
        if self._upstream is None:
            raise _RelayError(CLOSE_INTERNAL, "gateway not connected", "not_connected")
        await self._upstream.send(payload)

    async def _send_to_client(self, payload: str) -> None:
        try:
            await self._ws.send_text(payload)
        except (WebSocketDisconnect, RuntimeError):
            raise _RelayError(CLOSE_GOING_AWAY, "client gone", "client_closed")

    async def _send_error_to_client(self, request_id: object, code: int, message: str) -> None:
        await self._send_to_client(
            self._encode(
                {
                    "jsonrpc": _JSONRPC,
                    "id": request_id,
                    "error": {"code": code, "message": message},
                }
            )
        )

    async def _safe_close_client(self, code: int, reason: str) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            await self._ws.close(code=code, reason=reason[:120])
        except Exception:
            pass

    async def _safe_close_upstream(self) -> None:
        upstream = self._upstream
        self._upstream = None
        if upstream is None:
            return
        try:
            await upstream.close(code=CLOSE_GOING_AWAY, reason="client closed")
        except Exception:
            pass
