"""The soul a new bot starts from: one file on the host, so both apps agree.

What matters to the owner:

* setting a default is one call, and reading it back gives the same text on either device;
* an empty text *is* the reset — the next bot starts from Hermes's own default again;
* a soul is instructions, so there is a ceiling on it that the app can explain;
* the routes need a device ticket, like every other bot route.
"""

from __future__ import annotations

import httpx


def _request(bridge, method: str, path: str, body=None):
    ticket = bridge.pair()["ticket"]
    return httpx.request(method, f"{bridge.base_url}{path}", json=body,
                         headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


class TestTheDefaultSoul:
    def test_a_new_host_has_no_override(self, bridge) -> None:
        response = _request(bridge, "GET", "/v1/bot-defaults")
        assert response.status_code == 200, response.text
        payload = response.json()
        assert payload["soul"]["present"] is False
        assert payload["soul"]["text"] == ""
        # Whether Hermes's own default could be read is the host's business; the field is either the
        # text or a plain null.
        assert "built_in" in payload

    def test_writing_it_is_readable_from_another_device(self, bridge) -> None:
        written = _request(bridge, "PUT", "/v1/bot-defaults/soul",
                           {"text": "You are a hermes agent from nous research. Be brief."})
        assert written.status_code == 200, written.text
        assert written.json()["soul"]["present"] is True
        assert written.json()["soul"]["chars"] == 52
        again = _request(bridge, "GET", "/v1/bot-defaults").json()
        assert again["soul"]["text"].startswith("You are a hermes agent")
        assert again["soul"]["updated_at"]

    def test_empty_text_hands_the_job_back_to_hermes(self, bridge) -> None:
        _request(bridge, "PUT", "/v1/bot-defaults/soul", {"text": "something"})
        cleared = _request(bridge, "PUT", "/v1/bot-defaults/soul", {"text": "   \n "})
        assert cleared.status_code == 200, cleared.text
        assert cleared.json()["soul"] == {"text": "", "chars": 0, "present": False,
                                          "updated_at": None}

    def test_a_soul_has_a_ceiling(self, bridge) -> None:
        response = _request(bridge, "PUT", "/v1/bot-defaults/soul", {"text": "x" * 64_001})
        assert response.status_code == 422

    def test_it_needs_a_device(self, bridge) -> None:
        response = httpx.get(f"{bridge.base_url}/v1/bot-defaults", timeout=10)
        assert response.status_code == 401

    def test_the_file_lives_beside_the_bridge_database(self, bridge) -> None:
        """Not in either app, and not in a profile: this is roster-level configuration."""
        _request(bridge, "PUT", "/v1/bot-defaults/soul", {"text": "hello"})
        assert (bridge.config.db_path.parent / "default-soul.txt").read_text() == "hello"
