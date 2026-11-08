"""The bridge-owned shared session pointer, one per bot profile.

Both apps must agree on *the* conversation for a bot. The pointer lives in the
same registry DB as devices/bot_icons, is read/written only by paired devices,
and a PUT can never remove a row: an unknown bot is ``null``, never a 404.
"""

from __future__ import annotations

import threading
from concurrent.futures import ThreadPoolExecutor

import httpx
from fastapi.testclient import TestClient

from hermes_bridge.app import create_app
from hermes_bridge.config import BridgeConfig

PATH = "/v1/bots/research/session"
STORED = "20261106_165329_293f4b"


def _make_app(tmp_path, name: str = "bridge.db"):
    app = create_app(BridgeConfig(db_path=tmp_path / name))
    for device in ("phone", "mac"):
        app.state.bridge.registry.add_device(
            device_id=device,
            name=device,
            platform="test",
            public_key="test",
            refresh_token="secret-" + device,
        )
    return app


def _auth(client: TestClient, device: str = "phone") -> dict:
    response = client.post(
        "/v1/token", json={"device_id": device, "refresh_token": "secret-" + device}
    )
    assert response.status_code == 200, response.text
    return {"Authorization": "Bearer " + response.json()["ws_ticket"]}


def test_unknown_profile_is_null_and_two_devices_share_the_pointer(tmp_path):
    app = _make_app(tmp_path)
    with TestClient(app) as client:
        assert client.get(PATH, headers=_auth(client)).json() == {
            "profile": "research",
            "stored_session_id": None,
        }
        put = client.put(PATH, headers=_auth(client), json={"stored_session_id": STORED})
        assert put.status_code == 200, put.text
        assert put.json() == {"profile": "research", "stored_session_id": STORED}
        # The other platform sees the same answer, and other bots stay independent.
        assert client.get(PATH, headers=_auth(client, "mac")).json()["stored_session_id"] == STORED
        assert client.get("/v1/bots/other/session", headers=_auth(client, "mac")).json() == {
            "profile": "other",
            "stored_session_id": None,
        }


def test_last_write_wins_and_the_pointer_survives_a_restart(tmp_path):
    config = BridgeConfig(db_path=tmp_path / "bridge.db")
    app = _make_app(tmp_path)
    with TestClient(app) as client:
        assert client.put(PATH, headers=_auth(client), json={"stored_session_id": STORED}).status_code == 200
        assert client.put(PATH, headers=_auth(client, "mac"), json={"stored_session_id": "20261106_170000_aaaaaa"}).status_code == 200
    restarted = create_app(config)
    with TestClient(restarted) as client:
        assert client.get(PATH, headers=_auth(client)).json()["stored_session_id"] == "20261106_170000_aaaaaa"


def test_invalid_payloads_are_rejected_and_never_delete_the_row(tmp_path):
    app = _make_app(tmp_path)
    with TestClient(app) as client:
        assert client.put(PATH, headers=_auth(client), json={"stored_session_id": STORED}).status_code == 200
        bad = [
            {},                                   # empty body
            {"stored_session_id": ""},            # empty value
            {"stored_session_id": "   "},         # whitespace only
            {"stored_session_id": "../secrets"},  # path traversal
            {"stored_session_id": "a/b"},         # path separator
            {"stored_session_id": "a\\b"},        # windows separator
            {"stored_session_id": ".hidden"},     # path-ish character
            {"stored_session_id": "x" * 129},     # too long
            {"stored_session_id": None},          # not a string
            {"stored_session_id": 42},
            {"stored_session_id": STORED, "extra": 1},  # not a single field
        ]
        for body in bad:
            response = client.put(PATH, headers=_auth(client), json=body)
            assert response.status_code == 422, (body, response.status_code, response.text)
        assert client.get(PATH, headers=_auth(client)).json()["stored_session_id"] == STORED


def test_unauthenticated_access_is_401(tmp_path):
    app = _make_app(tmp_path)
    with TestClient(app) as client:
        assert client.get(PATH).status_code == 401
        assert client.put(PATH, json={"stored_session_id": STORED}).status_code == 401
        access = client.post(
            "/v1/token", json={"device_id": "phone", "refresh_token": "secret-phone"}
        ).json()["access_token"]
        assert client.get(PATH, headers={"Authorization": "Bearer " + access}).status_code == 401
        reused = _auth(client)
        assert client.put(PATH, headers=reused, json={"stored_session_id": STORED}).status_code == 200
        assert client.get(PATH, headers=reused).status_code == 401


def test_audit_names_the_event_and_never_the_session_id(tmp_path):
    app = _make_app(tmp_path)
    audit = app.state.bridge.audit
    with TestClient(app) as client:
        client.put(PATH, headers=_auth(client), json={"stored_session_id": STORED})
        client.get(PATH, headers=_auth(client))
        client.put(PATH, headers=_auth(client), json={"stored_session_id": "../nope"})
    writes = audit.all("session_pointer")
    assert writes, "the pointer was written without an audit record"
    assert writes[0]["outcome"] == "stored"
    assert writes[0]["profile"] == "research"
    assert STORED not in str(audit.records), "a stored session id reached the audit log"


def test_concurrent_put_pair_resolves_to_one_of_the_two_values(bridge_factory):
    bridge = bridge_factory()
    paired = bridge.pair()
    values = ("20261106_180000_111111", "20261106_180001_222222")
    barrier = threading.Barrier(2)

    def write(value: str) -> int:
        with bridge.client() as client:
            token = client.post(
                "/v1/token",
                json={"device_id": paired["device_id"], "refresh_token": paired["refresh_token"]},
            )
            headers = {"Authorization": "Bearer " + token.json()["ws_ticket"]}
            barrier.wait(timeout=5)
            return client.put(PATH, headers=headers, json={"stored_session_id": value}).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        statuses = list(pool.map(write, values))
    assert statuses == [200, 200]
    with bridge.client() as client:
        token = client.post(
            "/v1/token",
            json={"device_id": paired["device_id"], "refresh_token": paired["refresh_token"]},
        )
        headers = {"Authorization": "Bearer " + token.json()["ws_ticket"]}
        stored = client.get(PATH, headers=headers).json()["stored_session_id"]
    assert stored in values
