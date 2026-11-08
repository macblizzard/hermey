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

from fastapi import HTTPException


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
