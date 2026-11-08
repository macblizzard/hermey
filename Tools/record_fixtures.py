#!/usr/bin/env python3
"""Record the Hermes TUI gateway's stdio protocol into an ndjson transcript.

The gateway (``python -m tui_gateway.entry``) reads newline-delimited JSON-RPC
from stdin and writes newline-delimited JSON-RPC to stdout. This script spawns
one in a throwaway ``HERMES_HOME``, plays a small script of requests, and appends
every frame in both directions to a file as it happens.

Why a recorder instead of docs: Hermes' protocol drifts between releases, and the
fixtures are what the client tests are pinned to. Where the docs and the recorded
bytes disagree, the bytes win (see ``fixtures/NOTES.md``).

Usage::

    python Tools/record_fixtures.py --out fixtures/m0-handshake.ndjson
    python Tools/record_fixtures.py --script Tools/scripts/approval.json \\
        --gateway-python /path/to/hermes/venv/bin/python --keep-home

Output, one record per line::

    {"t": 1762345678.123, "dir": "stdin",  "frame": {...}}
    {"t": 1762345678.456, "dir": "stdout", "frame": {...}}

``dir`` is relative to the gateway: ``stdin`` frames were sent to it, ``stdout``
frames came from it. A line that is not JSON is kept verbatim under ``raw`` so a
traceback printed on stdout is not lost.

The file is opened in append mode and never truncated -- two recordings can be
concatenated into one transcript. ``--raw-out`` additionally writes the gateway's
stdout frames as bare JSON lines, the shape of ``fixtures/m0-handshake.ndjson``.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional, Sequence, TextIO

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT_DIR = REPO_ROOT / "fixtures"

#: The M0 handshake: liveness, the mandatory capability declaration, the
#: gateway's own capabilities, and one deliberate unknown method so the -32601
#: error envelope is captured too.
DEFAULT_SCRIPT: list[dict[str, Any]] = [
    {"jsonrpc": "2.0", "id": 1, "method": "ping"},
    {"jsonrpc": "2.0", "id": 2, "method": "client.capabilities", "params": {"server_requests": True}},
    {"jsonrpc": "2.0", "id": 3, "method": "gateway.capabilities"},
    {"jsonrpc": "2.0", "id": 4, "method": "no.such.method"},
]


class Recorder:
    def __init__(
        self,
        out_path: Path,
        gateway_python: str,
        home: Path,
        cwd: Path,
        script: list[dict[str, Any]],
        settle: float,
        timeout: float,
        raw_out: Optional[Path],
        env_overrides: dict[str, str],
        echo: bool = False,
    ) -> None:
        self.out_path = out_path
        self.gateway_python = gateway_python
        self.home = home
        self.cwd = cwd
        self.script = script
        self.settle = settle
        self.timeout = timeout
        self.raw_out = raw_out
        self.env_overrides = env_overrides
        self.echo = echo

        self._lock = threading.Lock()
        self._out: Optional[TextIO] = None
        self._raw: Optional[TextIO] = None
        self._ready = threading.Event()
        self._eof = threading.Event()
        self.counts = {"stdin": 0, "stdout": 0, "malformed": 0}
        self.stderr_lines: list[str] = []
        self._stderr_path = out_path.with_suffix(out_path.suffix + ".stderr.log")

    # -- process plumbing --------------------------------------------------

    def _environment(self) -> dict[str, str]:
        env = os.environ.copy()
        env["HERMES_HOME"] = str(self.home)
        env["PYTHONUNBUFFERED"] = "1"
        # A recording must not be held open by the sidecar publisher or by a
        # slow shutdown grace.
        env.pop("HERMES_TUI_SIDECAR_URL", None)
        env["HERMES_TUI_GATEWAY_SHUTDOWN_GRACE_S"] = "0.5"
        env.update(self.env_overrides)
        return env

    def _record(self, direction: str, payload: str) -> None:
        payload = payload.strip()
        if not payload:
            return
        entry: dict[str, Any] = {"t": round(time.time(), 3), "dir": direction}
        try:
            frame = json.loads(payload)
        except json.JSONDecodeError:
            entry["raw"] = payload
            with self._lock:
                self.counts["malformed"] += 1
                self.counts[direction] += 1
                if self._out:
                    self._out.write(json.dumps(entry, ensure_ascii=False) + "\n")
                    self._out.flush()
            return
        entry["frame"] = frame
        with self._lock:
            self.counts[direction] += 1
            if self._out:
                self._out.write(json.dumps(entry, ensure_ascii=False) + "\n")
                self._out.flush()
            if direction == "stdout" and self._raw:
                self._raw.write(json.dumps(frame, ensure_ascii=False) + "\n")
                self._raw.flush()
        if direction == "stdout" and isinstance(frame, dict):
            params = frame.get("params")
            if isinstance(params, dict) and params.get("type") == "gateway.ready":
                self._ready.set()
        if self.echo:
            print(f"[{direction}] {payload}", file=sys.stderr)

    def _read_stdout(self, stream) -> None:
        try:
            for raw in iter(stream.readline, b""):
                self._record("stdout", raw.decode("utf-8", "replace"))
        finally:
            self._eof.set()

    def _read_stderr(self, stream) -> None:
        try:
            with open(self._stderr_path, "w", encoding="utf-8") as log:
                for raw in iter(stream.readline, b""):
                    text = raw.decode("utf-8", "replace")
                    log.write(text)
                    log.flush()
                    with self._lock:
                        self.stderr_lines.append(text.rstrip())
                        if len(self.stderr_lines) > 80:
                            del self.stderr_lines[: len(self.stderr_lines) - 80]
        except OSError:
            pass

    # -- run ---------------------------------------------------------------

    def run(self) -> int:
        self.out_path.parent.mkdir(parents=True, exist_ok=True)
        self._out = open(self.out_path, "a", encoding="utf-8")
        if self.raw_out:
            self.raw_out.parent.mkdir(parents=True, exist_ok=True)
            self._raw = open(self.raw_out, "a", encoding="utf-8")

        cmd = [self.gateway_python, "-m", "tui_gateway.entry"]
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(self.cwd),
            env=self._environment(),
            bufsize=0,
        )
        readers = [
            threading.Thread(target=self._read_stdout, args=(proc.stdout,), daemon=True),
            threading.Thread(target=self._read_stderr, args=(proc.stderr,), daemon=True),
        ]
        for reader in readers:
            reader.start()

        deadline = time.monotonic() + self.timeout
        exit_code: Optional[int] = None
        try:
            # gateway.ready is written before the first request is read, but a
            # client may write first; waiting only keeps the transcript tidy.
            self._ready.wait(timeout=min(15.0, self.timeout))
            self._send_script(proc, deadline)
            if self.settle > 0:
                time.sleep(min(self.settle, max(0.0, deadline - time.monotonic())))
            try:
                if proc.stdin and not proc.stdin.closed:
                    proc.stdin.close()
            except OSError:
                pass
            remaining = max(1.0, deadline - time.monotonic())
            try:
                exit_code = proc.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try:
                    exit_code = proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    exit_code = proc.wait(timeout=5)
                print(
                    f"record_fixtures: gateway did not exit within {self.timeout}s; killed",
                    file=sys.stderr,
                )
        finally:
            for reader in readers:
                reader.join(timeout=5)
            try:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=5)
            except OSError:
                pass
            self._close_files()

        self._report(exit_code)
        if exit_code not in (0, None):
            return exit_code or 1
        if not self._ready.is_set():
            print(
                "record_fixtures: no gateway.ready frame was captured; check the stderr log",
                file=sys.stderr,
            )
            return 1
        return 0

    def _send_script(self, proc: subprocess.Popen, deadline: float) -> None:
        assert proc.stdin is not None
        for frame in self.script:
            if time.monotonic() > deadline:
                break
            payload = json.dumps(frame, separators=(",", ":"))
            try:
                proc.stdin.write((payload + "\n").encode("utf-8"))
                proc.stdin.flush()
            except (BrokenPipeError, ValueError):
                break
            self._record("stdin", payload)
            time.sleep(0.15)

    def _close_files(self) -> None:
        with self._lock:
            for handle in (self._out, self._raw):
                if handle:
                    try:
                        handle.close()
                    except OSError:
                        pass
            self._out = None
            self._raw = None

    def _report(self, exit_code: Optional[int]) -> None:
        print(
            f"record_fixtures: {self.counts['stdout']} stdout frames, "
            f"{self.counts['stdin']} stdin frames "
            f"({self.counts['malformed']} non-JSON) -> {self.out_path}",
            file=sys.stderr,
        )
        if self.raw_out:
            print(f"record_fixtures: raw stdout frames -> {self.raw_out}", file=sys.stderr)
        if self.counts["malformed"]:
            print(
                "record_fixtures: non-JSON lines were kept under \"raw\"; "
                "they usually mean the gateway crashed",
                file=sys.stderr,
            )
        if exit_code not in (0, None):
            print(f"record_fixtures: gateway exited {exit_code}", file=sys.stderr)
            if self.stderr_lines:
                print("--- gateway stderr (tail) ---", file=sys.stderr)
                for line in self.stderr_lines[-20:]:
                    print(line, file=sys.stderr)


def load_script(path: Optional[Path]) -> list[dict[str, Any]]:
    if path is None:
        return list(DEFAULT_SCRIPT)
    text = path.read_text(encoding="utf-8")
    stripped = text.lstrip()
    if stripped.startswith("["):
        data = json.loads(text)
        if not isinstance(data, list):
            raise ValueError("script JSON must be an array of frames")
        return [frame for frame in data if isinstance(frame, dict)]
    script: list[dict[str, Any]] = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        frame = json.loads(line)
        if isinstance(frame, dict):
            script.append(frame)
    return script


def gateway_python_works(python: str, cwd: Path) -> bool:
    try:
        result = subprocess.run(
            [python, "-c", "import tui_gateway.entry"],
            cwd=str(cwd),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    if result.returncode != 0:
        detail = (result.stderr or b"").decode("utf-8", "replace").strip().splitlines()
        if detail:
            print(f"record_fixtures: {detail[-1]}", file=sys.stderr)
    return result.returncode == 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="record_fixtures.py", description=__doc__.splitlines()[0]
    )
    parser.add_argument("--out", type=Path, help="ndjson transcript to append to")
    parser.add_argument("--raw-out", type=Path, help="also write bare gateway stdout frames")
    parser.add_argument("--script", type=Path, help="ndjson (or JSON array) of frames to send")
    parser.add_argument(
        "--gateway-python",
        default=os.environ.get("HERMES_GATEWAY_PYTHON") or sys.executable,
        help="interpreter that can import tui_gateway (default: $HERMES_GATEWAY_PYTHON)",
    )
    parser.add_argument("--cwd", type=Path, default=Path.cwd(), help="gateway working directory")
    parser.add_argument("--home", type=Path, help="HERMES_HOME to use instead of a temp dir")
    parser.add_argument("--keep-home", action="store_true", help="do not delete the temp HERMES_HOME")
    parser.add_argument("--settle", type=float, default=1.0, help="seconds to wait before closing stdin")
    parser.add_argument("--timeout", type=float, default=60.0, help="hard limit for the gateway process")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE")
    parser.add_argument("--echo", action="store_true", help="echo frames to stderr while recording")
    args = parser.parse_args(argv)

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = args.out or (DEFAULT_OUT_DIR / f"recorded-{stamp}.ndjson")
    env_overrides: dict[str, str] = {}
    for item in args.env:
        key, sep, value = item.partition("=")
        if not sep or not key:
            parser.error(f"--env expects KEY=VALUE, got {item!r}")
        env_overrides[key] = value

    try:
        script = load_script(args.script)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"record_fixtures: bad script: {exc}", file=sys.stderr)
        return 2
    if not script:
        print("record_fixtures: script is empty", file=sys.stderr)
        return 2

    if not gateway_python_works(args.gateway_python, args.cwd):
        print(
            "record_fixtures: that interpreter cannot import tui_gateway.entry; "
            "pass --gateway-python /path/to/hermes/venv/bin/python "
            "(or set HERMES_GATEWAY_PYTHON)",
            file=sys.stderr,
        )
        return 2

    temporary_home = args.home is None
    home = args.home or Path(tempfile.mkdtemp(prefix="hermes-fixture-home-"))
    home.mkdir(parents=True, exist_ok=True)

    recorder = Recorder(
        out_path=out,
        gateway_python=args.gateway_python,
        home=home,
        cwd=args.cwd,
        script=script,
        settle=args.settle,
        timeout=args.timeout,
        raw_out=args.raw_out,
        env_overrides=env_overrides,
        echo=args.echo,
    )
    try:
        return recorder.run()
    finally:
        if temporary_home and not args.keep_home:
            shutil.rmtree(home, ignore_errors=True)
        elif temporary_home:
            print(f"record_fixtures: kept HERMES_HOME at {home}", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
