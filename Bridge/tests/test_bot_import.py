"""Import bots: the zip the export writes, read back, with a preview and an explicit conflict policy.

What a user would notice being broken:
* an export → import round trip comes back with the same words, memories, notes, routines and icon;
* a preview shows the plan and writes nothing;
* importing beside an existing bot never silently replaces it (merge keeps, overwrite replaces, copy lands as
  name-2);
* a file from another product is refused with a reason instead of becoming an empty bot.
"""

from __future__ import annotations

import io
import json
import zipfile

import pytest

from hermes_bridge import bot_backup


@pytest.fixture
def profiles(tmp_path, monkeypatch):
    root = tmp_path / "profiles"
    root.mkdir()
    monkeypatch.setenv("HERMES_PROFILES_ROOT", str(root))
    # Icons live outside the profiles root; keep the test's writes on the test's disk.
    monkeypatch.setattr(bot_backup, "_icon_path", lambda profile: tmp_path / "icons" / f"{profile}.png")
    return root


def _bot(root, name: str, *, soul="", memory="", notes="", routines=()):
    directory = root / name
    (directory / "memories").mkdir(parents=True)
    (directory / "profile.yaml").write_text("description: from the host\ndescription_auto: false\n")
    if soul:
        (directory / "SOUL.md").write_text(soul)
    if memory:
        (directory / "memories" / "MEMORY.md").write_text(memory)
    if notes:
        (directory / "NOTES.md").write_text(notes)
    if routines:
        (directory / "cron").mkdir()
        (directory / "cron" / "jobs.json").write_text(json.dumps({"jobs": list(routines)}))
    return directory


class _Runtime:
    """Just enough of the runtime for the category helpers, which no-op here."""

    class config:
        host_name = "test-host"
        db_path = "/tmp/hermey-test.db"

    class audit:
        @staticmethod
        def emit(*_a, **_k):
            pass


def _document(**overrides) -> dict:
    document = {
        "version": bot_backup.BACKUP_VERSION,
        "kind": "hermey-bot-backup",
        "exported_at": "2026-11-20T00:00:00Z",
        "host": "old-host",
        "categories": [],
        "bots": [{
            "profile": "scribe", "name": "Scribe", "description": "notes",
            "soul": "You keep notes.", "memory": {"memory": "likes plain text", "user": "Mo"},
            "notes": "a note", "categories": [], "enabled": True, "icon": "icons/scribe.png",
            "routines": [{"id": "job-1", "name": "nightly", "prompt": "go", "schedule": "0 3 * * *"}],
        }],
    }
    document.update(overrides)
    return document


def _zip_with_icon(document: dict, icon: bytes = b"\x89PNG\r\n\x1a\nfake") -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("backup.json", json.dumps(document))
        archive.writestr("icons/scribe.png", icon)
    return buffer.getvalue()


class TestReadingTheFile:
    def test_a_zip_and_a_bare_document_are_the_same_backup(self):
        document, icons = bot_backup.load_backup(_zip_with_icon(_document()))
        assert document["bots"][0]["profile"] == "scribe"
        assert icons["scribe"].startswith(b"\x89PNG")

        bare, no_icons = bot_backup.load_backup(json.dumps(_document()).encode())
        assert bare["bots"] == document["bots"]
        assert no_icons == {}

    def test_a_file_from_another_product_is_refused(self):
        with pytest.raises(bot_backup.HTTPException) as error:
            bot_backup.load_backup(json.dumps({"bots": [{"name": "x"}]}).encode())
        assert error.value.status_code == 422

    def test_a_newer_version_is_refused_rather_than_half_read(self):
        document = _document(version=bot_backup.BACKUP_VERSION + 1)
        with pytest.raises(bot_backup.HTTPException) as error:
            bot_backup.load_backup(json.dumps(document).encode())
        assert error.value.status_code == 409

    def test_a_zip_without_backup_json_says_so(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("something.txt", "hi")
        with pytest.raises(bot_backup.HTTPException) as error:
            bot_backup.load_backup(buffer.getvalue())
        assert "backup.json" in str(error.value.detail)


class TestImporting:
    def test_a_round_trip_restores_the_words_the_schedule_and_the_icon(self, profiles):
        document, icons = bot_backup.load_backup(_zip_with_icon(_document()))
        summary = bot_backup.import_backup(_Runtime(), document, icons=icons)

        assert [c["profile"] for c in summary["created"]] == ["scribe"]
        directory = profiles / "scribe"
        assert (directory / "SOUL.md").read_text() == "You keep notes."
        assert (directory / "memories" / "MEMORY.md").read_text() == "likes plain text"
        assert (directory / "NOTES.md").read_text() == "a note"
        jobs = json.loads((directory / "cron" / "jobs.json").read_text())["jobs"]
        assert [j["id"] for j in jobs] == ["job-1"]
        assert bot_backup._icon_path("scribe").read_bytes().startswith(b"\x89PNG")

    def test_a_dry_run_reports_the_plan_and_writes_nothing(self, profiles):
        document, icons = bot_backup.load_backup(_zip_with_icon(_document()))
        summary = bot_backup.import_backup(_Runtime(), document, icons=icons, dry_run=True)

        assert summary["dry_run"] is True
        assert [c["profile"] for c in summary["created"]] == ["scribe"]
        assert not (profiles / "scribe").exists()
        assert not bot_backup._icon_path("scribe").exists()

    def test_merge_leaves_a_live_bot_s_own_words_alone(self, profiles):
        _bot(profiles, "scribe", soul="mine, not yours")
        document = _document()
        bot_backup.import_backup(_Runtime(), document, mode="merge")
        assert (profiles / "scribe" / "SOUL.md").read_text() == "mine, not yours"

    def test_overwrite_replaces_them_when_asked(self, profiles):
        _bot(profiles, "scribe", soul="mine, not yours")
        bot_backup.import_backup(_Runtime(), _document(), mode="overwrite")
        assert (profiles / "scribe" / "SOUL.md").read_text() == "You keep notes."

    def test_copy_lands_beside_the_existing_bot(self, profiles):
        _bot(profiles, "scribe", soul="mine, not yours")
        summary = bot_backup.import_backup(_Runtime(), _document(), mode="copy")
        assert [c["profile"] for c in summary["created"]] == ["scribe-2"]
        assert (profiles / "scribe" / "SOUL.md").read_text() == "mine, not yours"
        assert (profiles / "scribe-2" / "SOUL.md").read_text() == "You keep notes."

    def test_an_unknown_mode_is_refused(self, profiles):
        with pytest.raises(bot_backup.HTTPException) as error:
            bot_backup.import_backup(_Runtime(), _document(), mode="replace-everything")
        assert error.value.status_code == 422

    def test_the_export_still_writes_the_shape_import_reads(self, profiles):
        _bot(profiles, "scribe", soul="s", memory="m", notes="n")
        archive = bot_backup.build_archive(_Runtime())
        document, icons = bot_backup.load_backup(archive)
        assert document["kind"] == "hermey-bot-backup"
        assert document["version"] == bot_backup.BACKUP_VERSION
        assert document["bots"][0]["profile"] == "scribe"
        assert document["bots"][0]["soul"] == "s"
