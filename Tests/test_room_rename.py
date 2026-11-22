"""Renaming a group chat must actually reach the host.

The Rename item existed on both platforms and the whole UI chain was wired — the sidebar's inline
editor, `model.requestRename`, `GroupChatViews.consumeRenameSignal`, `AppModel.renameRoom` (which even
updated the list optimistically) — but the client's protocol default for `renameRoom` was `{}`, an empty
body. So the editor closed, the row kept its old name, and no RPC was ever sent.

The host was never the problem: `hermeyd` has `POST /v1/rooms/{room_id}/rename` (rooms.rs) which validates
the name and calls the engine's `groups.rename`. This file keeps the last link honest.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROOMS = (ROOT / "Sources" / "HermesKit" / "Rooms.swift").read_text(encoding="utf-8")
APP_MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
SIDEBAR = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
MOBILE_LIST = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
CLIENT = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text(encoding="utf-8")


class TheClientSendsTheRename(unittest.TestCase):
    def test_the_bridge_pointer_posts_the_rename_route(self) -> None:
        # There is more than one `renameRoom` in this file (another store sends `trimmed`), so assert the
        # route and a name field are present rather than pinning one body's exact wording.
        self.assertIn('v1/rooms/\\(roomID)/rename', ROOMS,
                      "the bridge pointer must post the host's rename route")
        self.assertTrue('"name": name' in ROOMS or '"name": trimmed' in ROOMS,
                        "the body must carry the new name")

    def test_the_actor_delegates_to_the_pointer(self) -> None:
        self.assertIn("func renameRoom(_ roomID: String, name: String) async throws", CLIENT)
        self.assertIn("sessionPointer.renameRoom(roomID, name: name)", CLIENT)


class BothPlatformsOfferIt(unittest.TestCase):
    def test_macos_sidebar_has_the_entry_point(self) -> None:
        self.assertIn("model.requestRename(room.id)", SIDEBAR)

    def test_ios_list_has_the_entry_point(self) -> None:
        self.assertIn("model.requestRename(room.id)", MOBILE_LIST)

    def test_the_model_refreshes_after_renaming(self) -> None:
        body = APP_MODEL[APP_MODEL.index("public func renameRoom(_ roomID: String, to name: String)"):]
        body = body[: body.index("\n    }")]
        self.assertIn("client.renameRoom(roomID, name: trimmed)", body)
        self.assertIn("refreshRooms()", body, "the optimistic row must be reconciled with the host")


if __name__ == "__main__":
    unittest.main()
