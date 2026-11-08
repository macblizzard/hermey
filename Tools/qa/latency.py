"""Measure the wire, not the model.

Three numbers decide whether the client feels instant, and none of them involve
the LLM:

* **connect → ``gateway.ready``** — a reconnect after backgrounding must be
  hundreds of milliseconds, not seconds (target: < 400 ms on the tailnet).
* **``prompt.submit`` → first ``message.delta``** — everything the transport adds
  before the model's first token (target: one RTT).
* **delta cadence** — the scripted 8 ms stream must arrive at 8 ms, not in bursts.
  A relay that buffers shows up here and nowhere else.

The scripted scenario emits its first delta with **no delay**, so
``submit → first delta`` is pure transport. Its cadence is 8 ms, so the measured
intervals show buffering and event-loop stalls directly.

Usage
-----
    python Tools/qa/latency.py                     # gateway leg, 20 samples
    python Tools/qa/latency.py --through-bridge     # the real path: phone → bridge → gateway
    python Tools/qa/latency.py --csv /tmp/lat.csv --samples 50

Numbers measured on loopback are a *regression baseline*, not the tailnet budget:
they exclude WireGuard, TLS and the radio. They are still the only way to tell a
transport regression from a bad network day.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import statistics
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

QA_DIR = Path(__file__).resolve().parent
if str(QA_DIR) not in sys.path:
    sys.path.insert(0, str(QA_DIR))

import harness  # noqa: E402
from replay_server import ReplayServer  # noqa: E402
from rpc import RpcTimeout, Socket  # noqa: E402

DEFAULT_SCRIPT = QA_DIR / "scenarios" / "latency-stream.ndjson"


@dataclass
class Sample:
    open_ms: float
    ready_ms: float
    ping_rtt_ms: float
    submit_to_first_delta_ms: float
    delta_intervals_ms: list[float] = field(default_factory=list)
    stream_ms: float = 0.0
    #: Gateway-side view: when the delta left the gateway minus when submit arrived.
    gateway_hop_ms: float | None = None
    deltas: int = 0


async def sample_once(url: str, *, prompt: str = "summarise the build", timeout: float = 10.0) -> Sample:
    t0 = time.perf_counter()
    sock = await Socket.connect(url, timeout=timeout)
    opened = time.perf_counter()
    try:
        await sock.expect(type="gateway.ready", timeout=timeout)
        ready = time.perf_counter()

        await sock.send_frame({"jsonrpc": "2.0", "id": 1, "method": "ping"})
        ping_start = time.perf_counter()
        await sock.response_for(1, timeout=timeout)
        ping = time.perf_counter()

        await sock.send_frame(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "client.capabilities",
                "params": {"server_requests": True},
            }
        )
        await sock.response_for(2, timeout=timeout)

        submit_at = time.perf_counter()
        await sock.send_frame(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "prompt.submit",
                "params": {"session_id": "sess-lat", "text": prompt},
            }
        )

        first = await sock.recv(timeout=timeout)
        if (first.get("params") or {}).get("type") != "message.delta":
            raise RuntimeError(f"expected a delta, got {first}")
        first_delta_at = time.perf_counter()

        arrivals = [first_delta_at]
        while True:
            frame = await sock.recv(timeout=timeout)
            kind = (frame.get("params") or {}).get("type")
            if kind == "message.delta":
                arrivals.append(time.perf_counter())
            elif kind == "message.complete":
                done = time.perf_counter()
                break
            else:
                raise RuntimeError(f"unexpected event during the stream: {kind}")

        return Sample(
            open_ms=(opened - t0) * 1000,
            ready_ms=(ready - t0) * 1000,
            ping_rtt_ms=(ping - ping_start) * 1000,
            submit_to_first_delta_ms=(first_delta_at - submit_at) * 1000,
            delta_intervals_ms=[
                (b - a) * 1000 for a, b in zip(arrivals, arrivals[1:])
            ],
            stream_ms=(done - submit_at) * 1000,
            deltas=len(arrivals),
        )
    finally:
        await sock.close()


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(p / 100 * len(ordered)) - 1))
    return ordered[index]


def summarise(samples: list[Sample]) -> dict:
    intervals = [i for s in samples for i in s.delta_intervals_ms]
    return {
        "samples": len(samples),
        "open_ms": {
            "p50": percentile([s.open_ms for s in samples], 50),
            "p95": percentile([s.open_ms for s in samples], 95),
        },
        "ready_ms": {
            "p50": percentile([s.ready_ms for s in samples], 50),
            "p95": percentile([s.ready_ms for s in samples], 95),
        },
        "ping_rtt_ms": {
            "p50": percentile([s.ping_rtt_ms for s in samples], 50),
            "p95": percentile([s.ping_rtt_ms for s in samples], 95),
            "p99": percentile([s.ping_rtt_ms for s in samples], 99),
        },
        "submit_to_first_delta_ms": {
            "p50": percentile([s.submit_to_first_delta_ms for s in samples], 50),
            "p95": percentile([s.submit_to_first_delta_ms for s in samples], 95),
            "max": max(s.submit_to_first_delta_ms for s in samples),
        },
        "delta_interval_ms": {
            "p50": percentile(intervals, 50),
            "p95": percentile(intervals, 95),
            "max": max(intervals) if intervals else float("nan"),
            "scripted": 8.0,
        },
        "stream_ms": {
            "p50": percentile([s.stream_ms for s in samples], 50),
            "max": max(s.stream_ms for s in samples),
        },
        "deltas_per_sample": samples[0].deltas,
    }


def format_report(summary: dict, *, target: str) -> str:
    def line(label: str, p50: float, p95: float, extra: str = "") -> str:
        return f"  {label:<34}{p50:8.2f} {p95:8.2f}   {extra}"

    lines = [
        f"path: {target}   samples: {summary['samples']}   "
        f"deltas/sample: {summary['deltas_per_sample']}",
        f"  {'':<34}{'p50':>8} {'p95':>8}   (ms)",
        line("TCP+TLS+WS open", summary["open_ms"]["p50"], summary["open_ms"]["p95"]),
        line("connect → gateway.ready", summary["ready_ms"]["p50"], summary["ready_ms"]["p95"]),
        line("ping RTT", summary["ping_rtt_ms"]["p50"], summary["ping_rtt_ms"]["p95"],
             f"p99 {summary['ping_rtt_ms']['p99']:.2f}"),
        line("prompt.submit → 1st delta", summary["submit_to_first_delta_ms"]["p50"],
             summary["submit_to_first_delta_ms"]["p95"],
             f"max {summary['submit_to_first_delta_ms']['max']:.2f}"),
        line("delta interval (scripted 8)", summary["delta_interval_ms"]["p50"],
             summary["delta_interval_ms"]["p95"],
             f"max {summary['delta_interval_ms']['max']:.2f}"),
        line("stream total", summary["stream_ms"]["p50"], summary["stream_ms"]["max"]),
    ]
    return "\n".join(lines)


def probe(
    *,
    script: str | Path = DEFAULT_SCRIPT,
    samples: int = 20,
    through_bridge: bool = False,
    url: str | None = None,
    warmup: int = 1,
) -> tuple[list[Sample], str]:
    """Run the measurement and return the samples plus a human label for the path."""
    if url:
        return _run(url, samples + warmup)[warmup:], url

    server = ReplayServer(str(script), linger=1.0).start()
    bridge = None
    try:
        if through_bridge:
            bridge = harness.BridgeUnderTest(
                f"{server.url}{harness.GATEWAY_PATH}",
                env={"HERMES_BRIDGE_GATEWAY_URL": f"{server.url}{harness.GATEWAY_PATH}"},
            ).start()
            pairing = bridge.pair(name="latency")
            samples_out: list[Sample] = []
            for _ in range(samples + warmup):
                ticket = bridge.mint_ticket(pairing)
                samples_out.extend(_run(bridge.ws_url(ticket.ticket), 1))
            return samples_out[warmup:], f"phone → bridge → gateway (loopback, {Path(script).name})"
        return (
            _run(server.url, samples + warmup)[warmup:],
            f"gateway direct (loopback, {Path(script).name})",
        )
    finally:
        if bridge is not None:
            bridge.stop()
        server.stop()


def _run(url: str, count: int) -> list[Sample]:
    async def _all() -> list[Sample]:
        out: list[Sample] = []
        for _ in range(count):
            out.append(await sample_once(url))
        return out

    return asyncio.run(_all())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Measure the Hermes client transport")
    parser.add_argument("--script", default=str(DEFAULT_SCRIPT), help="replay scenario to serve")
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--through-bridge", action="store_true",
                        help="measure the real path through hermes_bridge")
    parser.add_argument("--url", help="measure an already-running endpoint instead")
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--csv", help="write one row per sample")
    parser.add_argument("--json", action="store_true", help="print the summary as JSON")
    args = parser.parse_args(argv)

    if args.samples < 1:
        parser.error("--samples must be >= 1")

    samples, label = probe(
        script=args.script,
        samples=args.samples,
        through_bridge=args.through_bridge,
        url=args.url,
        warmup=args.warmup,
    )
    summary = summarise(samples)

    if args.json:
        print(json.dumps({"path": label, "summary": summary,
                          "samples": [asdict(s) for s in samples]}, indent=2))
    else:
        print(format_report(summary, target=label))
        print(
            "\nloopback only: excludes WireGuard, TLS and the radio. "
            "Compare runs, do not read the absolute number as the tailnet budget."
        )

    if args.csv:
        path = Path(args.csv)
        columns = ["open_ms", "ready_ms", "ping_rtt_ms", "submit_to_first_delta_ms",
                   "delta_interval_p50_ms", "stream_ms", "deltas"]
        rows = [
            {
                "open_ms": s.open_ms,
                "ready_ms": s.ready_ms,
                "ping_rtt_ms": s.ping_rtt_ms,
                "submit_to_first_delta_ms": s.submit_to_first_delta_ms,
                "delta_interval_p50_ms": percentile(s.delta_intervals_ms, 50),
                "stream_ms": s.stream_ms,
                "deltas": s.deltas,
            }
            for s in samples
        ]
        path.write_text(",".join(columns) + "\n" + "\n".join(
            ",".join(f"{row[c]:.3f}" if isinstance(row[c], float) else str(row[c]) for c in columns)
            for row in rows
        ) + "\n", encoding="utf-8")
        print(f"\nwrote {len(rows)} rows to {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
