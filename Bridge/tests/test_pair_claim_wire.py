"""The claim body's field names are the contract between the clients and the host.

The Mac app posted `publicKey`/`deviceName` while the host's model is `public_key`/`device_name`,
so FastAPI answered 422 for a field that was "missing" and the sheet could only show the status
code. Both shapes are pinned here: camelCase must be refused, snake_case must pair.
"""

from __future__ import annotations

import base64

PUBLIC_KEY = base64.b64encode(b"\x11" * 32).decode("ascii")


def _mint(bridge) -> str:
    return bridge.app.state.bridge.pairing.mint()[0]


def test_camel_case_body_is_refused(bridge):
    client = bridge.client()
    response = client.post("/v1/pair/claim", json={
        "code": _mint(bridge),
        "publicKey": PUBLIC_KEY,
        "deviceName": "MacBook Pro",
        "platform": "macos",
    })

    assert response.status_code == 422, "the host names this field public_key"
    detail = response.json()["detail"]
    assert any("public_key" in (item.get("loc") or []) for item in detail)


def test_snake_case_body_pairs(bridge):
    client = bridge.client()
    response = client.post("/v1/pair/claim", json={
        "code": _mint(bridge),
        "public_key": PUBLIC_KEY,
        "device_name": "MacBook Pro",
        "platform": "macos",
    })

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["device_id"]
    assert body["refresh_token"]
