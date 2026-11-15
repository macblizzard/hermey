"""Regressions for the audit's fixes.

Four things used to fail quietly and are pinned here:

* **one resolver for the profiles root.** Four modules carried their own copy of "where do the bots
  live", and three of them ignored ``HERMES_PROFILES_ROOT`` — the variable the installer sets — so
  a correct install could answer "no bots" from the previews, the search, the banner watcher and
  the attachment route while the roster was full.
* **the disabled-bots file is state, not a scratch pad.** It was written in place (a partial write
  read back as "nothing is disabled", i.e. every bot quietly back on) and mutated without a lock
  (two devices toggling two bots lost one of the changes).
* **a restore used to file bots into a category id that only existed on the other host**, and it
  interpolated a backup's description straight into ``profile.yaml``, where a newline opened keys.
* **a genui card session outlived the device that minted it**; revocation has to land there too.
"""
from __future__ import annotations

import json
import sqlite3
import threading
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from hermes_bridge import bot_admin, paths
from hermes_bridge.app import _pairing_ttl, create_app
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


def _profile_with_a_message(root: Path, name: str, text: str = "hello from a preview") -> None:
    directory = root / name
    directory.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(directory / "state.db")
    conn.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at REAL, last_activity_at REAL)")
    conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT,"
                 " role TEXT, content TEXT, timestamp REAL)")
    conn.execute("INSERT INTO sessions VALUES ('s1', 0, 0)")
    conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?,?,?,?)",
                 ("s1", "assistant", text, 1.0))
    conn.commit()
    conn.close()


# -- one resolver -----------------------------------------------------------


def test_the_installer_variable_is_the_one_answer(tmp_path, monkeypatch) -> None:
    root = tmp_path / "somewhere" / "profiles"
    monkeypatch.setenv("HERMES_PROFILES_ROOT", str(root))
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "ignored"))
    assert paths.profiles_root() == root


def test_a_profile_home_names_its_siblings(tmp_path, monkeypatch) -> None:
    """The gateway often carries ``~/.hermes/profiles/<name>`` in HERMES_HOME; bots are its siblings."""
    home = tmp_path / "install"
    (home / "profiles" / "cody").mkdir(parents=True)
    monkeypatch.delenv("HERMES_PROFILES_ROOT", raising=False)
    monkeypatch.setenv("HERMES_HOME", str(home / "profiles" / "cody"))
    assert paths.profiles_root() == home / "profiles"


def test_previews_and_search_read_that_root(tmp_path, monkeypatch) -> None:
    root = tmp_path / "elsewhere" / "profiles"
    monkeypatch.setenv("HERMES_PROFILES_ROOT", str(root))
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "wrong-home"))
    _profile_with_a_message(root, "fino")

    with _app(tmp_path) as client:
        previews = client.get("/v1/bots/previews", headers=_auth(client))
        assert previews.status_code == 200, previews.text
        assert "fino" in previews.json()["previews"], previews.json()

        found = client.get("/v1/search?q=preview", headers=_auth(client))
        assert found.status_code == 200, found.text
        assert [row["profile"] for row in found.json()["results"]] == ["fino"]


# -- the disabled-bots file -------------------------------------------------


def test_a_corrupt_state_file_is_kept_and_never_read_as_enabled(tmp_path, monkeypatch) -> None:
    state = tmp_path / "disabled-bots.json"
    state.write_text('{"cody": {"enabled": fal', encoding="utf-8")
    monkeypatch.setattr(bot_admin, "STATE_FILE", state)

    assert bot_admin._read_state() == {}
    assert bot_admin.disabled_profiles() == set()
    # The bytes are still there to recover from, and the damage is visible on disk.
    assert state.with_suffix(".json.damaged").read_text(encoding="utf-8") == '{"cody": {"enabled": fal'


def test_state_writes_are_atomic_and_leave_no_scratch_file(tmp_path, monkeypatch) -> None:
    state = tmp_path / "disabled-bots.json"
    monkeypatch.setattr(bot_admin, "STATE_FILE", state)

    bot_admin._write_state({"cody": {"enabled": False, "paused_jobs": []}})

    assert json.loads(state.read_text(encoding="utf-8"))["cody"]["enabled"] is False
    assert [p.name for p in tmp_path.iterdir()] == ["disabled-bots.json"]


def test_two_toggles_do_not_lose_each_other(tmp_path, monkeypatch) -> None:
    """The read-modify-write is under one lock: twenty writers, twenty markers."""
    state = tmp_path / "disabled-bots.json"
    monkeypatch.setattr(bot_admin, "STATE_FILE", state)

    def disable(index: int) -> None:
        bot_admin._mutate_state(
            lambda document: document.__setitem__(f"bot{index}", {"enabled": False}))

    threads = [threading.Thread(target=disable, args=(index,)) for index in range(20)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert len(bot_admin.disabled_profiles()) == 20


def test_a_hostile_job_id_never_reaches_the_dashboard_url() -> None:
    """The paused ids come back off disk, so they are filtered before they are interpolated."""
    entry = {"enabled": False, "paused_jobs": ["../../api/profiles/cody", "ok-1", 7, None]}
    assert bot_admin._known_job_ids(entry) == ["ok-1"]
    assert bot_admin._known_job_ids({"paused_jobs": "not-a-list"}) == []


# -- restore ---------------------------------------------------------------


def test_a_restore_files_a_bot_into_the_local_category(tmp_path, monkeypatch) -> None:
    root = tmp_path / "profiles"
    root.mkdir()
    monkeypatch.setenv("HERMES_PROFILES_ROOT", str(root))

    document = {
        "version": 1,
        "bots": [{"profile": "aria", "soul": "You are Aria.", "categories": ["foreign-id"]}],
        # The id belongs to the host that wrote the backup; the name is what travels.
        "categories": [{"id": "foreign-id", "name": "Work"}],
    }
    with _app(tmp_path) as client:
        restored = client.post("/v1/backup/restore", json=document, headers=_auth(client))
        assert restored.status_code == 200, restored.text
        assert restored.json()["skipped"] == []

        categories = client.get("/v1/bot-categories", headers=_auth(client)).json()
        assert [c["name"] for c in categories["categories"]] == ["Work"]
        local_id = categories["categories"][0]["id"]
        assert local_id != "foreign-id"
        assert categories["assignments"] == {"aria": local_id}


def test_a_description_cannot_open_a_yaml_key(tmp_path, monkeypatch) -> None:
    root = tmp_path / "profiles"
    root.mkdir()
    monkeypatch.setenv("HERMES_PROFILES_ROOT", str(root))

    document = {"version": 1, "categories": [], "bots": [
        {"profile": "aria", "description": "Ops\nmodel: opus\nprovider: evil", "soul": "x"},
    ]}
    with _app(tmp_path) as client:
        assert client.post("/v1/backup/restore", json=document,
                           headers=_auth(client)).status_code == 200

    written = (root / "aria" / "profile.yaml").read_text(encoding="utf-8")
    assert written.splitlines() == ['description: "Ops model: opus provider: evil"',
                                    "description_auto: false"]


# -- a card session dies with its device ------------------------------------


def test_a_card_session_stops_working_when_its_device_is_revoked(tmp_path, monkeypatch) -> None:
    root = tmp_path / "profiles"
    boards = root / "fino" / "plugin-data" / "hermes-genui" / "blocks"
    boards.mkdir(parents=True)
    (boards / "00b7610f.json").write_text(json.dumps({"blocks": []}), encoding="utf-8")
    monkeypatch.setenv("HERMES_PROFILES_ROOT", str(root))

    app = create_app(BridgeConfig(db_path=tmp_path / "bridge.db"))
    app.state.bridge.registry.add_device(device_id="mac", name="mac", platform="test",
                                         public_key="test", refresh_token="secret")
    with TestClient(app) as client:
        session = client.post("/v1/genui/session?bot=fino", headers=_auth(client)).json()["session"]
        assert client.get(f"/v1/genui/blocks/00b7610f?bot=fino&session={session}").status_code == 200

        app.state.bridge.registry.revoke("mac")

        # Without the registry check this is a 200 for the rest of the session's two minutes.
        assert client.get(f"/v1/genui/blocks/00b7610f?bot=fino&session={session}").status_code == 401


# -- room attachments -------------------------------------------------------


@pytest.mark.parametrize("hostile", ["../../etc/passwd", "..", "a/b", "\x00evil", "  "])
def test_a_room_attachment_cannot_climb_out_of_its_folder(tmp_path, monkeypatch, hostile: str) -> None:
    """The picked name is a label, never a path: it is reduced to one safe component."""
    from hermes_bridge import rooms

    monkeypatch.setattr(rooms, "ATTACHMENT_ROOT", tmp_path / "room-attachments")
    written = rooms._store_attachments("room-1", [rooms.RoomAttachmentIn(
        name=hostile, data_base64="aGVsbG8=")])

    assert len(written) == 1
    _label, path = written[0]
    folder = tmp_path / "room-attachments" / "room-1"
    assert path.parent == folder
    # One component, under this room's folder: the uuid prefix means even a name of ".." is a file
    # name here rather than a parent directory.
    assert "/" not in path.name and "\\" not in path.name
    assert path.resolve().is_relative_to(folder.resolve())
    assert path.read_bytes() == b"hello"


# -- an operator convenience is not a policy dial ---------------------------


@pytest.mark.parametrize("configured, expected", [
    ("120", 120),
    ("nonsense", 600),
    ("1", 30),
    ("31536000", 3600),
    ("", 600),
])
def test_the_pairing_ttl_is_clamped(monkeypatch, configured: str, expected: int) -> None:
    monkeypatch.setenv("HERMES_BRIDGE_PAIRING_TTL", configured)
    assert _pairing_ttl() == expected
