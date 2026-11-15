"""Banners while the app is shut: the relay, its registration, and the watcher's memory.

The delivery path is deliberately small — one HTTP POST to a Bark endpoint — but three things here
are worth testing because getting them wrong is invisible until a banner is wrong:

* a URL is split into server and key, and anything that is not a URL is refused;
* a device is not told about the bot it says it is reading;
* the watcher's first pass records history instead of announcing it, so a restart is not a hundred
  banners from last week.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import time

import httpx
import pytest

from hermes_bridge.push import BarkRelay, ReplyWatcher, _split_bark_url


@pytest.fixture
def device(bridge):
    """One paired device, and a way to make tickets for it.

    Pairing twice would make two devices — a ticket is single use but a *device* is not, so the
    tests that register then report presence must present the same device twice.
    """
    paired = bridge.pair()

    def post(path, body=None):
        header = {"Authorization": f"Bearer {bridge.mint_ticket(paired['device_id'])}"}
        return httpx.post(f"{bridge.base_url}{path}", json=body or {}, headers=header, timeout=10)

    post.device_id = paired["device_id"]
    return post


class TestTheUrl:
    def test_it_splits_server_and_key(self):
        assert _split_bark_url("http://100.86.19.1:8081/AbCdEf123") == ("http://100.86.19.1:8081",
                                                                       "AbCdEf123")

    def test_it_keeps_a_path_prefix(self):
        assert _split_bark_url("https://example.com/bark/AbCdEf/") == ("https://example.com/bark/AbCdEf"
                                                                       .rsplit("/", 1)[0], "AbCdEf")

    @pytest.mark.parametrize("bad", ["", "100.0.0.1:8081/key", "http://host/", "http://host/k y"])
    def test_it_refuses_what_is_not_a_push_url(self, bad):
        with pytest.raises(Exception):
            _split_bark_url(bad)


class TestRegistration:
    def test_a_device_registers_and_is_remembered(self, bridge, device):
        response = device("/v1/push/register", {"url": "http://127.0.0.1:8081/Key123"})

        assert response.status_code == 200, response.text
        assert response.json()["endpoint"] == "http://127.0.0.1:8081"
        targets = bridge.app.state.bridge.registry.push_targets()
        assert [t["key"] for t in targets] == ["Key123"]
        assert targets[0]["provider"] == "bark"

    def test_presence_marks_the_bot_this_device_is_reading(self, bridge, device):
        device("/v1/push/register", {"url": "http://127.0.0.1:8081/Key123"})
        response = device("/v1/push/presence", {"bot": "cody"})

        assert response.status_code == 200, response.text
        assert bridge.app.state.bridge.registry.push_targets()[0]["preset_bot"] == "cody"

    def test_presence_can_be_cleared(self, bridge, device):
        device("/v1/push/register", {"url": "http://127.0.0.1:8081/Key123"})
        device("/v1/push/presence", {"bot": "cody"})
        device("/v1/push/presence", {"bot": None})

        assert bridge.app.state.bridge.registry.push_targets()[0]["preset_bot"] is None

    def test_a_nonsense_bot_name_is_ignored_rather_than_stored(self, bridge, device):
        device("/v1/push/register", {"url": "http://127.0.0.1:8081/Key123"})
        device("/v1/push/presence", {"bot": "../etc/passwd"})

        assert bridge.app.state.bridge.registry.push_targets()[0]["preset_bot"] is None

    def test_a_test_banner_goes_to_the_relay(self, bridge, device, monkeypatch):
        sent = []

        def fake_send(self, base, key, *, title, body, group="", url="", icon=""):
            sent.append((base, key, title, body))
            return True

        monkeypatch.setattr(BarkRelay, "send", fake_send)
        device("/v1/push/register", {"url": "http://127.0.0.1:8081/Key123"})

        response = device("/v1/push/test")

        assert response.status_code == 200, response.text
        assert sent and sent[0][1] == "Key123"
        assert "working" in sent[0][3]

    def test_a_device_with_no_relay_says_so(self, bridge, device):
        assert device("/v1/push/test").status_code == 404


class TestTheRelayClient:
    def test_a_rejected_banner_is_reported_not_raised(self, monkeypatch):
        relay = BarkRelay(timeout=1)

        class Boom:
            def __init__(self, *a, **k): raise OSError("no route")

        monkeypatch.setattr("urllib.request.urlopen", Boom)
        assert relay.send("http://127.0.0.1:1", "K", title="t", body="b") is False


class TestTheWatcher:
    """The watcher decides *what* deserves a banner; the relay only carries it."""

    def _profile(self, home, name="cody", session="s1", text="a reply", stamp=None):
        profile = home / "profiles" / name
        profile.mkdir(parents=True, exist_ok=True)
        db = profile / "state.db"
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, "
                     "started_at REAL, last_activity_at REAL)")
        conn.execute("CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, "
                     "session_id TEXT, role TEXT, content TEXT, timestamp REAL)")
        conn.execute("INSERT OR IGNORE INTO sessions VALUES (?, 0, 0)", (session,))
        conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?,?,?,?)",
                     (session, "assistant", text, stamp or time.time()))
        conn.commit()
        conn.close()
        return profile

    def test_the_first_pass_records_history_instead_of_announcing_it(self, bridge, device,
                                                                   tmp_path, monkeypatch):
        monkeypatch.setenv("HERMES_HOME", str(tmp_path))
        self._profile(tmp_path)
        device("/v1/push/register", {"url": "http://127.0.0.1:8081/Key123"})
        delivered = []
        monkeypatch.setattr(BarkRelay, "send",
                            lambda self, *a, **k: delivered.append(k) or True)

        watcher = ReplyWatcher(bridge.app.state.bridge, BarkRelay())
        watcher.tick()

        assert delivered == []
        assert bridge.app.state.bridge.registry.push_watch("cody") is not None

    def test_a_new_reply_is_announced_once(self, bridge, device, tmp_path, monkeypatch):
        monkeypatch.setenv("HERMES_HOME", str(tmp_path))
        self._profile(tmp_path, stamp=time.time() - 60)
        device("/v1/push/register", {"url": "http://127.0.0.1:8081/Key123"})
        delivered = []
        monkeypatch.setattr(BarkRelay, "send",
                            lambda self, *a, **k: delivered.append(k) or True)
        watcher = ReplyWatcher(bridge.app.state.bridge, BarkRelay())
        watcher.tick()

        self._profile(tmp_path, session="s2", text="new answer", stamp=time.time())
        watcher.tick()
        watcher.tick()

        assert len(delivered) == 1, "the same reply must not be announced twice"
        assert delivered[0]["body"].startswith("new answer")
        assert delivered[0]["url"] == "hermey://bot/cody"

    def test_the_bot_on_screen_is_not_announced(self, bridge, device, tmp_path, monkeypatch):
        monkeypatch.setenv("HERMES_HOME", str(tmp_path))
        self._profile(tmp_path, stamp=time.time() - 60)
        device("/v1/push/register", {"url": "http://127.0.0.1:8081/Key123"})
        device("/v1/push/presence", {"bot": "cody"})
        delivered = []
        monkeypatch.setattr(BarkRelay, "send",
                            lambda self, *a, **k: delivered.append(k) or True)
        watcher = ReplyWatcher(bridge.app.state.bridge, BarkRelay())
        watcher.tick()

        self._profile(tmp_path, session="s2", text="while you watch", stamp=time.time())
        watcher.tick()

        assert delivered == []
