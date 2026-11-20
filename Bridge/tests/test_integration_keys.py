"""Cloudflare and Vercel connect with a key, not a sign-in page.

Composio has no managed OAuth app for either, so the owner pastes a key instead. What must hold: the service is
only offered when Composio actually knows it, the field list comes from Composio rather than being guessed
here, and the key never comes back in a response or an audit line.
"""

from __future__ import annotations

import unittest
from unittest import mock

from fastapi import FastAPI
from fastapi.testclient import TestClient

from hermes_bridge import composio as composio_module
from hermes_bridge.composio import CATALOG, KEY_TOOLKITS, ComposioClient, create_integrations_router


class StubClient:
    """Records what it is asked, and hands back shapes like Composio's."""

    def __init__(self) -> None:
        self.key_values: dict[str, str] | None = None
        self.key_fields_called: list[str] = []

    def connected_accounts(self, slug: str | None = None) -> list[dict]:
        return []

    def key_fields(self, slug: str) -> list[dict]:
        self.key_fields_called.append(slug)
        return [
            {"name": "generic_api_key", "label": "Cloudflare Global API Key", "required": True, "secret": True},
            {"name": "generic_id", "label": "Cloudflare Account Email", "required": True, "secret": False},
        ]

    def connect_with_key(self, slug: str, values: dict[str, str]) -> dict:
        self.key_values = values
        return {"account_id": "ca_keyed", "status": "ACTIVE"}


def _router(client) -> TestClient:
    runtime = mock.MagicMock()
    app = FastAPI()
    app.include_router(create_integrations_router(runtime, client=client))
    return TestClient(app)


class TestTheCatalogue(unittest.TestCase):
    def test_both_services_are_offered(self) -> None:
        slugs = {entry[0] for entry in CATALOG}
        self.assertIn("cloudflare", slugs)
        self.assertIn("vercel", slugs)

    def test_every_key_service_is_in_the_catalogue(self) -> None:
        """A slug in one list and not the other is a card nobody can reach, or a service nobody can connect."""
        slugs = {entry[0] for entry in CATALOG}
        self.assertTrue(KEY_TOOLKITS <= slugs, f"not in the catalogue: {KEY_TOOLKITS - slugs}")

    def test_only_the_key_services_are_marked_key_based(self) -> None:
        stub = StubClient()
        # A stub that answers the one call _one makes; the real type would need a live host.
        key_based = composio_module._one(stub, ("cloudflare", "Cloudflare", "DNS")).key_based  # type: ignore[arg-type]
        oauth = composio_module._one(stub, ("gmail", "Gmail", "Mail")).key_based  # type: ignore[arg-type]
        self.assertTrue(key_based)
        self.assertFalse(oauth)


class TestTheKeyRoutes(unittest.TestCase):
    def test_fields_come_from_composio(self) -> None:
        stub = StubClient()
        with mock.patch.object(composio_module, "user_id", return_value="owner"):
            reply = _router(stub).get("/v1/integrations/cloudflare/key-fields")
        self.assertEqual(reply.status_code, 200)
        fields = reply.json()["fields"]
        self.assertEqual([f["name"] for f in fields], ["generic_api_key", "generic_id"])
        self.assertEqual(stub.key_fields_called, ["cloudflare"])

    def test_fields_for_a_service_that_is_not_key_based_are_refused(self) -> None:
        with mock.patch.object(composio_module, "user_id", return_value="owner"):
            reply = _router(StubClient()).get("/v1/integrations/gmail/key-fields")
        self.assertEqual(reply.status_code, 400)

    def test_the_key_reaches_composio_and_never_comes_back(self) -> None:
        stub = StubClient()
        with mock.patch.object(composio_module, "user_id", return_value="owner"):
            reply = _router(stub).post("/v1/integrations/cloudflare/key-connect",
                                       json={"values": {"generic_api_key": "secret-key-value",
                                                        "generic_id": "me@example.com"}})
        self.assertEqual(reply.status_code, 200)
        assert stub.key_values is not None
        self.assertEqual(stub.key_values["generic_api_key"], "secret-key-value")
        body = reply.text
        self.assertNotIn("secret-key-value", body)
        self.assertEqual(reply.json()["account_id"], "ca_keyed")

    def test_empty_values_are_refused_before_composio(self) -> None:
        stub = StubClient()
        with mock.patch.object(composio_module, "user_id", return_value="owner"):
            reply = _router(stub).post("/v1/integrations/vercel/key-connect", json={"values": {"bearer_token": "  "}})
        self.assertEqual(reply.status_code, 422)
        self.assertIsNone(stub.key_values)

    def test_a_failure_does_not_echo_the_key(self) -> None:
        stub = StubClient()
        stub.connect_with_key = mock.Mock(side_effect=composio_module.ComposioError("Composio refused the request (401)"))
        with mock.patch.object(composio_module, "user_id", return_value="owner"):
            reply = _router(stub).post("/v1/integrations/vercel/key-connect",
                                       json={"values": {"bearer_token": "another-secret"}})
        self.assertEqual(reply.status_code, 502)
        self.assertNotIn("another-secret", reply.text)


class TestTheRealClientShape(unittest.TestCase):
    """The payloads that the API actually accepted, pinned so a refactor cannot quietly change them."""

    def test_auth_config_is_created_as_custom_api_key(self) -> None:
        client = ComposioClient(key="k", api="https://example.invalid")
        with mock.patch.object(client, "_request", side_effect=[{"items": []}, {"auth_config": {"id": "ac_1"}}]) as call:
            config = client.key_auth_config("cloudflare")
        self.assertEqual(config, "ac_1")
        body = call.call_args_list[1].args[2]
        self.assertEqual(body["toolkit"]["slug"], "cloudflare")
        self.assertEqual(body["auth_config"]["type"], "use_custom_auth")
        # Composio validates the camelCase name and rejects auth_scheme/"AuthScheme".
        self.assertEqual(body["auth_config"]["authScheme"], "API_KEY")
        self.assertEqual(body["auth_config"]["credentials"], {})

    def test_an_existing_api_key_config_is_reused(self) -> None:
        client = ComposioClient(key="k", api="https://example.invalid")
        rows = {"items": [{"id": "ac_existing", "toolkit_slug": "vercel", "auth_scheme": "API_KEY"}]}
        with mock.patch.object(client, "_request", return_value=rows) as call:
            self.assertEqual(client.key_auth_config("vercel"), "ac_existing")
        self.assertEqual(call.call_count, 1)

    def test_connect_sends_the_key_in_the_connection_state_and_nothing_else(self) -> None:
        client = ComposioClient(key="k", api="https://example.invalid")
        with mock.patch.object(client, "key_auth_config", return_value="ac_1"), \
                mock.patch.object(client, "_request", return_value={"id": "ca_9", "status": "ACTIVE"}) as call:
            result = client.connect_with_key("cloudflare", {"generic_api_key": "k", "generic_id": "e"})
        body = call.call_args.args[2]
        self.assertEqual(body["auth_config"], {"id": "ac_1"})
        self.assertEqual(body["connection"]["state"]["authScheme"], "API_KEY")
        self.assertEqual(body["connection"]["state"]["val"], {"generic_api_key": "k", "generic_id": "e"})
        self.assertEqual(result["account_id"], "ca_9")


if __name__ == "__main__":
    unittest.main()
