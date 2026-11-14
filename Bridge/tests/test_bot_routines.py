"""A bot's routines over HTTP: the list, the switch beside each row, and what must not be sent.

Two halves matter here. The first is the *reduction*: a routine's prompt is the bot's own
instructions — thousands of characters, and often the owner's private setup — so the list route has
to answer with the four fields a row draws and nothing else. The second is the *switch*: the job id
becomes a path segment of a dashboard call, which makes it input rather than an identifier.

The dashboard is stubbed at `_dashboard`, the one function these routes use to reach the scheduler,
so the tests pin our own contract (what we ask the dashboard for, with which profile) instead of
re-testing the host's cron API.
"""
from __future__ import annotations

import httpx
import pytest

from hermes_bridge import bot_admin


def _bot_home(tmp_path, monkeypatch, profile: str = "cody"):
    """A profiles root with one bot in it — `_profile_dir` refuses a name that is not there."""
    home = tmp_path / "hermes-home"
    directory = home / "profiles" / profile
    directory.mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(home))
    return directory


def _get(bridge, path):
    """A bridge ticket is single use, so every request pairs first."""
    ticket = bridge.pair()["ticket"]
    return httpx.get(f"{bridge.base_url}{path}",
                     headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


def _post(bridge, path, body):
    ticket = bridge.pair()["ticket"]
    return httpx.post(f"{bridge.base_url}{path}", json=body,
                      headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


class _Dashboard:
    """The dashboard's cron API, replaced by something that records instead of scheduling."""

    def __init__(self, jobs):
        self.jobs = jobs
        self.calls: list[tuple[str, str]] = []

    def __call__(self, method, path):
        self.calls.append((method, path))
        if method == "GET":
            return 200, self.jobs
        return 200, {"ok": True}


def _job(**overrides):
    job = {
        "id": "fbc2fb0f324d",
        "name": "nightly-audit",
        "prompt": "You are the auditor. Read /root/jobs/private and report anything secret you find.",
        "schedule_display": "every day at 3am",
        "schedule": {"kind": "cron", "expr": "0 3 * * *", "display": "every day at 3am"},
        "next_run_at": "2026-11-16T03:00:00+01:00",
        "last_run_at": "2026-11-15T03:21:37+01:00",
        "last_status": "ok",
        "last_error": None,
        "enabled": True,
        "state": "scheduled",
    }
    job.update(overrides)
    return job


class TestTheRoutineList:
    def test_it_answers_with_the_row_a_list_draws(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard([_job()])
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        response = _get(bridge, "/v1/bots/cody/routines")

        assert response.status_code == 200, response.text
        rows = response.json()["routines"]
        assert len(rows) == 1
        row = rows[0]
        assert row["id"] == "fbc2fb0f324d"
        assert row["name"] == "nightly-audit"
        assert row["schedule"] == "every day at 3am"
        assert row["next_run_at"] == "2026-11-16T03:00:00+01:00"
        assert row["last_status"] == "ok"
        assert row["paused"] is False
        assert row["completed"] is False
        # The prompt is the bot's own instructions, not a field a list needs back.
        assert "prompt" not in row
        assert "You are the auditor" not in response.text

    def test_the_dashboard_is_asked_about_this_bot_only(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch, profile="aria")
        dashboard = _Dashboard([])
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        _get(bridge, "/v1/bots/aria/routines")

        assert dashboard.calls == [("GET", "/api/cron/jobs?profile=aria")]

    def test_off_has_two_spellings_and_both_read_as_paused(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        # `enabled: false` is how a one-off disable looks; `state: paused` is what the pause route
        # writes. Reading only one of them would draw a paused routine as running.
        jobs = [_job(id="a" * 8, name="by-enabled", enabled=False),
                _job(id="b" * 8, name="by-state", state="paused"),
                _job(id="c" * 8, name="running")]
        monkeypatch.setattr(bot_admin, "_dashboard", _Dashboard(jobs))

        rows = {row["name"]: row for row in _get(bridge, "/v1/bots/cody/routines").json()["routines"]}

        assert rows["by-enabled"]["paused"] is True
        assert rows["by-state"]["paused"] is True
        assert rows["running"]["paused"] is False

    def test_a_one_shot_that_already_ran_is_completed_not_paused(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        monkeypatch.setattr(bot_admin, "_dashboard",
                            _Dashboard([_job(state="completed", next_run_at=None)]))

        row = _get(bridge, "/v1/bots/cody/routines").json()["routines"][0]

        assert row["completed"] is True
        assert row["paused"] is False, "it is not switched off, it is finished"

    def test_a_paused_routine_sorts_below_the_ones_with_a_next_run(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        jobs = [_job(id="a" * 8, name="later", next_run_at="2026-11-17T03:00:00+01:00"),
                _job(id="b" * 8, name="paused", enabled=False, next_run_at=None),
                _job(id="c" * 8, name="sooner", next_run_at="2026-11-16T03:00:00+01:00")]
        monkeypatch.setattr(bot_admin, "_dashboard", _Dashboard(jobs))

        names = [row["name"] for row in _get(bridge, "/v1/bots/cody/routines").json()["routines"]]

        assert names == ["sooner", "later", "paused"]

    def test_a_bot_that_does_not_exist_is_a_404(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard([])
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        response = _get(bridge, "/v1/bots/nobody/routines")

        assert response.status_code == 404
        assert dashboard.calls == [], "a bot that is not there is not asked about"

    def test_the_list_needs_a_device_ticket(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        monkeypatch.setattr(bot_admin, "_dashboard", _Dashboard([]))

        response = httpx.get(f"{bridge.base_url}/v1/bots/cody/routines", timeout=10)

        assert response.status_code == 401


class TestTheRoutineSwitch:
    def test_pausing_posts_the_pause_route_for_this_bot(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard([_job()])
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        response = _post(bridge, "/v1/bots/cody/routines/fbc2fb0f324d/state", {"paused": True})

        assert response.status_code == 200, response.text
        assert response.json() == {"profile": "cody", "id": "fbc2fb0f324d", "paused": True}
        assert ("POST", "/api/cron/jobs/fbc2fb0f324d/pause?profile=cody") in dashboard.calls

    def test_resuming_posts_the_resume_route(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard([_job(state="paused")])
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        response = _post(bridge, "/v1/bots/cody/routines/fbc2fb0f324d/state", {"paused": False})

        assert response.status_code == 200
        assert ("POST", "/api/cron/jobs/fbc2fb0f324d/resume?profile=cody") in dashboard.calls

    def test_a_job_id_cannot_reshape_the_dashboard_call(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard([_job()])
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        response = _post(bridge, "/v1/bots/cody/routines/..%2F..%2Fprofiles%2Fdefault/state",
                         {"paused": True})

        assert response.status_code in (404, 422), response.text
        assert dashboard.calls == [], "a hostile id must never reach the dashboard"

    def test_the_body_has_to_say_which_way(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard([_job()])
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        # Pin the refusal as well as the acceptance: a client-side rename of `paused` must fail
        # loudly here rather than as a switch that reports success and does nothing.
        response = _post(bridge, "/v1/bots/cody/routines/fbc2fb0f324d/state", {"pausedAt": True})

        assert response.status_code == 422
        assert dashboard.calls == []

    def test_the_switch_needs_a_device_ticket(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        monkeypatch.setattr(bot_admin, "_dashboard", _Dashboard([_job()]))

        response = httpx.post(f"{bridge.base_url}/v1/bots/cody/routines/fbc2fb0f324d/state",
                              json={"paused": True}, timeout=10)

        assert response.status_code == 401


@pytest.mark.parametrize("job_id", ["", "x" * 65, "a/b", "a b", "../x"])
def test_an_id_that_is_not_a_token_is_refused_before_anything_is_called(job_id):
    # Straight at the pattern the route uses, so the rule is provable without an HTTP round trip.
    assert bot_admin.JOB_ID_RE.match(job_id) is None
