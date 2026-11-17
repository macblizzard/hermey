"""A bot's effort level and aux/vision model over HTTP.

The desktop model sheet asks for these two the moment it opens, so both halves have to be right: what we
read out of the host's config (a `reasoning_effort: false` means *disabled*, not unset, and a missing aux
block means "inherit the main model") and what we send back (a patch carrying only the keys this route
owns, because `PUT /api/config` deep-merges over whatever is on disk).

The dashboard is stubbed at `_dashboard`, the one function these routes use to reach it, so these pin our
own contract instead of re-testing the host's config API.
"""
from __future__ import annotations

import httpx
import pytest

from hermes_bridge import bot_admin


def _bot_home(tmp_path, monkeypatch, profile: str = "cody"):
    home = tmp_path / "hermes-home"
    directory = home / "profiles" / profile
    directory.mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(home))
    return directory


class _Dashboard:
    """A dashboard holding one config document, recording what was sent to it."""

    def __init__(self, config):
        self.config = config
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "PUT":
            patch = (body or {}).get("config") or {}
            agent = dict(self.config.get("agent") or {})
            if "reasoning_effort" in (patch.get("agent") or {}):
                agent["reasoning_effort"] = patch["agent"]["reasoning_effort"]
            self.config["agent"] = agent
            auxiliary = dict(self.config.get("auxiliary") or {})
            # The patch nests the same way the file does: {"auxiliary": {"vision": {...}}}.
            incoming = (patch.get("auxiliary") or {}).get("vision")
            if isinstance(incoming, dict):
                vision = dict(auxiliary.get("vision") or {})
                vision.update(incoming)
                auxiliary["vision"] = vision
            self.config["auxiliary"] = auxiliary
            return 200, {"ok": True}
        return 200, self.config

    @property
    def writes(self):
        return [call for call in self.calls if call[0] == "PUT"]


def _get(bridge, path):
    ticket = bridge.pair()["ticket"]
    return httpx.get(f"{bridge.base_url}{path}",
                     headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


def _put(bridge, path, body):
    ticket = bridge.pair()["ticket"]
    return httpx.put(f"{bridge.base_url}{path}", json=body,
                     headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


class TestReadingTheSettings:
    def test_it_reports_the_effort_and_the_vision_model(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard({
            "agent": {"reasoning_effort": "high"},
            "auxiliary": {"vision": {"provider": "openai", "model": "gpt-6-luna"}},
        })
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        response = _get(bridge, "/v1/bots/cody/model-settings")

        assert response.status_code == 200, response.text
        payload = response.json()
        assert payload["profile"] == "cody"
        assert payload["effort"] == "high"
        assert payload["vision"] == {"provider": "openai", "model": "gpt-6-luna"}
        # The sheet draws the levels from the host's own list rather than a copy of it.
        assert payload["efforts"][0] == ""
        assert "high" in payload["efforts"] and "none" in payload["efforts"]
        # Read through this bot's config, never the process default.
        assert dashboard.calls[0][1].endswith("profile=cody")

    def test_effort_false_means_disabled_not_unset(self, bridge, tmp_path, monkeypatch):
        # YAML `reasoning_effort: false` is the host's way of saying thinking is off; reporting "" would
        # show the sheet as "provider default" and quietly re-enable it on the next save.
        _bot_home(tmp_path, monkeypatch)
        monkeypatch.setattr(bot_admin, "_dashboard", _Dashboard({"agent": {"reasoning_effort": False}}))

        payload = _get(bridge, "/v1/bots/cody/model-settings").json()

        assert payload["effort"] == "none"

    def test_an_unset_aux_block_inherits_the_main_model(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        monkeypatch.setattr(bot_admin, "_dashboard", _Dashboard({"agent": {}}))

        payload = _get(bridge, "/v1/bots/cody/model-settings").json()

        assert payload["vision"] == {"provider": "auto", "model": ""}
        assert payload["effort"] == ""


class TestWritingTheSettings:
    def test_it_sends_a_patch_with_only_its_own_keys(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard({"agent": {"reasoning_effort": "low"},
                                "display": {"theme": "midnight"}})
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        response = _put(bridge, "/v1/bots/cody/model-settings", {"effort": "xhigh"})

        assert response.status_code == 200, response.text
        assert response.json()["effort"] == "xhigh"
        patch = dashboard.writes[0][2]["config"]
        assert patch == {"agent": {"reasoning_effort": "xhigh"}}
        # The profile is named in the path *and* the body: the dashboard's own scope reads the body.
        assert dashboard.writes[0][1].endswith("profile=cody")
        assert dashboard.writes[0][2]["profile"] == "cody"

    def test_none_is_written_as_false(self, bridge, tmp_path, monkeypatch):
        # The host reads `False`, not the string "none", as thinking switched off.
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard({"agent": {}})
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        _put(bridge, "/v1/bots/cody/model-settings", {"effort": "none"})

        assert dashboard.writes[0][2]["config"]["agent"]["reasoning_effort"] is False

    def test_the_vision_model_is_written_under_auxiliary(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard({"agent": {}})
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        response = _put(bridge, "/v1/bots/cody/model-settings",
                        {"vision_provider": "anthropic", "vision_model": "claude-haiku-5.5"})

        assert response.status_code == 200, response.text
        assert dashboard.writes[0][2]["config"] == {
            "auxiliary": {"vision": {"provider": "anthropic", "model": "claude-haiku-5.5"}}}
        assert response.json()["vision"] == {"provider": "anthropic", "model": "claude-haiku-5.5"}

    def test_an_empty_provider_means_inherit_again(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard({"auxiliary": {"vision": {"provider": "openai", "model": "x"}}})
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        _put(bridge, "/v1/bots/cody/model-settings", {"vision_provider": ""})

        assert dashboard.writes[0][2]["config"]["auxiliary"]["vision"]["provider"] == "auto"

    def test_an_unknown_effort_is_refused_before_anything_is_written(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        dashboard = _Dashboard({"agent": {}})
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        response = _put(bridge, "/v1/bots/cody/model-settings", {"effort": "hgih"})

        assert response.status_code == 422
        assert dashboard.writes == []

    def test_the_profile_must_exist(self, bridge, tmp_path, monkeypatch):
        _bot_home(tmp_path, monkeypatch)
        monkeypatch.setattr(bot_admin, "_dashboard", _Dashboard({}))

        assert _get(bridge, "/v1/bots/nobody/model-settings").status_code in (400, 404)
