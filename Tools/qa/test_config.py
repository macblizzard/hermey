"""Configuration refuses to start in a shape that would be unsafe.

These are cheap, direct tests of the invariants the bridge promises at startup,
rather than of any request path.
"""

from __future__ import annotations

import pytest

from hermes_bridge.config import BridgeConfig, ConfigError


def test_the_bridge_refuses_a_non_loopback_bind():
    for host in ("0.0.0.0", "100.64.0.1", "hermes.example.ts.net", ""):
        with pytest.raises(ConfigError) as info:
            BridgeConfig(bind_host=host).validate()
        assert "loopback" in str(info.value).lower()


def test_the_bridge_refuses_a_remote_gateway():
    with pytest.raises(ConfigError) as info:
        BridgeConfig(gateway_url="ws://100.64.0.1:9119/api/ws").validate()
    assert "loopback" in str(info.value).lower()


def test_the_gateway_url_must_be_a_websocket_url_with_a_path():
    with pytest.raises(ConfigError):
        BridgeConfig(gateway_url="http://127.0.0.1:9119/api/ws").validate()
    with pytest.raises(ConfigError):
        BridgeConfig(gateway_url="ws://127.0.0.1:9119").validate()


def test_the_frame_cap_has_a_hard_ceiling():
    with pytest.raises(ConfigError):
        BridgeConfig(frame_cap=0).validate()
    with pytest.raises(ConfigError):
        BridgeConfig(frame_cap=64 * 1024 * 1024).validate()
    # The shipped default is 16 MiB (an 8 MiB attachment is ~10.7 MiB base64-encoded); a smaller
    # cap is allowed, which is how the QA harness pins 1 MiB to exercise the refusal path.
    assert BridgeConfig().validate() is None
    BridgeConfig(frame_cap=2 * 1024 * 1024).validate()


def test_the_upstream_url_carries_the_token_but_the_safe_form_does_not():
    config = BridgeConfig(
        gateway_url="ws://127.0.0.1:9119/api/ws?profile=assistant",
        gateway_token="super-secret",
    )
    upstream = config.upstream_url()
    assert "token=super-secret" in upstream
    assert "profile=assistant" in upstream
    safe = config.safe_gateway_url()
    assert "super-secret" not in safe
    assert "token=" not in safe
    # The safe form drops the whole query — anything else could carry the token.
    assert safe == "ws://127.0.0.1:9119/api/ws"


def test_a_token_already_in_the_url_is_replaced_not_duplicated():
    config = BridgeConfig(
        gateway_url="ws://127.0.0.1:9119/api/ws?token=stale",
        gateway_token="fresh",
    )
    upstream = config.upstream_url()
    assert "stale" not in upstream
    assert upstream.count("token=") == 1
    assert "token=fresh" in upstream


def test_extra_methods_are_validated():
    with pytest.raises(ValueError):
        from hermes_bridge.policy import build_client_allow_list

        build_client_allow_list(frozenset({"not a method"}))
