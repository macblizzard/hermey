"""A long conversation must open on a phone.

The bug these tests pin down: `session.resume` answers with the whole transcript in ONE frame
(cody's bot chat measured 1450 rows / 3.4 MB), and iOS refuses to deliver a message that size —
"could not open the conversation: … Message too long" — then every reconnect retries it. So the
bridge ships the newest page and serves older pages from its own copy of that resume.
"""

from __future__ import annotations

import asyncio
import json

import websockets
from hermes_bridge.history_paging import HistoryCache, encoded_size, plan_before, plan_newest

from bridge_test_support import GATEWAY_TOKEN  # noqa: F401  (fixtures import it)

SESSION = "20261109_213600_47cc65"
PROFILE = "cody"


def messages(count: int, size: int = 200) -> list[dict]:
    return [
        {"role": "user" if index % 2 == 0 else "assistant",
         "text": f"{index:05d}" + "x" * size,
         "row_id": 1000 + index}
        for index in range(count)
    ]


# ── planning ─────────────────────────────────────────────────────────────


def test_newest_page_keeps_the_tail_and_points_at_its_offset():
    rows = messages(50)
    page, cursor = plan_newest(rows, max_messages=10, max_bytes=10**9)
    assert page == rows[-10:]
    assert cursor == 40


def test_newest_page_reports_no_cursor_when_it_holds_everything():
    rows = messages(5)
    page, cursor = plan_newest(rows, max_messages=100, max_bytes=10**9)
    assert page == rows
    assert cursor is None


def test_newest_page_honours_the_byte_ceiling_but_never_ships_nothing():
    rows = messages(10)
    one = encoded_size(rows[0])
    page, cursor = plan_newest(rows, max_messages=100, max_bytes=one * 3)
    assert len(page) <= 3 and page == rows[-len(page):]
    assert cursor == 10 - len(page)
    # A single row bigger than the whole ceiling still ships: an empty resume looks like a lost
    # conversation, which is the failure this module exists to prevent.
    page, cursor = plan_newest(rows, max_messages=100, max_bytes=1)
    assert len(page) == 1 and page == rows[-1:] and cursor == 9


def test_older_pages_walk_backwards_without_gaps_or_overlap():
    rows = messages(30)
    page, cursor = plan_newest(rows, max_messages=10, max_bytes=10**9)
    collected = list(page)
    while cursor:
        page, cursor = plan_before(rows, cursor, limit=10, max_bytes=10**9)
        collected = list(page) + collected
    assert collected == rows


def test_first_page_has_no_older_rows():
    page, cursor = plan_before(messages(10), 0, limit=5)
    assert page == [] and cursor is None


def test_older_page_is_contiguous_and_bounded():
    rows = messages(100)
    page, cursor = plan_before(rows, 100, limit=7)
    assert page == rows[93:100]
    assert cursor == 93


# ── cache ────────────────────────────────────────────────────────────────


def test_cache_is_bounded_and_evicts_the_least_recently_used():
    cache = HistoryCache(max_bytes=encoded_size({"text": "x" * 400}) * 2)
    cache.remember(("a", ""), [{"text": "x" * 400}])
    cache.remember(("b", ""), [{"text": "y" * 400}])
    assert cache.get(("a", "")) is not None
    cache.remember(("c", ""), [{"text": "z" * 400}])
    assert cache.get(("b", "")) is None
    assert cache.get(("a", "")) is not None
    assert cache.get(("c", "")) is not None


def test_cache_keys_separate_bots_that_share_a_session_id():
    cache = HistoryCache(max_bytes=10**6)
    cache.remember(HistoryCache.key(SESSION, "cody"), [{"text": "cody"}])
    assert cache.get(HistoryCache.key(SESSION, "atlas")) is None
    assert cache.get(HistoryCache.key(SESSION, "cody")) == [{"text": "cody"}]


# ── relay ────────────────────────────────────────────────────────────────


def _resume_reply(request_id: object, rows: list[dict]) -> dict:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": {
            "session_id": "rt-1",
            "session_key": SESSION,
            "messages": rows,
            "message_count": len(rows),
            "status": "idle",
            "running": False,
            "info": {},
            "resumed": True,
        },
    }


def test_resume_ships_its_newest_page_and_history_pages_are_served_locally(bridge, fake_gateway):
    """The frame the app receives is bounded, and 'load earlier' never reaches the gateway."""
    rows = messages(400, size=400)
    ticket = bridge.pair()["ticket"]
    fake_gateway.auto_respond = False

    async def scenario():
        async with websockets.connect(bridge.ws_url(ticket), proxy=None, max_size=None,
                                      open_timeout=5) as ws:
            ready = json.loads(await asyncio.wait_for(ws.recv(), 5))
            assert ready["method"] == "event"

            await ws.send(json.dumps({
                "jsonrpc": "2.0", "id": 1, "method": "session.resume",
                "params": {"session_id": SESSION, "profile": PROFILE},
            }))
            forwarded = fake_gateway.wait_for(lambda f: f.get("method") == "session.resume")
            fake_gateway.push(_resume_reply(forwarded["id"], rows))
            reply = json.loads(await asyncio.wait_for(ws.recv(), 10))

            result = reply["result"]
            assert reply["id"] == 1
            assert len(result["messages"]) < len(rows), "the whole transcript was relayed"
            assert result["messages"] == rows[-len(result["messages"]):]
            history = result["history"]
            assert history["total"] == len(rows)
            assert history["shown"] == len(result["messages"])
            assert history["cursor"] == len(rows) - len(result["messages"])

            # Ask for the rows before the page the resume shipped.
            await ws.send(json.dumps({
                "jsonrpc": "2.0", "id": 2, "method": "session.history",
                "params": {"session_id": SESSION, "profile": PROFILE,
                           "cursor": history["cursor"], "limit": 50},
            }))
            page = json.loads(await asyncio.wait_for(ws.recv(), 10))
            assert page["id"] == 2
            assert page["result"]["messages"] == rows[history["cursor"] - 50:history["cursor"]]
            assert page["result"]["cursor"] == history["cursor"] - 50
            assert page["result"]["total"] == len(rows)

            # Nothing was forwarded upstream: the gateway's session.history is the MODEL history,
            # which is not the transcript the app is scrolling.
            assert not [f for f in fake_gateway.received if f.get("method") == "session.history"]

    asyncio.run(scenario())


def test_history_page_without_a_cached_resume_is_refused_not_forwarded(bridge, fake_gateway):
    ticket = bridge.pair()["ticket"]
    fake_gateway.auto_respond = False

    async def scenario():
        async with websockets.connect(bridge.ws_url(ticket), proxy=None, max_size=None,
                                      open_timeout=5) as ws:
            await asyncio.wait_for(ws.recv(), 5)  # gateway.ready
            await ws.send(json.dumps({
                "jsonrpc": "2.0", "id": 9, "method": "session.history",
                "params": {"session_id": "never-resumed", "profile": PROFILE, "cursor": 10},
            }))
            reply = json.loads(await asyncio.wait_for(ws.recv(), 10))
            assert reply["id"] == 9
            assert reply["error"]["code"] == -32001
            assert not [f for f in fake_gateway.received if f.get("method") == "session.history"]

    asyncio.run(scenario())


def test_a_cursorless_history_call_still_reaches_the_gateway(bridge, fake_gateway):
    """The app's existing `history(limit:)` callers keep their old behaviour."""
    ticket = bridge.pair()["ticket"]
    fake_gateway.auto_respond = False

    async def scenario():
        async with websockets.connect(bridge.ws_url(ticket), proxy=None, max_size=None,
                                      open_timeout=5) as ws:
            await asyncio.wait_for(ws.recv(), 5)
            await ws.send(json.dumps({
                "jsonrpc": "2.0", "id": 4, "method": "session.history",
                "params": {"session_id": SESSION},
            }))
            sent = fake_gateway.wait_for(lambda f: f.get("method") == "session.history")
            fake_gateway.push({"jsonrpc": "2.0", "id": sent["id"],
                               "result": {"messages": [], "count": 0}})
            reply = json.loads(await asyncio.wait_for(ws.recv(), 10))
            assert reply["id"] == 4 and reply["result"]["count"] == 0

    asyncio.run(scenario())
