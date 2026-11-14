"""A bot's notes over HTTP: one file, read and written, and nothing a caller can steer.

The route reads and *writes* inside a profile directory, so the whole attack surface is the profile
name, the file name and the size of the body. All three are fixed here: the name is checked against
the CLI's own pattern, the file name is a constant, and the body is capped.
"""
from __future__ import annotations

import httpx
import pytest


def _bot_home(tmp_path, monkeypatch, profile: str = "cody", notes: str | None = None):
    home = tmp_path / "hermes-home"
    directory = home / "profiles" / profile
    directory.mkdir(parents=True)
    if notes is not None:
        (directory / "NOTES.md").write_text(notes, encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(home))
    return directory


def _get(bridge, path):
    """A bridge ticket is single use, so every request pairs first."""
    ticket = bridge.pair()["ticket"]
    return httpx.get(f"{bridge.base_url}{path}",
                     headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


def _put(bridge, path, body):
    ticket = bridge.pair()["ticket"]
    return httpx.put(f"{bridge.base_url}{path}", json=body,
                     headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


class TestReadingTheNote:
    def test_a_bot_with_no_note_answers_an_empty_document(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)

        response = _get(bridge, "/v1/bots/cody/notes")

        assert response.status_code == 200, response.text
        payload = response.json()
        assert payload["profile"] == "cody"
        assert payload["notes"]["text"] == ""
        assert payload["notes"]["present"] is False
        assert payload["notes"]["updated_at"] is None

    def test_it_reads_the_file_that_is_there(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch, notes="- ask it for the vault inventory\n- next: rotate keys\n")

        response = _get(bridge, "/v1/bots/cody/notes")

        assert response.status_code == 200, response.text
        notes = response.json()["notes"]
        assert notes["text"].startswith("- ask it for the vault inventory")
        assert notes["chars"] == len(notes["text"])
        assert notes["present"] is True
        assert notes["updated_at"]  # the sheet shows when it was last written

    def test_a_symlink_is_refused_not_followed(self, bridge, tmp_path, monkeypatch):
        directory = _bot_home(tmp_path, monkeypatch)
        secret = tmp_path / "id_rsa"
        secret.write_text("PRIVATE", encoding="utf-8")
        (directory / "NOTES.md").symlink_to(secret)

        response = _get(bridge, "/v1/bots/cody/notes")

        assert response.status_code == 200, response.text
        notes = response.json()["notes"]
        assert notes["text"] == ""
        assert "symlink" in notes["error"]

    def test_an_unknown_bot_is_a_404(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        assert _get(bridge, "/v1/bots/nobody/notes").status_code == 404

    def test_a_bad_profile_name_is_refused_before_it_touches_the_disk(self, bridge, tmp_path,
                                                                     monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        assert _get(bridge, "/v1/bots/..%2Fetc/notes").status_code in (404, 422)


class TestWritingTheNote:
    def test_it_writes_the_file_and_reads_back_the_same_text(self, bridge, tmp_path, monkeypatch):
        directory = _bot_home(tmp_path, monkeypatch)

        response = _put(bridge, "/v1/bots/cody/notes",
                        {"text": "- move the backups to the new disk\n- then prune the old ones\n"})

        assert response.status_code == 200, response.text
        notes = response.json()["notes"]
        assert notes["present"] is True
        assert "prune the old ones" in notes["text"]
        on_disk = (directory / "NOTES.md").read_text(encoding="utf-8")
        assert on_disk == notes["text"]
        # And a second device reads exactly what the first wrote — one file, one truth.
        again = _get(bridge, "/v1/bots/cody/notes").json()["notes"]
        assert again["text"] == on_disk

    def test_an_empty_text_clears_the_note_without_removing_the_file(self, bridge, tmp_path,
                                                                     monkeypatch):
        directory = _bot_home(tmp_path, monkeypatch, notes="something")

        response = _put(bridge, "/v1/bots/cody/notes", {"text": ""})

        assert response.status_code == 200, response.text
        assert response.json()["notes"]["present"] is True
        assert (directory / "NOTES.md").read_text(encoding="utf-8") == ""

    def test_an_oversized_note_is_refused(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)

        response = _put(bridge, "/v1/bots/cody/notes", {"text": "x" * 64_001})

        assert response.status_code == 413

    def test_a_symlink_is_not_written_through(self, bridge, tmp_path, monkeypatch):
        directory = _bot_home(tmp_path, monkeypatch)
        secret = tmp_path / "id_rsa"
        secret.write_text("PRIVATE", encoding="utf-8")
        (directory / "NOTES.md").symlink_to(secret)

        response = _put(bridge, "/v1/bots/cody/notes", {"text": "overwrite"})

        assert response.status_code == 409
        assert secret.read_text(encoding="utf-8") == "PRIVATE"

    def test_writing_needs_a_device(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        response = httpx.put(f"{bridge.base_url}/v1/bots/cody/notes", json={"text": "hello"},
                             timeout=10)
        assert response.status_code == 401


class TestTheNoteBelongsToTheBot:
    def test_it_lives_inside_the_profile_so_a_deleted_bot_takes_it_with_it(self, bridge, tmp_path,
                                                                          monkeypatch):
        directory = _bot_home(tmp_path, monkeypatch)
        _put(bridge, "/v1/bots/cody/notes", {"text": "planned work"})

        # Deleting a bot removes its profile directory; nothing else has to remember the note.
        for child in sorted(directory.rglob("*"), reverse=True):
            child.unlink()
        directory.rmdir()

        assert not directory.exists()
        assert _get(bridge, "/v1/bots/cody/notes").status_code == 404
