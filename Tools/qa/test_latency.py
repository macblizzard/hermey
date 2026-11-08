"""The latency harness is itself an instrument; a broken one lies quietly.

So: it must produce the scripted number of deltas, detect the scripted 8 ms
cadence, and work over both legs.
"""

from __future__ import annotations

import json

import pytest

import latency


def test_probe_measures_the_gateway_leg():
    samples, label = latency.probe(samples=3, warmup=1)
    assert len(samples) == 3
    assert "gateway direct" in label
    assert all(s.deltas == 31 for s in samples), [s.deltas for s in samples]

    summary = latency.summarise(samples)
    # Loose bounds: loopback, no TLS. Tight enough to catch a stub, loose enough
    # for a busy CI box.
    assert 0 <= summary["ping_rtt_ms"]["p50"] < 250
    assert 0 <= summary["submit_to_first_delta_ms"]["p50"] < 250
    # The scenario streams every 8 ms; if the harness were buffering, this would
    # collapse to ~0 or balloon.
    assert 2.0 <= summary["delta_interval_ms"]["p50"] <= 40.0, summary["delta_interval_ms"]
    assert summary["deltas_per_sample"] == 31


def test_probe_can_measure_through_the_bridge():
    samples, label = latency.probe(samples=2, through_bridge=True, warmup=1)
    assert "bridge" in label
    assert len(samples) == 2
    summary = latency.summarise(samples)
    assert summary["submit_to_first_delta_ms"]["p50"] < 400
    assert summary["deltas_per_sample"] == 31


def test_report_is_a_readable_table():
    samples, label = latency.probe(samples=1, warmup=0)
    report = latency.format_report(latency.summarise(samples), target=label)
    for fragment in ("gateway.ready", "ping RTT", "1st delta", "delta interval", "stream total"):
        assert fragment in report, report
    assert "p50" in report


def test_cli_json_output_is_machine_readable(capsys):
    assert latency.main(["--samples", "1", "--warmup", "0", "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["summary"]["samples"] == 1
    assert payload["samples"][0]["deltas"] == 31
    assert payload["path"]


def test_percentile_is_monotonic():
    values = [5.0, 1.0, 3.0, 2.0, 4.0]
    assert latency.percentile(values, 50) <= latency.percentile(values, 95)
    assert latency.percentile(values, 95) <= latency.percentile(values, 99)
    assert latency.percentile([], 50) != latency.percentile([], 50)  # NaN
