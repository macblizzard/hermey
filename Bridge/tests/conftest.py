from __future__ import annotations

import base64
import itertools
import sys
import threading
import time
from pathlib import Path
from urllib.parse import quote

import httpx
import pytest

BRIDGE_ROOT = Path(__file__).resolve().parents[1]
if str(BRIDGE_ROOT) not in sys.path:
    sys.path.insert(0, str(BRIDGE_ROOT))

from hermes_bridge.app import create_app  # noqa: E402
from hermes_bridge.audit import AuditLog  # noqa: E402
from hermes_bridge.config import DEFAULT_FRAME_CAP, BridgeConfig  # noqa: E402
from hermes_bridge.registry import DeviceRegistry  # noqa: E402
from fake_gateway import FakeGateway  # noqa: E402
from bridge_test_support import GATEWAY_TOKEN, TEST_PUBLIC_KEY  # noqa: F401

GATEWAY_TOKEN = "gateway-token-9f3c2a-do-not-leak"
TEST_PUBLIC_KEY = base64.b64encode(b"\x11" * 32).decode("ascii")


class LiveBridge:
    """The FastAPI app served by uvicorn on a real loopback port."""

    def __init__(self, app, config: BridgeConfig, audit: AuditLog) -> None:
        import uvicorn

        self.app = app
        self.config = config
        self.audit = audit
        self.registry: DeviceRegistry = app.state.bridge.registry
        self._server = uvicorn.Server(
            uvicorn.Config(
                app,
                host="127.0.0.1",
                port=0,
                log_level="warning",
                access_log=False,
                lifespan="off",
            )
        )
        self._thread: threading.Thread | None = None
        self.port = 0

    def start(self) -> "LiveBridge":
        self._thread = threading.Thread(target=self._server.run, name="bridge-test", daemon=True)
        self._thread.start()
        deadline = time.time() + 10
        while time.time() < deadline:
            if self._server.started:
                sockets = list(self._server.servers[0].sockets)
                self.port = sockets[0].getsockname()[1]
                return self
            time.sleep(0.01)
        raise RuntimeError("bridge did not start")

    def stop(self) -> None:
        if self._thread is None:
            return
        self._server.should_exit = True
        self._thread.join(10)
        self._thread = None

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def ws_url(self, ticket: str) -> str:
        return f"ws://127.0.0.1:{self.port}/v1/ws?ticket={quote(ticket)}"

    def client(self) -> httpx.Client:
        return httpx.Client(base_url=self.base_url, timeout=5.0)

    def pair(
        self,
        *,
        name: str = "iPhone",
        platform: str = "ios",
        public_key: str = TEST_PUBLIC_KEY,
    ) -> dict:
        with self.client() as client:
            start = client.post("/v1/pair/start")
            start.raise_for_status()
            code = start.json()["code"]
            claim = client.post(
                "/v1/pair/claim",
                json={
                    "code": code,
                    "public_key": public_key,
                    "device_name": name,
                    "platform": platform,
                },
            )
            claim.raise_for_status()
            claimed = claim.json()
            token = client.post(
                "/v1/token",
                json={
                    "device_id": claimed["device_id"],
                    "refresh_token": claimed["refresh_token"],
                },
            )
            token.raise_for_status()
        return {
            "code": code,
            "device_id": claimed["device_id"],
            "refresh_token": claimed["refresh_token"],
            "ticket": token.json()["ws_ticket"],
        }

    def mint_ticket(self, device_id: str) -> str:
        runtime = self.app.state.bridge
        return runtime.tickets.mint(device_id)


@pytest.fixture
def fake_gateway():
    gateway = FakeGateway().start()
    try:
        yield gateway
    finally:
        gateway.stop()


@pytest.fixture
def bridge_factory(tmp_path, fake_gateway):
    servers: list[tuple[LiveBridge, DeviceRegistry]] = []
    counter = itertools.count()

    def make(
        *,
        gateway_url: str | None = None,
        frame_cap: int | None = None,
        connect_timeout: float = 3.0,
        gateway_token: str | None = GATEWAY_TOKEN,
        extra_client_methods: frozenset[str] = frozenset(),
    ) -> LiveBridge:
        config = BridgeConfig(
            db_path=tmp_path / f"bridge-{next(counter)}.db",
            gateway_url=gateway_url or fake_gateway.url,
            gateway_token=gateway_token,
            connect_timeout=connect_timeout,
            extra_client_methods=extra_client_methods,
            frame_cap=frame_cap or DEFAULT_FRAME_CAP,
        )
        config.validate()
        registry = DeviceRegistry(config.db_path)
        audit = AuditLog(keep=2000)
        app = create_app(config, registry=registry, audit=audit)
        server = LiveBridge(app, config, audit).start()
        servers.append((server, registry))
        return server

    try:
        yield make
    finally:
        for server, registry in servers:
            server.stop()
            registry.close()


@pytest.fixture
def bridge(bridge_factory) -> LiveBridge:
    return bridge_factory()
