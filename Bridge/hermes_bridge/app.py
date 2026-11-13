"""Bridge HTTP + WebSocket surface.

HTTP: health, pairing, device registry, token exchange.
WS:   ``/v1/ws?ticket=...`` -- the JSON-RPC relay in :mod:`hermes_bridge.proxy`.

Security posture:

* pairing codes can only be minted by a process actually on the host -- a
  connection that arrived through ``tailscale serve`` carries proxy headers and
  is refused, even though its peer address is loopback;
* a claim is rate limited per source address, because the 8-digit code is the
  only brute-forceable secret in the system;
* refresh tokens are stored as SHA-256 only, and a device is checked *again* at
  ticket redemption and at upgrade, so a revoke takes effect immediately;
* a WS ticket is single use, 30 s, and bound to the device that asked for it.

The gateway URL and token never appear in a response, an error string or an audit
record.
"""

from __future__ import annotations

import base64
import logging
import os
import secrets
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Optional

from fastapi import FastAPI, Header, HTTPException, Request, WebSocket
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from .audit import AuditLog
from .device_auth import is_local_host_request as is_local_host_request_shared
from .bot_icons import create_bot_icons_router
from .attachment_files import create_attachment_files_router
from .workspace import create_workspace_router
from .bot_previews import create_bot_previews_router
from .genui import create_genui_router
from .bot_admin import create_bot_admin_router
from .rooms import create_rooms_router
from .bot_message import create_bot_message_router
from .bot_sessions import create_bot_sessions_router
from .config import BridgeConfig, is_loopback_host
from .device_auth import require_device
from .display import create_display_router
from .pairing import InvalidPublicKey, normalize_public_key
from .proxy import GatewayProxy, LiveSessions
from .registry import DeviceRegistry
from .tickets import AttemptThrottle, PairingCodes, TicketStore
from .voice import VoiceBackend, create_voice_router

#: How long a minted pairing code stays usable. Two minutes is shorter than the walk from the
#: host to a phone with the app open, and a code is single-use, loopback-minted and rate-limited,
#: so ten minutes buys usability without buying risk. Override with HERMES_BRIDGE_PAIRING_TTL.
PAIRING_CODE_TTL_SECONDS = int(os.environ.get("HERMES_BRIDGE_PAIRING_TTL", "600"))
ACCESS_TOKEN_TTL_SECONDS = 15 * 60
WS_TICKET_TTL_SECONDS = 30
MAX_CONTROL_BODY_BYTES = 1 * 1024 * 1024
MAX_VOICE_BODY_BYTES = 16 * 1024 * 1024
PROTOCOL_VERSION = 1
MAX_DEVICES = 32

_PROXY_HEADERS = ("forwarded", "x-forwarded-for", "x-real-ip", "tailscale-user-login")


class PairStartResponse(BaseModel):
    code: str
    expires_at: float
    host: str
    protocol_version: int


class PairClaimRequest(BaseModel):
    code: str = Field(min_length=4, max_length=64)
    public_key: str = Field(min_length=32, max_length=512)
    device_name: str = Field(default="device", max_length=80)
    platform: str = Field(default="unknown", max_length=16)


class PairClaimResponse(BaseModel):
    device_id: str
    refresh_token: str
    protocol_version: int


class TokenRequest(BaseModel):
    refresh_token: str
    device_id: str


class TokenResponse(BaseModel):
    access_token: str
    ws_ticket: str
    expires_in: int


@dataclass
class BridgeRuntime:
    config: BridgeConfig
    registry: DeviceRegistry
    audit: AuditLog
    pairing: PairingCodes
    tickets: TicketStore
    claims: AttemptThrottle
    live: LiveSessions


def _is_local_host_request(request: Request) -> bool:
    """True only for a direct loopback caller, not a tailscale-serve proxy."""
    return is_local_host_request_shared(request)


def _client_key(request: Request) -> str:
    """The identity a rate limiter keys on.

    The *first* entry of `X-Forwarded-For` is whatever the caller typed, so keying on it let a
    brute-forcer rotate the header past the attempt limit. The last entry is the hop that actually
    connected to the proxy, which a client cannot rewrite; the socket peer is used when there is
    no header at all.
    """
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        hops = [hop.strip() for hop in forwarded.split(",") if hop.strip()]
        if hops:
            return hops[-1][:64]
    return (request.client.host if request.client else "unknown")[:64]


def _public_host(request: Request) -> str:
    """The host a pairing code should name.

    ``HERMES_BRIDGE_PUBLIC_HOST`` when the install configured one (it puts the tailnet name there),
    else the ``Host`` header the caller actually used — so a code never names somebody else's domain.
    """
    configured = os.environ.get("HERMES_BRIDGE_PUBLIC_HOST", "").strip()
    if configured:
        return configured
    return request.headers.get("host", "127.0.0.1")


def create_app(
    config: Optional[BridgeConfig] = None,
    *,
    registry: Optional[DeviceRegistry] = None,
    audit: Optional[AuditLog] = None,
    voice_backend: Optional[VoiceBackend] = None,
    display_gateway_call=None,
    display_ws_url=None,
) -> FastAPI:
    cfg = config or BridgeConfig.from_env()
    cfg.validate()

    reg = registry or DeviceRegistry(cfg.db_path)
    log = audit or AuditLog(logger=logging.getLogger(cfg.audit_logger_name))
    runtime = BridgeRuntime(
        config=cfg,
        registry=reg,
        audit=log,
        pairing=PairingCodes(ttl=PAIRING_CODE_TTL_SECONDS),
        tickets=TicketStore(ttl=WS_TICKET_TTL_SECONDS),
        claims=AttemptThrottle(limit=10, window=60.0),
        live=LiveSessions(),
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        yield
        if registry is None:  # only close what this app created
            reg.close()

    app = FastAPI(title="hermes-bridge", version="0.2.0", lifespan=lifespan)

    @app.middleware("http")
    async def limit_body(request: Request, call_next):
        """Refuse an oversized body before anything parses it.

        FastAPI reads and validates a body before a handler runs, so a limit *inside* a handler is
        a limit after the memory is already spent — and two of these routes are unauthenticated.
        Control routes are small by design; a voice upload is audio and gets a larger ceiling.
        """
        limit = MAX_VOICE_BODY_BYTES if request.url.path.startswith("/v1/voice/") else MAX_CONTROL_BODY_BYTES
        declared = request.headers.get("content-length")
        if declared is None and "chunked" in request.headers.get("transfer-encoding", "").lower():
            # Every client here knows its size. A chunked body would reach the parser without ever
            # being counted, which is the one way this middleware can be walked around.
            return JSONResponse({"detail": "content-length required"}, status_code=411)
        if declared is not None:
            try:
                if int(declared) > limit:
                    return JSONResponse({"detail": "request body too large"}, status_code=413)
            except ValueError:
                return JSONResponse({"detail": "bad content-length"}, status_code=400)
        return await call_next(request)
    app.state.bridge = runtime
    app.include_router(create_bot_icons_router(runtime))
    app.include_router(create_bot_previews_router(runtime))
    app.include_router(create_genui_router(runtime))
    # An uploaded picture lives on this host; a device that lost its copy asks for it here.
    app.include_router(create_attachment_files_router(runtime))
    app.include_router(create_workspace_router(runtime))
    app.include_router(create_bot_sessions_router(runtime))
    # Operator-side: the agent on this host messages another bot in that bot's own chat.
    app.include_router(create_bot_message_router(runtime))
    app.include_router(create_bot_admin_router(runtime))
    app.include_router(create_rooms_router(runtime))
    # The shared Bot Computer: status/lease/thumbnail over HTTP, raw RFB over its own WebSocket.
    # The two hooks exist for tests: production dials the configured gateway.
    app.include_router(create_display_router(runtime, gateway_call=display_gateway_call,
                                             display_ws_url=display_ws_url))
    # Keys are read from the bridge EnvironmentFile at construction, never from a
    # request; tests pass a backend with an injected transport.
    app.include_router(create_voice_router(runtime, voice_backend))

    @app.middleware("http")
    async def no_store(request: Request, call_next):
        started = time.perf_counter()
        audit_path = "/v1/bot-icons/{bot_id}" if request.url.path.startswith("/v1/bot-icons/") else request.url.path
        try:
            response = await call_next(request)
        except Exception:
            if request.url.path.startswith("/v1/"):
                runtime.audit.emit("http", method=request.method, path=audit_path,
                                   outcome="500", duration_ms=time.perf_counter() - started)
            raise
        if request.url.path.startswith("/v1/"):
            response.headers.setdefault("Cache-Control", "no-store")
            response.headers.setdefault("X-Content-Type-Options", "nosniff")
            # Pairing and token failures were invisible: uvicorn runs with access_log off and the
            # audit log only covered the websocket, so "the app says the host does not know this
            # device" could not be traced to a request or a status code. Record method, path,
            # status and duration — still no bodies and no headers, so no code or token leaks.
            runtime.audit.emit("http", method=request.method, path=audit_path,
                               outcome=str(response.status_code),
                               duration_ms=time.perf_counter() - started)
        return response

    @app.get("/v1/health")
    def health() -> dict:
        # Unauthenticated, so it says only that the bridge is alive. The device count was a
        # free fingerprint for anyone who could reach the port.
        return {
            "status": "ok",
            "protocol_version": PROTOCOL_VERSION,
            "ws": True,
        }

    @app.post("/v1/pair/start", response_model=PairStartResponse)
    def pair_start(request: Request) -> PairStartResponse:
        if not _is_local_host_request(request):
            raise HTTPException(
                status_code=403,
                detail="pairing codes are minted on the host only",
            )
        code, _expires = runtime.pairing.mint()
        return PairStartResponse(
            code=code,
            expires_at=time.time() + PAIRING_CODE_TTL_SECONDS,
            host=_public_host(request),
            protocol_version=PROTOCOL_VERSION,
        )

    @app.post("/v1/pair/claim", response_model=PairClaimResponse)
    def pair_claim(body: PairClaimRequest, request: Request) -> PairClaimResponse:
        allowed, retry_after = runtime.claims.check(_client_key(request))
        if not allowed:
            log.emit(
                "client_request_rejected",
                reason="claim_rate_limited",
                direction="client_to_gateway",
            )
            raise HTTPException(
                status_code=429,
                detail="too many pairing attempts",
                headers={"Retry-After": str(retry_after)},
            )

        if not runtime.pairing.redeem(body.code):
            raise HTTPException(status_code=401, detail="pairing code invalid or expired")

        try:
            public_key = normalize_public_key(body.public_key)
        except InvalidPublicKey as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

        if runtime.registry.count_active() >= MAX_DEVICES:
            raise HTTPException(status_code=409, detail="device limit reached; revoke one first")

        device_id = base64.urlsafe_b64encode(secrets.token_bytes(12)).decode().rstrip("=")
        refresh = secrets.token_urlsafe(32)
        runtime.registry.add_device(
            device_id=device_id,
            name=body.device_name,
            platform=body.platform,
            public_key=public_key,
            refresh_token=refresh,
        )
        return PairClaimResponse(
            device_id=device_id, refresh_token=refresh, protocol_version=PROTOCOL_VERSION
        )

    @app.post("/v1/token", response_model=TokenResponse)
    def token(body: TokenRequest) -> TokenResponse:
        device = runtime.registry.verify_refresh(body.device_id, body.refresh_token)
        if device is None:
            raise HTTPException(status_code=401, detail="unknown device or bad refresh token")
        ticket = runtime.tickets.mint(device.device_id)
        runtime.registry.touch(device.device_id)
        return TokenResponse(
            access_token=secrets.token_urlsafe(32),
            ws_ticket=ticket,
            expires_in=ACCESS_TOKEN_TTL_SECONDS,
        )

    @app.get("/v1/devices")
    def devices(authorization: Optional[str] = Header(default=None)) -> list[dict]:
        require_device(runtime, authorization)
        return [
            {
                "device_id": d.device_id,
                "name": d.name,
                "platform": d.platform,
                "created_at": d.created_at,
                "last_seen_at": d.last_seen_at,
                "revoked": d.revoked,
            }
            for d in runtime.registry.list_devices()
        ]

    @app.delete("/v1/devices/{device_id}")
    async def revoke(device_id: str, authorization: Optional[str] = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        if runtime.registry.get(device_id) is None:
            raise HTTPException(status_code=404, detail="unknown device")
        runtime.registry.revoke(device_id)
        runtime.tickets.revoke_device(device_id)
        # A revoke that leaves the device's socket open is a promise we cannot keep: the
        # phone would keep streaming turns until it noticed. Close it from this side.
        closed = await runtime.live.close_device(device_id)
        return {"revoked": device_id, "sockets_closed": closed}

    @app.delete("/v1/devices/{device_id}/revoked")
    def delete_revoked_device(device_id: str, authorization: Optional[str] = Header(default=None)) -> dict:
        require_device(runtime, authorization)
        result = runtime.registry.delete_revoked(device_id)
        if result == "active":
            raise HTTPException(status_code=409, detail="device is not revoked")
        if result == "missing":
            raise HTTPException(status_code=404, detail="unknown device")
        runtime.tickets.revoke_device(device_id)
        return {"deleted": device_id}

    @app.websocket("/v1/ws")
    async def ws_proxy(websocket: WebSocket) -> None:
        ticket = websocket.query_params.get("ticket")
        if not ticket:
            authorization = websocket.headers.get("authorization", "")
            if authorization.lower().startswith("bearer "):
                ticket = authorization[7:].strip()

        # Redeem before accept: an unauthenticated upgrade never becomes a
        # socket, and the ticket is gone even if the peer immediately hangs up.
        device_id = runtime.tickets.redeem(ticket) if ticket else None
        if not device_id or not runtime.registry.is_active(device_id):
            log.emit(
                "ticket_rejected",
                device_id=device_id,
                reason="invalid_expired_or_revoked",
                outcome="denied",
            )
            await websocket.close(code=4401)
            return

        if not runtime.live.has_room(device_id):
            runtime.audit.emit("ws", device_id=device_id, path="/v1/ws",
                               outcome="too_many_connections")
            await websocket.close(code=4429)
            return

        await websocket.accept()
        proxy = GatewayProxy(websocket, device_id, cfg, log)
        await runtime.live.register(proxy)
        try:
            await proxy.run()
        finally:
            await runtime.live.unregister(proxy)

    return app
