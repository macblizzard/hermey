"""Helpers shared by the QA tests.

Why this file exists: `conftest.py` cannot be imported by name when two test directories are
collected in one pytest run (both this suite and `Bridge/tests` have a `conftest.py`). Four test
modules here did `from conftest import run, scenario_path`, which resolves to whichever conftest
pytest registered last. These helpers live under a unique module name instead.
"""

from __future__ import annotations

import asyncio
from pathlib import Path

QA_DIR = Path(__file__).resolve().parent
ROOT = QA_DIR.parents[1]


def run(coro, *, timeout: float = 60.0):
    """Run one coroutine to completion with a hard ceiling.

    No pytest-asyncio: one fresh loop per call keeps teardown predictable, and every fixture in
    this suite binds to loopback sockets that must not outlive the test.
    """

    async def _wrapper():
        return await asyncio.wait_for(coro, timeout)

    return asyncio.run(_wrapper())


def scenario_path(name: str) -> Path:
    path = QA_DIR / "scenarios" / name
    assert path.is_file(), f"missing scenario {path}"
    return path
