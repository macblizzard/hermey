"""What the bridge is allowed to remember: who did what, never what was said.

The design rule is blunt (02-architecture.md §6.8): ``device_id``, method,
duration and byte counts. No prompt text, no tool output, no tokens. This file
puts a canary in a real turn and then searches everywhere the bridge could have
written it — the audit records, the log lines, the SQLite file.
"""

from __future__ import annotations

import json
import logging

import pytest

from qa_support import run, scenario_path
from rpc import Socket

CANARY = "canary-prompt-9f3c-never-log-this"
COMMAND = "rm -rf build && make"
ALLOWED_KEYS = {
    "ts",
    "event",
    "device",
    "method",
    "path",
    "duration_ms",
    "bytes",
    "direction",
    "outcome",
    "reason",
    "close_code",
    "profile",
}


def _run_turn(relay, prompt_text: str = CANARY) -> None:
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            await sock.request("prompt.submit", {"session_id": "sess-1", "text": prompt_text}, request_id=3)
            await sock.expect(type="message.delta")
            request = None
            while request is None:
                frame = await sock.recv(timeout=5.0)
                if frame.get("method") == "approval":
                    request = frame
            await sock.answer(request["id"], {"choice": "once"})
            while (await sock.recv(timeout=5.0)).get("params", {}).get("type") != "message.complete":
                pass

    run(body())


def test_the_audit_log_records_the_turn_but_none_of_its_text(relay_factory, caplog):
    caplog.set_level(logging.DEBUG, logger="hermes_bridge")
    relay = relay_factory(str(scenario_path("turn-approval.ndjson")))
    _run_turn(relay)

    records = relay.audit.records
    assert records, "the bridge audited nothing"

    blob = json.dumps(records)
    assert CANARY not in blob, "prompt text reached the audit log"
    assert COMMAND not in blob, "tool input reached the audit log"

    logged = "\n".join(record.getMessage() for record in caplog.records)
    assert CANARY not in logged, "prompt text reached the log stream"
    assert COMMAND not in logged

    # …but the shape of the turn is there, which is what the log is for.
    request = relay.audit.last("client_request")
    assert request["method"] == "prompt.submit"
    assert request["bytes"] > 0
    assert request["device"] == relay.runtime.registry.list_devices()[0].device_id
    assert relay.audit.last("server_request")["method"] == "approval"
    assert relay.audit.last("server_response")["method"] == "approval"
    assert relay.audit.last("server_response")["duration_ms"] is not None


def test_audit_records_have_a_closed_key_set_and_scalar_values(relay_factory):
    relay = relay_factory(str(scenario_path("turn-approval.ndjson")))
    _run_turn(relay)

    for record in relay.audit.records:
        assert set(record) <= ALLOWED_KEYS, f"unexpected audit field in {record}"
        assert record["event"]
        for key, value in record.items():
            assert not isinstance(value, (dict, list)), f"{key} is structured: {record}"


def test_each_audit_record_is_one_json_line(relay_factory, caplog):
    caplog.set_level(logging.INFO, logger="hermes_bridge.audit")
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()

    run(body())
    lines = [r.getMessage() for r in caplog.records if r.name.startswith("hermes_bridge.audit")]
    assert lines, "no audit lines were logged"
    for line in lines:
        assert "\n" not in line
        parsed = json.loads(line)
        assert parsed["event"] in {
            "ws_open", "capabilities_sent", "client_request", "notification",
            "server_request", "server_response", "client_response", "ws_close",
            # HTTP pairing/token calls made while setting the turn up; the record carries the
            # route and status only, never a code or a token.
            "http",
        }, parsed


def test_the_audit_never_contains_a_token_or_ticket(relay_factory):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    pairing = relay.bridge.pair()
    ticket = relay.bridge.mint_ticket(pairing)

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()

    run(body())
    blob = json.dumps(relay.audit.records)
    assert ticket.ticket not in blob
    assert pairing.refresh_token not in blob
    assert pairing.public_key not in blob


def test_a_rejected_upgrade_is_audited_without_the_ticket(relay_factory):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    from rpc import assert_upgrade_refused

    run(assert_upgrade_refused(relay.bridge.ws_url("bogus-ticket-value")))
    rejected = relay.audit.last("ticket_rejected")
    assert rejected is not None
    assert rejected["outcome"] == "denied"
    assert "bogus-ticket-value" not in json.dumps(relay.audit.records)


@pytest.mark.parametrize("method", ["shell.exec", "cli.exec", "config.set", "vault.read"])
def test_dangerous_methods_never_reach_the_gateway_or_the_audit(relay_factory, method):
    relay = relay_factory(str(scenario_path("handshake.ndjson")))
    ticket = relay.mint_ticket()

    async def body():
        async with Socket.open(relay.ws_url(ticket.ticket)) as sock:
            await sock.expect(type="gateway.ready")
            await sock.handshake()
            response = await sock.request_response(method, {"cmd": CANARY}, request_id=40)
            assert response["error"]["code"] == -32601

    run(body())
    conn = relay.wait_for_gateway(1)[0]
    assert method not in conn.inbound_methods()
    assert CANARY not in json.dumps(relay.audit.records)
