"""Reply notifications: one decision, two deliveries, and a badge that tells the truth.

The decision is `ReplyNotificationPolicy`'s and the model asks it once. Each platform then only
delivers: `UNUserNotificationCenter` on macOS and iOS, a Dock tile on the Mac, an icon badge on
both. Nothing here can be unit-tested on Linux — the shells are app targets — so the wiring is
pinned from source, the way the other cross-platform guards are.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
POLICY = (ROOT / "Sources" / "HermesAppKit" / "ReplyNotifications.swift").read_text(encoding="utf-8")
MAC_NOTIFIER = (ROOT / "Apps" / "HermesMac" / "Support" / "ReplyNotifier.swift").read_text(encoding="utf-8")
MAC_ROOT = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
MAC_SETTINGS = (ROOT / "Apps" / "HermesMac" / "Views" / "NotificationsSettingsTab.swift").read_text(encoding="utf-8")
IOS_NOTIFIER = (ROOT / "Apps" / "HermesMobile" / "App" / "ReplyNotifications.swift").read_text(encoding="utf-8")
IOS_APP = (ROOT / "Apps" / "HermesMobile" / "HermesMobileApp.swift").read_text(encoding="utf-8")
IOS_ENV = (ROOT / "Apps" / "HermesMobile" / "App" / "AppEnvironment.swift").read_text(encoding="utf-8")
IOS_SETTINGS = (ROOT / "Apps" / "HermesMobile" / "Views" / "SettingsScreen.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "project.yml").read_text(encoding="utf-8")


class TheDecisionLivesInOnePlace(unittest.TestCase):
    def test_the_model_asks_the_policy(self) -> None:
        body = MODEL.split("private func raiseReplyNotification", 1)[1].split("\n    }", 1)[0]
        self.assertIn("ReplyNotificationPolicy.shouldDeliver", body)

    def test_neither_shell_decides_for_itself(self) -> None:
        # A shell that filters on its own is how the two apps start disagreeing about the same
        # reply; both must be delivery-only.
        for name, source in (("macOS", MAC_NOTIFIER), ("iOS", IOS_NOTIFIER)):
            self.assertNotIn("shouldDeliver", source,
                             f"{name} decided whether to notify instead of asking the policy")

    def test_the_bot_on_screen_is_excluded(self) -> None:
        self.assertIn("guard botID != visibleBotID else { markRead(botID, at: date); return }", MODEL)
        self.assertIn("guard botID != visibleBotID else { return false }", POLICY)

    def test_a_reply_is_announced_once(self) -> None:
        # The same message arrives through the previews sweep and, for the open session, a
        # completion: two doors, one banner.
        self.assertIn("notifiedIdentities", MODEL)
        self.assertIn("guard !notifiedIdentities.contains(note.identity) else { return }", MODEL)

    def test_the_badge_counts_bots_and_rooms(self) -> None:
        self.assertIn("ReplyNotificationPolicy.badge(unread: unreadCounts, rooms: roomUnreadCounts)",
                      MODEL)
        self.assertIn("let rooms = rooms.values.reduce(0)", POLICY)

    def test_a_clock_sweeps_while_the_window_sits_in_one_chat(self) -> None:
        # Without this the model only looked at the host when the list appeared, so nine bots
        # replying under one open conversation raised nothing at all.
        self.assertIn("public static let unreadSweepInterval", MODEL)
        sweep = MODEL.split("public func startUnreadSweep()", 1)[1].split("\n    }", 1)[0]
        self.assertIn("loadBotPreviews()", sweep)
        self.assertIn("connection.isLive", sweep, "a dead socket must not be polled")
        # Started by both doors into the wire, and stopped with it.
        self.assertIn("startUnreadSweep()\n        } catch", MODEL)
        self.assertIn("startUnreadSweep()\n            //", MODEL)
        self.assertIn("unreadSweepTask?.cancel()", MODEL)


class TheMacDelivers(unittest.TestCase):
    def test_banners_are_posted_not_swallowed(self) -> None:
        self.assertIn("UNUserNotificationCenter.current()", MAC_NOTIFIER)
        self.assertIn("completionHandler([.banner, .list, .sound])", MAC_NOTIFIER,
                      "a frontmost app must still show the banner: the reply is in another chat")

    def test_the_dock_tile_carries_the_count(self) -> None:
        self.assertIn("NSApp.dockTile.badgeLabel = count > 0 ? \"\\(count)\" : nil", MAC_NOTIFIER)

    def test_a_tap_opens_that_bot(self) -> None:
        self.assertIn("onOpenBot", MAC_NOTIFIER)
        self.assertIn("ReplyNotifier.shared.onOpenBot = { botID in store.selectBot(botID) }", MAC_ROOT)

    def test_the_shell_keeps_the_badge_current(self) -> None:
        self.assertIn(".onChange(of: store.model.badgeCount) { _, count in", MAC_ROOT)
        self.assertIn("ReplyNotifier.shared.updateBadge(count)", MAC_ROOT)

    def test_settings_reports_a_denied_permission(self) -> None:
        self.assertIn("x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                      MAC_SETTINGS)
        self.assertIn("Turned off in System Settings", MAC_SETTINGS)


class ThePhoneDelivers(unittest.TestCase):
    def test_the_shell_does_not_buzz_over_the_app(self) -> None:
        body = IOS_NOTIFIER.split("func post(_ note: ReplyNotification)", 1)[1].split("\n    }", 1)[0]
        self.assertIn("guard UIApplication.shared.applicationState != .active else", body)

    def test_the_icon_badge_is_set(self) -> None:
        self.assertIn("setBadgeCount", IOS_NOTIFIER)

    def test_the_background_refresh_is_registered_before_launch_returns(self) -> None:
        self.assertIn("ReplyBackgroundRefresh.register()", IOS_APP)
        init = IOS_APP.split("struct HermesMobileApp: App {", 1)[1].split("var body", 1)[0]
        self.assertIn("ReplyBackgroundRefresh.register()", init,
                      "registration after launch is refused, and the app never wakes")

    def test_the_registered_identifier_is_the_one_the_bundle_permits(self) -> None:
        identifier = re.search(r'taskIdentifier = "([^"]+)"', IOS_NOTIFIER)
        assert identifier is not None, "the refresh no longer names a task identifier"
        self.assertTrue(f"- {identifier.group(1)}" in PROJECT,
                        "iOS silently refuses a request for an identifier the bundle does not list")
        self.assertIn("UIBackgroundModes:", PROJECT)
        self.assertIn("- fetch", PROJECT)

    def test_only_the_announced_marks_are_written_by_the_refresh(self) -> None:
        # Writing `lastRead` from a background refresh would mark messages read that nobody read.
        self.assertIn("hermey.notified.", IOS_NOTIFIER)
        self.assertIn("persistNotified", IOS_NOTIFIER)
        self.assertNotIn('set(marks, forKey: "hermey.lastRead.', IOS_NOTIFIER)

    def test_the_sink_and_the_tap_are_wired(self) -> None:
        self.assertIn("model.replyNotificationSink = { note in", IOS_ENV)
        self.assertIn("openBotRequest", IOS_ENV)
        self.assertIn("path.append(bot)", IOS_APP)

    def test_settings_offers_the_system_door(self) -> None:
        self.assertIn("UIApplication.openSettingsURLString", IOS_SETTINGS)


class BothSwitchesComeFromTheModel(unittest.TestCase):
    def test_the_platform_toggle_is_stored_not_view_local(self) -> None:
        self.assertIn("func setReplyNotifications(enabled:", MODEL)
        self.assertIn("model.setReplyNotifications(enabled: $0)", MAC_SETTINGS)
        self.assertIn("model.setReplyNotifications(enabled: $0)", IOS_SETTINGS,
                      "a toggle stored per view would let the two apps disagree")

    def test_a_quieted_bot_is_honoured_on_both(self) -> None:
        self.assertIn("toggleNotificationMute", MODEL)
        self.assertIn("toggleNotificationMute", MAC_SETTINGS)
        self.assertIn("toggleNotificationMute", IOS_SETTINGS + IOS_SETTINGS)


if __name__ == "__main__":
    unittest.main()
