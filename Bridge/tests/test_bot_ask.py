"""`ask_user`: a question lands in the bot's chat and the owner's reply comes back."""

from __future__ import annotations

import sqlite3
import time
from pathlib import Path

from hermes_bridge import bot_message


def _profile_with_state(root: Path, profile: str = "aria") -> None:
    directory = root / profile
    directory.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(directory / "state.db")
    conn.execute(
        "CREATE TABLE messages ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, "
        "content TEXT, timestamp REAL)"
    )
    # The owner's answer, deliberately one second in the future so it is after the ask.
    conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
        ("s1", "user", "yes, keep going", time.time() + 1.0),
    )
    conn.commit()
    conn.close()


def test_ask_returns_the_owner_reply_from_the_bot_chat(tmp_path, monkeypatch, bridge):
    root = tmp_path / "profiles"
    _profile_with_state(root)

    monkeypatch.setattr(bot_message, "profiles_root", lambda: root)

    async def fake_deliver(runtime, stored, message, profile, queued=False):
        # `queued` is part of the real signature: the ask path marks its delivery so a busy turn
        # holds the question instead of steering it. A double that omits the keyword turns the
        # route into a 500.
        assert queued is True, "an ask must be queued, not steered into a running turn"
        return "s1", "the question was delivered"

    monkeypatch.setattr(bot_message, "_deliver", fake_deliver)
    monkeypatch.setattr(
        bridge.app.state.bridge.registry, "get_bot_session", lambda profile: "s1"
    )

    with bridge.client() as client:
        response = client.post(
            "/v1/bots/aria/ask",
            json={"question": "Should I keep going?", "from": "cody"},
        )

    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["answered"] is True
    assert payload["reply"] == "yes, keep going"
    assert payload["profile"] == "aria"
    assert "Should I keep going?" in payload["question"]


def test_ask_without_a_conversation_is_a_409(tmp_path, monkeypatch, bridge):
    root = tmp_path / "profiles"
    root.mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(bot_message, "profiles_root", lambda: root)
    monkeypatch.setattr(
        bridge.app.state.bridge.registry, "get_bot_session", lambda profile: None
    )

    with bridge.client() as client:
        response = client.post(
            "/v1/bots/aria/ask",
            json={"question": "Anyone there?", "from": "cody"},
        )

    assert response.status_code == 409
    assert "no conversation yet" in response.json()["detail"]
