"""A fixture replay server that stands in for the Hermes TUI gateway.

Why this exists
---------------
Every claim about this client is currently checked against Swift code and
hand-written JSON. But the gateway behaviours that actually break clients are
*timing* behaviours: an event that never arrives, a request answered 400 ms
late, an approval that blocks the agent until the client answers. A recorded
transcript cannot express those; a script can.

Two replay modes, one format
----------------------------
* **Transcript** — a plain `fixtures/*.ndjson` file. Every line is a real frame,
  sent byte-for-byte as recorded, in order. Use it to prove the client decodes
  observed bytes (`fixtures/NOTES.md` says the fixtures win over the docs).
* **Script** — the same NDJSON, plus directives under the reserved ``"$qa"``
  key. Directives let a scenario wait for a request before answering, stay
  silent, delay, or close with a specific code.

Directives are deliberately *request-gated* rather than sleep-gated: a step
``{"$qa": {"wait_for": {"method": "prompt.submit"}}}`` blocks until the frame
arrives. A scenario written this way cannot race the client, and a slow CI box
does not turn into a flaky test.

Example
-------
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}
{"$qa":{"reply":{"method":"ping","result":{"pong":true}}}}
{"$qa":{"wait_for":{"method":"prompt.submit"}}}
{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","payload":{"delta":"hi"}}}
{"$qa":{"close":{"code":1000,"reason":"done"}}}
```

The server is intentionally permissive on receive (``max_size=None``): the
*bridge* is what must enforce the 1 MiB frame cap, so the replay server has to
be able to observe a frame that a broken bridge forwarded. Never let the fake
gateway be the thing that rejects oversize frames — that would hide the bug.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Sequence

from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

log = logging.getLogger("qa.replay")

#: The bridge's documented per-frame cap (02-architecture.md §9). Kept here so
#: tests and scripts share one constant instead of a magic number.
FRAME_CAP_BYTES = 1 << 20

#: Reserved key: a line whose only key is this is a directive, not a frame.
DIRECTIVE_KEY = "$qa"

DEFAULT_TIMEOUT = 10.0

ALLOWED_DIRECTIVES = {
    "sleep",
    "reply",
    "auto_reply",
    "wait_for",
    "wait_for_response",
    "require",
    "unmatched",
    "close",
    "mark",
}


class ScriptError(ValueError):
    """The scenario file is malformed. Fails loudly; never silently ignored."""


class ScriptTimeout(RuntimeError):
    """A directive waited for a frame that never arrived."""


class _ScriptClose(Exception):
    """Internal: the script asked to close the socket."""


# --------------------------------------------------------------------------- #
# Records
# --------------------------------------------------------------------------- #


@dataclass
class RecordedFrame:
    seq: int
    #: Seconds since the connection was accepted (monotonic, process-local).
    at: float
    #: Bytes on the wire, UTF-8 encoded.
    size: int
    text: str
    frame: dict | None
    binary: bool = False


@dataclass
class ConnectionRecord:
    """Everything the fake gateway saw and sent on one connection."""

    index: int
    accepted_at: float
    script_name: str = ""
    #: Request path the peer dialled (e.g. ``/api/ws?token=…``).
    path: str = ""
    inbound: list[RecordedFrame] = field(default_factory=list)
    outbound: list[RecordedFrame] = field(default_factory=list)
    closed_code: int | None = None
    closed_reason: str = ""
    #: Set when a directive timed out; the scenario did not run as written.
    error: str | None = None
    #: Wall-clock start used for the relative ``at`` stamps above.
    t0: float = 0.0
    #: How the fake gateway answers requests the script does not answer.
    policy: str = "silent"
    #: Ids already answered by a ``reply`` directive (guards double answers).
    responded: set[str] = field(default_factory=set)
    #: Set by the reader on every inbound frame; waiters block on it.
    wakeup: asyncio.Event = field(default_factory=asyncio.Event)
    #: Named points in the scenario, for tests and latency reports.
    marks: list[tuple[float, str]] = field(default_factory=list)
    #: method -> {"result": …} | {"error": …}, answered whenever they arrive.
    auto: dict[str, dict] = field(default_factory=dict)
    #: Serialises concurrent sends (script pump + reader answering).
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    # -- outbound helpers ---------------------------------------------------
    def sent_frames(self) -> list[dict]:
        return [f.frame for f in self.outbound if f.frame is not None]

    def event_types(self) -> list[str]:
        return [
            (f.frame.get("params") or {}).get("type", "")
            for f in self.outbound
            if f.frame and f.frame.get("method") == "event"
        ]

    def sent_requests(self) -> list[dict]:
        """Frames the gateway sent *to* the client as server->client requests."""
        return [
            f.frame
            for f in self.outbound
            if f.frame and f.frame.get("method") and f.frame.get("id") is not None
        ]

    # -- inbound helpers ----------------------------------------------------
    def inbound_methods(self) -> list[str]:
        return [f.frame["method"] for f in self.inbound if f.frame and "method" in f.frame]

    def inbound_with_method(self, method: str) -> list[RecordedFrame]:
        return [f for f in self.inbound if f.frame and f.frame.get("method") == method]

    def inbound_responses(self) -> list[RecordedFrame]:
        """Frames from the client that answer a server->client request."""
        return [
            f
            for f in self.inbound
            if f.frame and "method" not in f.frame and f.frame.get("id") is not None
        ]

    @property
    def inbound_bytes(self) -> int:
        return sum(f.size for f in self.inbound)

    @property
    def max_inbound_size(self) -> int:
        return max((f.size for f in self.inbound), default=0)

    def timeline(self) -> list[tuple[float, str, str]]:
        """(at, direction, label) for both directions — for order assertions."""
        out: list[tuple[float, str, str]] = []
        for f in self.inbound:
            label = (f.frame or {}).get("method") or f"response:{(f.frame or {}).get('id')}"
            out.append((f.at, "in", str(label)))
        for f in self.outbound:
            fr = f.frame or {}
            label = (fr.get("params") or {}).get("type") or fr.get("method") or "frame"
            out.append((f.at, "out", str(label)))
        return sorted(out, key=lambda t: t[0])

    def first_at(self, direction: str, label: str) -> float | None:
        for at, d, lab in self.timeline():
            if d == direction and lab == label:
                return at
        return None


# --------------------------------------------------------------------------- #
# Script parsing
# --------------------------------------------------------------------------- #


@dataclass
class ScriptItem:
    line: int
    raw: str | None = None
    frame: dict | None = None
    directive: dict | None = None

    @property
    def is_frame(self) -> bool:
        return self.frame is not None


def _validate_directive(d: Any, line: int) -> dict:
    if not isinstance(d, dict) or not d:
        raise ScriptError(f"line {line}: {DIRECTIVE_KEY} must be a non-empty object")
    unknown = set(d) - ALLOWED_DIRECTIVES
    if unknown:
        raise ScriptError(
            f"line {line}: unknown directive(s) {sorted(unknown)}; "
            f"allowed: {sorted(ALLOWED_DIRECTIVES)}"
        )
    if len(d) > 1 and "sleep" not in d:
        # Multiple directives on one line are allowed only for sleep+action,
        # which keeps the parser honest about ordering.
        raise ScriptError(f"line {line}: one directive per line (got {sorted(d)})")
    for key in ("wait_for", "wait_for_response", "reply", "close", "unmatched", "require"):
        if key in d and not isinstance(d[key], (dict, list, str)):
            raise ScriptError(f"line {line}: {key} has the wrong shape")
    if "wait_for" in d:
        spec = d["wait_for"]
        if not isinstance(spec, dict) or "method" not in spec:
            raise ScriptError(f"line {line}: wait_for needs {{'method': ...}}")
        if "occurrence" in spec and not isinstance(spec["occurrence"], int):
            raise ScriptError(f"line {line}: wait_for.occurrence must be an int")
    if "reply" in d:
        spec = d["reply"]
        if not isinstance(spec, dict) or "method" not in spec:
            raise ScriptError(f"line {line}: reply needs {{'method': ...}}")
        if "result" not in spec and "error" not in spec:
            raise ScriptError(f"line {line}: reply needs 'result' or 'error'")
    if "unmatched" in d and d["unmatched"] not in {"silent", "method_not_found"}:
        raise ScriptError(
            f"line {line}: unmatched must be 'silent' or 'method_not_found'"
        )
    if "auto_reply" in d:
        table = d["auto_reply"]
        if not isinstance(table, dict) or not table:
            raise ScriptError(f"line {line}: auto_reply must be a non-empty object")
        for method, spec in table.items():
            if not isinstance(spec, dict) or not ({"result", "error"} & set(spec)):
                raise ScriptError(
                    f"line {line}: auto_reply[{method!r}] needs 'result' or 'error'"
                )
    return d


def parse_script(source: str | Path | Iterable[str | dict]) -> list[ScriptItem]:
    """Parse a scenario.

    ``source`` may be a path, NDJSON text, or an iterable of lines/dicts (the
    last form lets a test build a one-off frame too big to keep in the repo).

    Three shapes are accepted on each line:

    1. a raw JSON-RPC **frame** — sent as recorded;
    2. a ``"$qa"`` **directive** (see the module docstring);
    3. a **recorder record** (``{"t": …, "dir": "stdin"|"stdout", "frame": {…}}``),
       which is what ``Tools/record_fixtures.py`` writes. ``stdout`` records are
       replayed in order; ``stdin`` records become a gate on the matching request,
       so a fresh recording replays with the same ordering without hand-editing.
    """
    if isinstance(source, Path):
        lines = source.read_text(encoding="utf-8").splitlines()
    elif isinstance(source, str):
        if "\n" not in source and Path(source).is_file():
            lines = Path(source).read_text(encoding="utf-8").splitlines()
        else:
            lines = source.splitlines()
    else:
        lines = list(source)

    items: list[ScriptItem] = []
    seen_requests: dict[str, int] = {}
    for n, line in enumerate(lines, start=1):
        if isinstance(line, dict):
            obj, raw = line, None
        else:
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.startswith("//"):
                continue
            raw = stripped
            try:
                obj = json.loads(stripped)
            except json.JSONDecodeError as exc:
                raise ScriptError(f"line {n}: not JSON: {exc}") from exc
            if not isinstance(obj, dict):
                raise ScriptError(f"line {n}: every line must be a JSON object")

        if DIRECTIVE_KEY in obj:
            if set(obj) != {DIRECTIVE_KEY}:
                raise ScriptError(
                    f"line {n}: {DIRECTIVE_KEY} must be the only key on its line "
                    f"(found {sorted(obj)})"
                )
            items.append(
                ScriptItem(line=n, directive=_validate_directive(obj[DIRECTIVE_KEY], n))
            )
            continue

        if _looks_like_recorder_record(obj):
            frame = obj.get("frame")
            if not isinstance(frame, dict):
                continue  # a non-JSON or stderr record: nothing to replay
            if obj.get("dir") in ("stdout", "out", "gateway"):
                items.append(ScriptItem(line=n, frame=frame))
            elif obj.get("dir") in ("stdin", "in", "client"):
                method = frame.get("method")
                if method:
                    seen_requests[method] = seen_requests.get(method, 0) + 1
                    items.append(
                        ScriptItem(
                            line=n,
                            directive={
                                "wait_for": {
                                    "method": method,
                                    "occurrence": seen_requests[method],
                                    "timeout": DEFAULT_TIMEOUT,
                                }
                            },
                        )
                    )
            continue

        if "jsonrpc" not in obj and "method" not in obj and "id" not in obj:
            raise ScriptError(
                f"line {n}: neither a JSON-RPC frame nor a {DIRECTIVE_KEY} directive"
            )
        items.append(ScriptItem(line=n, frame=obj, raw=raw))
    if not items:
        raise ScriptError("empty scenario")
    return items


def _looks_like_recorder_record(obj: dict) -> bool:
    """``Tools/record_fixtures.py`` wraps each frame: ``{"t", "dir", "frame"}``."""
    return "dir" in obj and ("frame" in obj or "raw" in obj) and "jsonrpc" not in obj


def dumps_frame(frame: dict) -> str:
    """Serialise a frame the way the gateway does: one line, no trailing newline."""
    return json.dumps(frame, ensure_ascii=False, separators=(", ", ": "))


# --------------------------------------------------------------------------- #
# Server
# --------------------------------------------------------------------------- #


class ReplayServer:
    """Serves one scenario (or a sequence of them) over WebSocket on loopback.

    ``scripts`` is either a single scenario or a sequence of scenarios handed
    out one per connection, in order (the last one repeats) — that is how a
    reconnect test gets a fresh gateway session.
    """

    def __init__(
        self,
        scripts: Any,
        *,
        host: str = "127.0.0.1",
        port: int = 0,
        linger: float = 5.0,
        name: str = "",
    ) -> None:
        if isinstance(scripts, (str, Path)):
            self._scripts = [parse_script(scripts)]
            self._names = [Path(str(scripts)).name if "\\n" not in str(scripts) else "inline"]
        else:
            seq = list(scripts)
            if not seq:
                raise ScriptError("no scenarios given")
            if isinstance(seq[0], ScriptItem) or isinstance(seq[0], dict):
                self._scripts = [parse_script(seq)]
                self._names = ["inline"]
            else:
                self._scripts = [parse_script(s) for s in seq]
                self._names = [
                    Path(s).name if isinstance(s, (str, Path)) else "inline" for s in seq
                ]
        self._host = host
        self._requested_port = port
        self._linger = linger
        self.name = name

        self._connections: list[ConnectionRecord] = []
        self._thread: threading.Thread | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._stop: asyncio.Event | None = None
        self._ready = threading.Event()
        self._port = port
        self._started_at = 0.0

    # -- lifecycle ----------------------------------------------------------
    def start(self) -> "ReplayServer":
        self._thread = threading.Thread(target=self._run, name="qa-replay", daemon=True)
        self._thread.start()
        if not self._ready.wait(10):
            raise RuntimeError("replay server did not start within 10 s")
        return self

    def stop(self) -> None:
        if self._loop and self._stop:
            self._loop.call_soon_threadsafe(self._stop.set)
        if self._thread:
            self._thread.join(timeout=10)
        self._thread = None

    def __enter__(self) -> "ReplayServer":
        return self.start()

    def __exit__(self, *exc: object) -> None:
        self.stop()

    def _run(self) -> None:
        loop = asyncio.new_event_loop()
        self._loop = loop
        asyncio.set_event_loop(loop)

        async def main() -> None:
            async with serve(
                self._handle,
                self._host,
                self._requested_port,
                max_size=None,          # see module docstring: the bridge enforces caps
                ping_interval=None,     # silence must stay silence
            ) as server:
                self._port = list(server.sockets)[0].getsockname()[1]
                self._stop = asyncio.Event()
                self._started_at = time.time()
                self._ready.set()
                await self._stop.wait()

        try:
            loop.run_until_complete(main())
        finally:
            try:
                loop.run_until_complete(loop.shutdown_asyncgens())
            finally:
                loop.close()

    # -- introspection ------------------------------------------------------
    @property
    def port(self) -> int:
        return self._port

    @property
    def url(self) -> str:
        return f"ws://{self._host}:{self._port}"

    @property
    def connections(self) -> list[ConnectionRecord]:
        # Records are appended in the server loop and only read by tests after
        # a synchronisation point (a received frame or a wait_for_* helper).
        return list(self._connections)

    def connection(self, index: int = 0) -> ConnectionRecord:
        try:
            return self._connections[index]
        except IndexError:  # pragma: no cover - test bug, not server bug
            raise AssertionError(
                f"no connection {index}; saw {len(self._connections)}"
            ) from None

    def wait_for_connections(self, count: int, timeout: float = 10.0) -> list[ConnectionRecord]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if len(self._connections) >= count:
                return self.connections
            time.sleep(0.005)
        raise AssertionError(
            f"expected {count} connection(s), saw {len(self._connections)}"
        )

    def wait_for_closed(self, index: int = 0, timeout: float = 5.0) -> ConnectionRecord:
        """Wait until the server has observed the close (the client sees it first)."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                rec = self._connections[index]
            except IndexError:
                raise AssertionError(f"no connection {index}") from None
            if rec.closed_code is not None:
                return rec
            time.sleep(0.005)
        raise AssertionError(
            f"connection {index} was still open after {timeout}s "
            f"(inbound: {self._connections[index].inbound_methods()})"
        )

    # -- handler ------------------------------------------------------------
    async def _handle(self, conn: ServerConnection) -> None:
        index = len(self._connections)
        rec = ConnectionRecord(
            index=index,
            accepted_at=time.time(),
            script_name=self._names[min(index, len(self._names) - 1)],
            t0=time.monotonic(),
            path=getattr(getattr(conn, "request", None), "path", "") or "",
        )
        self._connections.append(rec)

        items = self._scripts[min(index, len(self._scripts) - 1)]
        log.info("connection %d accepted (%s, %d steps)", index, rec.script_name, len(items))

        reader = asyncio.create_task(self._reader(conn, rec))
        try:
            await self._run_script(conn, rec, items)
        except _ScriptClose:
            pass
        except ScriptTimeout as exc:
            rec.error = str(exc)
            log.warning("connection %d: scenario timed out: %s", index, exc)
        except ConnectionClosed:
            pass
        finally:
            if rec.closed_code is None:
                try:
                    await asyncio.wait_for(reader, self._linger)
                except (asyncio.TimeoutError, TimeoutError):
                    reader.cancel()
                    try:
                        await reader
                    except (asyncio.CancelledError, Exception):
                        pass
                except Exception:
                    pass
            else:
                reader.cancel()

    async def _reader(self, conn: ServerConnection, rec: ConnectionRecord) -> None:
        try:
            async for message in conn:
                binary = isinstance(message, bytes)
                text = (
                    message.decode("utf-8", "replace")
                    if binary
                    else message  # type: ignore[assignment]
                )
                frame: dict | None
                try:
                    parsed = json.loads(text)
                    frame = parsed if isinstance(parsed, dict) else None
                except json.JSONDecodeError:
                    frame = None
                rec.inbound.append(
                    RecordedFrame(
                        seq=len(rec.inbound),
                        at=time.monotonic() - rec.t0,
                        size=len(text.encode("utf-8")),
                        text=text,
                        frame=frame,
                        binary=binary,
                    )
                )
                rec.wakeup.set()

                # Auto-answers: the gateway does not "wait its turn" for ping or
                # client.capabilities, whichever side asks (the bridge injects
                # its own handshake; so does a client).
                if frame and frame.get("method") in rec.auto and frame.get("id") is not None:
                    key = _id_key(frame["id"])
                    if key not in rec.responded:
                        rec.responded.add(key)
                        spec = rec.auto[frame["method"]]
                        response: dict[str, Any] = {"jsonrpc": "2.0", "id": frame["id"]}
                        if "error" in spec:
                            response["error"] = spec["error"]
                        else:
                            response["result"] = spec.get("result")
                        await self._send(conn, rec, dumps_frame(response))

                if (
                    rec.policy == "method_not_found"
                    and frame
                    and frame.get("method")
                    and frame.get("id") is not None
                ):
                    key = _id_key(frame["id"])
                    if key not in rec.responded:
                        await self._send(
                            conn,
                            rec,
                            dumps_frame(
                                {
                                    "jsonrpc": "2.0",
                                    "id": frame["id"],
                                    "error": {
                                        "code": -32601,
                                        "message": f"unknown method: {frame['method']}",
                                    },
                                }
                            ),
                        )
        except ConnectionClosed as exc:
            rec.closed_code = exc.code
            rec.closed_reason = exc.reason or ""
        except Exception as exc:  # pragma: no cover - defensive
            rec.error = f"reader crashed: {exc!r}"
        else:
            # ``async for`` swallows the closing exception, so a clean peer close
            # (the normal case: the bridge hung up) lands here, not in the handler.
            code = getattr(conn, "close_code", None)
            if code is None:
                code = getattr(getattr(conn, "protocol", None), "close_code", None)
            rec.closed_code = 1000 if code is None else int(code)
            rec.closed_reason = getattr(conn, "close_reason", "") or ""

    async def _send(self, conn: ServerConnection, rec: ConnectionRecord, text: str) -> None:
        if not text.endswith("\n"):
            text += "\n"
        payload = text.encode("utf-8")
        async with rec.send_lock:
            await conn.send(text)
        rec.outbound.append(
            RecordedFrame(
                seq=len(rec.outbound),
                at=time.monotonic() - rec.t0,
                size=len(payload),
                text=text,
                frame=_try_json(text),
            )
        )

    # -- directives ---------------------------------------------------------
    async def _run_script(
        self, conn: ServerConnection, rec: ConnectionRecord, items: list[ScriptItem]
    ) -> None:
        for item in items:
            if item.frame is not None:
                await self._send(conn, rec, item.raw if item.raw is not None else dumps_frame(item.frame))
                continue
            d = item.directive or {}
            if "sleep" in d:
                await asyncio.sleep(float(d["sleep"]))
            if "mark" in d:
                rec.marks.append((time.monotonic() - rec.t0, str(d["mark"])))
            if "reply" in d:
                await self._do_reply(conn, rec, d["reply"])
            if "auto_reply" in d:
                rec.auto.update(d["auto_reply"])
                # Answer anything already waiting (the client may have raced ahead).
                for f in list(rec.inbound):
                    fr = f.frame or {}
                    if fr.get("method") in rec.auto and fr.get("id") is not None:
                        key = _id_key(fr["id"])
                        if key in rec.responded:
                            continue
                        rec.responded.add(key)
                        spec = rec.auto[fr["method"]]
                        response: dict[str, Any] = {"jsonrpc": "2.0", "id": fr["id"]}
                        if "error" in spec:
                            response["error"] = spec["error"]
                        else:
                            response["result"] = spec.get("result")
                        await self._send(conn, rec, dumps_frame(response))
            if "wait_for" in d:
                await self._do_wait(rec, d["wait_for"])
            if "wait_for_response" in d:
                await self._do_wait_response(rec, d["wait_for_response"])
            if "require" in d:
                for method in d["require"]:
                    await self._do_wait(rec, {"method": method})
            if "unmatched" in d:
                rec.policy = d["unmatched"]  # type: ignore[attr-defined]
            if "close" in d:
                spec = d["close"] or {}
                code = int(spec.get("code", 1000))
                reason = str(spec.get("reason", ""))
                await conn.close(code, reason)
                rec.closed_code, rec.closed_reason = code, reason
                raise _ScriptClose

    async def _do_wait(self, rec: ConnectionRecord, spec: Any) -> None:
        method = spec["method"]
        occurrence = int(spec.get("occurrence", 1))
        timeout = float(spec.get("timeout", DEFAULT_TIMEOUT))

        def pred() -> bool:
            hits = [f for f in rec.inbound if f.frame and f.frame.get("method") == method]
            return len(hits) >= occurrence

        await self._await(
            rec, pred, f"request {method!r}#{occurrence}", timeout
        )

    async def _do_wait_response(self, rec: ConnectionRecord, spec: Any) -> None:
        wanted = _id_key(spec["id"])
        timeout = float(spec.get("timeout", DEFAULT_TIMEOUT))

        def pred() -> bool:
            return any(
                f.frame
                and "method" not in f.frame
                and f.frame.get("id") is not None
                and _id_key(f.frame["id"]) == wanted
                for f in rec.inbound
            )

        await self._await(rec, pred, f"answer to {spec['id']!r}", timeout)

    async def _do_reply(self, conn: ServerConnection, rec: ConnectionRecord, spec: Any) -> None:
        method = spec["method"]
        timeout = float(spec.get("timeout", DEFAULT_TIMEOUT))

        def find() -> dict | None:
            for f in rec.inbound:
                fr = f.frame or {}
                if (
                    fr.get("method") == method
                    and fr.get("id") is not None
                    and _id_key(fr["id"]) not in rec.responded
                ):
                    return fr
            return None

        request = await self._await_value(rec, find, f"request {method!r}", timeout)
        frame: dict[str, Any] = {"jsonrpc": "2.0", "id": request["id"]}
        if "error" in spec:
            frame["error"] = spec["error"]
        else:
            frame["result"] = spec.get("result")
        rec.responded.add(_id_key(request["id"]))
        if spec.get("delay"):
            await asyncio.sleep(float(spec["delay"]))
        await self._send(conn, rec, dumps_frame(frame))

    # -- waiting ------------------------------------------------------------
    async def _await(self, rec: ConnectionRecord, pred, what: str, timeout: float) -> None:
        await self._await_value(rec, lambda: True if pred() else None, what, timeout)

    async def _await_value(self, rec: ConnectionRecord, find, what: str, timeout: float):
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while True:
            value = find()
            if value is not None:
                return value
            remaining = deadline - loop.time()
            if remaining <= 0:
                raise ScriptTimeout(
                    f"waited {timeout:.1f}s for {what}; saw inbound "
                    f"{rec.inbound_methods() or '<nothing>'}"
                )
            rec.wakeup.clear()  # type: ignore[attr-defined]
            if find() is not None:
                continue
            try:
                await asyncio.wait_for(rec.wakeup.wait(), remaining)  # type: ignore[attr-defined]
            except (asyncio.TimeoutError, TimeoutError):
                raise ScriptTimeout(
                    f"waited {timeout:.1f}s for {what}; saw inbound "
                    f"{rec.inbound_methods() or '<nothing>'}"
                ) from None


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #


def _id_key(value: Any) -> str:
    """Compare ids the way a proxy must: 1 and "1" are different ids."""
    return f"{type(value).__name__}:{value}"


def _try_json(text: str) -> dict | None:
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def serve_forever(path: str, host: str = "127.0.0.1", port: int = 9400) -> None:
    server = ReplayServer(path, host=host, port=port).start()
    print(f"replaying {path} on {server.url} (ctrl-c to stop)", flush=True)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        server.stop()


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Replay Hermes gateway fixtures over WebSocket")
    parser.add_argument("script", help="scenario .ndjson, or a recorded fixtures/*.ndjson")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9400)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s %(message)s",
    )
    try:
        serve_forever(args.script, args.host, args.port)
    except ScriptError as exc:
        print(f"scenario error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
