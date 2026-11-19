"""The fill step: a stale port must be refused, and a value must stay a value.

`DevToolsActivePort` outlives the browser that wrote it — this host had one nine days old pointing at
a port nothing was listening on. Attaching to it would either fail confusingly or, worse, reach an
unrelated process that happened to take the port. So the file is a hint, and `/json/version` is the
proof. These tests pin that, plus the two smaller traps: a value with quotes must not break out of the
generated JavaScript, and the fill must answer False rather than raise when there is no browser.
"""

from __future__ import annotations

import json
import pathlib
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

from hermes_bridge import credentials_fill as fill


class _FakeDevTools(BaseHTTPRequestHandler):
    """The two endpoints the module asks for, and nothing else."""

    def do_GET(self) -> None:  # noqa: N802 - http.server's spelling
        if self.path == "/json/version":
            body = b'{"Browser": "Chromium/1"}'
        elif self.path == "/json/list":
            body = json.dumps([{"type": "page", "webSocketDebuggerUrl": "ws://127.0.0.1:1/devtools/page/1"},
                               {"type": "service_worker"}]).encode()
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args) -> None:  # noqa: A002 - http.server's signature
        return


def _serve() -> tuple[HTTPServer, int]:
    server = HTTPServer(("127.0.0.1", 0), _FakeDevTools)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


class TestThePortIsProvenNotAssumed:
    def test_a_stale_file_is_refused(self, tmp_path: pathlib.Path) -> None:
        """The port answers nothing → None, not the number the file claims."""
        (tmp_path / "DevToolsActivePort").write_text("1\n/devtools/browser/dead-beef\n", encoding="utf-8")
        assert fill.devtools_port(tmp_path) is None

    def test_a_live_port_is_returned(self, tmp_path: pathlib.Path) -> None:
        server, port = _serve()
        try:
            (tmp_path / "DevToolsActivePort").write_text(f"{port}\n/devtools/browser/x\n", encoding="utf-8")
            assert fill.devtools_port(tmp_path) == port
        finally:
            server.shutdown()

    def test_a_missing_file_is_not_an_error(self, tmp_path: pathlib.Path) -> None:
        assert fill.devtools_port(tmp_path) is None

    def test_the_page_socket_is_chosen_over_a_worker(self) -> None:
        server, port = _serve()
        try:
            assert fill._page_socket(port) == "ws://127.0.0.1:1/devtools/page/1"
        finally:
            server.shutdown()


class TestTheValueStaysAValue:
    def test_a_quoted_value_cannot_break_the_script(self) -> None:
        nasty = 'pa"ss\\wo\nrd</script>'
        script = fill._field_expression("password", nasty)
        literal = script.split("const value = ", 1)[1].split(";\n", 1)[0]
        assert json.loads(literal) == nasty, "the value must round-trip as one JSON string literal"

    def test_the_field_selector_matches_the_card_field(self) -> None:
        assert "input[type=password]" in fill._field_expression("password", "x")
        assert "one-time-code" in fill._field_expression("one-time code", "123456")

    def test_the_script_uses_the_native_setter(self) -> None:
        """A plain `.value =` leaves React believing the field is empty — a silent failure."""
        script = fill._field_expression("password", "x")
        assert "getOwnPropertyDescriptor" in script
        assert "dispatchEvent(new Event(\"input\"" in script


class TestAFillWithoutABrowserIsAnAnswer:
    def test_no_port_means_false_not_an_exception(self, tmp_path: pathlib.Path) -> None:
        class Card:
            site = "example.test"

        assert fill.fill(Card(), {"password": "x"}, tmp_path) is False
