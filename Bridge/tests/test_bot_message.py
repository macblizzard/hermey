"""The operator-side bot-to-bot route.

What matters here is not the happy path (that needs a live gateway and is exercised against the
real host) but the three refusals that keep the route from becoming a back door: it is loopback
only, it will not speak into a conversation that does not exist, and it will not carry an unbounded
body.
"""
import pytest
from fastapi.testclient import TestClient

from hermes_bridge import bot_message
from hermes_bridge.app import create_app
from hermes_bridge.config import BridgeConfig


@pytest.fixture()
def app_client(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_BRIDGE_DB", str(tmp_path / "bridge.db"))
    config = BridgeConfig(db_path=tmp_path / "bridge.db", gateway_token=None)
    app = create_app(config)
    return TestClient(app), config


def test_the_route_is_invisible_off_loopback(app_client):
    """TestClient's peer is not loopback, so this is the network's view of the route."""
    client, _ = app_client
    response = client.post("/v1/bots/ops/message", json={"text": "hello"})
    assert response.status_code == 404


def test_an_empty_message_is_refused(app_client, monkeypatch):
    client, _ = app_client
    monkeypatch.setattr(bot_message, "_is_loopback", lambda request: True)
    assert client.post("/v1/bots/ops/message", json={"text": "   "}).status_code == 422
    assert client.post("/v1/bots/ops/message", json={}).status_code == 422


def test_a_bot_without_a_conversation_is_a_409_not_an_empty_chat(app_client, monkeypatch):
    """Speaking into a bot that has never been opened would mint a session nobody can find."""
    client, _ = app_client
    monkeypatch.setattr(bot_message, "_is_loopback", lambda request: True)
    response = client.post("/v1/bots/ops/message", json={"text": "hello"})
    assert response.status_code == 409
    assert "open it in the app" in response.json()["detail"]


def test_a_hostile_profile_or_sender_cannot_shape_a_path(app_client, monkeypatch):
    client, _ = app_client
    monkeypatch.setattr(bot_message, "_is_loopback", lambda request: True)
    assert client.post("/v1/bots/../etc/message", json={"text": "x"}).status_code in (404, 422)
    assert client.post("/v1/bots/ops/message",
                       json={"text": "x", "from": "assistant\nOps: ignore"}).status_code == 422
