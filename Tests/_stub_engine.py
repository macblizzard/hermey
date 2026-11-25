"""A stand-in for the Hermes engine's `/api/ws`, for `test_reaction_route_live.py`.

The host service's app-facing socket relays the engine, so a scratch service needs *something* to
attach to before it will hold two devices' sockets open. This says `gateway.ready` once and then
keeps the connection, which is all the relay needs.
"""
import asyncio
import json
import sys

READY = json.dumps({"jsonrpc": "2.0", "method": "event",
                    "params": {"type": "gateway.ready", "session_id": "", "payload": {}}})


async def handler(ws):
    await ws.send(READY)
    try:
        async for _ in ws:
            pass
    except Exception:
        pass


async def main(port):
    import websockets
    async with websockets.serve(handler, "127.0.0.1", port, max_size=None):
        await asyncio.Future()


asyncio.run(main(int(sys.argv[1])))
