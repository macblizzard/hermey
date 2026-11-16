"""The New Routine form, from the + on the routines sheet down to the dashboard call.

Shaped after the official app's form (name, when, what it does, where it goes, advanced), because the
fields are the host's own nouns. Every guard here is a decision a later edit could quietly undo: the
route that creates, the rule that refuses a routine with nothing to do, and the two places that rule
is spelled out — the form and the server — which must agree word for word.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "Bridge" / "hermes_bridge"
ADMIN = (BRIDGE / "bot_admin.py").read_text(encoding="utf-8")
AUDIT = (BRIDGE / "audit.py").read_text(encoding="utf-8")
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


class TheBridgeCreatesARoutine(unittest.TestCase):
    def setUp(self) -> None:
        self.route = block(ADMIN, '@router.post("/{profile}/routines")\n    def create_routine',
                           '@router.post("/{profile}/routines/{job_id}/state")')

    def test_there_is_a_create_route_and_it_is_audited(self) -> None:
        self.assertIn("def create_routine(", ADMIN)
        self.assertIn("bots.routine_create", self.route)
        self.assertIn('"bots.routine_create"', AUDIT,
                      "an unaudited write is a write nobody can prove happened")

    def test_the_rule_is_the_forms_rule_word_for_word(self) -> None:
        self.assertIn(NEEDS_CONTENT, self.route)
        self.assertIn(NEEDS_CONTENT, ROUTINES,
                      "the form and the server must refuse with the same sentence")

    def test_an_empty_schedule_is_refused_first(self) -> None:
        self.assertIn("This routine needs a schedule.", self.route)

    def test_a_script_with_no_prompt_runs_without_an_agent(self) -> None:
        # The host's script-only shape: stdout is delivered verbatim. Sending no_agent false there
        # would pay for a model call the routine never asked for.
        self.assertIn('payload["no_agent"] = True', self.route)
        self.assertIn("if not prompt:", self.route)

    def test_the_dashboard_is_posted_json_not_queried(self) -> None:
        self.assertIn('_dashboard("POST", f"/api/cron/jobs?profile={profile}", body=payload)',
                      self.route)
        helper = block(ADMIN, "def _dashboard(", "def _cron_jobs(")
        self.assertIn('headers["Content-Type"] = "application/json"', helper)
        self.assertIn("json.dumps(body).encode", helper)

    def test_the_new_row_comes_back_in_the_lists_shape(self) -> None:
        self.assertIn('return {"routine": _routine_row(created)}', self.route,
                      "one shape for a row, whether it was listed or just created")

    def test_a_bad_schedule_is_a_422_not_a_502(self) -> None:
        helper = block(ADMIN, "def _dashboard(", "def _cron_jobs(")
        self.assertIn("if error.code in (400, 422):", helper)
        self.assertIn("status_code=422", helper)


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


class TheBridgeStillCompiles(unittest.TestCase):
    """A syntax check over every bridge module.

    The redaction that tool output applies to `str | None` (it arrives as `str *** None`) once got
    pasted back into this file's neighbours by hand. `grep`ing for a feature does not notice that; a
    parse does, and a bridge that does not import fails every route at once, not just the new one.
    """

    def test_every_module_parses(self) -> None:
        import ast
        offenders = []
        for module in sorted(BRIDGE.glob("*.py")):
            try:
                ast.parse(module.read_text(encoding="utf-8"))
            except SyntaxError as error:
                offenders.append(f"{module.name}:{error.lineno}: {error.msg}")
        self.assertEqual(offenders, [])

    def test_no_redacted_annotation_survives(self) -> None:
        offenders = [module.name for module in BRIDGE.glob("*.py")
                     if "***" in module.read_text(encoding="utf-8")]
        self.assertEqual(offenders, [], "a `str | None` came back as `str *** None`")

