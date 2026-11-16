#!/usr/bin/env python3
"""Static server for the Hermes app source, with caching turned off.

`python3 -m http.server` answers `If-Modified-Since` with `304 Not Modified` and sends no
`Cache-Control`, so a sideloading front end is free to keep showing the source it fetched once —
observed as "the repo still shows 1.27" while the file on disk, and every fresh curl, said 1.28.
A source that exists to announce new builds must never be cached.

Everything else is deliberately identical to `http.server`: same directory, same MIME guesses,
loopback-bound, and it is only ever reached through `tailscale serve`.
"""

from __future__ import annotations

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        # `no-store` beats revalidation: nothing may be reused without asking again.
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def send_head(self):
        # Drop any conditional request so `If-Modified-Since` cannot produce a 304.
        for header in ("If-Modified-Since", "If-None-Match"):
            if header in self.headers:
                del self.headers[header]
        return super().send_head()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--directory", default="/srv/hermes-apps-dist")
    args = parser.parse_args()

    handler = partial(NoCacheHandler, directory=args.directory)
    ThreadingHTTPServer((args.bind, args.port), handler).serve_forever()


if __name__ == "__main__":
    main()
