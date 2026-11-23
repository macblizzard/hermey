"""The HermesCards client target, pinned at the source.

The target has no Swift compiler on this box: `swift build --build-tests` on CI is the only
compiler, so the Python suite guards the parts a tidy-up can silently break — the marker's
alone-on-line and fence rules, the degradation contract, the approval view's shape, the injected
theme (the target must not import `HermeyUI`) and the `cards.enabled` default. The behaviour
itself is pinned by the XCTest cases in `Tests/HermesCardsTests/`, which this file also checks
for the load-bearing scenarios so they cannot be dropped.
"""
from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
TARGET = ROOT / "Sources/HermesCards"
TESTS = ROOT / "Tests/HermesCardsTests"

MARKER = (TARGET / "CardMarker.swift").read_text()
MODEL = (TARGET / "CardModel.swift").read_text()
THEME = (TARGET / "CardTheme.swift").read_text()
VIEW = (TARGET / "CardView.swift").read_text()
SETTINGS = (TARGET / "CardsSettings.swift").read_text()

MARKER_TESTS = (TESTS / "CardMarkerTests.swift").read_text()
MODEL_TESTS = (TESTS / "CardModelTests.swift").read_text()
SETTINGS_TESTS = (TESTS / "CardsSettingsTests.swift").read_text()


def imports(source: str) -> set[str]:
    return set(re.findall(r"^import\s+([A-Za-z_][A-Za-z0-9_]*)", source, re.MULTILINE))


class TargetTests(unittest.TestCase):
    def test_the_target_is_foundation_and_swiftui_only(self) -> None:
        for name in ("CardMarker", "CardModel", "CardTheme", "CardView", "CardsSettings"):
            self.assertTrue((TARGET / f"{name}.swift").is_file(), name)

        imported: set[str] = set()
        for path in TARGET.glob("*.swift"):
            imported |= imports(path.read_text())
        self.assertEqual(imported, {"Foundation", "SwiftUI"})

    def test_the_design_system_is_not_imported(self) -> None:
        # HermesCards depends on HermesKit only. Colours arrive through CardTheme, never through
        # a HermeyUI import — otherwise the target cannot be built or tested without the app.
        for path in [*TARGET.glob("*.swift"), *TESTS.glob("*.swift")]:
            source = path.read_text()
            self.assertNotIn("import HermeyUI", source, path.name)
            self.assertNotIn("HermeyUI.", source, path.name)

    def test_the_swift_tests_exist_where_ci_will_run_them(self) -> None:
        for name in ("CardMarkerTests", "CardModelTests", "CardsSettingsTests"):
            self.assertTrue((TESTS / f"{name}.swift").is_file(), name)


class MarkerTests(unittest.TestCase):
    def test_a_marker_must_span_the_whole_line(self) -> None:
        # Anchored at both ends: `Here: ::card{...}` is a sentence, not a card, and must keep all
        # its text. The inner class refuses braces, so two markers on one line cannot match.
        self.assertIn(r'linePattern = #"^::card\{([^{}]*)\}$"#', MARKER)

    def test_a_fence_is_tracked_before_a_marker_is_read(self) -> None:
        # The order matters: fence opening/closing is checked, then the marker. A marker inside a
        # fence is appended to the prose and never becomes a ref.
        body = MARKER[MARKER.index("public static func scan"):]
        fence = body.index("if let open = fence")
        opening = body.index("if let open = openingFence")
        marker = body.index("if let ref = marker(in: trimmed)")
        self.assertLess(fence, opening)
        self.assertLess(opening, marker)
        self.assertIn("private static func openingFence", MARKER)
        self.assertIn("private static func closes", MARKER)
        self.assertIn("count >= 3", MARKER)

    def test_refs_are_collected_in_order_and_the_line_is_dropped(self) -> None:
        self.assertIn("var refs: [CardRef] = []", MARKER)
        self.assertIn("refs.append(ref)", MARKER)
        self.assertIn("kept.joined(separator: \"\\n\")", MARKER)
        # A valid marker line is `continue`d, so it never reaches `kept`.
        self.assertIn("if let ref = marker(in: trimmed) {", MARKER)
        self.assertIn("continue", MARKER)

    def test_the_id_is_the_shape_the_route_accepts(self) -> None:
        self.assertIn(r'idPattern = #"^[A-Za-z0-9_-]{1,40}$"#', MARKER)
        self.assertIn("id.range(of: idPattern, options: .regularExpression)", MARKER)

    def test_an_unknown_kind_is_still_a_ref(self) -> None:
        # The parser passes the kind through; CardModel is what refuses a kind it cannot draw, so
        # the line still disappears and the bubble can say "Card not available".
        self.assertNotIn("Card.Kind(rawValue", MARKER)
        self.assertIn('attributes["kind"]', MARKER)

    def test_crlf_is_not_treated_as_two_line_breaks(self) -> None:
        # `String.split(separator: "\n")` is the wrong tool: Swift treats "\r\n" as ONE Character, so it
        # never breaks a CRLF message and every marker stays buried inside a single line. The split has
        # to happen at the NSString level, and the carriage return must survive into the prose.
        self.assertIn('hasSuffix("\\r")', MARKER)
        self.assertIn('text.components(separatedBy: "\\n")', MARKER)
        self.assertNotIn('text.split(separator: "\\n"', MARKER)
        self.assertIn("kept.append(raw)", MARKER)
        self.assertNotIn("kept.append(line)", MARKER)

    def test_the_parser_cases_are_pinned_in_swift(self) -> None:
        for name in (
            "testMarkerAloneOnItsLineIsFound",
            "testMarkerInsideAFenceIsProse",
            "testTwoMarkersComeBackInOrder",
            "testAMarkerMustBeAloneOnItsLine",
            "testAnUnknownKindStillParses",
            "testMissingOrUnfetchableFieldsLeaveTheLineAsText",
            "testCRLFKeepsItsLineEndings",
        ):
            self.assertIn(name, MARKER_TESTS, name)


class ModelTests(unittest.TestCase):
    def test_the_failure_is_one_apology_and_decoding_never_throws(self) -> None:
        self.assertIn('public static let unavailableMessage = "Card not available"', MODEL)
        self.assertIn("public enum CardModel: Sendable, Equatable, Decodable", MODEL)
        self.assertIn("guard let raw = try? JSONDecoder().decode(RawCard.self, from: data)", MODEL)
        self.assertIn("guard let raw = try? RawCard(from: decoder)", MODEL)
        self.assertIn("return .unavailable(unavailableMessage)", MODEL)

    def test_every_named_violation_is_validated(self) -> None:
        for source in (
            'schema == "card.v1"',
            "Card.Kind(wire: rawKind)",
            "!title.isEmpty",
            "Card.StatusState(rawValue: rawState)",
            "rawActions.count <= 3",
        ):
            self.assertIn(source, MODEL, source)

    def test_the_specs_kinds_and_states_are_the_only_ones(self) -> None:
        for wire in (
            "case approval",
            "case task",
            'case draftEmail = "draft-email"',
            "case pending",
            "case running",
            "case done",
            "case error",
            'case awaitingApproval = "awaiting-approval"',
        ):
            self.assertIn(wire, MODEL, wire)

    def test_unknown_fields_and_bad_elements_degrade_one_at_a_time(self) -> None:
        # Codable ignores unknown keys; Failable swallows one bad block/action; unknown block
        # types and styles are dropped, not fatal.
        self.assertIn("private struct Failable<Value: Decodable>: Decodable", MODEL)
        self.assertIn("value = try? Value(from: decoder)", MODEL)
        self.assertIn("var body: [Failable<RawBlock>]?", MODEL)
        self.assertIn("var actions: [Failable<RawAction>]?", MODEL)
        self.assertIn("default:\n            return nil", MODEL)

    def test_resolved_ticks_one_action_and_locks_the_rest(self) -> None:
        self.assertIn("public enum ActionState", MODEL)
        self.assertIn("return matches(action, resolved) ? .chosen : .locked", MODEL)
        self.assertIn("chosen == action.label || chosen == action.send", MODEL)

    def test_the_model_cases_are_pinned_in_swift(self) -> None:
        for name in (
            "testAValidApprovalDecodesEverythingItDraws",
            "testAResolvedCardTicksOnlyTheChosenAction",
            "testUnknownFieldsAndBlocksAreIgnored",
            "testABadSchemaIsUnavailable",
            "testAMissingOrEmptyTitleIsUnavailable",
            "testAnUnknownKindIsUnavailable",
            "testAFourthActionIsUnavailable",
            "testAnUnknownStatusStateIsUnavailable",
            "testMalformedJSONAndNonObjectRootsAreUnavailable",
            "testAFortyKilobyteBodyDegradesToADrawingCardNotACrash",
        ):
            self.assertIn(name, MODEL_TESTS, name)


class ThemeAndViewTests(unittest.TestCase):
    def test_the_default_palette_is_the_house_light_palette(self) -> None:
        for hex_value in ("0xFAF9F5", "0xF0EEE6", "0x141413", "0xCC6543", "0xB3392B", "0xE3DACC"):
            self.assertIn(hex_value, THEME, hex_value)
        self.assertIn("public struct CardTheme", THEME)
        self.assertIn("public static let hermey = CardTheme()", THEME)
        self.assertIn("radiusCard: CGFloat = 16", THEME)
        self.assertIn("radiusControl: CGFloat = 10", THEME)

    def test_the_view_takes_its_theme_by_injection(self) -> None:
        self.assertIn("theme: CardTheme = .hermey", VIEW)
        self.assertIn("private let theme: CardTheme", VIEW)

    def test_p1_draws_the_approval_layout_only(self) -> None:
        self.assertIn("if card.kind == .approval", VIEW)
        # Task and draft-email are P3/P4: no half-layout is drawn for them.
        self.assertIn("EmptyView()", VIEW)

    def test_the_approval_surfaces_title_body_and_buttons(self) -> None:
        self.assertIn("Text(card.title)", VIEW)
        self.assertIn("ForEach(card.body.indices", VIEW)
        self.assertIn("case .text(let text):", VIEW)
        self.assertIn("case .kv(let rows):", VIEW)
        self.assertIn("case .fields(let rows):", VIEW)
        self.assertIn("ForEach(card.actions.indices", VIEW)
        self.assertIn("Button {", VIEW)
        self.assertIn("Text(action.label)", VIEW)

    def test_primary_is_accent_and_danger_is_the_destructive_tint(self) -> None:
        self.assertIn("case .some(.primary): return theme.accent", VIEW)
        self.assertIn("case .some(.danger): return theme.danger.opacity(0.12)", VIEW)
        self.assertIn("case .some(.primary): return theme.accentInk", VIEW)

    def test_a_resolved_action_is_ticked_and_the_rest_disabled(self) -> None:
        self.assertIn("if state == .chosen", VIEW)
        self.assertIn('Image(systemName: "checkmark")', VIEW)
        self.assertIn(".disabled(state != .available)", VIEW)
        self.assertIn(".opacity(state == .locked ? 0.45 : 1)", VIEW)

    def test_the_unavailable_case_draws_the_apology(self) -> None:
        self.assertIn("case .unavailable(let message):", VIEW)
        self.assertIn("Text(message)", VIEW)


class SettingsTests(unittest.TestCase):
    def test_the_switch_defaults_on(self) -> None:
        self.assertIn('public static let enabledKey = "cards.enabled"', SETTINGS)
        self.assertIn("(defaults.object(forKey: enabledKey) as? Bool) ?? true", SETTINGS)

    def test_settings_cases_are_pinned_in_swift(self) -> None:
        for name in (
            "testTheKeyIsTheOneTheDefaultsCommandWrites",
            "testAnUntouchedStoreMeansOn",
            "testTheSwitchRoundTrips",
        ):
            self.assertIn(name, SETTINGS_TESTS, name)


if __name__ == "__main__":
    unittest.main()
