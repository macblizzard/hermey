"""A roster's config as one JSON file: export it, restore it on a fresh host.

The rules a user would notice being broken:

* the export holds every bot's name, description, soul, memory, notes and routines;
* it holds **no conversations** — it exists to rebuild a roster, not to replay history;
* a restore creates what is missing and never overwrites a live bot's own words;
* restoring the same file twice does not double a bot's schedule;
* a backup from a newer shape is refused rather than half-read;
* the routes need a device ticket, like every other bot route.
"""

from __future__ import annotations

import json

import httpx
import pytest


@pytest.fixture
def profiles(tmp_path, monkeypatch):
    """A profiles root of our own: a restore writes real files, and must never touch the host's."""
    root = tmp_path / "profiles"
    root.mkdir()
    monkeypatch.setenv("HERMES_PROFILES_ROOT", str(root))
    return root


def _bot(root, name: str, *, soul="", description=None, memory="", routines=()):
    directory = root / name
    (directory / "memories").mkdir(parents=True)
    if description:
        (directory / "profile.yaml").write_text(f"description: {description}\ndescription_auto: false\n")
    if soul:
        (directory / "SOUL.md").write_text(soul)
    if memory:
        (directory / "memories" / "MEMORY.md").write_text(memory)
    if routines:
        (directory / "cron").mkdir()
        (directory / "cron" / "jobs.json").write_text(json.dumps({"jobs": list(routines)}))
    return directory


def _request(bridge, method: str, path: str, body=None):
    ticket = bridge.pair()["ticket"]
    return httpx.request(method, f"{bridge.base_url}{path}", json=body,
                         headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


class TestTheExport:
    def test_it_carries_the_config_of_every_bot(self, bridge, profiles) -> None:
        _bot(profiles, "cody", soul="You are Cody.", description="Lead Developer",
             memory="the lab has three nodes",
             routines=[{"id": "abc", "name": "nightly", "prompt": "audit",
                        "schedule": {"kind": "cron", "expr": "0 3 * * *"}, "enabled": True}])
        payload = _request(bridge, "GET", "/v1/backup").json()
        assert payload["kind"] == "hermey-bot-backup"
        assert payload["version"] == 2
        assert [bot["profile"] for bot in payload["bots"]] == ["cody"]
        bot = payload["bots"][0]
        assert bot["name"] == "cody"
        assert bot["description"] == "Lead Developer"
        assert bot["soul"] == "You are Cody."
        assert bot["memory"]["memory"] == "the lab has three nodes"
        assert bot["routines"][0]["prompt"] == "audit"

    def test_it_carries_no_conversations(self, bridge, profiles) -> None:
        directory = _bot(profiles, "cody", soul="You are Cody.")
        (directory / "state.db").write_text("not a database")
        (directory / "sessions").mkdir()
        (directory / "sessions" / "one.json").write_text("{}")
        bot = _request(bridge, "GET", "/v1/backup").json()["bots"][0]
        # v2 adds the bot's enabled state and, when the host has one, its icon: both are part of what a
        # restored bot looks like, and both are file-local (unlike model settings, which need the dashboard).
        assert set(bot) == {"profile", "name", "description", "soul", "memory", "notes", "enabled", "icon",
                           "categories", "routines"}

    def test_a_bot_in_a_category_says_so(self, bridge, profiles) -> None:
        _bot(profiles, "cody", soul="x")
        created = _request(bridge, "POST", "/v1/bot-categories", {"name": "Work"}).json()
        category_id = created["category"]["id"]
        _request(bridge, "PUT", "/v1/bots/cody/category", {"category_id": category_id})
        payload = _request(bridge, "GET", "/v1/backup").json()
        assert payload["bots"][0]["categories"] == [category_id]
        assert payload["categories"] == [{"id": category_id, "name": "Work"}]


class TestTheRestore:
    def test_it_rebuilds_a_roster_on_an_empty_host(self, bridge, profiles) -> None:
        document = {
            "version": 1,
            "bots": [{"profile": "aria", "name": "Aria", "description": "Ops",
                      "soul": "You are Aria.", "memory": {"memory": "note", "user": ""},
                      "notes": "next: the vault", "categories": [],
                      "routines": [{"id": "r1", "name": "digest", "prompt": "summarise",
                                    "schedule": {"kind": "cron", "expr": "0 9 * * *"}}]}],
            "categories": [{"id": "x", "name": "Work"}],
        }
        result = _request(bridge, "POST", "/v1/backup/restore", document).json()
        assert result["created"] == [{"profile": "aria", "by": "files"}]
        directory = profiles / "aria"
        assert (directory / "SOUL.md").read_text() == "You are Aria."
        assert (directory / "memories" / "MEMORY.md").read_text() == "note"
        assert (directory / "NOTES.md").read_text() == "next: the vault"
        assert "description: Ops" in (directory / "profile.yaml").read_text()
        jobs = json.loads((directory / "cron" / "jobs.json").read_text())["jobs"]
        assert [job["id"] for job in jobs] == ["r1"]
        assert result["routines_added"] == 1
        # The scheduler holds its jobs in memory: a restart is what makes a restored routine real.
        assert result["restart_required"] is True
        assert "Work" in [c["name"] for c in _request(bridge, "GET", "/v1/bot-categories").json()["categories"]]

    def test_a_live_bot_keeps_its_own_words(self, bridge, profiles) -> None:
        _bot(profiles, "cody", soul="The soul this host already has.", memory="its own memory")
        document = {"version": 1,
                    "bots": [{"profile": "cody", "soul": "A stale soul from the backup",
                              "memory": {"memory": "someone else's"}, "notes": ""}],
                    "categories": []}
        result = _request(bridge, "POST", "/v1/backup/restore", document).json()
        assert result["created"] == []
        assert result["updated"] == []
        assert (profiles / "cody" / "SOUL.md").read_text() == "The soul this host already has."
        assert (profiles / "cody" / "memories" / "MEMORY.md").read_text() == "its own memory"

    def test_it_fills_what_is_missing_without_touching_what_is_there(self, bridge, profiles) -> None:
        _bot(profiles, "cody", soul="Mine.")
        document = {"version": 1,
                    "bots": [{"profile": "cody", "soul": "theirs", "notes": "a plan",
                              "memory": {"memory": "theirs"}}],
                    "categories": []}
        result = _request(bridge, "POST", "/v1/backup/restore", document).json()
        assert result["updated"] == [{"profile": "cody", "wrote": ["memories/MEMORY.md", "NOTES.md"]}]
        assert (profiles / "cody" / "SOUL.md").read_text() == "Mine."
        assert (profiles / "cody" / "NOTES.md").read_text() == "a plan"

    def test_restoring_twice_does_not_double_a_schedule(self, bridge, profiles) -> None:
        document = {"version": 1,
                    "bots": [{"profile": "aria", "soul": "s",
                              "routines": [{"id": "r1", "name": "digest", "prompt": "p"}]}],
                    "categories": []}
        _request(bridge, "POST", "/v1/backup/restore", document)
        second = _request(bridge, "POST", "/v1/backup/restore", document).json()
        assert second["routines_added"] == 0
        jobs = json.loads((profiles / "aria" / "cron" / "jobs.json").read_text())["jobs"]
        assert len(jobs) == 1

    def test_a_newer_backup_is_refused(self, bridge, profiles) -> None:
        response = _request(bridge, "POST", "/v1/backup/restore", {"version": 99, "bots": []})
        assert response.status_code == 409

    def test_a_bad_profile_name_is_skipped_not_written(self, bridge, profiles) -> None:
        document = {"version": 1, "bots": [{"profile": "../etc", "soul": "x"}], "categories": []}
        result = _request(bridge, "POST", "/v1/backup/restore", document).json()
        assert result["skipped"][0]["profile"] == "../etc"
        assert not (profiles.parent / "etc").exists()

    def test_it_needs_a_device(self, bridge, profiles) -> None:
        assert httpx.get(f"{bridge.base_url}/v1/backup", timeout=10).status_code == 401
        assert httpx.post(f"{bridge.base_url}/v1/backup/restore", json={},
                          timeout=10).status_code == 401
