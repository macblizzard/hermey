"""The dock-launched browser: fill through its DevTools port, but only a port proven alive.

`docs/CREDENTIALS.md` names the DevTools port as the fallback when no extension is connected. The
port comes from a file the browser leaves behind, and that file outlives the browser that wrote it —
this host had one nine days old pointing at a port nothing listened on. So the file is a hint and
`/json/version` is the proof. These tests pin that, the JSON-literal rule that keeps a quoted
password from breaking the generated script, and the refusal to type into a page that is not the
site the card names.
"""

from __future__ import annotations

import http.server
import importlib.util
import json
import os
import pathlib
import threading
import time
import types
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLI = ROOT / "hermeyd" / "assets" / "agent-skills" / "bin" / "hermey_signin.py"

PAGE_URL = "https://www.doctolib.de/authn/patient/realms/doctolib-patient/protocol/openid-connect/auth"


def load():
    spec = importlib.util.spec_from_file_location("hermey_signin_under_test", CLI)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.time = types.SimpleNamespace(time=time.time, sleep=lambda _seconds: None, monotonic=time.time)
    return module


class _DevTools(http.server.BaseHTTPRequestHandler):
    """The two endpoints a fill asks for, and a worker target that must be skipped."""

    def do_GET(self) -> None:  # noqa: N802 - http.server's spelling
        if self.path == "/json/version":
            body = b'{"Browser": "Chromium/1"}'
        elif self.path == "/json/list":
            body = json.dumps(
                [
                    {"type": "service_worker"},
                    {"type": "page", "url": PAGE_URL,
                     "webSocketDebuggerUrl": "ws://127.0.0.1:1/devtools/page/1"},
                ]
            ).encode()
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


def serve() -> tuple[http.server.HTTPServer, int]:
    server = http.server.HTTPServer(("127.0.0.1", 0), _DevTools)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


class ThePortIsProvenNotAssumed(unittest.TestCase):
    def setUp(self):
        self.hs = load()

    def test_a_stale_port_file_is_refused(self):
        """The file names a port; nothing answers there; that is not an endpoint."""
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "DevToolsActivePort"
            path.write_text("1\n/devtools/browser/dead-beef\n", encoding="utf-8")
            with mock.patch.dict(os.environ, {"HERMEY_CDP_FILE": str(path)}, clear=False):
                self.hs._cdp_port_files = lambda: []
                os.environ.pop("HERMEY_CDP_PORT", None)
                self.assertIsNone(self.hs._cdp_base())

    def test_a_missing_file_is_not_an_error(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(
                os.environ, {"HERMEY_CDP_FILE": str(pathlib.Path(tmp) / "absent")}, clear=False
            ):
                self.hs._cdp_port_files = lambda: []
                os.environ.pop("HERMEY_CDP_PORT", None)
                self.assertIsNone(self.hs._cdp_base())

    def test_a_live_endpoint_is_used(self):
        import tempfile

        server, port = serve()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                path = pathlib.Path(tmp) / "DevToolsActivePort"
                path.write_text(f"{port}\n/devtools/browser/x\n", encoding="utf-8")
                with mock.patch.dict(os.environ, {"HERMEY_CDP_FILE": str(path)}, clear=False):
                    self.hs._cdp_port_files = lambda: []
                    os.environ.pop("HERMEY_CDP_PORT", None)
                    self.assertEqual(self.hs._cdp_base(), f"http://127.0.0.1:{port}")
        finally:
            server.shutdown()


class TheValueStaysAValue(unittest.TestCase):
    def setUp(self):
        self.hs = load()

    def test_a_quoted_value_cannot_break_the_script(self):
        nasty = 'pa"ss\\wo\nrd</script>'
        payload = self.hs._fill_payload({"password": nasty}, ["password"])
        script = self.hs._fill_js(payload)
        literal = script.split("const wanted = ", 1)[1].split(";\n", 1)[0]
        self.assertEqual(json.loads(literal)[0]["value"], nasty)

    def test_the_script_uses_the_native_setter(self):
        """A plain `.value =` leaves React believing the field is empty — a silent failure."""
        script = self.hs._fill_js(self.hs._fill_payload({"password": "x"}, ["password"]))
        self.assertIn("getOwnPropertyDescriptor", script)
        self.assertIn('dispatchEvent(new Event("input"', script)

    def test_the_selector_matches_the_field_a_card_names(self):
        payload = self.hs._fill_payload(
            {"password": "x", "one-time code": "123456", "username": "me"}, ["password", "username"]
        )
        self.assertEqual(payload[0]["selector"], "input[type=password]")
        self.assertNotIn("one-time code", [item["name"] for item in payload])
        self.assertIn("input[name*=user i]", payload[1]["selector"])


class RefusesAPageThatIsNotTheSite(unittest.TestCase):
    def setUp(self):
        self.hs = load()

    def test_no_endpoint_means_no_fallback_and_no_exception(self):
        self.hs._cdp_base = lambda: None
        self.assertIsNone(self.hs._cdp_fill("doctolib.de", {"password": "x"}, ["password"]))

    def test_a_page_for_another_site_is_named_not_typed_into(self):
        server, port = serve()
        try:
            self.hs._cdp_base = lambda: f"http://127.0.0.1:{port}"

            def forbidden(*_args, **_kwargs):
                raise AssertionError("nothing may be typed into a page for another site")

            self.hs._ws_eval = forbidden
            line = self.hs._cdp_fill("example.test", {"password": "hunter2"}, ["password"])
            self.assertIn("not filled", line)
            self.assertIn("is showing", line)
            self.assertIn(PAGE_URL[:60], line)
            self.assertNotIn("hunter2", line)
        finally:
            server.shutdown()


class SaysWhetherTheDevToolsFillLanded(unittest.TestCase):
    """`filled` must mean the page still holds it — a script that ran is not a fill."""

    def setUp(self):
        self.hs = load()
        self.hs._cdp_base = lambda: "http://127.0.0.1:1"
        self.hs._cdp_pages = lambda base: [
            {"type": "page", "url": PAGE_URL, "webSocketDebuggerUrl": "ws://127.0.0.1:1/devtools/page/1"}
        ]
        self.hs._ws_eval = lambda url, script: {"filled": ["password"], "missing": []}

    def test_a_value_the_page_kept_reads_as_filled(self):
        self.hs._field_state = lambda page, wanted: ("set", "password")
        line = self.hs._cdp_fill("doctolib.de", {"password": "hunter2"}, ["password"])
        self.assertEqual(line, "filled (the DevTools port; no extension was connected)")

    def test_a_value_the_page_dropped_is_named_not_called_filled(self):
        self.hs._field_state = lambda page, wanted: ("empty", "password")
        line = self.hs._cdp_fill("doctolib.de", {"password": "hunter2"}, ["password"])
        self.assertIn("did not land", line)
        self.assertIn("now reads empty", line)
        self.assertNotIn("hunter2", line)

    def test_a_click_keeps_the_scripts_word_because_there_is_no_field_to_read(self):
        self.hs._ws_eval = lambda url, script: {"filled": ["choice"], "missing": []}

        def forbidden(*_args, **_kwargs):
            raise AssertionError("a choice click has no field to verify")

        self.hs._field_state = forbidden
        line = self.hs._cdp_fill("doctolib.de", {"choice": "Continue with Google"}, ["choice"])
        self.assertTrue(line.startswith("filled"))


class FallsBackOnlyAfterTheExtensionIsGivenItsChance(unittest.TestCase):
    def setUp(self):
        self.hs = load()

    def test_the_devtools_answer_is_the_one_reported(self):
        self.hs._await_browser = lambda *args, **kwargs: False
        self.hs._cdp_fill = lambda site, values, wanted: "filled (the DevTools port; no extension was connected)"
        line = self.hs._deliver("http://127.0.0.1:8790", {"password": "x"}, ["password"], "doctolib.de")
        self.assertEqual(line, "filled (the DevTools port; no extension was connected)")

    def test_without_a_devtools_endpoint_the_refusal_still_says_no_browser(self):
        self.hs._await_browser = lambda *args, **kwargs: False
        self.hs._cdp_fill = lambda site, values, wanted: None
        line = self.hs._deliver("http://127.0.0.1:8790", {"password": "x"}, ["password"], "doctolib.de")
        self.assertTrue(line.startswith("not filled — no browser connected"))


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
