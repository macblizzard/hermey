"""``python -m hermes_bridge`` -- the only supported way to start the bridge.

The bind address is validated before uvicorn sees it. A bridge on anything but
loopback is refused outright: ``tailscale serve`` is the TLS/tailnet boundary,
and an directly-exposed bridge would be an unauthenticated control channel for a
host that can run shell commands.
"""

from __future__ import annotations

import argparse
import logging
import sys
from dataclasses import replace
from typing import Optional, Sequence

from .app import create_app
from .config import BridgeConfig, ConfigError


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="hermes-bridge", description=__doc__)
    parser.add_argument("--host", help="bind host (loopback only)")
    parser.add_argument("--port", type=int, help="bind port")
    parser.add_argument("--db", help="device registry SQLite path")
    parser.add_argument("--gateway-url", help="ws:// URL of the local Hermes gateway")
    parser.add_argument("--log-level", default="INFO")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)

    try:
        config = BridgeConfig.from_env()
        changes = {}
        if args.host:
            changes["bind_host"] = args.host
        if args.port:
            changes["bind_port"] = args.port
        if args.db:
            from pathlib import Path

            changes["db_path"] = Path(args.db).expanduser()
        if args.gateway_url:
            changes["gateway_url"] = args.gateway_url
        if changes:
            config = replace(config, **changes)
        config.validate()
    except ConfigError as exc:
        print(f"hermes-bridge: refusing to start: {exc}", file=sys.stderr)
        return 2

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    if not config.gateway_token:
        logging.getLogger("hermes_bridge").warning(
            "no HERMES_BRIDGE_GATEWAY_TOKEN set; the local gateway must be unauthenticated"
        )

    import uvicorn

    app = create_app(config)
    print(
        f"hermes-bridge: listening on ws://{config.bind_host}:{config.bind_port}/v1/ws "
        f"(loopback only), gateway={config.safe_gateway_url()}, db={config.db_path}",
        file=sys.stderr,
    )
    uvicorn.run(
        app,
        host=config.bind_host,
        port=config.bind_port,
        log_level="warning",
        # Access logs would print the WS ticket in the query string.
        access_log=False,
        # One message cannot exceed the frame cap; the proxy enforces the same
        # limit per frame for newline batches.
        ws_max_size=config.frame_cap,
        ws_ping_interval=20,
        ws_ping_timeout=20,
    )
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
