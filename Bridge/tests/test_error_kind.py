"""A failed client call must name itself without recording what was in it.

A JSON-RPC error message can quote the client's own input ("invalid params: <prompt fragment>"), so
the audit line carries a code and one slug from a closed set instead of the message. These tests pin
both halves: the classification, and the guarantee that the text has nowhere to go.
"""

from __future__ import annotations

import inspect

import pytest

from hermes_bridge import proxy
from hermes_bridge.audit import ERROR_KINDS, AuditLog


@pytest.mark.parametrize(
    "payload, expected",
    [
        ({"code": -32000, "message": "session is busy"}, "session_busy"),
        ({"code": -32000, "message": "a turn is already running"}, "session_busy"),
        ({"code": -32602, "message": "unknown session: abc"}, "unknown_session"),
        ({"code": -32602, "message": "no such session"}, "unknown_session"),
        ({"code": -32000, "message": "session not ready"}, "not_ready"),
        ({"code": -32000, "message": "socket closed"}, "not_ready"),
        ({"code": -32000, "message": "waiting for approval"}, "approval_pending"),
        ({"code": -32001, "message": "unauthorized ticket"}, "unauthorised"),
        ({"code": -32602, "message": "invalid params"}, "invalid_params"),
        ({"code": -32601, "message": "whatever"}, "method_not_found"),
        ({"code": -32603, "message": "whatever"}, "internal"),
        ({"code": -32000, "message": "astronomical anomaly"}, "other"),
    ],
)
def test_an_error_frame_is_classified_by_shape_not_text(payload, expected):
    assert proxy.error_kind({"error": payload}) == expected


def test_a_non_error_frame_has_no_kind():
    assert proxy.error_kind({"result": {}}) is None
    assert proxy.error_kind({"error": "not a dict"}) is None


def test_every_classifier_answer_is_in_the_closed_set():
    # If the classifier could invent a slug the audit log would silently rewrite it to "other",
    # losing the distinction exactly where it matters.
    for _, pattern in proxy._ERROR_KIND_PATTERNS:
        for sample in ("session is busy", "unknown session", "not ready", "approval needed",
                       "unauthorized", "invalid params", "method not found"):
            if pattern.search(sample):
                kind = next(k for k, p in proxy._ERROR_KIND_PATTERNS if p is pattern)
                assert kind in ERROR_KINDS


def test_the_record_carries_a_code_and_a_kind():
    audit = AuditLog(keep=5)
    record = audit.emit(
        "client_response",
        device_id="dev-1",
        method="prompt.submit",
        duration_ms=0.0033,
        nbytes=85,
        outcome="error",
        direction="gateway_to_client",
        error_code=-32000,
        error_kind="session_busy",
    )
    assert record["error_code"] == -32000
    assert record["error_kind"] == "session_busy"
    assert record["outcome"] == "error"


def test_an_unknown_kind_is_flattened_rather_than_logged():
    audit = AuditLog(keep=5)
    record = audit.emit("client_response", error_kind="moderation said: <prompt text>")
    assert record["error_kind"] == "other"
    assert "<prompt text>" not in str(record)


def test_the_emitter_has_nowhere_to_put_a_message():
    # The safety property is structural: no parameter exists that could carry the text.
    params = set(inspect.signature(AuditLog.emit).parameters)
    for forbidden in ("message", "error", "detail", "text", "params", "body", "prompt"):
        assert forbidden not in params, f"audit.emit must not accept {forbidden!r}"
