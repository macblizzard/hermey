"""Login cards: the owner types a secret into the app, the bot never receives it.

Design: ``docs/CREDENTIALS.md``. The shape here is deliberately tiny, because the security claim is
not in the code volume — it is in two properties that have to hold on every path:

1. A value entered in a card goes to a **deliverer** (the thing that fills the field) and nowhere
   else. No route, no response, no log line and no audit event ever carries it.
2. A card is single use and short-lived, and a bot can only ever learn *which* option was chosen and
   whether the fill worked.

The deliverer is injected rather than implemented here: on this host it types into the bot screen's
browser, in tests it records what it was handed. That keeps the "never returns the value" rule visible
in one place instead of spread across callers.
"""

from __future__ import annotations

import secrets
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel, Field

#: How long a card stays valid. Short on purpose: it is a prompt, not a session.
DEFAULT_TTL_SECONDS = 120

#: Card kinds, matching the three in the design doc.
CHOICE = "choice"
SECRET = "secret"
CONFIRM = "confirm"
KINDS = (CHOICE, SECRET, CONFIRM)


@dataclass
class Card:
    id: str
    kind: str
    site: str
    fields: list[str]
    note: str
    options: list[str]
    expires_at: float
    asked_by: str
    state: str = "open"          # open | answered | consumed | expired | cancelled
    answered_at: Optional[float] = None
    # Held in memory only, cleared the moment it is consumed. Never serialised anywhere.
    _values: dict[str, str] = field(default_factory=dict, repr=False)

    def public(self) -> dict[str, Any]:
        """What the app is shown. Never includes a value."""
        return {"id": self.id, "kind": self.kind, "site": self.site, "fields": self.fields,
                "options": self.options, "note": self.note, "asked_by": self.asked_by,
                "state": self.state, "expires_at": self.expires_at}

    def expired(self, now: Optional[float] = None) -> bool:
        return (now or time.time()) >= self.expires_at


class CardStore:
    """Open cards, keyed by an unguessable id.

    In memory by design: a card that outlives a restart is a card that can be answered after the page
    it belonged to is gone, which is exactly the confusion the design forbids.
    """

    def __init__(self, ttl: float = DEFAULT_TTL_SECONDS) -> None:
        self.ttl = ttl
        self.cards: dict[str, Card] = {}

    def create(self, *, kind: str, site: str, fields: list[str], note: str, options: list[str],
               asked_by: str, ttl: float | None = None) -> Card:
        if kind not in KINDS:
            raise ValueError(f"unknown card kind {kind!r}")
        life = self.ttl if ttl is None else max(30.0, min(float(ttl), 900.0))
        card = Card(id=secrets.token_urlsafe(18), kind=kind, site=site, fields=fields, note=note,
                    options=options, expires_at=time.time() + life, asked_by=asked_by)
        self.cards[card.id] = card
        return card

    def get(self, card_id: str) -> Card:
        card = self.cards.get(card_id)
        if card is None:
            raise KeyError(card_id)
        if card.state == "open" and card.expired():
            card.state = "expired"
        return card

    def sweep(self) -> list[Card]:
        """Retire everything that died of old age, so the store cannot grow without bound."""
        gone = [c for c in self.cards.values() if c.state in {"consumed", "expired", "cancelled"}]
        for card in gone:
            self.cards.pop(card.id, None)
        for card in self.cards.values():
            if card.state == "open" and card.expired():
                card.state = "expired"
        return gone

    def answer(self, card_id: str, values: dict[str, str]) -> Card:
        card = self.get(card_id)
        if card.state != "open":
            raise ValueError(f"card is {card.state}")
        card._values = dict(values)
        card.state = "answered"
        card.answered_at = time.time()
        return card

    def cancel(self, card_id: str) -> Card:
        card = self.get(card_id)
        if card.state == "open":
            card.state = "cancelled"
        return card

    def consume(self, card_id: str, only: list[str] | None = None) -> dict[str, str]:
        """Hand the values to the caller exactly once, then forget them.

        ``only`` takes a slice for a multi-step login: a page that asks for the email, then the password,
        then a code cannot receive all three at once, and asking the owner three times is the cost this
        avoids. Each slice is removed as it is delivered, so nothing is handed out twice.
        """
        card = self.get(card_id)
        if card.state != "answered":
            raise ValueError(f"card is {card.state}, not answered")
        if only:
            wanted = {str(name) for name in only}
            picked = {k: v for k, v in card._values.items() if k in wanted}
            for key in picked:
                card._values.pop(key, None)
            if not picked:
                raise ValueError("none of those fields are on this card")
            if not card._values:
                card.state = "consumed"
            return picked
        values = card._values
        card._values = {}
        card.state = "consumed"
        return values


class CardRequest(BaseModel):
    kind: str = Field(description="choice | secret | confirm")
    site: str = Field(description="the origin the bot is on, e.g. doctolib.de")
    fields: list[str] = Field(default_factory=list)
    options: list[str] = Field(default_factory=list)
    note: str = ""
    bot: str = "cody"
    #: Seconds this card stays answerable. A login in progress needs longer than a glance: the owner may be
    #: mid-task, and a two-minute window closed under them twice while testing.
    ttl: float | None = None


class CardAnswer(BaseModel):
    values: dict[str, str] = Field(default_factory=dict)


def create_credentials_router(runtime, store: CardStore,
                              deliver: Callable[[Card, dict[str, str]], bool]) -> APIRouter:
    """The four routes a card needs.

    ``deliver(card, values) -> bool`` performs the fill and is the only place a value is used. It is
    given the values directly — never through a response — so a caller cannot read them back.
    """
    router = APIRouter(prefix="/v1/credentials", tags=["credentials"])

    def authorize(request: Request, authorization: str | None) -> str:
        from .local_computers import is_local_host_request
        from .device_auth import require_device
        if is_local_host_request(request):
            return "host"
        return require_device(runtime, authorization)

    @router.post("/cards")
    def ask(body: CardRequest, request: Request,
            authorization: str | None = Header(default=None)) -> dict:
        """A bot asks for a card. Returns an id and nothing else — no values exist yet."""
        asked_by = authorize(request, authorization)
        store.sweep()
        card = store.create(kind=body.kind, site=body.site, fields=body.fields,
                            note=body.note, options=body.options, asked_by=asked_by,
                            ttl=body.ttl)
        # The audit record carries the site (a safe token) and the kind, never a value.
        runtime.audit.emit("credentials.requested", method=f"credentials.{body.kind}",
                           reason=body.site, path=f"/v1/credentials/cards/{card.id}",
                           outcome="open", profile=body.bot)
        return {"id": card.id, "expires_at": card.expires_at}

    @router.get("/cards")
    def pending(request: Request, authorization: str | None = Header(default=None)) -> dict:
        """Every card still waiting for the owner. What the app polls to know there is something to show.

        A list rather than a push: the app already talks to several hosts, and a poll every couple of
        seconds costs nothing while a card lives for two minutes.
        """
        authorize(request, authorization)
        store.sweep()
        live = [c.public() for c in store.cards.values() if c.state == "open"]
        return {"cards": live}

    @router.get("/cards/{card_id}")
    def read(card_id: str, request: Request,
             authorization: str | None = Header(default=None)) -> dict:
        """What the app renders. Never a value, in any state."""
        authorize(request, authorization)
        try:
            return store.get(card_id).public()
        except KeyError:
            raise HTTPException(status_code=404, detail="no such card") from None

    @router.post("/cards/{card_id}/answer")
    def answer(card_id: str, body: CardAnswer, request: Request,
               authorization: str | None = Header(default=None)) -> dict:
        """The owner typed something. The response says only that it was accepted."""
        authorize(request, authorization)
        try:
            card = store.answer(card_id, body.values)
        except KeyError:
            raise HTTPException(status_code=404, detail="no such card") from None
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from None
        runtime.audit.emit("credentials.answered", method=f"credentials.{card.kind}",
                           reason=card.site, path=f"/v1/credentials/cards/{card_id}",
                           outcome="answered")
        return {"ok": True, "state": card.state}

    @router.post("/cards/{card_id}/consume")
    def consume(card_id: str, request: Request,
                body: dict | None = None,
                authorization: str | None = Header(default=None)) -> dict:
        """The bot says "fill it now". It is told whether that worked, never what was in it.

        A body of {"only": ["password"]} delivers one slice of a multi-field card, which is how a login that
        asks for the email and then the password is answered once instead of twice.
        """
        authorize(request, authorization)
        only = None
        if isinstance(body, dict) and isinstance(body.get("only"), list):
            only = [str(name) for name in body["only"]]
        try:
            card = store.get(card_id)
            values = store.consume(card_id, only)
        except KeyError:
            raise HTTPException(status_code=404, detail="no such card") from None
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from None
        try:
            filled = deliver(card, values)
        finally:
            values.clear()
        runtime.audit.emit("credentials.consumed", method=f"credentials.{card.kind}",
                           reason=card.site, path=f"/v1/credentials/cards/{card_id}",
                           outcome="filled" if filled else "not_filled")
        # The card is already spent (its values are gone), but it stays in the store until the next
        # request sweeps it: a retry then hears "already used" instead of "no such card", which is the
        # difference between a bug and a bot that double-clicked.
        return {"ok": bool(filled), "state": card.state}

    @router.post("/cards/{card_id}/cancel")
    def cancel(card_id: str, request: Request,
               authorization: str | None = Header(default=None)) -> dict:
        authorize(request, authorization)
        try:
            card = store.cancel(card_id)
        except KeyError:
            raise HTTPException(status_code=404, detail="no such card") from None
        runtime.audit.emit("credentials.cancelled", method=f"credentials.{card.kind}",
                           reason=card.site, path=f"/v1/credentials/cards/{card_id}",
                           outcome=card.state)
        return {"ok": True, "state": card.state}

    return router
