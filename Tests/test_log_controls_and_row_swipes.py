"""The log sheet's two controls, and the two swipe verbs on a bot row.

Both were asked for on 2026-11-15 in the same breath: "inside view logs need a log refresh button and
a view button with options like newer first or newer last", and "swipe left on bot names … should
show option to pin the bot, and swipe right should show option to set as unread, for bot use just
icons and no labels".

Pinned here as shapes rather than pixels: the sheet re-reads without closing and remembers its
order; the row's swipes are icon-only and map left to pin and right to unread.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOG = (ROOT / "Sources" / "HermeyUI" / "ClientLogView.swift").read_text(encoding="utf-8")
MODEL_LOG = (ROOT / "Sources" / "HermesKit" / "ClientLog.swift").read_text(encoding="utf-8")
IOS_LIST = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")


class TheLogCanBeReReadAndReversed(unittest.TestCase):
    def test_refresh_reads_the_log_again_without_closing(self) -> None:
        self.assertIn('Label("Refresh", systemImage: "arrow.clockwise")', LOG)
        # The same reload the sheet runs on appear — not a dismissal that reopens the view.
        self.assertIn("feed.reload()", LOG)
        self.assertNotIn('dismiss()\n                        .onAppear', LOG)

    def test_the_order_is_a_persisted_choice_with_both_ends_named(self) -> None:
        # Build 442 offered "Newest first / Newest last" — two options one word apart — and a menu
        # that showed its selection only while it was open. The choice is now an enum whose two
        # cases name opposite ends, a segmented control that shows which one is on, and the order
        # itself is applied by the model.
        self.assertIn("@AppStorage(ClientLogOrder.storageKey)", LOG)
        self.assertIn("ClientLogOrder(rawValue: storedOrder)", LOG)
        self.assertIn(".pickerStyle(.segmented)", LOG)
        self.assertIn("ClientLogQuery(order: order, level: levelFilter", LOG)
        # `entries` in file order is the storage, not the view.
        self.assertIn("query.apply(to: feed.entries)", LOG)
        self.assertNotIn("ForEach(entries)", LOG)
        # The comparator and the two titles live where they can be unit-tested.
        self.assertIn('case .newestFirst: return Array(entries.reversed())', MODEL_LOG)
        self.assertIn('case .newestFirst: return "Newest first"', MODEL_LOG)
        self.assertIn('case .oldestFirst: return "Oldest first"', MODEL_LOG)

    def test_the_default_is_the_order_the_sheet_always_had(self) -> None:
        # Nothing stored, no legacy Bool set: newest last, oldest first — what a reader of this
        # sheet knows.
        self.assertIn("return ClientLogOrder.stored()", LOG)
        self.assertIn("public static func stored(in defaults: UserDefaults = .standard) -> ClientLogOrder",
                      MODEL_LOG)
        self.assertIn("? .newestFirst : .oldestFirst", MODEL_LOG)

    def test_the_order_control_follows_the_newest_line(self) -> None:
        # Acceptance: flipping the order keeps the reader on the newest entry, so the change is
        # visible instead of leaving them mid-list at an offset that no longer means anything.
        self.assertIn("proxy.scrollTo(id, anchor: anchor)", LOG)
        self.assertIn(".onChange(of: order)", LOG)

    def test_the_live_tail_and_the_entry_count_are_controls_not_side_effects(self) -> None:
        # The phone and the Mac both get every option: pause, search, level, category, count.
        self.assertIn("log.observe", LOG)
        self.assertIn('Image(systemName: feed.isLive ? "pause.fill" : "play.fill")', LOG)
        self.assertIn('TextField("Search the log"', LOG)
        self.assertIn('Text("All levels")', LOG)
        self.assertIn('Text("All categories")', LOG)
        # The count line is also where a copy's receipt appears, and where it reverts to the count:
        # one 1.6-second message in a spot the sheet already has, not a row that appears and pushes
        # the list down.
        self.assertIn("Text(copiedNotice ?? countLine)", LOG)

    def test_both_apps_present_the_same_view(self) -> None:
        # The parity fix: one presentation, reached from two places. A second, Mac-only log list is
        # what let the two drift apart in the first place.
        for host in (ROOT / "Apps" / "HermesMobile" / "Views" / "SettingsScreen.swift",
                     ROOT / "Apps" / "HermesMac" / "Views" / "AboutSettingsTab.swift"):
            self.assertIn('ClientLogView(title: "Log"', host.read_text(encoding="utf-8"))
        viewers = [path for path in (ROOT / "Apps").rglob("*.swift")
                   if "ClientLogEntry" in path.read_text(encoding="utf-8")]
        self.assertEqual(viewers, [], "no app-side copy of the log list; the sheet is shared")


class TheRowSwipesAreIconsOnly(unittest.TestCase):
    def setUp(self) -> None:
        self.row = IOS_LIST.split("private func row(for bot: Bot) -> some View", 1)[1]

    def test_left_swipe_pins_and_right_swipe_marks_unread(self) -> None:
        trailing = self.row.split(".swipeActions(edge: .trailing", 1)[1].split("}", 3)[0]
        leading = self.row.split(".swipeActions(edge: .leading", 1)[1].split("}", 3)[0]
        self.assertIn("togglePin(botID: bot.id)", trailing)
        self.assertIn("markUnread(bot.id)", leading)

    def test_the_reveals_carry_no_words(self) -> None:
        # A `Label` in a swipe action prints its title under the glyph. These are Images with an
        # accessibility label, so the row reveals one icon and VoiceOver still reads the verb.
        swipes = self.row.split(".swipeActions(edge: .trailing", 1)[1]
        swipes = swipes.split(".accessibilityLabel(accessibilityLabel(for: bot))", 1)[0]
        # `accessibilityLabel(` is not `Label(`: the glyph-only rule is about the visible label.
        self.assertIsNone(re.search(r"(?<![\w.])Label\(", swipes))
        self.assertIn('Image(systemName: model.isPinned(botID: bot.id) ? "pin.slash.fill" : "pin.fill")', swipes)
        self.assertIn('Image(systemName: "circle.badge.exclamationmark.fill")', swipes)
        self.assertIn('accessibilityLabel("Mark unread")', swipes)


class MarkUnreadIsAReminderNotAMeasurement(unittest.TestCase):
    def setUp(self) -> None:
        self.body = MODEL.split("public func markUnread(_ botID: String)", 1)[1].split("\n    }", 1)[0]

    def test_the_mark_moves_behind_the_newest_message(self) -> None:
        # Not removed: a missing mark reads as "first sight" on this device, and the host would
        # answer with the whole history as unread.
        self.assertIn("botPreviewTimes[botID] ?? Date()", self.body)
        self.assertIn("addingTimeInterval(-1)", self.body)

    def test_the_dot_goes_up_now_and_survives_a_relaunch(self) -> None:
        self.assertIn("unreadBots.insert(botID)", self.body)
        self.assertIn("Self.defaults.set(lastRead.mapValues(\\.timeIntervalSince1970), forKey: lastReadKey)",
                      self.body)


if __name__ == "__main__":
    unittest.main()
