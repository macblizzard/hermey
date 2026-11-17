"""One approval mode for every bot, written through the host's own config API.

The host accepts exactly `manual`, `smart` and `off`; the client's friendlier labels must not turn into
a value the terminal approval guard would ignore. No profile is silently skipped on a write.
"""
from __future__ import annotations

import httpx

from hermes_bridge import bot_admin


def _homes(tmp_path, monkeypatch, profiles=("cody", "atlas")):
    home = tmp_path / "hermes-home"
    for name in profiles:
        (home / "profiles" / name).mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("HERMES_HOME", str(home))
    return home


class _Dashboard:
    def __init__(self):
        self.configs: dict[str, dict] = {}
        self.writes: list[tuple[str, dict]] = []

    def __call__(self, method, path, body=None):
        profile = path.split("profile=")[-1].split("&")[0]
        config = self.configs.setdefault(profile, {})
        if method == "PUT":
            patch = (body or {}).get("config") or {}
            approvals = dict(config.get("approvals") or {})
            approvals.update(patch.get("approvals") or {})
            config["approvals"] = approvals
            self.writes.append((profile, patch))
            return 200, {"ok": True}
        return 200, config


def _get(bridge, path):
    ticket = bridge.pair()["ticket"]
    return httpx.get(f"{bridge.base_url}{path}",
                     headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


def _put(bridge, path, body):
    ticket = bridge.pair()["ticket"]
    return httpx.put(f"{bridge.base_url}{path}", json=body,
                     headers={"Authorization": f"Bearer {ticket}"}, timeout=10)


class TestFleetApprovalMode:
    def test_unset_profiles_read_as_manual(self, bridge, tmp_path, monkeypatch):
        _homes(tmp_path, monkeypatch)
        monkeypatch.setattr(bot_admin, "_dashboard", _Dashboard())

        payload = _get(bridge, "/v1/bots/approvals").json()

        assert payload["mode"] == "manual"
        assert set(payload["profiles"]) == {"cody", "atlas"}
        assert set(payload["available"]) == {"manual", "smart", "off"}

    def test_a_write_reaches_every_profile_and_is_re_read(self, bridge, tmp_path, monkeypatch):
        _homes(tmp_path, monkeypatch)
        dashboard = _Dashboard()
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        response = _put(bridge, "/v1/bots/approvals", {"mode": "smart"})

        assert response.status_code == 200, response.text
        assert set(response.json()["updated"]) == {"cody", "atlas"}
        assert response.json()["failed"] == {}
        assert {profile for profile, _ in dashboard.writes} == {"cody", "atlas"}
        assert all(patch["approvals"]["mode"] == "smart" for _, patch in dashboard.writes)
        assert _get(bridge, "/v1/bots/approvals").json()["mode"] == "smart"

    def test_different_modes_are_reported_as_mixed(self, bridge, tmp_path, monkeypatch):
        _homes(tmp_path, monkeypatch)
        dashboard = _Dashboard()
        dashboard.configs["atlas"] = {"approvals": {"mode": "off"}}
        monkeypatch.setattr(bot_admin, "_dashboard", dashboard)

        assert _get(bridge, "/v1/bots/approvals").json()["mode"] == "mixed"

    def test_an_invented_mode_is_refused(self, bridge, tmp_path, monkeypatch):
        _homes(tmp_path, monkeypatch)
        monkeypatch.setattr(bot_admin, "_dashboard", _Dashboard())

        assert _put(bridge, "/v1/bots/approvals", {"mode": "ask-me-maybe"}).status_code == 422
