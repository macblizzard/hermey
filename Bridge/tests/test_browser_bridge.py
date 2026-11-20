"""A fill target is a browser that said hello, and only it may leave.

The registry decides whether a login can reach a page. Two failures it must not have:

* a reconnect evicting its own replacement (the bug that made the computer-use socket churn for
  weeks — an old handler removing a new registration by id alone);
* a fill that waits for a browser which has gone, instead of answering "could not fill".
"""

from __future__ import annotations

import asyncio

from hermes_bridge.browser_bridge import BrowserRegistry


class FakeSocket:
    """Enough of a websocket to record what the bridge sent."""

    def __init__(self) -> None:
        self.sent: list[dict] = []

    async def send_json(self, payload: dict) -> None:
        self.sent.append(payload)


class TestOnlyTheOwnerMayLeave:
    def test_an_old_socket_cannot_evict_its_replacement(self) -> None:
        registry = BrowserRegistry()
        old, new = FakeSocket(), FakeSocket()
        first = registry.register("bot screen", old)
        registry.browsers.pop(first.id)                      # a reconnect replaces the entry
        second = registry.register("bot screen", new)
        registry.unregister(second.id, old)                  # the old handler wakes up late
        assert second.id in registry.browsers, "the new registration must survive"

    def test_leaving_fails_a_pending_fill(self) -> None:
        registry = BrowserRegistry()
        socket = FakeSocket()
        browser = registry.register("bot screen", socket)

        async def scenario() -> bool:
            task = asyncio.create_task(registry.fill({"password": "x"}, site="example.test"))
            await asyncio.sleep(0)                            # let fill register its future
            registry.unregister(browser.id, socket)
            return await task

        assert asyncio.run(scenario()) is False, "a fill must not hang on a browser that left"


class TestAFill:
    def test_without_a_browser_it_is_false_not_an_error(self) -> None:
        registry = BrowserRegistry()
        assert asyncio.run(registry.fill({"password": "x"}, site="example.test")) is False

    def test_the_values_are_sent_and_the_answer_is_read_back(self) -> None:
        registry = BrowserRegistry()
        socket = FakeSocket()
        browser = registry.register("bot screen", socket)

        async def scenario() -> bool:
            task = asyncio.create_task(registry.fill({"password": "hunter2"}, site="example.test"))
            await asyncio.sleep(0)
            sent = socket.sent[0]
            assert sent["type"] == "fill"
            assert sent["site"] == "example.test"
            assert sent["fields"] == [{"name": "password", "value": "hunter2"}]
            registry.on_message(browser.id, {"id": sent["id"], "ok": True})
            return await task

        assert asyncio.run(scenario()) is True

    def test_a_refused_fill_is_false(self) -> None:
        registry = BrowserRegistry()
        socket = FakeSocket()
        browser = registry.register("bot screen", socket)

        async def scenario() -> bool:
            task = asyncio.create_task(registry.fill({"password": "x"}, site="example.test"))
            await asyncio.sleep(0)
            registry.on_message(browser.id, {"id": socket.sent[0]["id"], "ok": False})
            return await task

        assert asyncio.run(scenario()) is False

    def test_a_message_for_an_unknown_call_is_ignored(self) -> None:
        registry = BrowserRegistry()
        browser = registry.register("bot screen", FakeSocket())
        registry.on_message(browser.id, {"id": "not-a-call", "ok": True})  # must not raise
