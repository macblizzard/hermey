"""The reaction round trip over the real routes, on a real service, with two devices.

`test_reaction_sync.py` reads the Rust and Swift sources; this file starts the built service
(`hermeyd/target/debug/hermeyd`, `cargo build --bin hermeyd`) in a throwaway home and drives it the
way the two apps do — pair, open the app socket, `PUT /v1/reactions`, `GET /v1/reactions` — so the
claim "a reaction made on one device appears on the other" is checked against a running host rather
than against a source file.

It skips (never fails) when it cannot run: no built binary, or no `websockets` package to hold the
two app sockets and the stub engine open. The `cargo test` case
`two_devices_agree_on_one_reaction_and_on_its_removal` covers the same ground at the handler level
and always runs.
"""
from __future__ import annotations

import asyncio
import json
import pathlib
import socket
import subprocess
import sys
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = ROOT / "hermeyd" / "target" / "debug" / "hermeyd"

BOT = "cody"
SESSION = "20261125_101500_ab12cd"

try:  # imported lazily by the test body; the module itself must stay importable without it
    import websockets  # noqa: F401
    HAVE_WEBSOCKETS = True
except Exception:  # pragma: no cover - the skip is the point
    HAVE_WEBSOCKETS = False


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for(url: str, timeout: float = 20.0) -> None:
    import urllib.request

    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as r:
                if r.status == 200:
                    return
        except Exception:
            time.sleep(0.1)
    raise AssertionError(f"{url} never answered")


@unittest.skipUnless(BINARY.is_file(), "hermeyd is not built (cargo build --bin hermeyd)")
@unittest.skipUnless(HAVE_WEBSOCKETS, "the websockets package is needed for the two app sockets")
class ReactionRouteLiveTests(unittest.TestCase):
    """One service, two paired devices, one message."""

    def setUp(self) -> None:
        import tempfile
        self.home = tempfile.mkdtemp(prefix="hermeyd-reactions-live-")
        self.port = free_port()
        self.engine_port = free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.stub = subprocess.Popen(
            [sys.executable, str(pathlib.Path(__file__).with_name("_stub_engine.py")),
             str(self.engine_port)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        env = {"HERMEYD_HOME": self.home, "HERMEYD_PORT": str(self.port),
               "HERMEYD_BIND": "127.0.0.1", "HERMEYD_BROWSER_PORT": str(free_port()),
               "HERMEYD_ENGINE_WS": f"ws://127.0.0.1:{self.engine_port}/api/ws",
               "PATH": "/usr/bin:/bin"}
        self.service = subprocess.Popen([str(BINARY)], env=env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(f"{self.base}/v1/health")

    def tearDown(self) -> None:
        for proc in (getattr(self, "service", None), getattr(self, "stub", None)):
            if proc and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
        import shutil
        shutil.rmtree(self.home, ignore_errors=True)

    # --- the two devices' verbs -------------------------------------------------------------

    def _post(self, path: str, body: dict) -> dict:
        import urllib.request
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())

    def _put(self, path: str, body: dict, token: str) -> dict:
        import urllib.request
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json",
                                              "Authorization": "Bearer " + token}, method="PUT")
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())

    def _get(self, path: str, token: str) -> dict:
        import urllib.request
        req = urllib.request.Request(self.base + path,
                                     headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())

    def _pair(self, name: str, platform: str) -> dict:
        code = self._post("/v1/pair/start", {})["code"]
        return self._post("/v1/pair/claim",
                          {"code": code, "device_name": name, "platform": platform,
                           "public_key": "k" * 44})

    def _ticket(self, device: dict) -> str:
        return self._post("/v1/token", {"device_id": device["device_id"],
                                        "refresh_token": device["refresh_token"]})["ws_ticket"]

    def test_a_reaction_made_on_the_mac_reaches_the_phone_and_a_clear_removes_it(self) -> None:
        mac = self._pair("Mo's Mac", "macos")
        phone = self._pair("iPhone", "ios")

        async def run() -> dict:
            import websockets
            heard: dict[str, list[str]] = {"mac": [], "phone": []}
            url = f"ws://127.0.0.1:{self.port}/v1/ws"
            async with websockets.connect(url + "?ticket=" + self._ticket(mac)) as mac_ws, \
                       websockets.connect(url + "?ticket=" + self._ticket(phone)) as phone_ws:
                async def drain(ws, sink) -> None:
                    try:
                        async for line in ws:
                            sink.append(line)
                    except Exception:
                        pass

                tasks = [asyncio.create_task(drain(mac_ws, heard["mac"])),
                         asyncio.create_task(drain(phone_ws, heard["phone"]))]
                await asyncio.sleep(1.5)  # both sockets attached before anything is written

                self._put("/v1/reactions",
                          {"bot": BOT, "session": SESSION, "message": "row:1",
                           "emoji": "👍", "by": "Mo's Mac"}, self._ticket(mac))
                await asyncio.sleep(1.0)
                on_phone = self._get(f"/v1/reactions?bot={BOT}&session={SESSION}",
                                     self._ticket(phone))

                self._put("/v1/reactions",
                          {"bot": BOT, "session": SESSION, "message": "row:1",
                           "emoji": "", "by": "iPhone"}, self._ticket(phone))
                await asyncio.sleep(1.0)
                after = self._get(f"/v1/reactions?bot={BOT}&session={SESSION}",
                                  self._ticket(mac))
                for task in tasks:
                    task.cancel()
                return {"heard": heard, "on_phone": on_phone, "after": after}

        out = asyncio.run(run())

        # The phone's read is the reaction the Mac made — this is the "open, and it is there" half.
        self.assertEqual(out["on_phone"], {"reactions": {"row:1": {"emoji": "👍", "by": "Mo's Mac"}}})
        # Both sockets heard the set and the clear without asking: the "live" half.
        for device in ("mac", "phone"):
            frames = [json.loads(line) for line in out["heard"][device]
                      if '"reaction.updated"' in line.replace(" ", "")]
            emoji = [f["params"]["payload"]["emoji"] for f in frames]
            self.assertEqual(emoji, ["👍", None], f"{device} frames: {frames}")
            self.assertTrue(all(f["params"]["payload"]["message"] == "row:1" for f in frames))
            self.assertTrue(all(f["params"]["session_id"] == SESSION for f in frames),
                            "the frame names the conversation it is about")
        # And the clear is gone for both.
        self.assertEqual(out["after"], {"reactions": {}})


if __name__ == "__main__":
    unittest.main()
