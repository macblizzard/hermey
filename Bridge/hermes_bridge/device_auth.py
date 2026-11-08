"""Bearer-ticket authentication shared by the paired-device HTTP routes.

Every authenticated bridge request mints its own 30-second, single-use ticket at
``POST /v1/token`` and presents it as ``Authorization: Bearer <ticket>``. A ticket
is consumed by exactly one request: it is never a session credential and never
survives the call. The ``access_token`` returned alongside it is random and not
verifiable, so it is never accepted here.

Redeeming first and checking the device second is deliberate: a revoked device
loses its outstanding tickets (``revoke_device``) *and* fails the active check,
so a revoke lands even in the window where a ticket was already minted.
"""

from __future__ import annotations

from typing import Optional

from fastapi import HTTPException, Request

#: Headers a reverse proxy adds. Their presence means the request was relayed, whatever the socket
#: peer says — `tailscale serve` dials 127.0.0.1, so the peer alone cannot tell host from tailnet.
PROXY_HEADERS = ("forwarded", "x-forwarded-for", "x-real-ip", "tailscale-user-login")


def bearer_token(authorization: Optional[str]) -> str:
    """``Bearer abc`` -> ``abc``; anything else -> ``''`` (never a parse error)."""
    parts = (authorization or '').split()
    return parts[1] if len(parts) == 2 and parts[0].lower() == 'bearer' else ''


def require_device(runtime, authorization: Optional[str]) -> str:
    """Consume the caller's single-use ticket, or raise 401.

    Returns the authenticated device id. No ticket value ever appears in the
    response, and a bad, expired, replayed or revoked one is indistinguishable
    from a missing one.
    """
    device_id = runtime.tickets.redeem(bearer_token(authorization))
    if not device_id or not runtime.registry.is_active(device_id):
        raise HTTPException(status_code=401, detail='invalid, expired or revoked ticket')
    return device_id


def is_local_host_request(request: Request) -> bool:
    """True only for a direct loopback caller, never a proxied one.

    The single copy of this rule: an operator-only route that re-implements it will get it wrong,
    and "the peer is 127.0.0.1" is not the same claim once `tailscale serve` is in front.
    """
    if any(header in request.headers for header in PROXY_HEADERS):
        return False
    from .config import is_loopback_host

    return is_loopback_host(request.client.host if request.client else "")
