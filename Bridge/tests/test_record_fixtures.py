"""The recorder is exercised against a stand-in gateway, not the real one.

CI has no Hermes install, so the test builds a minimal ``tui_gateway`` package
that speaks the same stdio envelope: one ``gateway.ready`` event, then an echo
for every request. The recorder must capture both directions verbatim.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RECORDER = REPO_ROOT / "Tools" / "record_fixtures.py"

FAKE_ENTRY = '''\
import json
import sys


def main():
    print(json.dumps({"jsonrpc": "2.0", "method": "event",
                      "params": {"type": "gateway.ready", "payload": {"replay_epoch": "fake"}}}),
          flush=True)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        request = json.loads(line)
        print(json.dumps({"jsonrpc": "2.0", "id": request.get("id"),
                          "result": {"echo": request.get("method")}}), flush=True)


if __name__ == "__main__":
    main()
'''


def install_fake_gateway(tmp_path: Path) -> Path:
    package = tmp_path / "tui_gateway"
    package.mkdir()
    (package / "__init__.py").write_text("", encoding="utf-8")
    (package / "entry.py").write_text(FAKE_ENTRY, encoding="utf-8")
    return tmp_path


def run_recorder(tmp_path: Path, out: Path, *extra: str) -> subprocess.CompletedProcess:
    script = tmp_path / "script.ndjson"
    script.write_text(
        '{"jsonrpc": "2.0", "id": 1, "method": "ping"}\n'
        '{"jsonrpc": "2.0", "id": 2, "method": "gateway.capabilities"}\n',
        encoding="utf-8",
    )
    env = os.environ.copy()
    env["PYTHONPATH"] = str(tmp_path)
    return subprocess.run(
        [
            sys.executable,
            str(RECORDER),
            "--out",
            str(out),
            "--script",
            str(script),
            "--gateway-python",
            sys.executable,
            "--cwd",
            str(tmp_path),
            "--timeout",
            "30",
            "--settle",
            "0.3",
            *extra,
        ],
        capture_output=True,
        text=True,
        timeout=90,
        env=env,
    )


def test_recorder_writes_every_frame_both_directions(tmp_path):
    install_fake_gateway(tmp_path)
    out = tmp_path / "trace.ndjson"
    result = run_recorder(tmp_path, out)
    assert result.returncode == 0, result.stderr

    records = [json.loads(line) for line in out.read_text(encoding="utf-8").splitlines()]
    assert {record["dir"] for record in records} == {"stdin", "stdout"}
    assert all("t" in record for record in records)

    stdout_frames = [r["frame"] for r in records if r["dir"] == "stdout"]
    assert stdout_frames[0]["params"]["type"] == "gateway.ready"
    echoes = [f["result"]["echo"] for f in stdout_frames if "result" in f]
    assert echoes == ["ping", "gateway.capabilities"]

    sent = [f for r in records if r["dir"] == "stdin" for f in [r["frame"]]]
    assert [frame["method"] for frame in sent] == ["ping", "gateway.capabilities"]


def test_recorder_appends_and_can_emit_a_raw_fixture(tmp_path):
    install_fake_gateway(tmp_path)
    out = tmp_path / "trace.ndjson"
    raw = tmp_path / "raw.ndjson"

    first = run_recorder(tmp_path, out, "--raw-out", str(raw))
    assert first.returncode == 0, first.stderr
    lines_after_first = len(out.read_text(encoding="utf-8").splitlines())

    second = run_recorder(tmp_path, out)
    assert second.returncode == 0, second.stderr
    assert len(out.read_text(encoding="utf-8").splitlines()) > lines_after_first

    raw_frames = [json.loads(line) for line in raw.read_text(encoding="utf-8").splitlines()]
    assert raw_frames[0]["params"]["type"] == "gateway.ready"


def test_recorder_reports_a_missing_gateway_module(tmp_path):
    # No tui_gateway package on the path.
    empty = tmp_path / "empty"
    empty.mkdir()
    result = subprocess.run(
        [
            sys.executable,
            str(RECORDER),
            "--out",
            str(tmp_path / "trace.ndjson"),
            "--gateway-python",
            sys.executable,
            "--cwd",
            str(empty),
        ],
        capture_output=True,
        text=True,
        timeout=60,
        env={**os.environ, "PYTHONPATH": str(empty)},
    )
    assert result.returncode == 2
    assert "tui_gateway" in result.stderr
