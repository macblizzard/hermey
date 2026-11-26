"""A banner wears the face the bot actually has: its drawn avatar, not the shape it retired.

The gap: `PushIcon` rasterised `BotAvatarStill` — the shape-and-palette face — so a bot that had
saved a generated avatar still appeared on a banner, in the notification list and on the icon the
host hands to the relay wearing its *previous* face. `BotAvatarView` had learned to pick the drawn
branch; the offscreen path had not.

The contract this file pins:

* **the drawn avatar is asked first** on every banner icon, through one reusable renderer
  (`BotAvatarIcon`) that draws the same `OpenBotAvatarRenderer` the roster does, at rest;
* **a bot without a definition is unchanged** — the same `BotAvatarStill` on the same plate;
* **a definition that cannot be drawn falls back to the shape face**, logged, never to a blank;
* **the cache is per bot, size, material, colour and body**, and is invalidated on a save and on a
  clear in both apps, so the face a bot no longer wears cannot be served;
* **posting a notification renders nothing** — the attachment is a file read, on both platforms.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
ICON = UI / "BotAvatarIcon.swift"
PUSH = UI / "PushIcon.swift"
MAC_CACHE = ROOT / "Apps" / "HermesMac" / "Support" / "MacFaceCache.swift"
MAC_NOTIFIER = ROOT / "Apps" / "HermesMac" / "Support" / "ReplyNotifier.swift"
MAC_STORE = ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift"
MAC_ROOT = ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift"
PHONE_CACHE = ROOT / "Apps" / "HermesMobile" / "App" / "MobileFaceCache.swift"
PHONE_ENV = ROOT / "Apps" / "HermesMobile" / "App" / "AppEnvironment.swift"
PHONE_SHELL = ROOT / "Apps" / "HermesMobile" / "HermesMobileApp.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def swift_files() -> list[Path]:
    return sorted(p for p in ROOT.rglob("*.swift") if "/.build/" not in str(p))


def call_arguments(text: str, marker: str) -> list[str]:
    """The argument text of every `marker(` call, parentheses balanced."""
    found: list[str] = []
    for match in re.finditer(r"(?<![A-Za-z])" + re.escape(marker), text):
        start = match.end() - 1
        depth = 0
        for index in range(start, len(text)):
            if text[index] == "(":
                depth += 1
            elif text[index] == ")":
                depth -= 1
                if depth == 0:
                    found.append(text[start + 1:index])
                    break
    return found


def function_body(text: str, marker: str) -> str:
    """The balanced `{ … }` body of the declaration whose text starts at `marker`."""
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening:index + 1]
    raise AssertionError(f"unbalanced body for {marker}")


class TheDrawnAvatarIsAskedFirst(unittest.TestCase):
    def test_push_icon_renders_the_definition_before_the_shape(self) -> None:
        push = read(PUSH)
        drawn = push.index("if let avatar {")
        fallback = push.index("return shapePNG(for: botID, color: color)")
        self.assertLess(drawn, fallback, "the shape face is reached before the drawn one")
        self.assertIn("BotAvatarIcon.png(for: botID, avatar: avatar, size: size)", push)
        self.assertIn("return drawn", push)

    def test_the_renderer_is_one_shared_function_beside_the_avatar(self) -> None:
        icon = read(ICON)
        self.assertIn("public enum BotAvatarIcon", icon)
        self.assertIn("public static func png(for botID: String,", icon)
        # The same drawing the roster uses — not a second copy of the definition.
        self.assertIn("OpenBotAvatarRenderer.draw(model,", icon)
        self.assertIn("OpenBotAvatarModel.model(for: avatar.definition)", icon)
        self.assertIn("avatar.material", icon)
        self.assertIn("avatar.color", icon)
        # Offscreen, so no timeline and no animated view can be sampled (they render blank).
        self.assertNotIn("TimelineView(", icon)
        self.assertNotIn("BotAvatarView(", icon)
        self.assertNotIn("BotAvatarStill(", icon)
        self.assertIn("ImageRenderer(content:", icon)

    def test_the_render_is_the_rest_pose_and_never_animates(self) -> None:
        icon = read(ICON)
        self.assertIn("OpenBotAvatarState.idle.pose(", icon)
        self.assertIn("time: 0", icon)
        self.assertIn("reducedMotion: true", icon)
        # The eye catchlight stays the material plan's own size rule (it is off below 64 pt); the
        # icon must not force it on at a small size.
        self.assertNotIn("catchlight:", icon)


class EveryIconPathPassesTheDefinition(unittest.TestCase):
    def test_no_call_site_builds_a_banner_icon_without_the_avatar(self) -> None:
        sites = 0
        for path in swift_files():
            for arguments in call_arguments(read(path), "PushIcon.png("):
                sites += 1
                self.assertIn("avatar:", arguments,
                              f"{path.relative_to(ROOT)} builds a banner icon without the definition")
        # Phone cache, phone shell, Mac cache, Mac shell.
        self.assertGreaterEqual(sites, 4, "the icon is built in fewer places than this found")

    def test_both_banner_caches_hand_over_the_stored_avatar(self) -> None:
        for path in (MAC_CACHE, PHONE_CACHE):
            with self.subTest(cache=path.relative_to(ROOT)):
                body = function_body(read(path), "static func refresh(faces:")
                self.assertIn("avatar: avatars[botID],", body)
                # A bot with an avatar but no stored shape still gets a picture.
                self.assertIn("Set(faces.keys).union(avatars.keys)", body)


class ABotWithoutADefinitionKeepsItsFace(unittest.TestCase):
    def test_the_shape_face_is_the_same_view_and_plate(self) -> None:
        shape = function_body(read(PUSH), "static func shapePNG(for botID: String, color: String?)")
        self.assertIn("BotAvatarStill(identity: botID", shape)
        self.assertIn("size * 0.76", shape)
        self.assertIn("cornerRadius: size * 0.2237", shape)
        self.assertIn("Tokens.surfaceRaised, Tokens.surface", shape)

    def test_the_drawn_document_wins_over_the_call_site_colour(self) -> None:
        # A bot with a definition is never repainted by a stale `bots.color`: the document carries
        # its own colour and material, and `BotAvatarIcon` reads those.
        icon = read(ICON)
        self.assertIn("avatar.color", icon)
        self.assertIn("avatar.material", icon)
        push = read(PUSH)
        self.assertIn("if let avatar {", push)


class TheFallbackIsLoggedNotBlank(unittest.TestCase):
    def test_an_unrenderable_definition_returns_the_shape_face(self) -> None:
        icon = read(ICON)
        self.assertIn('ClientLog.note("avatar icon: \\(botID)\'s definition cannot be drawn', icon)
        self.assertIn('ClientLog.note("avatar icon: \\(botID)\'s face rendered no image', icon)
        push = read(PUSH)
        # The drawn attempt falling through is immediately the shape path, not a nil answer.
        self.assertIn("if let drawn = BotAvatarIcon.png(for: botID, avatar: avatar, size: size)",
                      push)
        self.assertIn("return shapePNG(for: botID, color: color)", push)
        self.assertIn('ClientLog.note("push icon: \\(botID) has a definition that did not render', push)


class TheCacheIsCheapAndInvalidated(unittest.TestCase):
    def test_the_key_carries_bot_size_material_and_body(self) -> None:
        icon = read(ICON)
        key = function_body(icon, "static func cacheKey(botID: String")
        for part in ("botID,", "avatar.material.rawValue", "String(Int(size.rounded()))",
                     "avatar.definition.body.path", "avatar.color ?? \"-\""):
            with self.subTest(part=part):
                self.assertIn(part, key)

    def test_a_save_and_a_clear_invalidate_the_icon(self) -> None:
        # Both stores do it inside `saveBotAvatar`, which is also the clear (document: nil).
        for path, cache in ((MAC_STORE, "MacFaceCache"), (PHONE_ENV, "MobileFaceCache")):
            with self.subTest(store=path.name):
                save = function_body(read(path), "func saveBotAvatar(")
                self.assertIn(f"{cache}.invalidate(botID: botID)", save)
                self.assertIn(f"await {cache}.refresh(", save)
                # The relay's copy (what a Bark banner actually shows) is refreshed in the same
                # breath, so a suspended app cannot be shown the face the bot just retired.
                self.assertIn("model.syncPushIcons", save)
                self.assertIn("PushRelay.urlKey", save)
        # And each cache drops the renderer's bytes when it drops its file.
        for path in (MAC_CACHE, PHONE_CACHE):
            with self.subTest(cache=path.name):
                invalidate = function_body(read(path), "static func invalidate(botID: String)")
                self.assertIn("PushIcon.invalidate(botID: botID)", invalidate)

    def test_the_renderer_remembers_one_face_per_key(self) -> None:
        icon = read(ICON)
        self.assertIn("private static var cache: [String: Data]", icon)
        self.assertIn("cache[key] = data", icon)
        self.assertIn("if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }", icon)


class PostingANotificationRendersNothing(unittest.TestCase):
    def test_the_mac_attachment_is_a_file_read(self) -> None:
        attachment = function_body(read(MAC_CACHE), "static func attachment(for botID: String)")
        for forbidden in ("PushIcon", "ImageRenderer", "write(to:"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, attachment)
        self.assertIn("UNNotificationAttachment(", attachment)

    def test_the_phone_attachment_is_a_file_read(self) -> None:
        attachment = function_body(read(PHONE_CACHE), "static func attachment(for botID: String)")
        for forbidden in ("PushIcon", "ImageRenderer", "write(to:"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, attachment)

    def test_the_post_itself_draws_nothing(self) -> None:
        post = function_body(read(MAC_NOTIFIER), "func post(_ note: ReplyNotification)")
        self.assertNotIn("PushIcon", post)
        self.assertNotIn("ImageRenderer", post)
        self.assertIn("content.attachments = [face]", post)

    def test_the_draw_happens_in_the_prefetch_sweeps(self) -> None:
        self.assertIn("static func refresh(faces: [String: BotFaceChoice],",
                      read(MAC_CACHE))
        self.assertIn("static func refresh(faces: [String: BotFaceChoice],",
                      read(PHONE_CACHE))
        # The Mac fills the cache even when no relay is registered: a local banner reads it too.
        root = read(MAC_ROOT)
        sweep = function_body(root, "private func uploadPushFaces()")
        self.assertIn("await MacFaceCache.refresh(faces: store.botFaces, avatars: store.botAvatars)", sweep)
        self.assertLess(sweep.index("MacFaceCache.refresh"), sweep.index("PushRelay.urlKey"),
                        "the banner cache is skipped when no relay is registered")


class TheHostServesWhatTheAppRendered(unittest.TestCase):
    """The relay path: the host only stores the bytes the app uploaded, so the fix is app-side."""

    def test_the_get_handler_serves_a_stored_file(self) -> None:
        icons = read(ROOT / "hermeyd" / "src" / "parity_gaps.rs")
        handler = function_body(icons, "pub async fn push_icon_get(")
        self.assertIn("read_icon(&st, name)", handler)
        for forbidden in ("avatar", "render", "OpenBot"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, handler)

    def test_the_relay_icon_url_points_at_the_uploaded_png(self) -> None:
        push = read(ROOT / "hermeyd" / "src" / "push.rs")
        self.assertIn("/v1/push/icon", push)
        self.assertIn("path.is_file()", push)


if __name__ == "__main__":
    unittest.main()
