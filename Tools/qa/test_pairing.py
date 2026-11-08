"""Pairing, tokens, devices: the identity half of the bridge.

These are the invariants that decide whether a stranger on the tailnet can turn
into a device that speaks to an agent with shell access, so they are tested
directly rather than inferred from the WebSocket tests.
"""

from __future__ import annotations

import base64
import hashlib
import json
import sqlite3

import pytest


def bearer(bridge, pairing) -> dict[str, str]:
    return {"Authorization": "Bearer " + bridge.mint_ticket(pairing).ticket}

from qa_support import ROOT
from harness import BridgeUnderTest


# --------------------------------------------------------------------------- #
# Health and the pairing dance
# --------------------------------------------------------------------------- #


def test_health_reports_protocol_and_ws(bridge_factory):
    bridge = bridge_factory()
    response = bridge.http.get("/v1/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["protocol_version"] == 1
    assert body["ws"] is True
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["x-content-type-options"] == "nosniff"


def test_pairing_round_trip_yields_a_device_and_a_ticket(bridge_factory):
    bridge = bridge_factory()
    with bridge.http as client:
        start = client.post("/v1/pair/start")
        assert start.status_code == 200
        payload = start.json()
        assert len(payload["code"]) == 8 and payload["code"].isdigit()
        assert payload["protocol_version"] == 1
        assert payload["host"]

        claim = client.post(
            "/v1/pair/claim",
            json={
                "code": payload["code"],
                "public_key": bridge.device_public_key(),
                "device_name": "iPhone 16 Pro",
                "platform": "ios",
            },
        )
        assert claim.status_code == 200, claim.text
        device = claim.json()
        assert device["device_id"] and device["refresh_token"]

        token = client.post(
            "/v1/token",
            json={"device_id": device["device_id"], "refresh_token": device["refresh_token"]},
        )
        assert token.status_code == 200
        assert len(token.json()["ws_ticket"]) >= 32
        assert token.json()["expires_in"] == 15 * 60

        devices = client.get(
            "/v1/devices", headers={"Authorization": "Bearer " + token.json()["ws_ticket"]}
        ).json()
        assert [d["device_id"] for d in devices] == [device["device_id"]]
        assert devices[0]["revoked"] is False


def test_pairing_code_is_single_use(bridge_factory):
    bridge = bridge_factory()
    with bridge.http as client:
        code = client.post("/v1/pair/start").json()["code"]
        body = {"code": code, "public_key": bridge.device_public_key(), "device_name": "a", "platform": "ios"}
        assert client.post("/v1/pair/claim", json=body).status_code == 200
        assert client.post("/v1/pair/claim", json=body).status_code == 401


def test_pairing_code_expires(bridge_factory):
    bridge = bridge_factory()
    pairing = bridge.runtime.pairing
    code, expires = pairing.mint()
    real_clock = pairing._clock
    # Advance past the code's own expiry rather than a hardcoded 121s: the TTL is configurable
    # (HERMES_BRIDGE_PAIRING_TTL, default 600s), and a magic number silently stops testing
    # expiry the moment the default changes.
    pairing._clock = lambda: expires + 1.0
    try:
        with bridge.http as client:
            response = client.post(
                "/v1/pair/claim",
                json={"code": code, "public_key": bridge.device_public_key(), "device_name": "a",
                      "platform": "ios"},
            )
        assert response.status_code == 401
    finally:
        pairing._clock = real_clock


def test_pairing_codes_cannot_be_minted_through_a_proxy(bridge_factory):
    """A request that arrived via ``tailscale serve`` looks like loopback but is not local."""
    bridge = bridge_factory()
    with bridge.http as client:
        for header in ("X-Forwarded-For", "Tailscale-User-Login", "Forwarded"):
            response = client.post("/v1/pair/start", headers={header: "100.64.0.1"})
            assert response.status_code == 403, (header, response.status_code)


def test_pairing_codes_are_rate_limited(bridge_factory):
    """8 digits is brute-forceable, so guessing must cost something."""
    bridge = bridge_factory()
    with bridge.http as client:
        statuses = []
        for _ in range(12):
            response = client.post(
                "/v1/pair/claim",
                json={"code": "00000000", "public_key": bridge.device_public_key(),
                      "device_name": "x", "platform": "ios"},
            )
            statuses.append(response.status_code)
    assert statuses[:10] == [401] * 10, statuses
    assert 429 in statuses, statuses
    assert bridge.audit.last("client_request_rejected")["reason"] == "claim_rate_limited"


def test_a_placeholder_public_key_is_rejected(bridge_factory):
    bridge = bridge_factory()
    with bridge.http as client:
        code = client.post("/v1/pair/start").json()["code"]
        response = client.post(
            "/v1/pair/claim",
            json={"code": code, "public_key": "A" * 44, "device_name": "x", "platform": "ios"},
        )
        # 44 chars of "A" is valid base64 but not 32 bytes of key material.
        assert response.status_code == 400, response.text
        assert "32 bytes" in response.json()["detail"]


def test_the_device_limit_is_enforced(bridge_factory):
    bridge = bridge_factory()
    from hermes_bridge import app as app_module  # noqa: PLC0415

    # Shrink the limit instead of pairing 32 devices.
    original = app_module.MAX_DEVICES
    app_module.MAX_DEVICES = 1
    try:
        bridge.pair(name="first")
        with bridge.http as client:
            code = client.post("/v1/pair/start").json()["code"]
            response = client.post(
                "/v1/pair/claim",
                json={"code": code, "public_key": bridge.device_public_key(),
                      "device_name": "second", "platform": "ios"},
            )
        assert response.status_code == 409
    finally:
        app_module.MAX_DEVICES = original


# --------------------------------------------------------------------------- #
# Tokens
# --------------------------------------------------------------------------- #


def test_a_bad_refresh_token_is_refused(bridge_factory):
    bridge = bridge_factory()
    pairing = bridge.pair()
    response = bridge.token(pairing, refresh_token="nope")
    assert response.status_code == 401


def test_a_token_for_another_device_is_refused(bridge_factory):
    """A stolen refresh token is useless without the device id it belongs to."""
    bridge = bridge_factory()
    mine = bridge.pair(name="mine")
    theirs = bridge.pair(name="theirs")
    response = bridge.token(mine, device_id=theirs.device_id)
    assert response.status_code == 401


def test_a_revoked_device_cannot_mint_tokens(bridge_factory):
    bridge = bridge_factory()
    pairing = bridge.pair()
    with bridge.http as client:
        assert client.delete(f"/v1/devices/{pairing.device_id}",
                             headers=bearer(bridge, pairing)).status_code == 200
    assert bridge.token(pairing).status_code == 401


def test_revoking_an_unknown_device_is_a_404(bridge_factory):
    bridge = bridge_factory()
    pairing = bridge.pair()
    with bridge.http as client:
        assert client.delete("/v1/devices/nope", headers=bearer(bridge, pairing)).status_code == 404


def test_the_refresh_token_is_stored_hashed_and_never_on_disk(bridge_factory):
    """A heap dump or a stolen ``bridge.db`` must not yield a usable token."""
    bridge = bridge_factory()
    pairing = bridge.pair()

    # The device record the API exposes must not contain the token either.
    with bridge.http as client:
        listing = client.get("/v1/devices", headers=bearer(bridge, pairing)).text
    assert pairing.refresh_token not in listing
    assert pairing.public_key not in listing

    digest = hashlib.sha256(pairing.refresh_token.encode()).hexdigest()
    raw = bridge.db_path.read_bytes()
    assert pairing.refresh_token.encode() not in raw, "refresh token written in plaintext"
    assert digest.encode() in raw, "the hash the bridge compares against is not stored"

    with sqlite3.connect(bridge.db_path) as conn:
        rows = conn.execute("select * from devices").fetchall()
        columns = [d[0] for d in conn.execute("select * from devices").description]
    record = dict(zip(columns, rows[0]))
    assert record["refresh_token_hash"] == digest
    assert pairing.refresh_token not in json.dumps(record)


def test_the_access_token_is_not_a_bearer_for_the_http_api(bridge_factory):
    """``/v1/devices`` must not accept the token it just handed out as authority."""
    bridge = bridge_factory()
    pairing = bridge.pair()
    token = bridge.token(pairing).json()
    with bridge.http as client:
        response = client.get(
            "/v1/devices", headers={"Authorization": f"Bearer {token['access_token']}"}
        )
    assert response.status_code == 401
    assert "refresh_token_hash" not in response.text


def test_ticket_ttl_is_thirty_seconds(bridge_factory):
    from hermes_bridge.app import WS_TICKET_TTL_SECONDS

    assert WS_TICKET_TTL_SECONDS == 30
    assert bridge_factory().runtime.tickets.ttl == 30


def test_tickets_are_unique_and_long(bridge_factory):
    bridge = bridge_factory()
    pairing = bridge.pair()
    tickets = {bridge.mint_ticket(pairing).ticket for _ in range(5)}
    assert len(tickets) == 5
    assert all(len(t) >= 32 for t in tickets)


# --------------------------------------------------------------------------- #
# The gateway credential never leaves the process
# --------------------------------------------------------------------------- #


def test_the_gateway_token_is_not_exposed_by_any_http_surface(bridge_factory):
    secret = "gw-canary-2f8a1c-do-not-leak"
    bridge = bridge_factory(env={"HERMES_BRIDGE_GATEWAY_TOKEN": secret})
    pairing = bridge.pair()
    token = bridge.token(pairing).json()

    with bridge.http as client:
        bodies = [
            client.get("/v1/health").text,
            client.get("/v1/devices", headers=bearer(bridge, pairing)).text,
            client.post("/v1/pair/start").text,
            client.post("/v1/token", json={"device_id": pairing.device_id,
                                           "refresh_token": pairing.refresh_token}).text,
        ]
    for body in bodies + [json.dumps(token)]:
        assert secret not in body
    assert secret not in json.dumps(bridge.audit.records)
    assert secret not in bridge.runtime.config.safe_gateway_url()
