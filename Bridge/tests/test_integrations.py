"""Integrations route through a fake Composio, because the real one needs a key and a Google account.

What must hold regardless of Composio: the key never comes back in a response, an unknown service is a
404 rather than a guess, and a host with no key says so instead of offering a broken button.
"""

from __future__ import annotations

import json
import os
import pathlib
import threading
import unittest
from unittest import mock
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

from fastapi import FastAPI
from fastapi.testclient import TestClient

from hermes_bridge import composio as composio_module
from hermes_bridge.composio import ComposioClient, create_integrations_router

KEY = "comp_test_key_do_not_leak"


class FakeComposio(BaseHTTPRequestHandler):
    """Enough of the v3.1 surface for the three calls the bridge makes."""

    connected: dict[str, dict] = {}
    links: list[dict] = []
    created: list[str] = []
    has_configs: bool = True

    def log_message(self, fmt, *args):  # noqa: A003 - quieter than the default
        pass

    def _reply(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802
        url = urlparse(self.path)
        if self.headers.get("x-api-key") != KEY:
            self._reply(401, {"error": "bad key"})
            return
        if url.path.endswith("/auth_configs"):
            slug = parse_qs(url.query).get("toolkit_slug", [""])[0]
            items = ([] if not FakeComposio.has_configs else
                     [{"id": f"cfg_{slug}", "toolkit_slug": slug, "status": "ENABLED"}])
            self._reply(200, {"items": items})
            return
        if url.path.endswith("/connected_accounts"):
            slug = parse_qs(url.query).get("toolkit_slug", [""])[0]
            rows = [row for row in self.connected.values()
                    if not slug or row["toolkit_slug"] == slug]
            self._reply(200, {"items": rows})
            return
        self._reply(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        url = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.headers.get("x-api-key") != KEY:
            self._reply(401, {"error": "bad key"})
            return
        if url.path.endswith("/auth_configs"):
            slug = body.get("toolkit", {}).get("slug", "")
            FakeComposio.created.append(slug)
            self._reply(201, {"toolkit": {"slug": slug},
                              "auth_config": {"id": f"cfg_{slug}", "is_composio_managed": True}})
            return
        if url.path.endswith("/connected_accounts/link"):
            FakeComposio.links.append(body)
            self._reply(201, {"redirect_url": "https://composio.test/connect/abc123",
                              "connected_account_id": "ca_new"})
            return
        self._reply(404, {"error": "not found"})

    def do_DELETE(self) -> None:  # noqa: N802
        if self.headers.get("x-api-key") != KEY:
            self._reply(401, {"error": "bad key"})
            return
        account = self.path.rstrip("/").rsplit("/", 1)[-1]
        FakeComposio.connected = {k: v for k, v in FakeComposio.connected.items() if v["id"] != account}
        self._reply(200, {"ok": True})


class IntegrationsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = HTTPServer(("127.0.0.1", 0), FakeComposio)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.api = f"http://127.0.0.1:{cls.server.server_address[1]}/api/v3.1"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()

    def setUp(self) -> None:
        FakeComposio.connected = {}
        FakeComposio.links = []
        FakeComposio.created = []
        FakeComposio.has_configs = True
        self.client = ComposioClient(key=KEY, api=self.api)
        app = FastAPI()
        app.include_router(create_integrations_router(_FakeRuntime(), self.client))
        self.app = TestClient(app)

    def test_the_catalog_lists_every_service_with_its_state(self) -> None:
        FakeComposio.connected = {"g": {"id": "ca_1", "toolkit_slug": "gmail", "status": "ACTIVE"}}
        reply = self.app.get("/v1/integrations")
        assert reply.status_code == 200, reply.text
        body = reply.json()
        self.assertTrue(body["configured"])
        gmail = next(s for s in body["services"] if s["slug"] == "gmail")
        calendar = next(s for s in body["services"] if s["slug"] == "googlecalendar")
        self.assertTrue(gmail["connected"])
        self.assertEqual(gmail["account_id"], "ca_1")
        self.assertFalse(calendar["connected"])

    def test_connect_returns_a_hosted_link_and_never_the_key(self) -> None:
        reply = self.app.post("/v1/integrations/gmail/connect")
        assert reply.status_code == 200, reply.text
        self.assertEqual(reply.json()["url"], "https://composio.test/connect/abc123")
        self.assertNotIn(KEY, reply.text)
        self.assertTrue(FakeComposio.links[0]["user_id"], "a link must say whose account it is for")
        self.assertEqual(FakeComposio.links[0]["auth_config_id"], "cfg_gmail")

    def test_a_project_with_no_auth_config_gets_one_created(self) -> None:
        """A fresh Composio project has none, and Connect must still work without a dashboard visit."""
        FakeComposio.has_configs = False        # a project that has never connected this toolkit
        client = ComposioClient(key=KEY, api=self.api)
        self.assertEqual(client.connect_link("gmail"), "https://composio.test/connect/abc123")
        self.assertEqual(FakeComposio.created, ["gmail"], "the config should be created once")

    def test_an_existing_auth_config_is_reused(self) -> None:
        """Creating one per connect would litter the project."""
        client = ComposioClient(key=KEY, api=self.api)
        client.auth_config_id = lambda slug: "cfg_existing"  # the lookup finds one
        client.connect_link("gmail")
        self.assertEqual(FakeComposio.created, [])

    def test_an_unknown_service_is_a_404_not_a_guess(self) -> None:
        self.assertEqual(self.app.post("/v1/integrations/outlook/connect").status_code, 404)

    def test_without_a_key_it_says_so_instead_of_offering_a_button(self) -> None:
        # Isolate from whatever key this machine happens to export: the point is a host with none.
        env = {k: v for k, v in os.environ.items() if k != "COMPOSIO_API_KEY"}
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        no_file = mock.patch.object(composio_module, "KEY_FILE", pathlib.Path("/nonexistent/key"))
        no_file.start()
        self.addCleanup(no_file.stop)
        app = FastAPI()
        app.include_router(create_integrations_router(_FakeRuntime(), ComposioClient(key=None, api=self.api)))
        anonymous = TestClient(app)
        listing = anonymous.get("/v1/integrations").json()
        self.assertFalse(listing["configured"])
        self.assertTrue(all(not s["available"] for s in listing["services"]),
                        "with no key nothing may look connectable")
        failed = anonymous.post("/v1/integrations/gmail/connect")
        self.assertEqual(failed.status_code, 409)
        self.assertIn("no Composio key", failed.json()["detail"])

    def test_disconnect_revokes_the_connected_account(self) -> None:
        FakeComposio.connected = {"g": {"id": "ca_1", "toolkit_slug": "gmail", "status": "ACTIVE"}}
        reply = self.app.post("/v1/integrations/gmail/disconnect")
        assert reply.status_code == 200, reply.text
        self.assertEqual(reply.json()["state"], "revoked")
        self.assertEqual(FakeComposio.connected, {})

    def test_disconnecting_something_not_connected_is_not_an_error(self) -> None:
        reply = self.app.post("/v1/integrations/gmail/disconnect")
        self.assertEqual(reply.status_code, 200)
        self.assertEqual(reply.json()["state"], "not connected")

    def test_a_key_in_the_environment_is_used_when_none_is_passed(self) -> None:
        with mock.patch.dict("os.environ", {"COMPOSIO_API_KEY": KEY}):
            self.assertTrue(ComposioClient(api=self.api).configured)


class _FakeRuntime:
    """Only the audit sink the router touches."""

    class audit:  # noqa: N801 - mirrors the real runtime's attribute
        @staticmethod
        def emit(*args, **kwargs) -> None:
            return None

