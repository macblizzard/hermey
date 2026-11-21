"""The New Routine form, from the + on the routines sheet down to the dashboard call.

Shaped after the official app's form (name, when, what it does, where it goes, advanced), because the
fields are the host's own nouns. Every guard here is a decision a later edit could quietly undo: the
route that creates, the rule that refuses a routine with nothing to do, and the two places that rule
is spelled out — the form and the server — which must agree word for word.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
# The host service is the Rust crate in `hermeyd/` now; schedules are a translator over `cron.manage`.
BRIDGE = ROOT / "hermeyd" / "src"
ADMIN = (BRIDGE / "routines.rs").read_text(encoding="utf-8")
AUDIT = (BRIDGE / "audit.rs").read_text(encoding="utf-8")
ROUTES = (BRIDGE / "main.rs").read_text(encoding="utf-8")
POINTER = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text(encoding="utf-8")
ROUTINES = (ROOT / "Sources" / "HermesKit" / "Routines.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
SHEET = (ROOT / "Sources" / "HermeyUI" / "BotRoutinesSheet.swift").read_text(encoding="utf-8")
EDITOR = (ROOT / "Sources" / "HermeyUI" / "RoutineEditorSheet.swift").read_text(encoding="utf-8")

NEEDS_CONTENT = "This routine needs a prompt, a skill, or a script."


def block(source: str, start: str, end: str) -> str:
    if start not in source:
        raise AssertionError(f"missing anchor: {start!r}")
    tail = source.split(start, 1)[1]
    if end not in tail:
        raise AssertionError(f"missing end anchor after {start!r}: {end!r}")
    return tail.split(end, 1)[0]


class TheHostCreatesARoutine(unittest.TestCase):
    """Retargeted from `hermes_bridge/bot_admin.py` (deleted with the Python bridge)."""

    def setUp(self) -> None:
        self.route = block(ADMIN, "pub async fn create_routine(", "pub async fn set_routine_state(")

    def test_there_is_a_create_route_and_it_is_audited(self) -> None:
        self.assertIn('"/v1/bots/{profile}/routines"', ROUTES)
        self.assertIn("routines::create_routine", ROUTES)
        self.assertIn("pub async fn create_routine(", ADMIN)
        self.assertIn('"bots.routine_create"', AUDIT,
                      "an unaudited write is a write nobody can prove happened")

    def test_a_routine_with_nothing_to_do_is_refused(self) -> None:
        # The bridge refused with the form's own sentence. hermeyd can schedule a prompt only, so
        # its refusal names that rule instead; both sides still refuse rather than creating a job
        # that fires and does nothing.
        self.assertIn("this host can only schedule a prompt", self.route)
        self.assertIn(NEEDS_CONTENT, ROUTINES,
                      "the form still refuses a draft with a skill or a script and no prompt")

    def test_an_empty_schedule_is_refused_first(self) -> None:
        self.assertIn("if schedule.is_empty()", self.route)
        self.assertIn("a schedule is required", self.route)

    # Removed with the Python bridge: `test_a_script_with_no_prompt_runs_without_an_agent`,
    # `test_the_dashboard_is_posted_json_not_queried`, `test_the_new_row_comes_back_in_the_lists_shape`
    # and `test_a_bad_schedule_is_a_422_not_a_502` guarded `bot_admin.py`'s HTTP call to the Hermes
    # dashboard (`_dashboard`, `no_agent`, `status_code=422`). hermeyd has no dashboard client: it
    # speaks JSON-RPC `cron.manage` to the engine (`routines.rs`), where a bad schedule is the
    # engine's own error, and the answer is built by `routines.rs` rather than proxied.


class TheClientCanCreateOne(unittest.TestCase):
    def test_the_protocol_and_the_implementation_both_carry_it(self) -> None:
        self.assertIn("func createRoutine(_ profile: String, draft: RoutineDraft)", POINTER)
        self.assertIn('bridgePOST("v1/bots/\\(name)/routines"', POINTER)
        self.assertIn("public func createRoutine(_ draft: RoutineDraft, for profile: String)",
                      MODEL)

    def test_both_shells_offer_it(self) -> None:
        for rel in (("Apps", "HermesMobile", "Views", "ConversationScreen.swift"),
                    ("Apps", "HermesMac", "Workspace", "WorkspaceRoot.swift")):
            source = (ROOT.joinpath(*rel)).read_text(encoding="utf-8")
            self.assertIn("create: { draft in", source, f"{rel[-1]} cannot create a routine")


class TheSheetHasAPlus(unittest.TestCase):
    def test_the_plus_is_beside_the_title_and_opens_the_form(self) -> None:
        self.assertIn('Image(systemName: "plus")', SHEET)
        self.assertIn('.accessibilityLabel("Add routine")', SHEET)
        self.assertIn("showNewRoutine = true", SHEET)
        self.assertIn("RoutineEditorSheet(botName: botName, deliveries: deliveries)", SHEET)

    def test_send_to_lists_every_bot_from_the_shell_that_knows_them(self) -> None:
        # "built the send to for all bots": the form's choices come from the roster, and each bot maps
        # to the host's own delivery string.
        self.assertIn("deliveries: [RoutineDelivery]", EDITOR)
        self.assertIn("ForEach(deliveries)", EDITOR)
        self.assertIn("static func options(bots: [(profile: String, name: String)])", ROUTINES)
        self.assertIn('"bot-chat:\\(profile)"', ROUTINES)
        for rel in (("Apps", "HermesMobile", "Views", "ConversationScreen.swift"),
                    ("Apps", "HermesMac", "Workspace", "WorkspaceRoot.swift")):
            source = ROOT.joinpath(*rel).read_text(encoding="utf-8")
            self.assertIn("RoutineDelivery.options(", source, f"{rel[-1]} does not pass the roster")

    def test_the_list_is_re_read_after_a_create(self) -> None:
        made = block(SHEET, "RoutineEditorSheet(botName: botName, deliveries: deliveries) { draft in",
                     "return made")
        self.assertIn("await reload()", made,
                      "next_run_at is the host's answer and must not be guessed at")

    def test_a_shell_without_the_route_gets_no_button(self) -> None:
        self.assertIn("if let create {", SHEET)


class DoneAlwaysHasADoor(unittest.TestCase):
    """Both known Mac failures of this sheet, pinned.

    On macOS a `ToolbarItemGroup` whose first member was conditional collapsed to the member that
    existed: the + replaced Done and the sheet could not be closed (force-quit was needed, 2026-11-16).
    And a Mac sheet sizes to content while a `List` has no intrinsic height, so the New Routine modal
    opened blank with every row drawn into a zero-height sheet.
    """

    def test_add_and_done_share_one_toolbar_item(self) -> None:
        toolbar = block(SHEET, "ToolbarItem(placement: .confirmationAction) {", ".accessibilityIdentifier(\"routines.done\")")
        self.assertIn('Image(systemName: "plus")', toolbar)
        self.assertIn('Button("Done") { dismiss() }', toolbar)
        self.assertNotIn("ToolbarItemGroup(placement: .confirmationAction)", SHEET,
                         "a conditional first member can eat the Done button on macOS")

    def test_done_is_not_conditional(self) -> None:
        toolbar = block(SHEET, "ToolbarItem(placement: .confirmationAction) {", "ToolbarItem(placement: .cancellationAction)")
        done_at = toolbar.index('Button("Done")')
        create_at = toolbar.index("if let create {")
        self.assertLess(create_at, done_at, "Done is inside no `if`, and comes after the +")
        self.assertIn('accessibilityIdentifier("routines.done")', toolbar)

    def test_the_editor_gets_a_mac_sheet_floor(self) -> None:
        self.assertIn(".sheetSizing(minWidth: 520, minHeight: 560)", EDITOR,
                      "without a floor a List in a Mac sheet collapses to its title bar")

    def test_the_mac_launch_check_is_observable(self) -> None:
        mac_app = (ROOT / "Apps" / "HermesMac" / "HermesMacApp.swift").read_text(encoding="utf-8")
        self.assertIn("checkForUpdatesInBackground()", mac_app)
        self.assertIn('Logger(subsystem: "dev.hermey.app.mac", category: "updates")', mac_app,
                      "SULastCheckTime says a check happened; this says the launch path asked for one")


class TheMacPanelMatchesTheOtherMacPanels(unittest.TestCase):
    """Skills and MCP set the Mac's window language; routines has to speak it.

    Reported 2026-11-16: "it doesnt match the other windows like mcp or skills … and the routines window
    modal doesnt close with ESC". Escape is `onExitCommand` on the window, not a shortcut on one button,
    so it works with the list or a text field focused.
    """

    def setUp(self) -> None:
        self.sheet = (ROOT / "Apps" / "HermesMac" / "Workspace" / "MacBotRoutinesSheet.swift").read_text(encoding="utf-8")
        self.editor = (ROOT / "Apps" / "HermesMac" / "Workspace" / "MacRoutineEditorSheet.swift").read_text(encoding="utf-8")
        self.tools = (ROOT / "Apps" / "HermesMac" / "Workspace" / "MacBotToolsSheet.swift").read_text(encoding="utf-8")

    def test_it_uses_the_same_window_shape_as_skills_and_mcp(self) -> None:
        for side in (self.sheet, self.tools):
            self.assertIn(".frame(width: 560, height:", side)
            self.assertIn("Divider()", side)
            self.assertIn(".background(Tokens.canvas)", side)
            self.assertIn("frame(height: 52)", side, "the same header row height")
            self.assertIn("ScrollView {", side)
            self.assertIn("LazyVStack(spacing: 0)", side)

    def test_it_is_not_the_phones_navigation_stack_sheet(self) -> None:
        self.assertNotIn("NavigationStack {", self.sheet, "the Mac panel is not a nav stack")
        self.assertNotIn("List {", self.sheet)
        self.assertNotIn(".inlineSheetTitle()", self.sheet)

    def test_escape_closes_it(self) -> None:
        self.assertIn(".onExitCommand { dismiss() }", self.sheet)
        self.assertIn(".onExitCommand { dismiss() }", self.editor)

    def test_the_editor_cancels_and_creates(self) -> None:
        self.assertIn('Button("Cancel") { dismiss() }', self.editor)
        self.assertIn(".keyboardShortcut(.cancelAction)", self.editor)
        self.assertIn('Button("Create Routine") { Task { await save() } }', self.editor)
        self.assertIn(".disabled(!draft.isCreatable)", self.editor)

    def test_the_mac_routes_to_the_panel_not_the_phone_sheet(self) -> None:
        root = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
        self.assertIn("MacBotRoutinesSheet(", root)
        # `MacBotRoutinesSheet(` contains the phone sheet's name as a substring, so the check is a
        # regex with a negative lookbehind rather than a substring test.
        import re as _re
        self.assertIsNone(_re.search(r"(?<!Mac)BotRoutinesSheet\(", root),
                          "the Mac must not fall back to the phone's sheet")

    def test_the_add_button_lives_in_the_header(self) -> None:
        header = block(self.sheet, "private var header: some View", "private var empty")
        self.assertIn('Image(systemName: "plus")', header)
        self.assertIn('accessibilityIdentifier("routines.add")', header)
        self.assertIn('Button("Done") { dismiss() }', header)


class TheFormMatchesTheReference(unittest.TestCase):
    def test_the_fields_are_the_official_forms_fields(self) -> None:
        for anchor in ('TextField("Morning summary (optional)"',
                       'Text("When")',
                       'Section("What should it do?")',
                       "Picker(\"Send to\"",
                       'Text("Results are always kept in the routine\'s history too.")',
                       'Section("Advanced")',
                       'Button("Create Routine")'):
            self.assertIn(anchor, EDITOR, f"the form is missing {anchor!r}")

    def test_every_schedule_mode_is_offered(self) -> None:
        self.assertIn("ForEach(RoutineScheduleMode.allCases)", EDITOR)
        # `repeat` is a Swift keyword, so the case is spelled `repeating`; the label a person reads
        # is still "Repeat".
        for mode in ("daily", "weekly", "monthly", "repeating", "once", "custom"):
            self.assertIn(f"case .{mode}", ROUTINES, f"the picker promises {mode} but the model has no case")
        self.assertIn('case .repeating: return "Repeat"', ROUTINES)

    def test_the_button_obeys_the_rule_and_says_why(self) -> None:
        self.assertIn(".disabled(!draft.isCreatable)", EDITOR)
        self.assertIn("failure ?? draft.problem", EDITOR,
                      "the form's own hint and the host's refusal share one line")

    def test_a_one_shot_must_be_in_the_future(self) -> None:
        self.assertIn("if mode == .once { return onceAt > Date() }", ROUTINES)

    def test_times_are_the_phones_clock_and_say_so(self) -> None:
        self.assertIn("the host resolves them in the profile's timezone", EDITOR)


# Removed with the Python bridge: `TheBridgeStillCompiles` ast-parsed every `.py` file in
# `Bridge/hermes_bridge/` and refused a `***` that had replaced `str | None`. There are no Python
# modules left; the compiler is the equivalent guard for the Rust crate, and `cargo test` in CI runs
# it on every change.

