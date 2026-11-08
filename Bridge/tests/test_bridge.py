from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from bridge_test_support import TEST_PUBLIC_KEY
from hermes_bridge.app import WS_TICKET_TTL_SECONDS, create_app
from hermes_bridge.config import BridgeConfig
from hermes_bridge.registry import DeviceRegistry


@pytest.fixture
def app_bridge(tmp_path):
    config = BridgeConfig(
        db_path=tmp_path / "bridge.db",
        gateway_url="ws://127.0.0.1:9/api/ws",
        gateway_token="gateway-token-do-not-leak",
    )
    registry = DeviceRegistry(config.db_path)
    try:
        yield create_app(config, registry=registry)
    finally:
        registry.close()


def client(app, host: str = "127.0.0.1") -> TestClient:
    # TestClient's default client host is "testclient", so mint codes from loopback.
    return TestClient(app, client=(host, 50000))


def auth_headers(c: TestClient, device_id: str, refresh_token: str) -> dict[str, str]:
    token = c.post("/v1/token", json={"device_id": device_id, "refresh_token": refresh_token})
    assert token.status_code == 200, token.text
    return {"Authorization": "Bearer " + token.json()["ws_ticket"]}


def test_health(app_bridge):
    r = client(app_bridge).get("/v1/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["protocol_version"] == 1
    assert body["ws"] is True


def test_pairing_happy_path(app_bridge):
    c = client(app_bridge)
    start = c.post("/v1/pair/start")
    assert start.status_code == 200
    code = start.json()["code"]
    assert len(code) == 8

    claim = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": TEST_PUBLIC_KEY, "device_name": "iPhone", "platform": "ios"},
    )
    assert claim.status_code == 200, claim.text
    device_id = claim.json()["device_id"]
    refresh = claim.json()["refresh_token"]

    tok = c.post("/v1/token", json={"device_id": device_id, "refresh_token": refresh})
    assert tok.status_code == 200
    assert tok.json()["ws_ticket"]
    assert tok.json()["expires_in"] > 0

    # the code is single use
    again = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": TEST_PUBLIC_KEY, "device_name": "x", "platform": "ios"},
    )
    assert again.status_code == 401


def test_bad_refresh_token_is_refused(app_bridge):
    c = client(app_bridge)
    code = c.post("/v1/pair/start").json()["code"]
    claim = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": TEST_PUBLIC_KEY, "device_name": "Mac", "platform": "macos"},
    ).json()
    bad = c.post("/v1/token", json={"device_id": claim["device_id"], "refresh_token": "nope"})
    assert bad.status_code == 401


def test_revoked_device_cannot_mint_tokens(app_bridge):
    c = client(app_bridge)
    code = c.post("/v1/pair/start").json()["code"]
    claim = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": TEST_PUBLIC_KEY, "device_name": "Mac", "platform": "macos"},
    ).json()
    headers = auth_headers(c, claim["device_id"], claim["refresh_token"])
    assert c.delete(f"/v1/devices/{claim['device_id']}", headers=headers).status_code == 200
    tok = c.post(
        "/v1/token", json={"device_id": claim["device_id"], "refresh_token": claim["refresh_token"]}
    )
    assert tok.status_code == 401


def test_revoked_device_disappears_from_active_list(app_bridge):
    c = client(app_bridge)
    code = c.post("/v1/pair/start").json()["code"]
    claim = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": TEST_PUBLIC_KEY, "device_name": "Mac", "platform": "macos"},
    ).json()
    c.delete(f"/v1/devices/{claim['device_id']}",
             headers=auth_headers(c, claim["device_id"], claim["refresh_token"]))
    # A revoked device cannot authenticate the list, so inspect it through a second active device.
    admin = app_bridge.state.bridge.registry
    admin.add_device(device_id="admin", name="Admin", platform="ios", public_key="pk", refresh_token="admin-refresh")
    devices = c.get("/v1/devices", headers=auth_headers(c, "admin", "admin-refresh")).json()
    assert devices[0]["revoked"] is True
    assert "refresh_token" not in devices[0]


def test_pairing_code_is_host_only(app_bridge):
    assert client(app_bridge, host="10.0.0.9").post("/v1/pair/start").status_code == 403


def test_pairing_code_refused_through_a_reverse_proxy(app_bridge):
    """tailscale serve makes every peer loopback; proxy headers are what betray it."""
    c = client(app_bridge)
    assert c.post("/v1/pair/start", headers={"Tailscale-User-Login": "a@b"}).status_code == 403
    assert c.post("/v1/pair/start", headers={"X-Forwarded-For": "203.0.113.9"}).status_code == 403
    assert c.post("/v1/pair/start").status_code == 200


def test_ws_ticket_ttl_is_short():
    assert WS_TICKET_TTL_SECONDS == 30


def test_public_key_must_be_a_32_byte_ed25519_key(app_bridge):
    c = client(app_bridge)
    code = c.post("/v1/pair/start").json()["code"]
    r = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": "A" * 44, "device_name": "x", "platform": "ios"},
    )
    assert r.status_code == 400
    assert "32 bytes" in r.json()["detail"]


def test_public_key_is_stored_canonically(app_bridge):
    import base64

    raw = bytes(range(32))
    padded = base64.b64encode(raw).decode()
    c = client(app_bridge)
    code = c.post("/v1/pair/start").json()["code"]
    claim = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": padded, "device_name": "x", "platform": "ios"},
    ).json()
    stored = app_bridge.state.bridge.registry.get(claim["device_id"]).public_key
    assert stored == base64.urlsafe_b64encode(raw).decode().rstrip("=")


def test_claim_is_rate_limited(app_bridge):
    c = client(app_bridge)
    body = {
        "code": "00000000",
        "public_key": TEST_PUBLIC_KEY,
        "device_name": "x",
        "platform": "ios",
    }
    for _ in range(10):
        c.post("/v1/pair/claim", json=body)
    blocked = c.post("/v1/pair/claim", json=body)
    assert blocked.status_code == 429
    assert blocked.headers["Retry-After"]


def test_health_never_leaks_the_gateway(app_bridge):
    body = client(app_bridge).get("/v1/health").text
    assert "9/api/ws" not in body
    assert "gateway-token-do-not-leak" not in body


def test_token_response_never_contains_gateway_details(app_bridge):
    c = client(app_bridge)
    code = c.post("/v1/pair/start").json()["code"]
    claim = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": TEST_PUBLIC_KEY, "device_name": "iPhone", "platform": "ios"},
    ).json()
    body = c.post(
        "/v1/token",
        json={"device_id": claim["device_id"], "refresh_token": claim["refresh_token"]},
    ).text
    assert "9/api/ws" not in body
    assert "gateway-token-do-not-leak" not in body
    assert claim["refresh_token"] not in body


def test_revoking_a_device_kills_its_outstanding_ticket(app_bridge):
    c = client(app_bridge)
    code = c.post("/v1/pair/start").json()["code"]
    claim = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": TEST_PUBLIC_KEY, "device_name": "iPhone", "platform": "ios"},
    ).json()
    ticket = c.post(
        "/v1/token",
        json={"device_id": claim["device_id"], "refresh_token": claim["refresh_token"]},
    ).json()["ws_ticket"]

    c.delete(f"/v1/devices/{claim['device_id']}",
             headers=auth_headers(c, claim["device_id"], claim["refresh_token"]))
    assert app_bridge.state.bridge.tickets.redeem(ticket) is None


def test_device_limit_is_enforced(tmp_path, monkeypatch):
    import hermes_bridge.app as app_module

    monkeypatch.setattr(app_module, "MAX_DEVICES", 1)
    config = BridgeConfig(db_path=tmp_path / "bridge.db", gateway_url="ws://127.0.0.1:9/api/ws")
    registry = DeviceRegistry(config.db_path)
    try:
        c = client(app_module.create_app(config, registry=registry))

        def pair_one():
            code = c.post("/v1/pair/start").json()["code"]
            return c.post(
                "/v1/pair/claim",
                json={
                    "code": code,
                    "public_key": TEST_PUBLIC_KEY,
                    "device_name": "d",
                    "platform": "ios",
                },
            )

        assert pair_one().status_code == 200
        assert pair_one().status_code == 409
    finally:
        registry.close()


def test_unsafe_bind_host_is_refused(tmp_path):
    from hermes_bridge.config import ConfigError

    config = BridgeConfig(
        bind_host="0.0.0.0",
        db_path=tmp_path / "bridge.db",
        gateway_url="ws://127.0.0.1:9/api/ws",
    )
    with pytest.raises(ConfigError):
        create_app(config)


def test_remote_gateway_url_is_refused(tmp_path):
    from hermes_bridge.config import ConfigError

    config = BridgeConfig(
        db_path=tmp_path / "bridge.db",
        gateway_url="wss://gateway.example.com/api/ws",
        gateway_token="secret",
    )
    with pytest.raises(ConfigError):
        create_app(config)


def test_device_list_and_revoke_require_fresh_active_ticket(app_bridge):
    c = client(app_bridge)
    reg = app_bridge.state.bridge.registry
    for device in ('admin', 'target'):
        reg.add_device(device_id=device, name=device, platform='ios', public_key='pk',
                       refresh_token=device+'-refresh')

    for headers in ({}, {'Authorization': 'Bearer invalid'}):
        assert c.get('/v1/devices', headers=headers).status_code == 401
        assert c.delete('/v1/devices/target', headers=headers).status_code == 401
    assert reg.is_active('target')

    list_headers = auth_headers(c, 'admin', 'admin-refresh')
    response = c.get('/v1/devices', headers=list_headers)
    assert response.status_code == 200
    assert {row['device_id'] for row in response.json()} == {'admin', 'target'}
    assert c.get('/v1/devices', headers=list_headers).status_code == 401  # single use

    revoke_headers = auth_headers(c, 'admin', 'admin-refresh')
    assert c.delete('/v1/devices/target', headers=revoke_headers).status_code == 200
    assert not reg.is_active('target')
    assert c.delete('/v1/devices/target', headers=revoke_headers).status_code == 401


def test_permanent_cleanup_of_revoked_device(app_bridge):
    c = client(app_bridge)
    reg = app_bridge.state.bridge.registry
    for device in ('admin', 'old'):
        reg.add_device(device_id=device, name=device, platform='ios', public_key='pk', refresh_token=device+'-refresh')
    old_ticket = c.post('/v1/token', json={'device_id': 'old', 'refresh_token': 'old-refresh'}).json()['ws_ticket']
    assert c.delete('/v1/devices/old', headers=auth_headers(c, 'admin', 'admin-refresh')).status_code == 200
    ticket = c.post('/v1/token', json={'device_id': 'admin', 'refresh_token': 'admin-refresh'}).json()['ws_ticket']
    response = c.delete('/v1/devices/old/revoked', headers={'Authorization': 'Bearer '+ticket})
    assert response.status_code == 200
    assert reg.get('old') is None
    assert all(d['device_id'] != 'old' for d in c.get(
        '/v1/devices', headers=auth_headers(c, 'admin', 'admin-refresh')).json())
    assert c.post('/v1/token', json={'device_id': 'old', 'refresh_token': 'old-refresh'}).status_code == 401
    assert c.get('/v1/bot-icons', headers={'Authorization': 'Bearer '+old_ticket}).status_code == 401
    assert c.delete('/v1/devices/old/revoked', headers={'Authorization': 'Bearer '+ticket}).status_code == 401


def test_cleanup_requires_fresh_active_device_ticket_and_rejects_active(app_bridge):
    c = client(app_bridge)
    reg = app_bridge.state.bridge.registry
    for device in ('admin', 'target', 'revoked'):
        reg.add_device(device_id=device, name=device, platform='ios', public_key='pk', refresh_token=device+'-refresh')
    def mint(device):
        return c.post('/v1/token', json={'device_id': device, 'refresh_token': device+'-refresh'}).json()
    revoked_ticket = mint('revoked')['ws_ticket']
    reg.revoke('revoked')
    path = '/v1/devices/target/revoked'
    for headers in ({}, {'Authorization': 'Bearer invalid'},
                    {'Authorization': 'Bearer '+revoked_ticket},
                    {'Authorization': 'Bearer '+mint('admin')['access_token']}):
        assert c.delete(path, headers=headers).status_code == 401
    ticket = mint('admin')['ws_ticket']
    assert c.delete(path, headers={'Authorization': 'Bearer '+ticket}).status_code == 409
    assert reg.is_active('target')
    assert c.delete(path, headers={'Authorization': 'Bearer '+ticket}).status_code == 401
    ticket = mint('admin')['ws_ticket']
    assert c.delete('/v1/devices/missing/revoked', headers={'Authorization': 'Bearer '+ticket}).status_code == 404
    assert c.delete('/v1/devices/missing/revoked', headers={'Authorization': 'Bearer '+ticket}).status_code == 401
