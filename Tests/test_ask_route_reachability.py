"""`ask` has to work from the apps, which never come from loopback.

`require_loopback` refuses anything carrying a proxy header — deliberately, so an operator command is
not advertised to the network. But the Mac and the phone reach the host through tailscale serve, so
every proxied request is refused: the desktop pet's balloon showed the host's own "not found" and could
not send anything at all.

The fix keeps the boundary and moves it to the ticket: a direct loopback call is still allowed without
one (the bundled CLI), and a proxied call is allowed only when it carries a device ticket the host
issued. Without a ticket the answer stays the same 404 as an unknown route.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BOT_MESSAGE = (ROOT / "hermeyd" / "src" / "bot_message.rs").read_text(encoding="utf-8")


def handler_body(name: str) -> str:
    start = BOT_MESSAGE.index(f"pub async fn {name}(")
    return BOT_MESSAGE[start: BOT_MESSAGE.index("\n}\n", start)]


class AskIsReachableFromAnApp(unittest.TestCase):
    def test_ask_accepts_a_device_ticket(self) -> None:
        self.assertIn("require_loopback_or_device", handler_body("post_ask"))

    def test_ask_still_refuses_an_unauthenticated_proxy(self) -> None:
        helper = BOT_MESSAGE[BOT_MESSAGE.index("fn require_loopback_or_device"):]
        helper = helper[: helper.index("\n}\n")]
        self.assertIn("require_device", helper)
        self.assertIn('bad(StatusCode::NOT_FOUND, "not found")', helper,
                      "no ticket must look exactly like an unknown route")

    def test_loopback_still_works_without_a_ticket(self) -> None:
        helper = BOT_MESSAGE[BOT_MESSAGE.index("fn require_loopback_or_device"):]
        helper = helper[: helper.index("\n}\n")]
        self.assertIn("if require_loopback(peer, headers).is_ok()", helper)

    def test_message_stays_loopback_only(self) -> None:
        # Bot-to-bot delivery is not the owner typing: widening it would be a different decision.
        self.assertIn("require_loopback(&peer, &headers)?", handler_body("post_message"))


if __name__ == "__main__":
    unittest.main()
