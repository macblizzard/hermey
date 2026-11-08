"""The replay server is test infrastructure, so it gets tested like code.

If this file is green, a scenario that "failed" really did fail — the fake
gateway is not the suspect.
"""

from __future__ import annotations

import json

import pytest

from qa_support import ROOT, run, scenario_path
from replay_server import ScriptError, parse_script
from rpc import RpcTimeout, Socket

FIXTURE = ROOT / "fixtures" / "m0-handshake.ndjson"


# --------------------------------------------------------------------------- #
# Transcript mode: the recorded bytes, byte for byte
# --------------------------------------------------------------------------- #


def test_replays_the_recorded_fixture_byte_for_byte(replay_factory):
    """fixtures/NOTES.md: where docs and fixtures disagree, the fixtures win."""
    server = replay_factory(str(FIXTURE))
    expected = [line for line in FIXTURE.read_text(encoding="utf-8").splitlines() if line.strip()]

    async def body():
        async with Socket.open(server.url) as sock:
            got = []
            for _ in expected:
                got.append((await sock.recv_frame(timeout=5.0)).raw)
            return got

    assert run(body()) == expected


def test_frames_are_one_newline_terminated_json_object_each(replay_factory):
    server = replay_factory(str(FIXTURE))

    async def body():
        async with Socket.open(server.url) as sock:
            messages = []
            for _ in range(4):
                messages.append(await sock.ws.recv())
            return messages

    for message in run(body()):
        assert message.endswith("\n"), "a frame must be newline-terminated"
        assert message.count("\n") == 1, "one frame per message: no embedded newlines"
        assert isinstance(json.loads(message), dict)


def test_ready_arrives_before_anything_else(replay_factory):
    server = replay_factory(str(FIXTURE))

    async def body():
        async with Socket.open(server.url) as sock:
            return await sock.recv(timeout=5.0)

    first = run(body())
    assert first["method"] == "event"
    assert first["params"]["type"] == "gateway.ready"


# --------------------------------------------------------------------------- #
# Script mode: gating, ids, silence, close
# --------------------------------------------------------------------------- #


def test_wait_for_blocks_the_script_until_the_request_arrives(replay_factory):
    script = [
        {"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}},
        {"$qa": {"wait_for": {"method": "ping", "timeout": 5}}},
        {"jsonrpc": "2.0", "method": "event", "params": {"type": "after_ping", "payload": {}}},
    ]
    server = replay_factory(script)

    async def body():
        async with Socket.open(server.url) as sock:
            await sock.expect(type="gateway.ready")
            early = await sock.silence(0.3)
            await sock.request("ping")
            late = await sock.recv(timeout=5.0)
            return early, late

    early, late = run(body())
    assert early == [], f"gateway sent {early} before the request it waits for"
    assert late["params"]["type"] == "after_ping"


def test_reply_answers_with_the_clients_own_id_and_type(replay_factory):
    script = [
        {"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}},
        {"$qa": {"reply": {"method": "ping", "result": {"pong": True}}}},
        {"$qa": {"reply": {"method": "ping", "result": {"pong": True}}}},
    ]
    server = replay_factory(script)

    async def body():
        async with Socket.open(server.url) as sock:
            await sock.expect(type="gateway.ready")
            await sock.send_frame({"jsonrpc": "2.0", "id": 77, "method": "ping"})
            int_id = await sock.recv(timeout=5.0)
            await sock.send_frame({"jsonrpc": "2.0", "id": "abc", "method": "ping"})
            str_id = await sock.recv(timeout=5.0)
            return int_id, str_id

    int_id, str_id = run(body())
    assert int_id["id"] == 77 and isinstance(int_id["id"], int), int_id
    assert str_id["id"] == "abc", str_id
    assert int_id["result"] == {"pong": True}
    assert "jsonrpc" in int_id and "error" not in int_id


def test_session_list_can_be_silent_while_ping_answers(replay_factory):
    """fixtures/NOTES.md §4: 60 s of silence on session.list is a real behaviour."""
    server = replay_factory(str(scenario_path("silent-session-list.ndjson")))

    async def body():
        async with Socket.open(server.url) as sock:
            await sock.expect(type="gateway.ready")
            caps = await sock.handshake()
            await sock.request("session.list", {"limit": 5}, request_id=9)
            quiet = await sock.silence(0.6)
            return caps, quiet

    caps, quiet = run(body())
    assert caps["result"]["declines_not_shown"] is True
    assert quiet == [], f"a silent gateway answered anyway: {quiet}"
    assert server.connection(0).inbound_methods()[-1] == "session.list"


def test_close_directive_sets_the_code_the_client_sees(replay_factory):
    script = [
        {"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}},
        {"$qa": {"close": {"code": 4403, "reason": "device revoked"}}},
    ]
    server = replay_factory(script)

    async def body():
        async with Socket.open(server.url) as sock:
            await sock.expect(type="gateway.ready")
            with pytest.raises(Exception) as info:
                await sock.recv(timeout=5.0)
            return info.value

    exc = run(body())
    assert getattr(exc, "code", None) == 4403, exc
    assert server.wait_for_closed(0).closed_code == 4403


def test_records_both_directions_with_timings_and_sizes(replay_factory):
    server = replay_factory(str(scenario_path("latency-stream.ndjson")))

    async def body():
        async with Socket.open(server.url) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            await sock.request("prompt.submit", {"session_id": "s1", "text": "hi"})
            seen = []
            while True:
                frame = await sock.recv(timeout=5.0)
                seen.append((frame.get("params") or {}).get("type"))
                if frame.get("params", {}).get("type") == "message.complete":
                    return seen

    types = run(body())
    assert types[0] == "message.delta" and types[-1] == "message.complete"

    conn = server.connection(0)
    assert conn.inbound_methods() == ["ping", "client.capabilities", "prompt.submit"]
    assert conn.max_inbound_size > 0
    assert conn.inbound_bytes == sum(f.size for f in conn.inbound)
    assert [f.at for f in conn.outbound] == sorted(f.at for f in conn.outbound)
    assert conn.event_types()[0] == "gateway.ready"
    assert conn.event_types()[-1] == "message.complete"
    # The client's close is observed by the server (it may take a moment).
    closed = server.wait_for_closed(0)
    assert closed.closed_code is not None
    # The scenario ran to the end: no directive timed out.
    assert closed.error is None


def test_scripts_are_handed_out_one_per_connection(replay_factory):
    """Reconnect tests need a *fresh* gateway session, not the same tape again."""
    first = [
        {"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {"n": 1}}},
    ]
    second = [
        {"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {"n": 2}}},
    ]
    server = replay_factory([first, second])

    async def body():
        out = []
        for _ in range(2):
            async with Socket.open(server.url) as sock:
                out.append((await sock.recv(timeout=5.0))["params"]["payload"]["n"])
        return out

    assert run(body()) == [1, 2]


def test_oversize_frames_are_recorded_not_rejected(replay_factory):
    """The fake gateway must be able to *observe* a frame a broken bridge forwarded.

    If this server enforced the 1 MiB cap itself, an oversize-relay bug would
    turn into a clean 1009 from the gateway and the test would pass for the wrong
    reason.
    """
    oversized = (
        '{"jsonrpc":"2.0","id":1,"method":"prompt.submit","params":{"text":"'
        + "x" * (1 << 20)
        + '"}}\n'
    )
    server = replay_factory([{"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}}])

    async def body():
        async with Socket.open(server.url) as sock:
            await sock.expect(type="gateway.ready")
            await sock.send_raw(oversized)
            await sock.silence(0.2)

    run(body())
    conn = server.connection(0)
    assert [f.size for f in conn.inbound] == [len(oversized.encode())]
    assert conn.max_inbound_size > (1 << 20)


# --------------------------------------------------------------------------- #
# Parser: a broken scenario must fail loudly, never silently no-op
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "line,message",
    [
        ('{"$qa": {"nope": 1}}', "unknown directive"),
        ('{"$qa": {"wait_for": {}}}', "wait_for needs"),
        ('{"$qa": {"reply": {"method": "ping"}}}', "needs 'result' or 'error'"),
        ('{"$qa": {"unmatched": "shout"}}', "unmatched must be"),
        ('{"$qa": {"sleep": 0.1}, "id": 1}', "must be the only key"),
        ("this is not json", "not JSON"),
        ('["not", "an", "object"]', "must be a JSON object"),
        ('{"hello": "world"}', "neither a JSON-RPC frame"),
    ],
)
def test_malformed_scenarios_fail_loudly(line, message):
    with pytest.raises(ScriptError) as info:
        parse_script([line])
    assert message in str(info.value), str(info.value)


def test_comments_and_blank_lines_are_ignored():
    items = parse_script(
        [
            "# a comment",
            "",
            '{"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}}',
        ]
    )
    assert len(items) == 1 and items[0].is_frame


def test_sleep_and_mark_can_share_a_line():
    items = parse_script(['{"$qa": {"sleep": 0.01, "mark": "here"}}'])
    assert items[0].directive == {"sleep": 0.01, "mark": "here"}


def test_every_scenario_in_the_repo_parses(scenarios):
    files = sorted(scenarios.glob("*.ndjson"))
    assert files, "no scenarios found"
    for path in files:
        assert parse_script(path), path


# --------------------------------------------------------------------------- #
# Recorder output replays directly
# --------------------------------------------------------------------------- #


def test_a_recording_from_tools_record_fixtures_replays_as_a_scenario(tmp_path, replay_factory):
    """``Tools/record_fixtures.py`` wraps frames as ``{t, dir, frame}``.

    A fresh recording must be usable without hand-editing: ``stdout`` records are
    replayed in order, ``stdin`` records become gates so the ordering holds.
    """
    recording = tmp_path / "recorded.ndjson"
    recording.write_text(
        "\n".join(
            json.dumps(record)
            for record in (
                {"t": 0.01, "dir": "stderr", "raw": "some log line"},
                {
                    "t": 0.02,
                    "dir": "stdout",
                    "frame": {"jsonrpc": "2.0", "method": "event",
                              "params": {"type": "gateway.ready", "payload": {}}},
                },
                {"t": 0.03, "dir": "stdin", "frame": {"jsonrpc": "2.0", "id": 1, "method": "ping"}},
                {"t": 0.04, "dir": "stdout",
                 "frame": {"jsonrpc": "2.0", "id": 1, "result": {"pong": True}}},
            )
        )
        + "\n",
        encoding="utf-8",
    )
    server = replay_factory(str(recording))

    async def body():
        async with Socket.open(server.url) as sock:
            ready = await sock.expect(type="gateway.ready")
            await sock.send_frame({"jsonrpc": "2.0", "id": 1, "method": "ping"})
            return ready, await sock.recv(timeout=5.0)

    ready, pong = run(body())
    assert ready["params"]["type"] == "gateway.ready"
    assert pong == {"jsonrpc": "2.0", "id": 1, "result": {"pong": True}}
    assert server.connection(0).error is None
