"""Scenario tests for ``/v1/ws``: the bridge against a scripted gateway.

Each test boots the real bridge, points it at a replay server, pairs a device and
drives the socket. The assertions are about *contract*, not implementation:
frames verbatim, ids preserved, approvals blocked until answered, tickets spent
once, frames capped.

The gateway's payload shapes for approvals are illustrative — the recorded
fixtures contain no approval frame (see ``docs/QA.md``, "What is not verified").
What is verified is the envelope and the blocking semantics, which is what the
client has to get right.
"""

from __future__ import annotations

import json
import time

import pytest

from qa_support import run, scenario_path
from replay_server import FRAME_CAP_BYTES
from rpc import Socket, UpgradeRefused, assert_upgrade_refused

TURN = "turn-approval.ndjson"
CAPS = {"server_requests": ["approval", "clarify", "secret", "sudo", "terminal.read", "vault.code"]}


def inline(*frames, auto: dict | None = None) -> list[dict]:
    """A one-connection script: optional auto-answers, then frames in order."""
    script: list[dict] = []
    if auto:
        script.append({"$qa": {"auto_reply": auto}})
    script.extend(frames)
    return script


# --------------------------------------------------------------------------- #
# Relay basics
# --------------------------------------------------------------------------- #


def test_ready_is_forwarded_and_the_bridge_announces_its_own_capabilities(relay_factory):
    """The bridge is the party that answers server requests, so it must announce
    ``server_requests: true`` itself — and it must not leak that answer upstream."""
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            ready = await sock.expect(type="gateway.ready")
            assert ready["params"]["payload"]["replay_epoch"] == "qa-handshake"
            caps = await sock.handshake()
            return ready, caps

    _, caps = run(body())
    assert caps["result"]["declines_not_shown"] is True
    assert "approval" in caps["result"]["server_requests"]

    conn = relay.wait_for_gateway(1)[0]
    injected = [f for f in conn.inbound if f.frame and f.frame.get("id") == "__hermes_bridge_caps__"]
    assert len(injected) == 1, f"bridge did not send its own handshake: {conn.inbound_methods()}"
    assert injected[0].frame["method"] == "client.capabilities"
    assert injected[0].frame["params"] == {"server_requests": True}
    # Its answer is consumed, not forwarded to the app.
    assert conn.error is None


def test_a_client_cannot_narrow_the_server_requests_capability(relay_factory):
    """Approvals stay enabled: a client asking for less must not disable them."""
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.send_frame(
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "client.capabilities",
                    "params": {"server_requests": False},
                }
            )
            return await sock.response_for(2, timeout=5.0)

    run(body())
    conn = relay.wait_for_gateway(1)[0]
    forwarded = [
        f.frame
        for f in conn.inbound
        if f.frame and f.frame.get("method") == "client.capabilities" and f.frame.get("id") == 2
    ]
    assert forwarded, "the client's capabilities frame never reached the gateway"
    assert forwarded[0]["params"]["server_requests"] is True


def test_ids_and_payloads_are_relayed_verbatim(relay_factory):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()

    run(body())
    conn = relay.wait_for_gateway(1)[0]
    client_frames = [f.frame for f in conn.inbound if f.frame and f.frame.get("id") in (1, 2)]
    assert [f["id"] for f in client_frames] == [1, 2]
    assert all(isinstance(f["id"], int) for f in client_frames), "ids must not be coerced"
    assert len(relay.gateway.connections) == 1, "one client socket must be one upstream socket"


def test_a_silent_gateway_is_not_turned_into_an_empty_result(relay_factory):
    """Absence is not ``[]`` (fixtures/NOTES.md §4)."""
    relay = relay_factory(str(scenario_path("silent-session-list.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            await sock.request("session.list", {"limit": 5}, request_id=9)
            return await sock.silence(0.6)

    assert run(body()) == []


def test_methods_outside_the_allow_list_are_refused_by_the_bridge(relay_factory):
    """The allow-list is the security boundary: no ``shell.exec`` over this socket."""
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            shell = await sock.request_response("shell.exec", {"cmd": "id"}, request_id=10)
            unknown = await sock.request_response("no.such.method", request_id=11)
            return shell, unknown

    shell, unknown = run(body())
    assert shell["error"]["code"] == -32601
    assert "shell.exec" in shell["error"]["message"]
    assert unknown["error"]["code"] == -32601

    conn = relay.wait_for_gateway(1)[0]
    assert "shell.exec" not in conn.inbound_methods()
    assert "no.such.method" not in conn.inbound_methods()
    rejected = relay.audit.all("client_request_rejected")
    assert any(r.get("reason") == "method_not_allowed" for r in rejected)


def test_malformed_frames_do_not_kill_the_connection(relay_factory):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            await sock.send_raw("this is not json\n")
            parse_error = await sock.recv(timeout=5.0)
            # still usable afterwards
            await sock.request("ping", request_id=12)
            pong = await sock.response_for(12, timeout=5.0)
            return parse_error, pong

    parse_error, pong = run(body())
    assert parse_error["error"]["code"] == -32700
    assert pong["result"] == {"pong": True}


def test_method_names_are_validated_before_the_allow_list(relay_factory):
    """A method name is a token, not free text; it must never be echoed raw or proxied."""
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            return await sock.request_response("session.list; curl evil.example", request_id=13)

    response = run(body())
    assert response["error"]["code"] == -32601
    assert "invalid method" in response["error"]["message"]
    conn = relay.wait_for_gateway(1)[0]
    assert all("evil" not in (f.frame.get("method") or "") for f in conn.inbound)


def test_unsupported_server_requests_are_answered_by_the_bridge(relay_factory):
    """A gateway request the app cannot render gets ``-32601`` so the agent fails fast."""
    script = inline(
        {"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}},
        {"jsonrpc": "2.0", "id": "srv-1", "method": "preview.act", "params": {"target": "x"}},
        {"$qa": {"wait_for_response": {"id": "srv-1", "timeout": 5}}},
        auto={"ping": {"result": {"pong": True}}, "client.capabilities": {"result": CAPS}},
    )
    relay = relay_factory(script)
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            return await sock.silence(0.4)

    assert run(body()) == [], "an unsupported server request was forwarded to the app"
    conn = relay.wait_for_gateway(1)[0]
    answers = conn.inbound_responses()
    assert [a.frame["id"] for a in answers] == ["srv-1"]
    assert answers[0].frame["error"]["code"] == -32601
    assert relay.audit.last("server_request_declined")["method"] == "preview.act"


# --------------------------------------------------------------------------- #
# Server -> client requests
# --------------------------------------------------------------------------- #


def test_approval_round_trip_blocks_the_agent_until_answered(relay_factory):
    relay = relay_factory(str(scenario_path(TURN)))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            await sock.request("prompt.submit", {"session_id": "sess-1", "text": "build it"}, request_id=3)

            first = await sock.expect(type="message.delta")
            assert first["params"]["payload"]["delta"] == "I'll run the build."
            await sock.expect(type="message.delta")
            tool = await sock.expect(type="tool.start")
            assert tool["params"]["payload"]["call_id"] == "call-1"

            request = await sock.recv(timeout=5.0)
            assert request["method"] == "approval", request
            assert request["id"] == "srq-1", request
            assert request["params"]["choices"] == ["once", "always", "deny"]

            # The agent is blocked: nothing else arrives while the user decides.
            assert await sock.silence(0.25) == []

            await sock.answer("srq-1", {"choice": "once"})
            complete = await sock.expect(type="tool.complete")
            assert complete["params"]["payload"]["ok"] is True
            await sock.expect(type="message.complete")

    run(body())
    conn = relay.wait_for_gateway(1)[0]
    assert conn.error is None, f"scenario did not run as written: {conn.error}"

    answers = conn.inbound_responses()
    assert len(answers) == 1, f"expected one answer, saw {answers}"
    assert answers[0].frame == {"jsonrpc": "2.0", "id": "srq-1", "result": {"choice": "once"}}
    assert answers[0].at < (conn.first_at("out", "tool.complete") or 0), (
        "the gateway released the tool before the answer arrived"
    )
    assert relay.audit.last("server_response") is not None


def test_declining_an_approval_fails_the_tool(relay_factory):
    relay = relay_factory(str(scenario_path("turn-decline.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            await sock.request("prompt.submit", {"session_id": "sess-2", "text": "push"}, request_id=3)
            await sock.expect(type="tool.start")
            request = await sock.recv(timeout=5.0)
            assert request["id"] == "srq-2"
            await sock.answer("srq-2", {"choice": "deny"})
            complete = await sock.expect(type="tool.complete")
            assert complete["params"]["payload"]["ok"] is False
            await sock.expect(type="message.complete")

    run(body())
    conn = relay.wait_for_gateway(1)[0]
    assert conn.inbound_responses()[0].frame["result"] == {"choice": "deny"}


def test_a_stale_answer_is_dropped_and_not_forwarded(relay_factory):
    """Second device answers an approval the first already answered."""
    relay = relay_factory(str(scenario_path(TURN)))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            await sock.answer("srq-does-not-exist", {"choice": "deny"})
            await sock.request("ping", request_id=20)
            return await sock.response_for(20, timeout=5.0)

    assert run(body())["result"] == {"pong": True}
    conn = relay.wait_for_gateway(1)[0]
    assert conn.inbound_responses() == [], "a stale answer was forwarded upstream"
    assert relay.audit.last("client_response_dropped") is not None


def test_resume_replays_the_open_request_and_answering_it_finishes_the_turn(relay_factory):
    relay = relay_factory(str(scenario_path("resume-open-request.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            resume = await sock.request_response("session.resume", {"session_id": "sess-3"}, request_id=3)
            result = resume["result"]
            assert result["inflight"]["streaming"] is True
            assert [r["id"] for r in result["open_requests"]] == ["srq-9"]

            live = await sock.recv(timeout=5.0)
            assert live["method"] == "approval" and live["id"] == "srq-9"
            await sock.answer("srq-9", {"choice": "once"})
            assert (await sock.expect(type="tool.complete"))["params"]["payload"]["ok"] is True
            await sock.expect(type="message.complete")

    run(body())
    conn = relay.wait_for_gateway(1)[0]
    assert len(conn.inbound_responses()) == 1


def test_a_server_request_with_a_colliding_id_is_remapped_and_restored(relay_factory):
    """A gateway id that collides with an in-flight client request must not be
    confused with it; the app may see a remapped id, the gateway gets the original."""
    script = inline(
        {"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}},
        {"$qa": {"wait_for": {"method": "session.list", "timeout": 10}}},
        {"jsonrpc": "2.0", "id": 1, "method": "approval", "params": {"choices": ["once", "deny"]}},
        {"$qa": {"wait_for_response": {"id": 1, "timeout": 10}}},
        {"jsonrpc": "2.0", "method": "event", "params": {"type": "message.complete", "payload": {}}},
        auto={"ping": {"result": {"pong": True}}, "client.capabilities": {"result": CAPS}},
    )
    relay = relay_factory(script)
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            # id 1 is in flight, so the gateway's request with id 1 collides.
            await sock.request("session.list", {"limit": 5}, request_id=1)
            request = await sock.recv(timeout=5.0)
            assert request["method"] == "approval"
            assert request["id"] != 1, "the app must never see two live ids that collide"
            await sock.answer(request["id"], {"choice": "once"})
            await sock.expect(type="message.complete")
            return request["id"]

    remapped = run(body())
    conn = relay.wait_for_gateway(1)[0]
    answers = conn.inbound_responses()
    assert [a.frame["id"] for a in answers] == [1], (
        f"the gateway must get its original id back, got {answers}; app saw {remapped!r}"
    )


# --------------------------------------------------------------------------- #
# Tickets
# --------------------------------------------------------------------------- #


def test_ticket_is_spent_by_the_first_upgrade(relay_factory):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()
    url = relay.ws_url(ticket.ticket)

    async def body():
        async with Socket.open(url) as sock:
            await sock.expect(type="gateway.ready")
        return await assert_upgrade_refused(url)

    run(body())
    refusal = run(assert_upgrade_refused(url))
    assert refusal is not None
    relay.wait_for_gateway(1)
    assert len(relay.gateway.connections) == 1


def test_ticket_used_by_a_different_upgrade_after_revoke_is_refused(relay_factory):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    pairing = relay.bridge.pair()
    ticket = relay.bridge.mint_ticket(pairing)
    with relay.bridge.http as client:
        headers = {"Authorization": "Bearer " + relay.bridge.mint_ticket(pairing).ticket}
        assert client.delete(f"/v1/devices/{pairing.device_id}", headers=headers).status_code == 200

    run(assert_upgrade_refused(relay.ws_url(ticket.ticket)))
    assert relay.gateway.connections == []


def test_expired_ticket_is_refused(relay_factory, monkeypatch):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()
    store = relay.runtime.tickets
    # White-box on purpose: the TTL is 30 s and the suite will not sleep 31 s.
    real_clock = store._clock
    store._clock = lambda: real_clock() + 31.0
    try:
        run(assert_upgrade_refused(relay.ws_url(ticket.ticket)))
    finally:
        store._clock = real_clock
    assert relay.gateway.connections == []


def test_missing_ticket_is_refused(relay_factory):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))

    async def body():
        await assert_upgrade_refused(relay.bridge.ws_url(""))
        await assert_upgrade_refused(relay.bridge.ws_url("not-a-ticket"))

    run(body())
    assert relay.gateway.connections == []


def test_revoking_a_device_kills_its_unused_ticket(relay_factory):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    pairing = relay.bridge.pair()
    ticket = relay.bridge.mint_ticket(pairing)
    with relay.bridge.http as client:
        headers = {"Authorization": "Bearer " + relay.bridge.mint_ticket(pairing).ticket}
        client.delete(f"/v1/devices/{pairing.device_id}", headers=headers)

    run(assert_upgrade_refused(relay.ws_url(ticket.ticket)))


# --------------------------------------------------------------------------- #
# Frame limits
# --------------------------------------------------------------------------- #


def test_oversized_client_frame_is_refused_and_never_forwarded(relay_factory):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()
    oversized = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 7,
            "method": "prompt.submit",
            "params": {"session_id": "s", "text": "x" * (FRAME_CAP_BYTES + 1024)},
        }
    ) + "\n"

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            await sock.send_raw(oversized)
            try:
                frame = await sock.recv(timeout=5.0)
            except UpgradeRefused as exc:
                return exc
            raise AssertionError(f"relay answered instead of refusing: {str(frame)[:200]}")

    refusal = run(body())
    assert refusal.code == 1009, f"expected 1009, got {refusal}"
    conn = relay.wait_for_gateway(1)[0]
    assert conn.max_inbound_size <= FRAME_CAP_BYTES, (
        f"gateway received {conn.max_inbound_size} bytes — the bridge forwarded it"
    )
    assert "prompt.submit" not in conn.inbound_methods()
    assert relay.audit.last("frame_too_large") is not None


def test_oversized_gateway_frame_is_not_relayed(relay_factory):
    huge = "d" * (FRAME_CAP_BYTES + 4096)
    script = inline(
        {"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}},
        {
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": "message.delta", "payload": {"session_id": "s", "delta": huge}},
        },
        auto={"ping": {"result": {"pong": True}}, "client.capabilities": {"result": CAPS}},
    )
    relay = relay_factory(script)
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            # No handshake: the oversize event is already queued behind ready, so
            # the close can arrive at any moment.
            try:
                frame = await sock.recv(timeout=5.0)
            except UpgradeRefused as exc:
                return exc
            raise AssertionError(f"bridge relayed an oversize event ({len(json.dumps(frame))} bytes)")

    assert run(body()).code == 1009


def test_oversized_binary_frame_cannot_bypass_the_cap(relay_factory):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            await sock.ws.send(b'{"jsonrpc":"2.0","id":8,"method":"prompt.submit","params":{"t":"'
                               + b"x" * (FRAME_CAP_BYTES + 1024) + b'"}}\n')
            try:
                await sock.recv(timeout=5.0)
            except UpgradeRefused as exc:
                return exc
            raise AssertionError("an oversize binary frame was relayed")

    assert run(body()).code == 1009
    conn = relay.wait_for_gateway(1)[0]
    assert conn.max_inbound_size <= FRAME_CAP_BYTES


def test_one_message_may_carry_several_frames(relay_factory):
    """The protocol is newline-delimited, so a coalescing peer must still work."""
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            batch = "".join(
                json.dumps(f, separators=(",", ":")) + "\n"
                for f in (
                    {"jsonrpc": "2.0", "id": 30, "method": "session.list", "params": {"limit": 1}},
                    {"jsonrpc": "2.0", "id": 31, "method": "session.list", "params": {"limit": 2}},
                )
            )
            await sock.send_raw(batch)
            await sock.silence(0.2)

    run(body())
    conn = relay.wait_for_gateway(1)[0]
    sent = conn.inbound_with_method("session.list")
    assert [f.frame["id"] for f in sent] == [30, 31], conn.inbound_methods()


def test_a_chunked_frame_is_rejected_rather_than_half_forwarded(relay_factory):
    """Known limitation, pinned so it stays a *safe* failure.

    The bridge treats one WebSocket message as one frame boundary (the gateway's
    WS transport sends one frame per message, no trailing newline). A client that
    splits a single frame across two messages therefore gets ``-32700`` for each
    half — nothing partial is forwarded upstream. The Swift client sends one
    frame per message (``JSONRPCCodec.encodeFrame``), so this is not a live path;
    it is documented in docs/SECURITY.md and docs/QA.md.
    """
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()
    frame = json.dumps(
        {"jsonrpc": "2.0", "id": 32, "method": "session.list", "params": {"cursor": "y" * 4096}},
        separators=(",", ":"),
    )

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            await sock.ws.send(frame[:100])
            await sock.ws.send(frame[100:])
            await sock.ws.send("\n")
            return await sock.silence(0.5)

    errors = run(body())
    assert [e["error"]["code"] for e in errors] == [-32700, -32700], errors
    conn = relay.wait_for_gateway(1)[0]
    assert "session.list" not in conn.inbound_methods()
    assert conn.max_inbound_size <= FRAME_CAP_BYTES


# --------------------------------------------------------------------------- #
# Close propagation
# --------------------------------------------------------------------------- #


def test_gateway_close_reaches_the_client(relay_factory):
    script = inline(
        {"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}},
        {"$qa": {"close": {"code": 4403, "reason": "device revoked"}}},
        auto={"ping": {"result": {"pong": True}}, "client.capabilities": {"result": CAPS}},
    )
    relay = relay_factory(script)
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            try:
                await sock.recv(timeout=5.0)
            except UpgradeRefused as exc:
                return exc
            raise AssertionError("the client socket stayed open after the gateway closed")

    refusal = run(body())
    # The bridge collapses upstream closes into 1011 ("gateway closed"); it does
    # not forward Hermes' own code. Documented in docs/SECURITY.md, "gaps".
    assert refusal.code in {1011, 4403}, f"expected a prompt close, got {refusal}"
    relay.gateway.wait_for_closed(0, timeout=5)


def test_client_close_closes_the_upstream(relay_factory):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        sock = await Socket.connect(relay.ws_url(ticket.ticket))
        await sock.expect(type="gateway.ready")
        await sock.handshake()
        await sock.close()

    run(body())
    relay.gateway.wait_for_closed(0, timeout=5)


def test_the_gateway_token_travels_upstream_only(relay_factory):
    """The gateway token is full-authority: it may go to loopback, never to a phone."""
    secret = "gw-token-9c1f-never-to-the-client"
    relay = relay_factory(
        str(scenario_path("handshake.ndjson")),
        bridge_env={"HERMES_BRIDGE_GATEWAY_TOKEN": secret},
    )
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            return [f.raw for f in sock.frames]

    seen_by_client = run(body())
    conn = relay.wait_for_gateway(1)[0]
    assert secret in conn.path, f"the token was not used upstream (path={conn.path!r})"
    assert all(secret not in raw for raw in seen_by_client)


def test_revoking_a_device_drops_its_live_socket(relay_factory):
    # A long linger keeps the fake gateway's socket open, so any close observed
    # here can only come from the bridge.
    relay = relay_factory(str(scenario_path("handshake.ndjson")), gateway_kwargs={"linger": 30.0})
    pairing = relay.bridge.pair()
    ticket = relay.bridge.mint_ticket(pairing)

    async def body():
        sock = await Socket.connect(relay.ws_url(ticket.ticket))
        await sock.expect(type="gateway.ready")
        await sock.handshake()
        with relay.bridge.http as client:
            headers = {"Authorization": "Bearer " + relay.bridge.mint_ticket(pairing).ticket}
            assert client.delete(f"/v1/devices/{pairing.device_id}", headers=headers).status_code == 200
        try:
            frame = await sock.recv(timeout=1.5)
        except UpgradeRefused:
            return True
        raise AssertionError(f"the revoked device still received {frame}")

    assert run(body()) is True
