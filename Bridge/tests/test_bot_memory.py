"""A bot's memory over HTTP: two documents, read-only, and the shapes that must not leak.

The interesting half is not the happy path — it is that this route reads *files* out of a profile
directory, so the profile name and the file names are the whole attack surface. Both are fixed here:
the name is checked against the CLI's own pattern, and the two document names are constants rather
than anything a caller can influence.
"""
from __future__ import annotations

import httpx
import pytest


def _bot_home(tmp_path, monkeypatch, profile: str = "cody", memory: str | None = None,
              user: str | None = None):
    home = tmp_path / "hermes-home"
    directory = home / "profiles" / profile
    memories = directory / "memories"
    memories.mkdir(parents=True)
    if memory is not None:
        (memories / "MEMORY.md").write_text(memory, encoding="utf-8")
    if user is not None:
        (memories / "USER.md").write_text(user, encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(home))
    return directory


def _get(bridge, path):
    """A bridge ticket is single use, so every request pairs first."""
    ticket = bridge.pair()["ticket"]
    return httpx.get(f"{bridge.base_url}{path}",
                     headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


class TestTheMemoryDocuments:
    def test_it_answers_both_documents_with_their_text(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch,
                  memory="Memories saved this session (2,981/3,000 chars)\n- OpenCode default model.\n",
                  user="User profile\n- Reads replies in the iOS app; keep them short.\n")

        response = _get(bridge, "/v1/bots/cody/memory")

        assert response.status_code == 200, response.text
        payload = response.json()
        assert payload["profile"] == "cody"
        assert payload["memory"]["name"] == "MEMORY.md"
        assert "OpenCode default model" in payload["memory"]["text"]
        assert payload["user"]["name"] == "USER.md"
        assert "keep them short" in payload["user"]["text"]
        # The counts are what the sheet puts beside each heading, so they must be the text's own.
        assert payload["memory"]["chars"] == len(payload["memory"]["text"])
        assert payload["user"]["chars"] == len(payload["user"]["text"])

    def test_a_profile_that_never_remembered_anything_is_two_empty_documents(
            self, bridge, tmp_path, monkeypatch):
        # "Nothing remembered yet" is an answer, not a fault: a screen that errored here would send
        # the owner hunting for a problem that does not exist.
        _bot_home(tmp_path, monkeypatch)

        response = _get(bridge, "/v1/bots/cody/memory")

        assert response.status_code == 200
        payload = response.json()
        for key in ("memory", "user"):
            assert payload[key]["present"] is False
            assert payload[key]["text"] == ""
            assert payload[key]["chars"] == 0
            assert "error" not in payload[key]

    def test_one_document_can_exist_without_the_other(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch, user="only the user profile\n")

        payload = _get(bridge, "/v1/bots/cody/memory").json()

        assert payload["user"]["present"] is True
        assert payload["user"]["chars"] > 0
        assert payload["memory"]["present"] is False

    def test_a_file_too_large_to_draw_says_so_instead_of_being_sent(
            self, bridge, tmp_path, monkeypatch):
        # A runaway agent can write megabytes into a file that is replayed into every turn; the sheet
        # says why it is not showing it rather than hanging on a phone.
        big = _bot_home(tmp_path, monkeypatch)
        (big / "memories" / "MEMORY.md").write_text("x" * (300 * 1024), encoding="utf-8")

        payload = _get(bridge, "/v1/bots/cody/memory").json()

        assert payload["memory"]["text"] == ""
        assert payload["memory"]["chars"] == 0
        assert "larger" in payload["memory"]["error"]

    def test_a_non_utf8_file_is_read_replacing_rather_than_failing(
            self, bridge, tmp_path, monkeypatch):
        home = tmp_path / "hermes-home"
        directory = home / "profiles" / "cody"
        (directory / "memories").mkdir(parents=True)
        (directory / "memories" / "MEMORY.md").write_bytes(b"ok \xff\xfe broken bytes\n")
        monkeypatch.setenv("HERMES_HOME", str(home))

        payload = _get(bridge, "/v1/bots/cody/memory").json()

        assert payload["memory"]["present"] is True
        assert "ok" in payload["memory"]["text"]
        assert "error" not in payload["memory"], "a legacy byte must not blank the whole document"

    def test_a_bot_that_does_not_exist_is_a_404(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        assert _get(bridge, "/v1/bots/nobody/memory").status_code == 404

    @pytest.mark.parametrize("hostile", ["..", "cody/../default", "Cody", "cody "])
    def test_a_name_that_could_reshape_the_path_is_refused(self, bridge, tmp_path, monkeypatch,
                                                           hostile):
        # `..` and a slash would reach a different profile; a capital or a space is not a profile
        # name at all, so the route refuses rather than guessing which one was meant.
        _bot_home(tmp_path, monkeypatch)
        assert _get(bridge, f"/v1/bots/{hostile}/memory").status_code in (404, 422)

    def test_the_route_needs_a_device_ticket(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        response = httpx.get(f"{bridge.base_url}/v1/bots/cody/memory", timeout=10)
        assert response.status_code == 401

    def test_a_symlinked_document_is_refused_not_followed(self, bridge, tmp_path, monkeypatch):
        # The agent can write inside its own profile, so a link named MEMORY.md could otherwise hand
        # a paired device any host file it likes. Same rule as the workspace viewer.
        directory = _bot_home(tmp_path, monkeypatch)
        secret = tmp_path / "outside.md"
        secret.write_text("host secret\n", encoding="utf-8")
        (directory / "memories" / "MEMORY.md").symlink_to(secret)

        payload = _get(bridge, "/v1/bots/cody/memory").json()

        assert payload["memory"]["text"] == "", "the bytes behind the link must not be sent"
        assert "symlink" in payload["memory"]["error"]
