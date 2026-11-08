from __future__ import annotations

import hashlib
import time

from hermes_bridge.tickets import AttemptThrottle, PairingCodes, TicketStore


class Clock:
    def __init__(self, now: float = 1000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def test_ticket_is_single_use():
    store = TicketStore(ttl=30, clock=Clock())
    ticket = store.mint("dev-1")
    assert store.redeem(ticket) == "dev-1"
    assert store.redeem(ticket) is None


def test_ticket_expires_after_30_seconds():
    clock = Clock()
    store = TicketStore(ttl=30, clock=clock)
    ticket = store.mint("dev-1")
    clock.advance(29.9)
    assert store.redeem(ticket) == "dev-1"

    fresh = store.mint("dev-1")
    clock.advance(30.1)
    assert store.redeem(fresh) is None


def test_ticket_is_bound_to_one_device():
    store = TicketStore(ttl=30)
    assert store.redeem(store.mint("device-a")) == "device-a"
    assert store.redeem(store.mint("device-b")) == "device-b"
    assert store.redeem("not-a-ticket") is None
    assert store.redeem("") is None


def test_tickets_are_not_stored_in_plaintext():
    store = TicketStore(ttl=30)
    ticket = store.mint("dev-1")
    assert ticket not in repr(store.__dict__)
    keys = list(store._tickets.keys())
    assert keys == [hashlib.sha256(ticket.encode()).hexdigest()]


def test_revoking_a_device_kills_its_pending_tickets():
    store = TicketStore(ttl=30)
    a = store.mint("device-a")
    store.mint("device-a")
    b = store.mint("device-b")
    assert store.revoke_device("device-a") == 2
    assert store.redeem(a) is None
    assert store.redeem(b) == "device-b"


def test_pending_tickets_are_capped():
    store = TicketStore(ttl=30, max_pending=2)
    first = store.mint("d")
    store.mint("d")
    third = store.mint("d")
    assert store.redeem(first) is None  # evicted oldest
    assert store.redeem(third) == "d"


def test_pairing_code_is_single_use_and_hashed():
    codes = PairingCodes(ttl=120, clock=Clock())
    code, expires = codes.mint()
    assert len(code) == 8 and code.isdigit()
    assert code not in repr(codes.__dict__)
    assert codes.redeem(code) is True
    assert codes.redeem(code) is False
    assert codes.redeem("00000000") is False


def test_pairing_code_expires():
    clock = Clock()
    codes = PairingCodes(ttl=120, clock=clock)
    code, _ = codes.mint()
    clock.advance(121)
    assert codes.redeem(code) is False


def test_pairing_codes_are_bounded():
    codes = PairingCodes(ttl=120, max_outstanding=4)
    minted = [codes.mint()[0] for _ in range(8)]
    assert len(codes) == 4
    # the four newest still redeem
    assert all(codes.redeem(code) for code in minted[-4:])


def test_claim_throttle_limits_attempts_per_window():
    clock = Clock(0.0)
    throttle = AttemptThrottle(limit=3, window=60, clock=clock)
    assert throttle.check("1.2.3.4") == (True, 0)
    assert throttle.check("1.2.3.4")[0] is True
    assert throttle.check("1.2.3.4")[0] is True
    allowed, retry = throttle.check("1.2.3.4")
    assert allowed is False and retry >= 1
    # a different source is unaffected
    assert throttle.check("5.6.7.8")[0] is True
    clock.advance(61)
    assert throttle.check("1.2.3.4")[0] is True


def test_real_clock_ticket_still_short_lived():
    store = TicketStore(ttl=30.0)
    assert store.ttl <= 30.0
    start = time.monotonic()
    ticket = store.mint("d")
    assert store.redeem(ticket) == "d"
    assert time.monotonic() - start < 1.0
