#!/usr/bin/env python3
"""Time `session.resume` for one stored conversation: the numbers a "slow open" is made of.

Two measurements, because they answer different questions:

  engine   the engine's own assembly, phase by phase, on a COPY of a profile's state.db — no
           gateway, no socket, nothing the owner can feel. Run it when you want to know whether a
           resume is slow because of the database, the projection or the wire.
  wire     a real WebSocket `session.resume` against the live gateway (127.0.0.1:9121), which is
           the path the phone's socket takes minus the relay and the internet.

Why it exists: opening a bot whose Bot Chat holds 6,778 messages (4.5 MB of text) took long enough
for the client's 120 s `session.resume` timer to fire. The database was not the problem — reading
every row takes 0.03 s. The engine's *display projection* was: `_history_to_messages` over the
whole lineage, 6.2 s of pure Python, 7.5 MiB of JSON, once per resume, with concurrent resumes
serialised behind each other (6.2 s / 12.6 s / 18.5 s for three sent together). These numbers are
what the fix is measured against.

Usage:
    # engine phases, on a copy of the profile's database
    cp ~/.hermes/profiles/cody/state.db* /tmp/bench/ && \
    TOOLS/python3 Tools/bench_resume.py engine /tmp/bench/state.db local-9b01…

    # the live gateway path (needs the engine's own token)
    Tools/bench_resume.py wire local-9b01… --profile cody

The engine half imports the gateway's own modules, so run it with the interpreter that serves the
gateway (the `hermes` launcher's python), not a virtualenv of your own.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

#: Where the installed engine lives. Overridable so a checkout can be measured instead.
ENGINE = Path("/usr/local/lib/hermes-agent")


def _stamp(label: str, started: float) -> float:
    spent = time.perf_counter() - started
    print(f"{label:<12} {spent * 1000:9.1f} ms")
    return spent


def measure_engine(db_path: Path, session_id: str) -> int:
    """`session.resume`'s assembly, on a database copy, phase by phase."""
    sys.path.insert(0, str(ENGINE))
    # `_history_to_messages` lives in `session_history`, whose bodies are rebound onto `server`'s
    # globals (`method_ctx.bind_module`); importing the module directly and calling it NameErrors.
    import tui_gateway.server as srv
    from agent.replay_cleanup import canonicalize_replay_history
    from hermes_state import SessionDB

    started = time.perf_counter()
    db = SessionDB(db_path, read_only=True)
    total = _stamp("open", started)

    started = time.perf_counter()
    model_history, display_history = db.get_resume_conversations(session_id)
    total += _stamp("select", started)

    started = time.perf_counter()
    canonicalize_replay_history(model_history)
    total += _stamp("repair", started)

    started = time.perf_counter()
    messages = srv._history_to_messages(display_history, profile_home=None, image_urls=True)
    total += _stamp("project", started)

    frame = {"jsonrpc": "2.0", "id": 1, "result": {
        "session_id": session_id, "resumed": session_id, "message_count": len(messages),
        "messages": messages, "info": {}, "inflight": None, "running": False,
        "session_key": session_id, "started_at": 0.0, "status": "idle",
    }}
    started = time.perf_counter()
    body = json.dumps(frame)
    total += _stamp("serialise", started)

    print(f"\nrows: display={len(display_history)} model={len(model_history)} "
          f"messages={len(messages)}")
    print(f"payload: {len(body) / 1024 / 1024:.2f} MiB of JSON in one frame")
    print(f"total (no socket): {total * 1000:.1f} ms")
    db.close()
    return 0


def measure_wire(session_id: str, profile: str, ws: str, token_file: Path) -> int:
    """One real `session.resume` over the gateway's WebSocket, timed to first frame and to answer."""
    from websockets.sync.client import connect

    token = token_file.read_text(encoding="utf-8").strip() if token_file.exists() else ""
    url = f"{ws}?token={token}" if token else ws
    params = {"session_id": session_id}
    if profile:
        params["profile"] = profile

    wsock = connect(url, max_size=None, open_timeout=15)
    started = time.perf_counter()
    wsock.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "session.resume",
                           "params": params}))
    first = None
    received = 0
    answer = None
    while answer is None:
        frame = wsock.recv(timeout=300)
        first = first if first is not None else time.perf_counter() - started
        received += len(frame)
        for line in frame.splitlines():
            if line.strip() and json.loads(line).get("id") == 1:
                answer = json.loads(line)
    total = time.perf_counter() - started
    wsock.close()

    result = (answer or {}).get("result") or {}
    print(f"first frame   {(first or 0.0) * 1000:9.1f} ms")
    print(f"answer        {total * 1000:9.1f} ms")
    print(f"wire bytes    {received / 1024 / 1024:9.2f} MiB")
    print(f"messages      {len(result.get('messages') or [])} "
          f"(message_count={result.get('message_count')})")
    print(f"history       {result.get('history')}")
    if answer.get("error"):
        print(f"error         {answer['error']}")
    print("\nA windowed resume — the relay's job — answers with a subset plus "
          "history{cursor,total}; the whole transcript means nothing windowed it above the relay.")
    return 0 if not answer.get("error") else 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    engine = sub.add_parser("engine", help="phase timings on a database copy")
    engine.add_argument("db", type=Path)
    engine.add_argument("session_id")
    wire = sub.add_parser("wire", help="a real WebSocket resume against a live gateway")
    wire.add_argument("session_id")
    wire.add_argument("--profile", default="")
    wire.add_argument("--ws", default="ws://127.0.0.1:9121/api/ws")
    wire.add_argument("--token-file", type=Path, default=Path("/var/lib/hermey/engine.token"))
    args = parser.parse_args(argv)

    if args.mode == "engine":
        return measure_engine(args.db, args.session_id)
    return measure_wire(args.session_id, args.profile, args.ws, args.token_file)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
