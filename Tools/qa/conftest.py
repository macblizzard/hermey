"""Fixtures for the QA harness.

Run everything from the repo root:

    python -m pytest -q Tools/qa

The suite needs no services: each test boots a replay server (a scripted fake
Hermes gateway) and the real bridge, both on ephemeral loopback ports, with a
throwaway SQLite database.
"""

from __future__ import annotations

import asyncio
import sys
from dataclasses import dataclass
from pathlib import Path

import pytest

QA_DIR = Path(__file__).resolve().parent
ROOT = QA_DIR.parents[1]
for _path in (str(ROOT), str(ROOT / "Bridge"), str(QA_DIR)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

from harness import GATEWAY_PATH, BridgeUnderTest  # noqa: E402
from replay_server import ReplayServer  # noqa: E402
from qa_support import ROOT, QA_DIR, run, scenario_path  # noqa: F401


# --------------------------------------------------------------------------- #
# Async plumbing (no pytest-asyncio: one loop per call keeps teardown simple)
# --------------------------------------------------------------------------- #


def run(coro, *, timeout: float = 60.0):
    """Run one coroutine to completion, with a hard ceiling."""

    async def _wrapper():
        return await asyncio.wait_for(coro, timeout)

    return asyncio.run(_wrapper())


def scenario_path(name: str) -> Path:
    path = QA_DIR / "scenarios" / name
    assert path.is_file(), f"missing scenario {path}"
    return path


BRIDGE_WS_MISSING = (
    "the bridge does not expose /v1/ws; Bridge/hermes_bridge/proxy.py should be "
    "wired into app.py. See docs/QA.md."
)


@dataclass
class Relay:
    """The bridge under test plus the fake gateway behind it."""

    bridge: BridgeUnderTest
    gateway: ReplayServer
    scenario: str

    def mint_ticket(self, **kwargs):
        return self.bridge.mint_ticket(**kwargs)

    def ws_url(self, ticket: str) -> str:
        return self.bridge.ws_url(ticket)

    @property
    def audit(self):
        return self.bridge.audit

    @property
    def runtime(self):
        return self.bridge.runtime

    @property
    def db_path(self) -> Path:
        return self.bridge.db_path

    def connection(self, index: int = 0):
        return self.gateway.connection(index)

    def wait_for_gateway(self, count: int = 1, timeout: float = 10.0):
        return self.gateway.wait_for_connections(count, timeout=timeout)


# --------------------------------------------------------------------------- #
# Fixtures
# --------------------------------------------------------------------------- #


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return ROOT


@pytest.fixture()
def replay_factory():
    """Start replay servers; all of them are stopped at teardown."""
    started: list[ReplayServer] = []

    def make(script, **kwargs) -> ReplayServer:
        params = {"linger": 2.0}
        params.update(kwargs)
        server = ReplayServer(script, **params).start()
        started.append(server)
        return server

    yield make

    for server in started:
        server.stop()


@pytest.fixture()
def scenarios() -> Path:
    return QA_DIR / "scenarios"


@pytest.fixture()
def relay_factory(replay_factory):
    """``make(script) -> Relay``: a scripted gateway plus the real bridge in front."""
    started: list[BridgeUnderTest] = []

    def make(script, *, gateway_kwargs: dict | None = None, bridge_env: dict | None = None) -> Relay:
        gateway = replay_factory(script, **(gateway_kwargs or {}))
        bridge = BridgeUnderTest(
            f"{gateway.url}{GATEWAY_PATH}",
            env={
                "HERMES_BRIDGE_GATEWAY_URL": f"{gateway.url}{GATEWAY_PATH}",
                **(bridge_env or {}),
            },
        ).start()
        started.append(bridge)
        if not bridge.has_ws:
            pytest.skip(BRIDGE_WS_MISSING)
        name = Path(script).name if isinstance(script, (str, Path)) else "inline"
        return Relay(bridge=bridge, gateway=gateway, scenario=name)

    yield make

    for bridge in reversed(started):
        bridge.stop()


@pytest.fixture()
def bridge_factory():
    """A bridge with no scripted gateway — for HTTP-only tests."""
    started: list[BridgeUnderTest] = []

    def make(*, env: dict | None = None) -> BridgeUnderTest:
        bridge = BridgeUnderTest(
            "ws://127.0.0.1:9119/api/ws",  # never dialled by HTTP-only tests
            env=env or {},
        ).start()
        started.append(bridge)
        return bridge

    yield make

    for bridge in reversed(started):
        bridge.stop()
