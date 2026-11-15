"""Bot-to-bot exchanges: labelled for the target, recorded for the owner.

Delivery itself needs a live gateway, so `_deliver` is replaced here with a stub that answers
"delivered, no reply" — the route's own work (the label, the record, the pair read) is what these
tests are about.
"""
from __future__ import annotations

import httpx
import pytest
from fastapi.testclient import TestClient

from hermes_bridge import bot_message, bot_transfers
from hermes_bridge.app import create_app
from hermes_bridge.config import BridgeConfig


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_BRIDGE_DB", str(tmp_path / "bridge.db"))
    config = BridgeConfig(db_path=tmp_path / "bridge.db", gateway_token=None)
    app = create_app(config)
    monkeypatch.setattr(bot_message, "_is_loopback", lambda request: True)

    async def delivered(runtime, stored, message, profile):
        return ("session-" + profile, None)

    monkeypatch.setattr(bot_message, "_deliver", delivered)
    test_client = TestClient(app)
    runtime = app.state.bridge
    runtime.registry.set_bot_session(profile="ops", stored_session_id="session-ops-1")
    runtime.registry.set_bot_session(profile="cody", stored_session_id="session-cody-1")
    return test_client, runtime


def _send(client, profile: str, body: dict):
    return client.post(f"/v1/bots/{profile}/message", json=body)


class TestTheLabel:
    def test_the_sender_profile_is_named_when_the_caller_knows_it(self, client) -> None:
        test_client, _ = client
        response = _send(test_client, "ops", {"text": "the vault is rotated", "from": "assistant",
                                              "from_profile": "cody"})
        assert response.status_code == 200, response.text
        assert response.json()["text"].startswith("Assistant (cody) → Ops:")

    def test_a_caller_that_does_not_name_itself_keeps_the_old_form(self, client) -> None:
        test_client, _ = client
        response = _send(test_client, "ops", {"text": "hello", "from": "assistant"})
        assert response.json()["text"].startswith("Assistant → Ops:")

    def test_a_profile_shaped_like_a_path_is_refused(self, client) -> None:
        test_client, _ = client
        response = _send(test_client, "ops", {"text": "hi", "from": "assistant",
                                              "from_profile": "../etc"})
        assert response.status_code == 422, response.text


class TestTheRecord:
    def test_both_directions_come_back_in_order(self, client) -> None:
        test_client, runtime = client
        _send(test_client, "ops", {"text": "first", "from": "assistant", "from_profile": "cody"})
        _send(test_client, "cody", {"text": "second", "from": "assistant", "from_profile": "ops"})

        found = bot_transfers.entries(runtime, "cody", "ops")
        assert [entry["text"] for entry in found] == ["first", "second"]

    def test_another_pair_is_not_in_it(self, client) -> None:
        test_client, runtime = client
        _send(test_client, "ops", {"text": "for ops", "from": "assistant", "from_profile": "cody"})
        assert bot_transfers.entries(runtime, "cody", "aria") == []

    def test_the_words_are_recorded_without_the_label(self, client) -> None:
        test_client, runtime = client
        _send(test_client, "ops", {"text": "  spaced  ", "from": "assistant",
                                   "from_profile": "cody"})
        assert bot_transfers.entries(runtime, "cody", "ops")[0]["text"] == "spaced"

    def test_the_limit_keeps_the_newest(self, client) -> None:
        test_client, runtime = client
        for index in range(5):
            _send(test_client, "ops", {"text": f"note {index}", "from": "assistant",
                                       "from_profile": "cody"})
        newest = bot_transfers.entries(runtime, "cody", "ops", limit=2)
        assert [entry["text"] for entry in newest] == ["note 3", "note 4"]

    def test_the_route_needs_a_device(self, bridge) -> None:
        assert httpx.get(f"{bridge.base_url}/v1/bot-transfers?between=cody,ops",
                         timeout=10).status_code in (401, 403)
