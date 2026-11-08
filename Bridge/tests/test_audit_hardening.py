"""Regressions for the audit's bridge findings.

Each test here failed before the fix it names, and each is cheap: they are the parts of the
hardening that a future edit could quietly undo.
"""
import base64
import os

import pytest
from fastapi.testclient import TestClient

from hermes_bridge.app import create_app

#: A syntactically valid Ed25519 key (32 raw bytes, base64), not a real identity: the pairing
#: endpoint validates the shape before it stores it.
FAKE_KEY = base64.b64encode(b"k" * 32).decode()
from hermes_bridge.config import BridgeConfig


@pytest.fixture()
def app_client(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_BRIDGE_DB", str(tmp_path / "bridge.db"))
    monkeypatch.setenv("HERMES_BRIDGE_GATEWAY_TOKEN", "")
    config = BridgeConfig(db_path=tmp_path / "bridge.db", gateway_token=None)
    app = create_app(config)
    return TestClient(app), config


def test_health_does_not_report_the_device_count(app_client):
    """`/v1/health` is unauthenticated: it may say the bridge is alive and nothing else."""
    client, _ = app_client
    body = client.get("/v1/health").json()
    assert body["status"] == "ok"
    assert "devices" not in body


def test_an_oversized_control_body_is_refused_before_parsing(app_client):
    client, _ = app_client
    response = client.post("/v1/pair/claim",
                           content=b"x" * (2 * 1024 * 1024),
                           headers={"content-type": "application/json"})
    assert response.status_code == 413


def test_a_symlink_in_the_images_folder_is_not_served(tmp_path, monkeypatch):
    """A `.png` that points at a host file must not be readable through the attachment route."""
    home = tmp_path / "home"
    profile = home / "profiles" / "assistant" / "images"
    profile.mkdir(parents=True)
    secret = tmp_path / "secret.txt"
    secret.write_text("host secret\n")
    os.symlink(secret, profile / "evil.png")

    monkeypatch.setenv("HERMES_BRIDGE_DB", str(tmp_path / "bridge.db"))
    monkeypatch.setenv("HERMES_BRIDGE_GATEWAY_TOKEN", "")
    monkeypatch.setenv("HERMES_HOME", str(home))
    config = BridgeConfig(db_path=tmp_path / "bridge.db", gateway_token=None)
    client = TestClient(create_app(config))

    # TestClient's peer is not loopback, so the host-only mint route refuses; reach the runtime the
    # app exposes and mint a code the way a host-side operator would.
    code = client.app.state.bridge.pairing.mint()[0]
    device = client.post("/v1/pair/claim", json={
        "code": code, "public_key": FAKE_KEY, "device_name": "t", "platform": "test",
    })
    assert device.status_code == 200, device.text
    # The attachment route redeems a single-use *ticket*, the same credential the socket uses.
    ticket = client.post("/v1/token", json={
        "refresh_token": device.json()["refresh_token"],
        "device_id": device.json()["device_id"],
    }).json()["ws_ticket"]

    response = client.get("/v1/attachments/assistant/evil.png",
                          headers={"authorization": f"Bearer {ticket}"})
    assert response.status_code == 404
    assert b"host secret" not in response.content
