"""The always-visible task checklist above the composer.

The host already streams `todo_list` rows — the full board on every call — and nothing drew them.
These guards hold the four decisions that make the strip trustworthy:

* the board is the *last* result row, never the call's arguments echoed as a newer state;
* subtasks are indented under their parent;
* all four statuses have their own drawing;
* no board means no strip at all — never a placeholder claiming progress that does not exist;
* the strip sits above the composer on both shells and is recomputed from the transcript, so a
  resume or a paging adopt cannot leave a stale or duplicated board behind.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

BOARD = (ROOT / "Sources" / "HermesKit" / "TodoBoard.swift").read_text(encoding="utf-8")
VIEW = (ROOT / "Sources" / "HermeyUI" / "TaskChecklistView.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
MOBILE = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
MAC = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerBar.swift").read_text(encoding="utf-8")


class TodoBoardParsing(unittest.TestCase):
    def test_the_last_todo_list_row_wins(self) -> None:
        self.assertIn("entries.reversed()", BOARD)
        self.assertIn("return nil", BOARD, "the newest row is the board even when it cannot be read")

    def test_the_result_is_read_before_the_call_arguments(self) -> None:
        body = BOARD.split("private static func lastBoard", 1)[1]
        result = body.index("tool.content")
        call = body.index("tool.args")
        self.assertLess(result, call, "the result row is the board; the arguments are only the fallback")

    def test_a_call_row_is_ignored(self) -> None:
        self.assertIn("entry.role == .tool", BOARD)
        self.assertIn("isTodoList(tool.name)", BOARD)

    def test_malformed_and_empty_payloads_are_no_board(self) -> None:
        self.assertIn("try? JSONDecoder().decode(JSONValue.self", BOARD)
        self.assertIn("guard !items.isEmpty else { return nil }", BOARD)

    def test_items_keep_identity_and_parent(self) -> None:
        for field in ("public let id: String", "public let content: String",
                      "public let status: Status", "public let parent: String?"):
            self.assertIn(field, BOARD)

    def test_counts_and_liveness_come_from_the_board(self) -> None:
        self.assertIn("public var isActive: Bool { counts.inProgress > 0 }", BOARD)
        self.assertIn("counts.done + counts.cancelled == counts.total", BOARD)


class TodoBoardNesting(unittest.TestCase):
    def test_children_are_nested_under_the_parent(self) -> None:
        self.assertIn("children[parent, default: []].append(item)", BOARD)
        self.assertIn("walk(child, depth: depth + 1)", BOARD)

    def test_the_view_indents_by_depth(self) -> None:
        self.assertIn(".padding(.leading, CGFloat(row.depth) * 14)", VIEW)


class TaskChecklistStrip(unittest.TestCase):
    def test_all_four_statuses_are_drawn(self) -> None:
        self.assertIn('case .completed:', VIEW)
        self.assertIn("checkmark.circle.fill", VIEW)
        self.assertIn("PulsingDot()", VIEW)
        self.assertIn("case .pending:", VIEW)
        self.assertIn("case .cancelled:", VIEW)
        self.assertIn(".strikethrough(row.item.status == .cancelled", VIEW)

    def test_it_hides_once_everything_is_done(self) -> None:
        """A finished board is not a trophy: the strip disappears rather than folding to a summary."""
        self.assertIn("if board.isComplete {", VIEW)
        self.assertIn("EmptyView()", VIEW)
        self.assertIn("overrideExpanded ?? board.isActive", VIEW)

    def test_a_long_board_scrolls_in_place(self) -> None:
        self.assertIn("visibleRowLimit = 8", VIEW)
        self.assertIn("ScrollView(.vertical", VIEW)

    def test_the_list_never_takes_more_height_than_its_rows(self) -> None:
        """A ScrollView with no ceiling eats the whole pane — a two-row board once filled the phone."""
        self.assertNotIn("maxHeight: .infinity", VIEW)
        self.assertIn("min(rows.count, Self.visibleRowLimit)) * Self.rowHeight", VIEW)

    def test_no_board_draws_nothing(self) -> None:
        for shell, name in ((MOBILE, "mobile"), (MAC, "mac")):
            self.assertIn("if let board = model.taskBoard {", shell, name)
        # The view has no zero-value initialiser and no empty-state copy: it cannot draw a strip
        # without a board, and the parser returns nil rather than an empty one.
        self.assertNotIn("placeholder", VIEW.lower())
        self.assertNotIn("TodoBoard(items: [])", VIEW)


class MountPoints(unittest.TestCase):
    def test_the_strip_sits_directly_above_the_composer_on_the_phone(self) -> None:
        mount = MOBILE.index("TaskChecklistView(board: board)")
        composer = MOBILE.index("Composer(text: $model.draft")
        self.assertLess(mount, composer)
        self.assertNotIn("TranscriptRow", MOBILE[mount - 200:mount])

    def test_the_strip_sits_directly_above_the_composer_on_the_mac(self) -> None:
        mount = MAC.index("TaskChecklistView(board: board)")
        composer = MAC.index("Composer(text: $model.draft")
        self.assertLess(mount, composer)


class RecomputedOnAdopt(unittest.TestCase):
    def test_the_board_is_derived_from_the_loaded_transcript(self) -> None:
        self.assertIn("TodoBoard.board(from: transcript, live: liveToolEntries)", MODEL)

    def test_nothing_is_accumulated_across_a_resume(self) -> None:
        self.assertEqual(MODEL.count("var taskBoard"), 1,
                         "one computed property, not a stored board the model appends to")
        for banned in ("taskBoard.append", "todoBoard +=", "cachedTaskBoard"):
            self.assertNotIn(banned, MODEL)


if __name__ == "__main__":
    unittest.main()
