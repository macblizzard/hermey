"""The genui card routes: what the apps need to draw a plugin board.

The cards are drawn by the plugin's own bundle in a webview, so the bridge's job is narrow and
security-shaped: hand over the board JSON, the plugin bundle and React, and nothing else. These
cases pin the three things that could go wrong quietly — an unauthenticated route, a path that
walks out of the package, and a board id that is not an id.
"""
from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient

from hermes_bridge.app import create_app
from hermes_bridge.config import BridgeConfig

BOARD = [{"type": "heading", "text": "Tiny board"},
         {"type": "chart", "kind": "bar", "x": ["A", "B"], "series": [{"name": "Value", "data": [12, 30]}]}]


def _bridge(tmp_path: Path, monkeypatch):
    """An app, a paired device and one profile with one board on disk."""
    home = tmp_path / "home"
    profile = home / "profiles" / "fino"
    boards = profile / "plugin-data" / "hermes-genui" / "blocks"
    boards.mkdir(parents=True)
    (boards / "00b7610f.json").write_text(json.dumps(BOARD), encoding="utf-8")
    bundle = home / "plugins" / "hermes-genui" / "desktop"
    bundle.mkdir(parents=True)
    (bundle / "plugin.js").write_text("export default { register() {} };", encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(home))

    config = BridgeConfig(db_path=tmp_path / "bridge.db")
    app = create_app(config)
    app.state.bridge.registry.add_device(device_id="mac", name="mac", platform="test",
                                         public_key="test", refresh_token="secret")
    return app


def _ticket(client: TestClient) -> str:
    """A fresh ticket. One is single-use: a replay is refused, which is the point of them."""
    return client.post("/v1/token", json={"device_id": "mac", "refresh_token": "secret"}).json()["ws_ticket"]


def _auth(client: TestClient) -> dict[str, str]:
    return {"Authorization": "Bearer " + _ticket(client)}


def _session(client: TestClient, bot: str = "fino") -> str:
    """One card session: what a webview uses, because a ticket is good for exactly one request."""
    response = client.post(f"/v1/genui/session?bot={bot}", headers=_auth(client))
    assert response.status_code == 200, response.text
    return response.json()["session"]


def test_a_board_reaches_the_app_in_the_shape_the_renderer_reads(tmp_path, monkeypatch):
    app = _bridge(tmp_path, monkeypatch)
    with TestClient(app) as client:
        response = client.get("/v1/genui/blocks/00b7610f?bot=fino", headers=_auth(client))
        assert response.status_code == 200, response.text
        assert response.json() == {"blocks": BOARD}


def test_the_page_and_its_assets_accept_the_token_in_the_query(tmp_path, monkeypatch):
    """A webview cannot put a header on the module requests its own page makes."""
    app = _bridge(tmp_path, monkeypatch)
    with TestClient(app) as client:
        page = client.get(f"/v1/genui/host?block=00b7610f&bot=fino&session={_session(client)}")
        assert page.status_code == 200
        assert page.headers["content-type"].startswith("text/html")
        assert "importmap" in page.text
        for name in ("app.mjs", "jsx.mjs", "sdk.mjs"):
            asset = client.get(f"/v1/genui/assets/{name}?session={_session(client)}")
            assert asset.status_code == 200, name
            assert "javascript" in asset.headers["content-type"]
        bundle = client.get(f"/v1/genui/plugin.js?session={_session(client)}")
        assert bundle.status_code == 200
        assert "register" in bundle.text


def test_without_a_token_nothing_is_served(tmp_path, monkeypatch):
    app = _bridge(tmp_path, monkeypatch)
    with TestClient(app) as client:
        for path in ("/v1/genui/host", "/v1/genui/assets/app.mjs", "/v1/genui/plugin.js",
                     "/v1/genui/blocks/00b7610f?bot=fino"):
            assert client.get(path).status_code == 401, path
        assert client.get("/v1/genui/host?session=nothing").status_code == 401
        assert client.get("/v1/genui/host?token=not-a-ticket").status_code == 401
        assert client.post("/v1/genui/session?bot=fino").status_code == 401


def test_an_asset_name_cannot_walk_out_of_the_package(tmp_path, monkeypatch):
    app = _bridge(tmp_path, monkeypatch)
    with TestClient(app) as client:
        for name in ("../genui.py", "..%2Fgenui.py", "host.html/../../genui.py", "nothing.mjs"):
            response = client.get(f"/v1/genui/assets/{name}?session={_session(client)}")
            assert response.status_code in (404, 400), (name, response.status_code)


def test_a_board_id_must_be_an_id_and_a_bot_must_not_be_a_path(tmp_path, monkeypatch):
    app = _bridge(tmp_path, monkeypatch)
    with TestClient(app) as client:
        assert client.get("/v1/genui/blocks/NOTHEX?bot=fino", headers=_auth(client)).status_code == 404
        assert client.get("/v1/genui/blocks/00b7610f", headers=_auth(client)).status_code == 404
        assert client.get("/v1/genui/blocks/00b7610f?bot=../../etc", headers=_auth(client)).status_code == 404
        assert client.get("/v1/genui/blocks/deadbeef?bot=fino", headers=_auth(client)).status_code == 404


def test_ticks_survive_a_round_trip_and_are_capped(tmp_path, monkeypatch):
    app = _bridge(tmp_path, monkeypatch)
    with TestClient(app) as client:
        assert client.get("/v1/genui/blocks/00b7610f/state?bot=fino", headers=_auth(client)).json() == {}
        saved = client.put("/v1/genui/blocks/00b7610f/state?bot=fino", headers=_auth(client),
                           json={"state": {"0": [0, 2]}})
        assert saved.status_code == 204
        assert client.get("/v1/genui/blocks/00b7610f/state?bot=fino",
                          headers=_auth(client)).json() == {"state": {"0": [0, 2]}}
        assert client.put("/v1/genui/blocks/00b7610f/state?bot=fino", headers=_auth(client),
                          json={"state": {"0": "x" * 40_000}}).status_code == 413
        assert client.put("/v1/genui/blocks/00b7610f/state?bot=fino", headers=_auth(client),
                          json={"notstate": 1}).status_code == 400
        assert client.put("/v1/genui/blocks/deadbeef/state?bot=fino", headers=_auth(client),
                          json={"state": {}}).status_code == 404


def test_a_session_reads_the_boards_and_nothing_else_is_needed(tmp_path, monkeypatch):
    """One mint, then the page and every module it asks for: the shape a webview actually makes."""
    app = _bridge(tmp_path, monkeypatch)
    with TestClient(app) as client:
        session = _session(client)
        for path in (f"/v1/genui/host?block=00b7610f&bot=fino&session={session}",
                     f"/v1/genui/assets/app.mjs?session={session}",
                     f"/v1/genui/assets/sdk.mjs?session={session}",
                     f"/v1/genui/plugin.js?session={session}",
                     f"/v1/genui/blocks/00b7610f?bot=fino&session={session}"):
            assert client.get(path).status_code == 200, path
        # A session for one bot does not become a session for a board on another.
        assert client.get("/v1/genui/blocks/00b7610f?bot=cody&session=" + session).status_code == 404


def test_a_missing_plugin_is_an_honest_error_not_a_blank_page(tmp_path, monkeypatch):
    app = _bridge(tmp_path, monkeypatch)
    (tmp_path / "home" / "plugins" / "hermes-genui" / "desktop" / "plugin.js").unlink()
    with TestClient(app) as client:
        response = client.get(f"/v1/genui/plugin.js?session={_session(client)}")
        assert response.status_code == 503
        assert "not installed" in response.text
