"""Login cards: the value goes to the fill, never to the bot.

Design: `docs/CREDENTIALS.md`. These tests are the contract's teeth. If one of them fails, the promise
"the bot never sees your password" is no longer true, so they matter more than the feature tests.
"""

from __future__ import annotations

import time

import httpx
import pytest

from hermes_bridge.credentials import CardStore

SECRET = "hunter2-not-a-real-password"
CODE = "913204"


def _request(bridge, method: str, path: str, body=None):
    """A bridge ticket is single use, so every request pairs first."""
    paired = bridge.pair()
    headers = {"Authorization": f"Bearer {bridge.mint_ticket(paired['device_id'])}"}
    return httpx.request(method, f"{bridge.base_url}{path}", json=body, headers=headers, timeout=10)


class TestTheStoreIsSingleUse:
    def test_a_card_expires(self) -> None:
        store = CardStore(ttl=0.05)
        card = store.create(kind="secret", site="example.test", fields=["password"], note="",
                            options=[], asked_by="host")
        time.sleep(0.1)
        assert store.get(card.id).state == "expired"

    def test_values_are_handed_over_exactly_once(self) -> None:
        store = CardStore()
        card = store.create(kind="secret", site="example.test", fields=["password"], note="",
                            options=[], asked_by="host")
        store.answer(card.id, {"password": SECRET})
        assert store.consume(card.id) == {"password": SECRET}
        with pytest.raises(ValueError):
            store.consume(card.id)

    def test_a_cancelled_card_cannot_be_filled(self) -> None:
        store = CardStore()
        card = store.create(kind="secret", site="example.test", fields=["password"], note="",
                            options=[], asked_by="host")
        store.cancel(card.id)
        with pytest.raises(ValueError):
            store.answer(card.id, {"password": SECRET})

    def test_the_public_view_never_carries_a_value(self) -> None:
        store = CardStore()
        card = store.create(kind="secret", site="example.test", fields=["password"], note="",
                            options=[], asked_by="host")
        store.answer(card.id, {"password": SECRET})
        assert SECRET not in str(card.public())

    def test_an_unknown_kind_is_refused(self) -> None:
        store = CardStore()
        with pytest.raises(ValueError):
            store.create(kind="vault", site="x", fields=[], note="", options=[], asked_by="host")


class TestTheRoutesNeverReturnIt:
    """Round trip through the real app: ask, answer, read back, consume."""

    def test_ask_read_answer_consume(self, bridge) -> None:
        asked = _request(bridge, "POST", "/v1/credentials/cards",
                         {"kind": "secret", "site": "example.test", "fields": ["password"],
                          "note": "sign in", "bot": "cody"})
        assert asked.status_code == 200, asked.text
        card_id = asked.json()["id"]
        assert "password" not in str(asked.json()), "no value exists at ask time"

        seen = _request(bridge, "GET", f"/v1/credentials/cards/{card_id}")
        assert seen.status_code == 200, seen.text
        assert seen.json()["site"] == "example.test"
        assert SECRET not in seen.text

        answered = _request(bridge, "POST", f"/v1/credentials/cards/{card_id}/answer",
                            {"values": {"password": SECRET}})
        assert answered.status_code == 200, answered.text
        assert SECRET not in answered.text, "the answer must not echo what was typed"

        after = _request(bridge, "GET", f"/v1/credentials/cards/{card_id}")
        assert after.json()["state"] == "answered"
        assert SECRET not in after.text

        consumed = _request(bridge, "POST", f"/v1/credentials/cards/{card_id}/consume")
        assert consumed.status_code == 200, consumed.text
        assert SECRET not in consumed.text, "the bot is told whether it filled, never what"

    def test_a_card_cannot_be_filled_twice(self, bridge) -> None:
        card_id = _request(bridge, "POST", "/v1/credentials/cards",
                           {"kind": "secret", "site": "example.test", "fields": ["password"]}
                           ).json()["id"]
        _request(bridge, "POST", f"/v1/credentials/cards/{card_id}/answer",
                 {"values": {"password": SECRET}})
        first = _request(bridge, "POST", f"/v1/credentials/cards/{card_id}/consume")
        second = _request(bridge, "POST", f"/v1/credentials/cards/{card_id}/consume")
        assert first.status_code == 200
        assert second.status_code == 409

    def test_an_unanswered_card_cannot_be_consumed(self, bridge) -> None:
        card_id = _request(bridge, "POST", "/v1/credentials/cards",
                           {"kind": "secret", "site": "example.test", "fields": ["password"]}
                           ).json()["id"]
        assert _request(bridge, "POST", f"/v1/credentials/cards/{card_id}/consume").status_code == 409

    def test_cancel_is_final(self, bridge) -> None:
        card_id = _request(bridge, "POST", "/v1/credentials/cards",
                           {"kind": "choice", "site": "example.test",
                            "options": ["Continue with Google", "Email and password"]}).json()["id"]
        assert _request(bridge, "POST", f"/v1/credentials/cards/{card_id}/cancel").status_code == 200
        assert _request(bridge, "POST", f"/v1/credentials/cards/{card_id}/answer",
                        {"values": {"choice": "Email and password"}}).status_code == 409

    def test_the_app_can_see_what_is_waiting(self, bridge) -> None:
        """What the Mac polls: open cards, and only open ones."""
        first = _request(bridge, "POST", "/v1/credentials/cards",
                         {"kind": "secret", "site": "one.test", "fields": ["password"]}).json()["id"]
        second = _request(bridge, "POST", "/v1/credentials/cards",
                          {"kind": "choice", "site": "two.test",
                           "options": ["Continue with Google"]}).json()["id"]
        _request(bridge, "POST", f"/v1/credentials/cards/{second}/cancel")

        listed = _request(bridge, "GET", "/v1/credentials/cards")
        assert listed.status_code == 200, listed.text
        ids = [card["id"] for card in listed.json()["cards"]]
        assert first in ids
        assert second not in ids, "a cancelled card is not waiting for anybody"
        assert SECRET not in listed.text

    def test_an_unknown_card_is_a_404(self, bridge) -> None:
        assert _request(bridge, "GET", "/v1/credentials/cards/not-a-card").status_code == 404

    def test_the_audit_event_exists_for_each_step(self, bridge) -> None:
        """An unregistered event raises inside the handler and surfaces as a 500."""
        card_id = _request(bridge, "POST", "/v1/credentials/cards",
                           {"kind": "secret", "site": "example.test", "fields": ["password"]}
                           ).json()["id"]
        assert _request(bridge, "POST", f"/v1/credentials/cards/{card_id}/answer",
                        {"values": {"password": SECRET}}).status_code == 200
        assert _request(bridge, "POST", f"/v1/credentials/cards/{card_id}/consume").status_code == 200
