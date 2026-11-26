"""The HermesCards client target, pinned at the source.

The target has no Swift compiler on this box: `swift build --build-tests` on CI is the only
compiler, so the Python suite guards the parts a tidy-up can silently break — the marker's
alone-on-line and fence rules, the degradation contract, the three layouts (approval, task,
draft-email), the body blocks, the status chip, a resolved card, a live draft's editable fields
and its two controls, the composed turn Send posts, the injected theme (the target must not import
`HermeyUI`) and the `cards.enabled` default. The behaviour itself is pinned by the XCTest cases in
`Tests/HermesCardsTests/`, which this file also checks for the load-bearing scenarios so they
cannot be dropped.
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
DRAFT = (TARGET / "DraftEditing.swift").read_text()
SETTINGS = (TARGET / "CardsSettings.swift").read_text()

MARKER_TESTS = (TESTS / "CardMarkerTests.swift").read_text()
MODEL_TESTS = (TESTS / "CardModelTests.swift").read_text()
KINDS_TESTS = (TESTS / "CardKindsTests.swift").read_text()
SETTINGS_TESTS = (TESTS / "CardsSettingsTests.swift").read_text()
DRAFT_TESTS = (TESTS / "DraftEditingTests.swift").read_text()


def imports(source: str) -> set[str]:
    return set(re.findall(r"^import\s+([A-Za-z_][A-Za-z0-9_]*)", source, re.MULTILINE))


class TargetTests(unittest.TestCase):
    def test_the_target_is_foundation_and_swiftui_only(self) -> None:
        for name in ("CardMarker", "CardModel", "CardTheme", "CardView", "CardsSettings", "CardLoader",
                     "DraftEditing", "InfographicCard", "CardImageLoader"):
            self.assertTrue((TARGET / f"{name}.swift").is_file(), name)

        imported: set[str] = set()
        for path in TARGET.glob("*.swift"):
            imported |= imports(path.read_text())
        # `HermesKit` is the client (and `CardFetch`); nothing else. A design system, a transport of
        # its own or an app module here would make the target untestable without one.
        #
        # The one addition is the platform's own image framework, which `CardImageLoader` needs to
        # decode an infographic's hero picture (`NSImage`/`UIImage`). It is allowed only inside a
        # `canImport` branch, so the target still builds on any Apple platform, and the design
        # system is still never imported.
        self.assertEqual(imported - {"AppKit", "UIKit"}, {"Foundation", "SwiftUI", "HermesKit"})
        # …and only under a guard. An unconditional `import AppKit` is how a target stops building
        # for the phone, so each platform import must sit inside a `canImport` block (a `#else` a few
        # lines below the `#if` counts: UIKit is preferred where both exist).
        for path in TARGET.glob("*.swift"):
            lines = path.read_text().splitlines()
            for index, line in enumerate(lines):
                if line.strip() in ("import AppKit", "import UIKit"):
                    window = lines[max(0, index - 4):index]
                    self.assertTrue(any(entry.startswith("#if canImport(") for entry in window),
                                    f"{path.name}:{index + 1}: platform import outside a canImport branch")

    def test_the_design_system_is_not_imported(self) -> None:
        # HermesCards depends on HermesKit only. Colours arrive through CardTheme, never through
        # a HermeyUI import — otherwise the target cannot be built or tested without the app.
        for path in [*TARGET.glob("*.swift"), *TESTS.glob("*.swift")]:
            source = path.read_text()
            self.assertNotIn("import HermeyUI", source, path.name)
            self.assertNotIn("HermeyUI.", source, path.name)

    def test_the_swift_tests_exist_where_ci_will_run_them(self) -> None:
        for name in ("CardMarkerTests", "CardModelTests", "CardsSettingsTests", "CardKindsTests",
                     "DraftEditingTests"):
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

    def test_every_kind_decodes_and_bad_elements_degrade_one_at_a_time(self) -> None:
        # Codable ignores unknown keys; Failable swallows one bad block/action/email; unknown block
        # types and styles are dropped, not fatal.
        self.assertIn("private struct Failable<Value: Decodable>: Decodable", MODEL)
        self.assertIn("value = try? Value(from: decoder)", MODEL)
        self.assertIn("var body: [Failable<RawBlock>]?", MODEL)
        self.assertIn("var actions: [Failable<RawAction>]?", MODEL)
        self.assertIn("var email: Failable<RawEmail>?", MODEL)
        self.assertIn("default:\n            return nil", MODEL)

    def test_the_body_blocks_are_the_three_the_spec_allows(self) -> None:
        # `text` keeps its paragraph breaks; `kv` rows are [label, value] arrays and `fields` items
        # are {label, value} objects. Anything else is skipped, never fatal.
        for block in ('case "text":', 'case "kv":', 'case "fields":'):
            self.assertIn(block, MODEL, block)
        self.assertIn("case text(String)", MODEL)
        self.assertIn("case kv([Row])", MODEL)
        self.assertIn("case fields([Row])", MODEL)
        self.assertIn("return rows.isEmpty ? nil : .kv(rows)", MODEL)
        self.assertIn("return rows.isEmpty ? nil : .fields(rows)", MODEL)

    def test_the_draft_email_is_a_typed_block_not_a_generic_dump(self) -> None:
        self.assertIn("public struct Email: Sendable, Equatable", MODEL)
        for field in ("public let to: String?", "public let cc: String?",
                      "public let subject: String?", "public let bodyText: String?"):
            self.assertIn(field, MODEL, field)
        # The subject heads the card, and the title is the fallback when there is none.
        self.assertIn("public var heading: String", MODEL)
        self.assertIn("return title", MODEL)
        # A blank bodyText is no body at all.
        self.assertIn("isEmpty ? nil : text", MODEL)

    def test_the_status_chip_reads_in_words_and_prefers_the_bots_label(self) -> None:
        self.assertIn("public var chipText: String", MODEL)
        for word in ('return "Pending"', 'return "Running"', 'return "Done"',
                     'return "Error"', 'return "Awaiting approval"'):
            self.assertIn(word, MODEL, word)
        # `status.label` overrides the state's own word.
        self.assertIn("return state.chipText", MODEL)

    def test_a_single_short_line_reads_as_the_question_under_the_title(self) -> None:
        self.assertIn("public var leadText: String?", MODEL)
        self.assertIn("trimmed.count < 200", MODEL)
        self.assertIn('!trimmed.contains("\\n")', MODEL)

    def test_resolved_ticks_one_action_and_locks_the_rest(self) -> None:
        self.assertIn("public enum ActionState", MODEL)
        self.assertIn("return matches(action, resolved) ? .chosen : .locked", MODEL)
        self.assertIn("chosen == action.label || chosen == action.send", MODEL)
        # …and the card can say which action that was, as the label the owner pressed.
        self.assertIn("public var resolvedLabel: String?", MODEL)
        self.assertIn("actions.first { matches($0, resolved) }?.label ?? resolved.action", MODEL)

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

    def test_the_kind_cases_are_pinned_in_swift(self) -> None:
        for name in (
            "testTheKindsAreTheOnesTheSpecNames",
            "testATaskCardDecodesItsStatusChipAndBody",
            "testTheStatusChipPrefersTheBotsOwnLabel",
            "testEveryStatusStateReadsInWords",
            "testABlankLabelFallsBackToTheStateWord",
            "testADraftEmailCardDecodesToCcSubjectAndBody",
            "testADraftWithoutASubjectIsHeadedByItsTitle",
            "testADraftWhoseEmailBlockIsBrokenStillDraws",
            "testABlankBodyTextIsNoBodyAtAll",
            "testAResolvedDraftEmailLocksSendAndDiscard",
            "testAResolvedTaskNamesTheActionItTook",
            "testAResolutionThatNamesNoButtonIsStillShown",
            "testACardWithNoActionsIsStillACard",
            "testAnUnresolvedCardHasNoResolvedLabel",
            "testASingleShortLineIsTheLeadLine",
            "testAMultiLineOrLongBodyIsNotALeadLine",
            "testAnEmptyBodyDrawsNothingAtAll",
            "testAnInfographicDecodesItsPictureFactsAndHighlight",
            "testAnInfographicNeedsNoStatus",
            "testAProductInfographicCarriesPriceSellerAndAvailability",
            "testAnInfographicWithoutAPictureStillDecodes",
            "testAnImageThatIsNotHTTPIsNoImageAndTakesItsCaption",
            "testAFactWithNoValueOrLabelIsDroppedAndTheRestSurvive",
            "testAnInfographicLinkThatCannotBeOpenedIsNotDrawn",
        ):
            self.assertIn(name, KINDS_TESTS, name)

    def test_the_fixtures_cover_every_kind_and_the_broken_shapes(self) -> None:
        # One valid document per kind, plus the shapes a bot actually writes: no subject, no cc,
        # an `email` that is not an object, no actions, a resolution, a one-line body.
        for fixture in ("static let approval", "static let task", "static let draftEmail",
                        "static let draftEmailBare", "static let draftEmailBrokenEmail",
                        "static let resolvedTask", "static let taskWithoutActions",
                        "static let oneLineBody", "static let longBody"):
            self.assertIn(fixture, KINDS_TESTS, fixture)
        # Broken documents are pinned where they were pinned before, and still must not throw.
        for name in ("testABadSchemaIsUnavailable", "testAMissingOrEmptyTitleIsUnavailable",
                     "testAnUnknownKindIsUnavailable", "testAFourthActionIsUnavailable"):
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

    def test_each_kind_has_its_own_layout(self) -> None:
        # One switch on the kind, one layout per case — no kind falls through to an empty view.
        layouts = VIEW[VIEW.index("switch card.kind"):VIEW.index("// MARK: - Unavailable")]
        for kind, function in (("case .approval:", "surface(card)"),
                               ("case .task:", "statusChip(card)"),
                               ("case .draftEmail:", "draftDetails(card)")):
            self.assertIn(kind, layouts, kind)
        self.assertLess(layouts.index("case .approval:"), layouts.index("case .task:"))
        self.assertLess(layouts.index("case .task:"), layouts.index("case .draftEmail:"))
        self.assertIn("draftDetails(card)", layouts)
        for function in ("private func surface<", "private func statusChip", "private func draftDetails"):
            self.assertIn(function, VIEW, function)

    def test_the_card_surfaces_heading_body_blocks_and_buttons(self) -> None:
        self.assertIn("Text(card.heading)", VIEW)
        self.assertIn("ForEach(card.body.indices", VIEW)
        self.assertIn("case .text(let text):", VIEW)
        self.assertIn("case .kv(let rows):", VIEW)
        self.assertIn("case .fields(let rows):", VIEW)
        self.assertIn("ForEach(card.actions.indices", VIEW)
        self.assertIn("Button {", VIEW)
        self.assertIn("Text(action.label)", VIEW)
        # An empty body draws nothing: the loop is inside the `else` of the lead-line branch.
        self.assertIn("ForEach(card.body.indices", VIEW[VIEW.index("if let lead = card.leadText"):])

    def test_the_lead_line_is_the_one_line_rule(self) -> None:
        self.assertIn("if let lead = card.leadText", VIEW)
        self.assertIn("Text(lead)", VIEW)

    def test_the_task_card_draws_a_status_chip(self) -> None:
        self.assertIn("Text(card.status.chipText)", VIEW)
        self.assertIn("ProgressView()", VIEW)
        self.assertIn("if state == .running", VIEW)
        # The chip is words first: VoiceOver must never get a colour and nothing else.
        self.assertIn('accessibilityLabel("Status: \\(card.status.chipText)")', VIEW)

    def test_the_draft_email_draws_to_cc_and_a_scrolling_body(self) -> None:
        self.assertIn('row("To", to)', VIEW)
        self.assertIn('row("Cc", cc)', VIEW)
        self.assertIn("if let cc = email.cc, !cc.isEmpty", VIEW)
        self.assertIn("emailBody(text)", VIEW)
        self.assertIn("ScrollView(.vertical)", VIEW)
        self.assertIn("previewHeight(for: text)", VIEW)

    def test_a_resolved_card_names_its_action_and_locks_every_button(self) -> None:
        self.assertIn("if let label = card.resolvedLabel", VIEW)
        self.assertIn("resolvedNote(label)", VIEW)
        self.assertIn('Text("Resolved: \\(label)")', VIEW)
        # Every action is disabled once resolved — the chosen one included.
        self.assertIn(".disabled(state != .available)", VIEW)
        self.assertIn(".opacity(state == .locked ? 0.45 : 1)", VIEW)

    def test_primary_is_accent_and_danger_is_the_destructive_tint(self) -> None:
        self.assertIn("case .some(.primary): return theme.accent", VIEW)
        self.assertIn("case .some(.danger): return theme.danger.opacity(0.12)", VIEW)
        self.assertIn("case .some(.primary): return theme.accentInk", VIEW)

    def test_a_resolved_action_is_ticked(self) -> None:
        self.assertIn("if state == .chosen", VIEW)
        self.assertIn('Image(systemName: "checkmark")', VIEW)

    def test_the_unavailable_case_draws_the_apology(self) -> None:
        self.assertIn("case .unavailable(let message):", VIEW)
        self.assertIn("Text(message)", VIEW)


class LiveDraftTests(unittest.TestCase):
    """A draft-email card is a form the moment it draws: fields, then Send and Discard."""

    def controls(self) -> str:
        return VIEW[VIEW.index("private func draftControls"):VIEW.index("private func draftButton")]

    def draft_case(self) -> str:
        return VIEW[VIEW.index("case .draftEmail:"):VIEW.index("// MARK: - Unavailable")]

    def test_a_live_draft_is_a_form_and_has_no_edit_mode(self) -> None:
        # The fields are the card: there is no "Edit" tap, no second state and no flag to hold one.
        self.assertIn("@State private var draft: DraftEditor?", VIEW)
        self.assertIn("TextField(label, text: text)", VIEW)
        self.assertIn("TextEditor(text: text)", VIEW)
        self.assertNotIn("isEditing", VIEW)

    def test_the_card_shows_exactly_send_and_discard(self) -> None:
        controls = self.controls()
        self.assertIn('draftButton("Send", style: .primary)', controls)
        self.assertIn('draftButton("Discard", style: .danger)', controls)
        # `Edit` is never drawn: the controls do not iterate the file's actions at all, so a card
        # that still writes one renders the same two buttons as every other draft.
        self.assertNotIn("ForEach", controls)
        self.assertNotIn("actionRow", controls)
        self.assertNotIn("Card.Action", controls.split('draftButton("Discard"')[1])

    def test_discard_is_local_and_sends_no_turn(self) -> None:
        controls = self.controls()
        self.assertIn("self.discarded = true", controls)
        self.assertNotIn("onAction?", controls)
        # The card stays readable and stops answering: fields disabled, card dimmed, buttons gone.
        self.assertIn(".disabled(discarded)", VIEW)
        self.assertIn(".opacity(discarded ? 0.55 : 1)", VIEW)
        self.assertIn('Text("Discarded")', VIEW)

    def test_send_rides_the_path_every_card_button_already_used(self) -> None:
        # One callback, one action: the composed block is that action's `send`, so the hooks post
        # it and tick the card exactly as before.
        self.assertIn('onAction?(Card.Action(label: "Send",', VIEW)
        self.assertIn("send: typed.composedSend(lead: action?.send)", VIEW)
        self.assertIn("onAction: ((Card.Action) -> Void)? = nil", VIEW)
        # The view owns no transport and no second channel of its own.
        for word in ("URLSession", "URLRequest", "NotificationCenter"):
            self.assertNotIn(word, VIEW, word)

    def test_typing_is_seeded_from_the_document_and_never_overwritten(self) -> None:
        # `nil` until the first keystroke: the fields read the card, then the typed copy wins.
        self.assertIn('get: { self.editor(for: card)?[keyPath: keyPath] ?? "" }', VIEW)
        self.assertIn("self.draft = editing", VIEW)
        self.assertIn("draft ?? DraftEditor.editor(for: card)", VIEW)
        # A *different* document clears the typing; an ordinary re-render leaves it alone, because
        # the seed is the email's own text, not the view's identity.
        self.assertIn(".onChange(of: draftSeed)", VIEW)
        self.assertIn("self.draft = nil", VIEW)
        self.assertIn("private var draftSeed: String", VIEW)

    def test_nothing_is_persisted_and_nothing_is_written_back(self) -> None:
        for source, name in ((DRAFT, "DraftEditing"), (VIEW, "CardView")):
            for word in ("UserDefaults", "AppStorage", "SceneStorage", "FileManager", "write(to:"):
                self.assertNotIn(word, source, f"{name}: {word}")

    def test_a_resolved_draft_is_read_only_and_an_emailless_one_is_unchanged(self) -> None:
        draft_case = self.draft_case()
        # Only a live draft with an `email` block is the form.
        self.assertIn("if card.email != nil, !card.isResolved {", draft_case)
        # Resolved: facts, the note, and no controls at all.
        self.assertIn("} else if card.isResolved {", draft_case)
        self.assertIn("controls: { EmptyView() }", draft_case)
        # No email: exactly today's card, its own buttons included.
        self.assertIn("controls: { actionRow(card) }", draft_case)
        self.assertIn("draftDetails(card)", draft_case)

    def test_the_composed_block_is_deterministic(self) -> None:
        self.assertIn('public static let instruction = "send this email exactly as written:"', DRAFT)
        # The card's own token leads, so the agent still sees the intent, then the fixed block.
        self.assertIn("lines.append(lead)", DRAFT)
        self.assertIn("lines.append(DraftEditor.instruction)", DRAFT)
        self.assertIn('lines.append("To: " + DraftEditor.singleLine(to))', DRAFT)
        self.assertIn("if !copied.isEmpty {", DRAFT)
        self.assertIn('lines.append("Cc: " + copied)', DRAFT)
        self.assertIn('lines.append("Subject: " + DraftEditor.singleLine(subject))', DRAFT)
        self.assertIn('lines.append("---")', DRAFT)
        # A header is one line, so a pasted newline cannot reshape the block.
        self.assertIn("components(separatedBy: .newlines)", DRAFT)

    def test_the_send_token_is_the_cards_primary_action_and_never_edit(self) -> None:
        self.assertIn("var draftSendAction: Action?", DRAFT)
        self.assertIn("actions.filter { $0.draftRole != .edit }", DRAFT)
        self.assertIn("$0.style == .primary", DRAFT)
        self.assertIn("$0.style != .danger", DRAFT)

    def test_an_edited_send_still_names_its_button(self) -> None:
        # The composed block's first line is the card's `send`, and that is what `matches` reads
        # back, so the note under a sent draft says "Resolved: Send", not the whole email.
        self.assertIn('chosen.components(separatedBy: "\\n").first == action.send', MODEL)

    def test_the_draft_cases_are_pinned_in_swift(self) -> None:
        for name in (
            "testALiveDraftOpensReadyToTypeItsOwnValues",
            "testAResolvedDraftCannotBeTypedInto",
            "testADraftWithNoEmailBlockCannotBeTypedInto",
            "testOtherKindsAreNeverTypedInto",
            "testTheEditsAreWhatTheSendCarries",
            "testTheCardsOwnSendIsTheFirstLine",
            "testTheCcLineIsOmittedWhenEmpty",
            "testADraftWithNoUsableActionStillComposesAWholeBlock",
            "testAHeaderFieldIsOneLine",
            "testAnEmptyBodyStillEndsTheBlockAfterTheRule",
            "testThePrimaryActionIsTheSend",
            "testAnEditActionIsNeverTheSend",
            "testThePositionDecidesWhenTheFilesWordsDoNot",
            "testTheRolesReadTheCardsOwnLabels",
            "testTypingLeavesTheCardsDocumentAlone",
            "testASentEditedDraftStillNamesTheButtonThatSentIt",
        ):
            self.assertIn(name, DRAFT_TESTS, name)


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
