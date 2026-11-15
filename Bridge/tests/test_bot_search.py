"""Search inside the transcripts: every bot, newest first, snippets not dumps.

The bridge reads each profile's own `state.db`, so the tests build those databases directly — the
shape of a real one (sessions + messages) without a gateway in the way.
"""
from __future__ import annotations

import sqlite3

import httpx
import pytest


def _get(bridge, path: str):
    ticket = bridge.pair()["ticket"]
    return httpx.get(f"{bridge.base_url}{path}",
                     headers={"Authorization": f"Bearer {ticket}"}, timeout=15)


def _profile(home, name: str, messages: list[tuple[str, str, float, str]]):
    """One bot's state.db: (role, content, timestamp, session) rows."""
    directory = home / "profiles" / name
    directory.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(directory / "state.db")
    conn.execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, started_at REAL, "
                 "last_activity_at REAL)")
    conn.execute("CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, "
                 "session_id TEXT, role TEXT, content TEXT, timestamp REAL)")
    for index, (role, content, at, session) in enumerate(messages):
        conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?,?,?,?)",
                     (session, role, content, at))
        conn.execute("INSERT OR IGNORE INTO sessions (id, started_at, last_activity_at) "
                     "VALUES (?,?,?)", (session, at, at))
    conn.commit()
    conn.close()
    return directory


@pytest.fixture
def home(tmp_path, monkeypatch):
    root = tmp_path / "hermes-home"
    (root / "profiles").mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(root))
    return root


class TestFindingAMessage:
    def test_a_phrase_inside_a_message_is_found(self, bridge, home) -> None:
        _profile(home, "cody", [
            ("user", "can you check the CrowdSec rules tonight", 1000.0, "s1"),
            ("assistant", "done — three rules updated", 1001.0, "s1"),
        ])
        response = _get(bridge, "/v1/search?q=crowdsec")
        assert response.status_code == 200, response.text
        payload = response.json()
        assert payload["total"] == 1
        found = payload["results"][0]
        assert found["profile"] == "cody"
        assert found["role"] == "user"
        assert "CrowdSec" in found["snippet"]
        assert found["match"] == "CrowdSec"

    def test_every_bot_is_searched_newest_first(self, bridge, home) -> None:
        _profile(home, "cody", [("user", "the vault rotation, again", 1000.0, "s1")])
        _profile(home, "aria", [("user", "vault rotation is still pending", 2000.0, "s2")])
        results = _get(bridge, "/v1/search?q=vault").json()["results"]
        assert [r["profile"] for r in results] == ["aria", "cody"]

    def test_the_snippet_is_a_window_not_the_whole_message(self, bridge, home) -> None:
        body = "x" * 400 + " vault " + "y" * 400
        _profile(home, "cody", [("user", body, 1000.0, "s1")])
        snippet = _get(bridge, "/v1/search?q=vault").json()["results"][0]["snippet"]
        assert len(snippet) < 220
        assert "vault" in snippet
        assert snippet.startswith("…") and snippet.endswith("…")

    def test_only_user_and_assistant_rows_are_searched(self, bridge, home) -> None:
        _profile(home, "cody", [
            ("tool", "vault", 1000.0, "s1"),
            ("user", "vault please", 1001.0, "s1"),
        ])
        results = _get(bridge, "/v1/search?q=vault").json()["results"]
        assert [r["role"] for r in results] == ["user"]

    def test_a_bot_with_no_database_is_simply_absent(self, bridge, home) -> None:
        (home / "profiles" / "empty").mkdir(parents=True)
        assert _get(bridge, "/v1/search?q=anything").json()["results"] == []


class TestTheQueryRules:
    def test_one_character_is_not_a_search(self, bridge, home) -> None:
        _profile(home, "cody", [("user", "a", 1000.0, "s1")])
        payload = _get(bridge, "/v1/search?q=a").json()
        assert payload["results"] == []
        assert payload["total"] == 0

    def test_a_long_query_is_clipped_not_refused(self, bridge, home) -> None:
        _profile(home, "cody", [("user", "vault", 1000.0, "s1")])
        response = _get(bridge, "/v1/search?q=" + "v" * 500)
        assert response.status_code == 200, response.text

    def test_the_page_and_its_remainder(self, bridge, home) -> None:
        rows = [("user", f"vault note {index}", 1000.0 + index, "s1") for index in range(5)]
        _profile(home, "cody", rows)
        first = _get(bridge, "/v1/search?q=vault&limit=2").json()
        assert len(first["results"]) == 2
        assert first["total"] == 5
        assert first["more"] is True
        second = _get(bridge, "/v1/search?q=vault&limit=2&offset=4").json()
        assert len(second["results"]) == 1
        assert second["more"] is False

    def test_the_route_needs_a_device(self, bridge) -> None:
        assert httpx.get(f"{bridge.base_url}/v1/search?q=vault", timeout=10).status_code in (401, 403)
