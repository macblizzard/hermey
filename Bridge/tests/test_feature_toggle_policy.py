"""Two narrow doors opened in the bridge, and everything still shut behind them.

The app may now (a) flip a bot's `disabled_skills` / `enabled_mcp_servers` and (b) read the skills hub's
*list* action. Both were deliberately host-only before. The point of these tests is that the doors stay
narrow: names only, no free text, no install, no extra keys.
"""
from __future__ import annotations

import asyncio
import json
from test_proxy import open_ws, recv_frame

import pytest

from hermes_bridge.policy import (MAX_FEATURE_NAMES, is_bot_model_configure_allowed,
                                  is_skills_manage_allowed)


class TestTheFeatureListsAreNamesOnly:
    def test_a_toggle_is_accepted(self) -> None:
        assert is_bot_model_configure_allowed(
            {"name": "cody", "disabled_skills": ["grill-me", "obsidian"]})
        assert is_bot_model_configure_allowed(
            {"name": "cody", "enabled_mcp_servers": ["context7", "composio"]})

    def test_one_item_is_enough(self) -> None:
        # The app always sends the whole set, but an empty list is a legal whole set.
        assert is_bot_model_configure_allowed({"name": "cody", "disabled_skills": []})

    @pytest.mark.parametrize("value", [
        ["../etc/passwd"],          # a path, not a name
        ["grill me"],               # a space is free text
        ["/bin/sh"],
        [123],
        "grill-me",                 # not a list at all
        {"grill-me": True},
        ["a" * 200],
    ])
    def test_anything_that_is_not_a_name_is_refused(self, value) -> None:
        assert not is_bot_model_configure_allowed({"name": "cody", "disabled_skills": value})

    def test_the_list_is_capped(self) -> None:
        too_many = [f"skill-{index}" for index in range(MAX_FEATURE_NAMES + 1)]
        assert not is_bot_model_configure_allowed({"name": "cody", "disabled_skills": too_many})
        just_enough = too_many[:-1]
        assert is_bot_model_configure_allowed({"name": "cody", "disabled_skills": just_enough})

    def test_unknown_sections_are_still_refused(self) -> None:
        # toolsets and ui_meta stay host-only: this door is two lists wide.
        assert not is_bot_model_configure_allowed({"name": "cody", "enabled_toolsets": ["shell"]})
        assert not is_bot_model_configure_allowed({"name": "cody", "ui_meta": {}})


class TestTheSkillsHubIsReadOnly:
    def test_listing_is_allowed(self) -> None:
        assert is_skills_manage_allowed({"action": "list"})
        assert is_skills_manage_allowed({})
        assert is_skills_manage_allowed({"action": "list", "profile": "cody"})

    @pytest.mark.parametrize("params", [
        {"action": "install", "name": "something"},
        {"action": "browse"},
        {"action": "inspect", "query": "x"},
        {"action": "list", "query": "anything"},
    ])
    def test_anything_that_writes_or_searches_is_refused(self, params) -> None:
        assert not is_skills_manage_allowed(params)


def test_the_bridge_refuses_an_install_from_a_device(bridge, fake_gateway):
    async def run():
        async with open_ws(bridge.ws_url(bridge.pair()["ticket"])) as ws:
            await recv_frame(ws)
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 900, "method": "skills.manage",
                                      "params": {"action": "install", "name": "whatever"}}))
            response = await recv_frame(ws)
            assert "error" in response, "an install from a phone must not reach the gateway"
            assert response["error"]["code"] == -32601
    asyncio.run(run())
    assert not any(frame.get("id") == 900 for frame in fake_gateway.received)


def test_the_bridge_forwards_a_list(bridge, fake_gateway):
    async def run():
        async with open_ws(bridge.ws_url(bridge.pair()["ticket"])) as ws:
            await recv_frame(ws)
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 901, "method": "skills.manage",
                                      "params": {"action": "list"}}))
            response = await recv_frame(ws)
            assert response["id"] == 901
    asyncio.run(run())
    assert fake_gateway.wait_for(lambda frame: frame.get("id") == 901)
