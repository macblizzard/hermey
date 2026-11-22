"""A sign-in answer must actually reach the page, and a refusal must say which refusal it was.

Observed live on doctolib.de: the owner answered the card, `consume` handed the values over, and the fill
was refused with `no browser connected` — the MV3 worker had slept and its socket went with it. One
sentence then covered all three faults ("either it is not connected, or the page has no field"), so the
bot could not tell a sleeping extension from a stale page. These tests pin the wait, the single retry, and
the three distinct lines.
"""

from __future__ import annotations

import importlib.util
import pathlib
import time
import types
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
CLI = ROOT / "hermeyd" / "assets" / "agent-skills" / "bin" / "hermey_signin.py"

PAGE = {
    "url": "https://www.doctolib.de/authn/patient/realms/doctolib-patient/protocol/openid-connect/auth",
    "fields": [{"name": "input_:r0:", "type": "text", "autocomplete": "username", "placeholder": ""}],
    "buttons": ["Zurück", "Weiter"],
    "usernameFields": 1,
    "passwordFields": 0,
    "otpBoxes": 0,
    "formPresent": True,
}


def load():
    spec = importlib.util.spec_from_file_location("hermey_signin_under_test", CLI)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # No real sleeping: the wait loop is what is under test, not the clock.
    module.time = types.SimpleNamespace(time=time.time, sleep=lambda _seconds: None, monotonic=time.time)
    return module


class WaitsForTheExtension(unittest.TestCase):
    def setUp(self):
        self.hs = load()

    def test_a_sleeping_extension_is_pinged_until_the_window_closes(self):
        seen = []

        def fake_call(bridge, method, path, body=None, timeout=180):
            seen.append((method, path, body))
            if path.endswith("/targets"):
                return {"browsers": []}
            raise OSError("409 no browser connected")

        self.hs._call = fake_call
        self.assertFalse(self.hs._await_browser("http://127.0.0.1:8790", seconds=0.4))
        # Both halves of the wake: a ping to bring the worker back, and /targets to see that it did.
        self.assertTrue(any(body == {"type": "ping"} for _, _, body in seen))
        self.assertTrue(any(path.endswith("/targets") for _, path, _ in seen))

    def test_it_returns_the_moment_a_target_registers(self):
        pings = []

        def fake_call(bridge, method, path, body=None, timeout=180):
            if body == {"type": "ping"}:
                pings.append(1)
                if len(pings) >= 3:
                    return {"ok": True, "ready": True}
                raise OSError("409 no browser connected")
            return {"browsers": []}

        self.hs._call = fake_call
        self.assertTrue(self.hs._await_browser("http://127.0.0.1:8790", seconds=5))
        self.assertEqual(len(pings), 3)


class RetriesOnce(unittest.TestCase):
    def setUp(self):
        self.hs = load()
        self.hs._await_browser = lambda *args, **kwargs: True
        self.hs._field_state = lambda *args, **kwargs: ("set", "username")

    def test_a_fill_that_matched_nothing_is_tried_again_on_the_same_page(self):
        fills = []

        def fake_fill(channel, values, wanted):
            fills.append(list(wanted))
            return {"ok": len(fills) > 1}

        self.hs._probe = lambda *args, **kwargs: dict(PAGE)
        self.hs._fill = fake_fill
        self.assertEqual(self.hs._deliver("http://127.0.0.1:8790", {"username": "x"}, ["username"]),
                         "filled")
        self.assertEqual(len(fills), 2)

    def test_it_does_not_fill_again_once_the_page_has_navigated(self):
        fills = []

        def fake_fill(channel, values, wanted):
            fills.append(1)
            return {"ok": False}

        pages = [dict(PAGE), dict(PAGE, url="https://www.doctolib.de/")]
        self.hs._probe = lambda *args, **kwargs: pages.pop(0) if pages else dict(PAGE)
        self.hs._fill = fake_fill
        line = self.hs._deliver("http://127.0.0.1:8790", {"username": "x"}, ["username"])
        self.assertEqual(len(fills), 1)
        self.assertIn("no field matching username", line)


class SaysWhichFailure(unittest.TestCase):
    def test_the_three_failures_read_differently_and_carry_evidence(self):
        hs = load()
        no_browser = hs._no_browser("http://127.0.0.1:8790", 20)
        no_field = hs._no_field(PAGE, ["password"])
        lost = hs._did_not_land(PAGE, "password", "empty")
        self.assertTrue(no_browser.startswith("not filled — no browser connected"))
        self.assertIn("no field matching password", no_field)
        self.assertIn("input_:r0: [text/username]", no_field)  # what the probe actually saw
        self.assertIn(PAGE["url"][:60], no_field)
        self.assertIn("now reads empty", lost)
        self.assertEqual(len({no_browser, no_field, lost}), 3)
        for line in (no_browser, no_field, lost):
            self.assertNotIn("either it is not connected", line)  # the sentence this replaced

    def test_a_field_only_counts_where_the_extension_would_fill_it(self):
        hs = load()
        self.assertTrue(hs._field_matches(PAGE, "username"))
        self.assertFalse(hs._field_matches(PAGE, "password"))
        self.assertFalse(hs._field_matches(PAGE, "one-time code"))


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
