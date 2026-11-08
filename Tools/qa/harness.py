"""Boot the real bridge on loopback and drive it against a replay server.

Tests need four things the Bridge package does not expose by itself:

* an app instance listening on a *real* socket — so ``request.client.host`` is
  ``127.0.0.1`` (pairing codes are minted for a direct loopback caller only) and
  a refused WebSocket upgrade is an HTTP/close event the client can observe,
  not a TestClient artifact;
* ``HERMES_BRIDGE_GATEWAY_URL`` pointed at the replay server instead of the live
  Hermes on :9119;
* ``HERMES_BRIDGE_DB`` pointed at a throwaway SQLite file per test, so the suite
  never touches ``~/.local/state/hermes-bridge/bridge.db``;
* the in-memory ``AuditLog`` mirror, to assert what the bridge did and did not
  record.

Everything is loopback and ephemeral (port 0, temp dir). No tailnet, no real
gateway, no state outside the test's temp directory.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote

import httpx
import uvicorn

ROOT = Path(__file__).resolve().parents[2]
QA_DIR = Path(__file__).resolve().parent


def ensure_import_paths() -> None:
    for path in (str(ROOT), str(ROOT / "Bridge"), str(QA_DIR)):
        if path not in sys.path:
            sys.path.insert(0, path)


ensure_import_paths()

#: The gateway path the bridge dials. Any path works for the replay server; this
#: is the one Hermes uses, so it is the one we exercise.
GATEWAY_PATH = "/api/ws"


class RunningApp:
    """Run a FastAPI app under uvicorn in a daemon thread, on an ephemeral port."""

    def __init__(self, app, *, host: str = "127.0.0.1", name: str = "app") -> None:
        self.app = app
        self.host = host
        self.name = name
        self.port: int | None = None
        self._server: uvicorn.Server | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> "RunningApp":
        config = uvicorn.Config(
            self.app,
            host=self.host,
            port=0,
            log_level="warning",
            access_log=False,
        )
        self._server = uvicorn.Server(config)
        # uvicorn installs SIGINT/SIGTERM handlers, which only works on the main
        # thread; this daemon thread must not try.
        self._server.install_signal_handlers = lambda: None  # type: ignore[method-assign]
        self._thread = threading.Thread(target=self._server.run, name=f"qa-{self.name}", daemon=True)
        self._thread.start()

        deadline = time.time() + 20
        while time.time() < deadline:
            if self._server.started:
                break
            if self._thread is not None and not self._thread.is_alive():
                raise RuntimeError(f"{self.name} died during startup")
            time.sleep(0.01)
        else:
            raise RuntimeError(f"{self.name} did not start within 20 s")

        for server in self._server.servers:
            for sock in server.sockets:
                self.port = sock.getsockname()[1]
                break
        if self.port is None:
            raise RuntimeError(f"{self.name} started without a listening socket")
        return self

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    @property
    def ws_base(self) -> str:
        return f"ws://{self.host}:{self.port}"

    def stop(self) -> None:
        if self._server is not None:
            self._server.should_exit = True
        if self._thread is not None:
            self._thread.join(timeout=10)
        self._thread = None
        self._server = None

    def __enter__(self) -> "RunningApp":
        return self.start()

    def __exit__(self, *exc: object) -> None:
        self.stop()


#: The frame cap the QA suite measures against. Kept here so a change to the production default
#: cannot silently make the "oversized frame is refused" tests vacuous.
FRAME_CAP_BYTES = 1 << 20


@dataclass
class Pairing:
    device_id: str
    refresh_token: str
    public_key: str
    raw: dict


@dataclass
class Ticket:
    ticket: str
    device_id: str
    raw: dict


class BridgeUnderTest:
    """The real ``hermes_bridge`` app, booted against a replay server."""

    def __init__(
        self,
        gateway_url: str,
        *,
        env: dict[str, str] | None = None,
        app_factory: Any = None,
    ) -> None:
        self.gateway_url = gateway_url
        self._app_factory = app_factory
        self._extra_env = dict(env or {})
        self._saved_env: dict[str, str | None] = {}
        self._tmpdir: str | None = None
        self._running: RunningApp | None = None
        self.app = None

    # -- lifecycle ----------------------------------------------------------
    def start(self) -> "BridgeUnderTest":
        if self._app_factory is None:
            from hermes_bridge.app import create_app  # noqa: PLC0415 - late import by design

            self._app_factory = create_app
        self._tmpdir = tempfile.mkdtemp(prefix="qa-bridge-")
        env = {
            "HERMES_BRIDGE_GATEWAY_URL": self.gateway_url,
            # The production default has to clear an 8 MiB attachment (~10.7 MiB of base64), which
            # makes it useless as a test of the refusal path: pin the cap the tests measure against
            # instead of inheriting whatever the app defaults to today.
            "HERMES_BRIDGE_FRAME_CAP": str(FRAME_CAP_BYTES),
            "HERMES_BRIDGE_DB": str(Path(self._tmpdir) / "bridge.db"),
            "HERMES_BRIDGE_GATEWAY_TOKEN": "",
            **self._extra_env,
        }
        self._saved_env = {key: os.environ.get(key) for key in env}
        for key, value in env.items():
            os.environ[key] = value
        self.app = self._app_factory()
        self._running = RunningApp(self.app, name="bridge").start()
        return self

    def stop(self) -> None:
        if self._running is not None:
            self._running.stop()
            self._running = None
        # Close the registry sqlite handle before deleting the file.
        runtime = getattr(self.app.state, "bridge", None) if self.app is not None else None
        if runtime is not None:
            try:
                runtime.registry.close()
            except Exception:  # noqa: BLE001 - already closed
                pass
        for key, value in self._saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        if self._tmpdir:
            shutil.rmtree(self._tmpdir, ignore_errors=True)
            self._tmpdir = None
        self.app = None

    def __enter__(self) -> "BridgeUnderTest":
        return self.start()

    def __exit__(self, *exc: object) -> None:
        self.stop()

    # -- shape --------------------------------------------------------------
    @property
    def port(self) -> int:
        assert self._running and self._running.port
        return self._running.port

    @property
    def base_url(self) -> str:
        assert self._running
        return self._running.base_url

    @property
    def http(self) -> httpx.Client:
        return httpx.Client(base_url=self.base_url, timeout=10.0)

    def route_paths(self) -> list[str]:
        assert self.app is not None
        return sorted({getattr(r, "path", "") for r in self.app.routes})

    @property
    def has_ws(self) -> bool:
        return "/v1/ws" in self.route_paths()

    @property
    def runtime(self):
        assert self.app is not None
        return self.app.state.bridge

    @property
    def audit(self):
        return self.runtime.audit

    @property
    def registry(self):
        return self.runtime.registry

    @property
    def db_path(self) -> Path:
        return Path(self.runtime.config.db_path)

    # -- protocol -----------------------------------------------------------
    @staticmethod
    def device_public_key() -> str:
        """44-char urlsafe base64 — the length of an Ed25519 SPKI key on the wire."""
        import base64
        import os as _os

        return base64.urlsafe_b64encode(_os.urandom(32)).decode()

    def pair(self, *, name: str = "qa-device", platform: str = "ios") -> Pairing:
        public_key = self.device_public_key()
        with self.http as client:
            start = client.post("/v1/pair/start")
            assert start.status_code == 200, f"pair/start: {start.status_code} {start.text}"
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
            assert claim.status_code == 200, f"pair/claim: {claim.status_code} {claim.text}"
            body = claim.json()
        return Pairing(
            device_id=body["device_id"],
            refresh_token=body["refresh_token"],
            public_key=public_key,
            raw=body,
        )

    def token(self, pairing: Pairing | None = None, *, device_id: str | None = None,
              refresh_token: str | None = None) -> httpx.Response:
        pairing = pairing or self.pair()
        with self.http as client:
            return client.post(
                "/v1/token",
                json={
                    "device_id": device_id or pairing.device_id,
                    "refresh_token": refresh_token or pairing.refresh_token,
                },
            )

    def mint_ticket(self, pairing: Pairing | None = None) -> Ticket:
        pairing = pairing or self.pair()
        response = self.token(pairing)
        assert response.status_code == 200, f"token: {response.status_code} {response.text}"
        body = response.json()
        return Ticket(ticket=body["ws_ticket"], device_id=pairing.device_id, raw=body)

    def ws_url(self, ticket: str) -> str:
        assert self._running
        return f"{self._running.ws_base}/v1/ws?ticket={quote(ticket, safe='')}"
