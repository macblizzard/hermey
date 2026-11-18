"""The audit's bot-admin hardening, pinned.

These are the three behaviours that made the old implementation dangerous:

* dashboard calls ran under the *state-file* lock, so one slow answer stalled every other bot
  toggle for the whole request timeout;
* a partial disable dropped the record of the jobs it had already paused, which meant a later
  enable had nothing to resume;
* deleted-bot archives accumulated forever, because nothing ever pruned them.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from fastapi import HTTPException
from fastapi.testclient import TestClient

from hermes_bridge import bot_admin
from hermes_bridge.app import create_app
from hermes_bridge.config import BridgeConfig


def _app(tmp_path: Path, *, device: str = "mac") -> TestClient:
    config = BridgeConfig(db_path=tmp_path / "bridge.db")
    config.validate()
    app = create_app(config)
    app.state.bridge.registry.add_device(device_id=device, name=device, platform="test",
                                         public_key="test", refresh_token="secret")
    return TestClient(app)


def _auth(client: TestClient, device: str = "mac") -> dict[str, str]:
    ticket = client.post("/v1/token", json={"device_id": device,
                                            "refresh_token": "secret"}).json()["ws_ticket"]
    return {"Authorization": "Bearer " + ticket}


def _profile_root(tmp_path: Path, name: str = "aria") -> Path:
    root = tmp_path / "profiles"
    (root / name).mkdir(parents=True, exist_ok=True)
    return root


def test_dashboard_calls_do_not_hold_the_state_lock(tmp_path, monkeypatch) -> None:
    root = _profile_root(tmp_path)
    monkeypatch.setenv("HERMES_PROFILES_ROOT", str(root))
    state = tmp_path / "disabled-bots.json"
    monkeypatch.setattr(bot_admin, "STATE_FILE", state)

    seen: list[bool] = []

    def fake_dashboard(method: str, path: str, body: dict | None = None):
        # The route must not be holding the state-file lock while it talks to the dashboard.
        # A plain `acquire()` would deadlock if it were; a timed one answers the question.
        seen.append(bot_admin._STATE_LOCK.acquire(timeout=0.2))
        bot_admin._STATE_LOCK.release()
        if method == "GET":
            return 200, []
        return 200, {}

    monkeypatch.setattr(bot_admin, "_dashboard", fake_dashboard)

    with _app(tmp_path) as client:
        answer = client.post("/v1/bots/aria/state", json={"enabled": False},
                             headers=_auth(client))
    assert answer.status_code == 200, answer.text
    assert seen and all(seen), "dashboard calls ran under the state-file lock"


def test_a_partial_disable_still_records_the_jobs_it_paused(tmp_path, monkeypatch) -> None:
    root = _profile_root(tmp_path)
    monkeypatch.setenv("HERMES_PROFILES_ROOT", str(root))
    state = tmp_path / "disabled-bots.json"
    monkeypatch.setattr(bot_admin, "STATE_FILE", state)

    def fake_dashboard(method: str, path: str, body: dict | None = None):
        if method == "GET":
            return 200, [
                {"id": "job-a", "paused": False},
                {"id": "job-b", "paused": False},
            ]
        if method == "POST" and "/job-b/pause" in path:
            # One refusal in the middle of the batch: the first job is already paused.
            raise HTTPException(status_code=502, detail="dashboard refused")
        return 200, {}

    monkeypatch.setattr(bot_admin, "_dashboard", fake_dashboard)

    with _app(tmp_path) as client:
        answer = client.post("/v1/bots/aria/state", json={"enabled": False},
                             headers=_auth(client))
    assert answer.status_code == 200, answer.text
    payload = answer.json()
    assert payload["paused_jobs"] == ["job-a"]
    assert payload["failed_jobs"] == ["job-b"]

    written = json.loads(state.read_text(encoding="utf-8"))["aria"]
    assert written["paused_jobs"] == ["job-a"], "the already-paused job was lost"


def test_a_partial_enable_keeps_the_unresumed_job_on_disk(tmp_path, monkeypatch) -> None:
    root = _profile_root(tmp_path)
    monkeypatch.setenv("HERMES_PROFILES_ROOT", str(root))
    state = tmp_path / "disabled-bots.json"
    state.write_text(json.dumps({
        "aria": {"enabled": False,
                 "disabled_at": time.time(),
                 "paused_jobs": ["job-a", "job-b"]}
    }), encoding="utf-8")
    monkeypatch.setattr(bot_admin, "STATE_FILE", state)

    def fake_dashboard(method: str, path: str, body: dict | None = None):
        if method == "POST" and "/job-a/resume" in path:
            return 200, {}
        if method == "POST" and "/job-b/resume" in path:
            raise HTTPException(status_code=502, detail="dashboard refused")
        return 200, {}

    monkeypatch.setattr(bot_admin, "_dashboard", fake_dashboard)

    with _app(tmp_path) as client:
        answer = client.post("/v1/bots/aria/state", json={"enabled": True},
                             headers=_auth(client))
    assert answer.status_code == 200, answer.text
    payload = answer.json()
    assert payload["resumed_jobs"] == ["job-a"]
    assert payload["failed_jobs"] == ["job-b"]

    written = json.loads(state.read_text(encoding="utf-8"))["aria"]
    assert written["paused_jobs"] == ["job-b"], "the unresumed job was forgotten"


def test_deleted_bot_archives_are_capped(tmp_path, monkeypatch) -> None:
    archive_dir = tmp_path / "deleted-bots"
    archive_dir.mkdir()
    monkeypatch.setattr(bot_admin, "ARCHIVE_DIR", archive_dir)

    for index in range(30):
        (archive_dir / f"bot-{index:02d}.tar.gz").write_bytes(b"archive")

    bot_admin._prune_archives()

    remaining = sorted(path.name for path in archive_dir.glob("*.tar.gz"))
    assert len(remaining) == bot_admin.ARCHIVE_KEEP
    # The newest survive; the oldest are the stale copies.
    assert "bot-29.tar.gz" in remaining
    assert "bot-00.tar.gz" not in remaining


def test_the_dashboard_timeout_is_short() -> None:
    """A loopback call has no business taking two minutes to answer."""
    assert bot_admin.REQUEST_TIMEOUT <= 10
