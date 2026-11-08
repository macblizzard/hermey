from __future__ import annotations

import sqlite3

from hermes_bridge.registry import DeviceRegistry, hash_token


def make_registry(tmp_path) -> DeviceRegistry:
    return DeviceRegistry(tmp_path / "devices.db")


def test_device_survives_restart(tmp_path):
    reg = make_registry(tmp_path)
    reg.add_device(
        device_id="dev-1",
        name="iPhone",
        platform="ios",
        public_key="pk",
        refresh_token="refresh-me",
    )
    reg.close()

    reopened = make_registry(tmp_path)
    try:
        device = reopened.get("dev-1")
        assert device is not None
        assert device.name == "iPhone"
        assert device.revoked is False
        assert reopened.verify_refresh("dev-1", "refresh-me") is not None
    finally:
        reopened.close()


def test_only_the_hash_is_stored(tmp_path):
    reg = make_registry(tmp_path)
    try:
        reg.add_device(
            device_id="dev-2",
            name="Mac",
            platform="macos",
            public_key="pk",
            refresh_token="super-secret-refresh",
        )
        raw = (tmp_path / "devices.db").read_bytes()
        assert b"super-secret-refresh" not in raw

        with sqlite3.connect(tmp_path / "devices.db") as conn:
            stored = conn.execute(
                "SELECT refresh_token_hash FROM devices WHERE device_id = 'dev-2'"
            ).fetchone()[0]
        assert stored == hash_token("super-secret-refresh")
    finally:
        reg.close()


def test_revoke_persists_and_blocks_refresh(tmp_path):
    reg = make_registry(tmp_path)
    reg.add_device(
        device_id="dev-3",
        name="iPad",
        platform="ios",
        public_key="pk",
        refresh_token="r",
    )
    assert reg.revoke("dev-3") is True
    assert reg.is_active("dev-3") is False
    assert reg.verify_refresh("dev-3", "r") is None
    reg.close()

    reopened = make_registry(tmp_path)
    try:
        assert reopened.get("dev-3").revoked is True
        assert reopened.count_active() == 0
    finally:
        reopened.close()


def test_unknown_and_wrong_tokens_are_refused(tmp_path):
    reg = make_registry(tmp_path)
    try:
        assert reg.verify_refresh("nope", "x") is None
        reg.add_device(
            device_id="dev-4",
            name="d",
            platform="ios",
            public_key="pk",
            refresh_token="right",
        )
        assert reg.verify_refresh("dev-4", "wrong") is None
        assert reg.verify_refresh("dev-4", "right") is not None
        assert reg.revoke("unknown") is False
    finally:
        reg.close()


def test_rotate_refresh_invalidates_the_old_token(tmp_path):
    reg = make_registry(tmp_path)
    try:
        reg.add_device(
            device_id="dev-5",
            name="d",
            platform="ios",
            public_key="pk",
            refresh_token="old",
        )
        assert reg.rotate_refresh("dev-5", "new") is True
        assert reg.verify_refresh("dev-5", "old") is None
        assert reg.verify_refresh("dev-5", "new") is not None
    finally:
        reg.close()


def test_public_key_is_kept_for_future_signature_checks(tmp_path):
    reg = make_registry(tmp_path)
    try:
        reg.add_device(
            device_id="dev-6",
            name="d",
            platform="ios",
            public_key="PUBLICKEY",
            refresh_token="r",
        )
        assert reg.get("dev-6").public_key == "PUBLICKEY"
    finally:
        reg.close()


def test_bot_session_pointer_upserts_and_survives_restart(tmp_path):
    reg = make_registry(tmp_path)
    assert reg.get_bot_session("research") is None
    assert reg.set_bot_session(profile="research", stored_session_id="a", now=1.0) == 1.0
    assert reg.set_bot_session(profile="research", stored_session_id="b", now=2.0) == 2.0
    assert reg.get_bot_session("research") == "b"
    reg.close()

    reopened = make_registry(tmp_path)
    try:
        assert reopened.get_bot_session("research") == "b"
        assert reopened.get_bot_session("other") is None
    finally:
        reopened.close()


def test_cleanup_waits_for_concurrent_state_change_and_never_deletes_active(tmp_path):
    from concurrent.futures import ThreadPoolExecutor
    import threading

    reg = make_registry(tmp_path)
    reg.add_device(device_id='race', name='race', platform='ios', public_key='pk', refresh_token='secret')
    reg.revoke('race')
    with sqlite3.connect(reg.path) as writer, ThreadPoolExecutor(max_workers=1) as pool:
        writer.execute('BEGIN IMMEDIATE')
        writer.execute('UPDATE devices SET revoked = 0 WHERE device_id = ?', ('race',))
        started = threading.Event()
        def cleanup():
            started.set()
            return reg.delete_revoked('race')
        future = pool.submit(cleanup)
        assert started.wait(2)
        writer.commit()
        assert future.result(timeout=5) == 'active'
    assert reg.is_active('race')
    reg.revoke('race')
    assert reg.delete_revoked('race') == 'deleted'
    reg.touch('race')
    assert not reg.rotate_refresh('race', 'new')
    assert reg.delete_revoked('race') == 'missing'
    reg.close()
    reopened = make_registry(tmp_path)
    assert reopened.get('race') is None
    assert reopened.verify_refresh('race', 'secret') is None
    reopened.close()
