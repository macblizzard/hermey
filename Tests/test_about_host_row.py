"""Settings ▸ About's host row: one line, the version and its status together, the press beside them.

The row this replaces put `HOST SERVICE` on the left with a plain, grey `Check now` pushed to the far
right of the *heading*, and left `0.4.0 · up to date` on a line of its own underneath. So the button
looked detached from the thing it acts on, and as unadorned muted text it did not look pressable at
all. And every answer — current, behind, unknown — was painted in the same grey.

What has to stay true, and none of it is checkable from the Swift side alone (there is no test binary
for a `View`, and the difference between "up to date" and "could not check" is a colour):

* the section heading is still a heading, and nothing else shares its line;
* the version and the status are one string on one line;
* the action is on that same line, right-aligned in a slot whose width does not depend on the state;
* three answers, three tones;
* a check in flight says so and refuses a second press — including in the model, not only in the view.

The Swift sources are read as text.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

ABOUT = (ROOT / "Apps" / "HermesMac" / "Views" / "AboutSettingsTab.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
KIT = (ROOT / "Sources" / "HermesKit" / "HostUpdate.swift").read_text(encoding="utf-8")
IOS_SETTINGS = (ROOT / "Apps" / "HermesMobile" / "Views" / "SettingsScreen.swift").read_text(
    encoding="utf-8")


def block(source: str, opening: str, closing: str) -> str:
    """The text between one marker and the next, both exclusive."""
    assert opening in source, f"{opening!r} is gone"
    tail = source.split(opening, 1)[1]
    assert closing in tail, f"{closing!r} did not follow {opening!r}"
    return tail.split(closing, 1)[0]


SECTION = block(ABOUT, "private var hostSection: some View {", "/// The width every state")
ACTION = block(ABOUT, "private var hostAction: some View {", "/// The colour the host line carries")
TONE = block(ABOUT, "private var hostLineTone: Color {", "/// The host line:")
LINE = block(ABOUT, "private var hostLine: String {", "/// What the log is *about*")
CHECK = block(MODEL, "public func checkHostUpdate(refresh: Bool = false) async {",
              "/// 404 on `/v1/update`")


class TheRowIsOneLine(unittest.TestCase):

    def test_the_heading_is_still_a_heading_and_nothing_else(self) -> None:
        self.assertIn('SectionCaption("HOST SERVICE")', SECTION)
        # The old shape: caption and button sharing one HStack, four points apart.
        self.assertNotIn("HStack(spacing: 4)", SECTION,
                         "the action must not ride on the heading's line")
        self.assertNotIn(".buttonStyle(.plain)", SECTION,
                         "a plain, muted label does not look like a press")

    def test_the_version_and_the_status_are_one_string(self) -> None:
        # One line of text, built in one place, so no state can split it in two again.
        self.assertEqual(ABOUT.count("Text(hostLine)"), 1,
                         "the host line is drawn once, not once per state")
        self.assertIn('"\\(status.current) · \\(latest) available"', LINE)
        self.assertIn('"\\(status.current) · \\(latest) is out; this host does not update itself"', LINE)
        self.assertIn('"\\(status.current) · could not check"', LINE)
        self.assertIn('"\\(status.current) · up to date"', LINE)
        # The version is a monospaced number beside its status, not a heading of its own.
        section_text = SECTION.split("Text(hostLine)", 1)[1]
        self.assertIn(".monospacedDigit()", section_text.split("Spacer", 1)[0])

    def test_the_action_is_on_that_same_line(self) -> None:
        self.assertIn("Text(hostLine)", SECTION)
        self.assertIn("hostAction", SECTION)
        self.assertIn(".frame(width: Self.hostActionWidth, alignment: .trailing)", SECTION)
        self.assertLess(SECTION.index("Text(hostLine)"), SECTION.index("hostAction"),
                        "the status comes first, the press answers it")
        self.assertLess(SECTION.index("Spacer(minLength: 8)"), SECTION.index("hostAction"),
                        "the action is the right-hand end of the line")
        self.assertIn("private static let hostActionWidth: CGFloat = 104", ABOUT)

    def test_the_press_is_a_bordered_control_like_the_rest_of_the_pane(self) -> None:
        self.assertIn('Button("Check now")', ACTION)
        self.assertIn(".buttonStyle(.bordered)", ACTION)
        self.assertIn(".controlSize(.small)", ACTION)
        self.assertIn("checkHostUpdate(refresh: true)", ACTION)


class TheThreeAnswersReadDifferently(unittest.TestCase):

    def test_up_to_date_is_muted_and_never_claims_a_version_that_does_not_exist(self) -> None:
        self.assertIn("return Tokens.textMuted", TONE)
        self.assertIn('if status.latest == nil { return Tokens.warning }', TONE,
                      "a check that failed is not the same grey as one that answered")

    def test_an_available_update_is_the_accent_and_names_the_version_to_move_to(self) -> None:
        self.assertIn("if status.hasNewerRelease { return status.canSelfUpdate ? Tokens.accentText : Tokens.warning }",
                      TONE)
        self.assertIn("\\(latest) available", LINE, "the version to move to is in the line")

    def test_a_failed_check_is_the_warning_tone(self) -> None:
        self.assertIn("status.latest == nil", TONE)
        self.assertIn("Tokens.warning", TONE)
        self.assertIn("could not check", LINE)

    def test_the_row_keeps_the_hosts_own_number_when_a_check_failed(self) -> None:
        """The version the host reported is never replaced by "up to date" or by a cached value."""
        self.assertIn('return "\\(status.current) · could not check: \\(failure)"', LINE)
        # The failure sentence comes before either "up to date" return, so a press that 404s can
        # never leave the row reading as if it had been answered.
        self.assertLess(LINE.index("could not check: \\(failure)"), LINE.index('· up to date'),
                        "a failed check must not fall through to the answered sentence")
        self.assertIn("hostCheckFailure", TONE, "a failed press is not the same grey as a good one")
        # And with no answer at all, the reason a press did nothing is the line.
        self.assertIn('return "could not check: \\(failure)"', LINE)

    def test_a_host_that_cannot_update_itself_is_not_painted_as_an_offer(self) -> None:
        # Accent means "there is something to press"; this host has nothing to press.
        self.assertIn("status.canSelfUpdate ? Tokens.accentText : Tokens.warning", TONE)
        self.assertIn("does not update itself", LINE)


class TheRowDoesNotMoveBetweenStates(unittest.TestCase):

    def test_every_state_draws_the_same_class_of_control_in_the_same_slot(self) -> None:
        self.assertEqual(ACTION.count(".buttonStyle(.bordered)"), 4,
                         "Check now, Checking…, Update/Try again and Dismiss are one kind of control")
        self.assertEqual(ACTION.count(".controlSize(.small)"), 5,
                         "the busy spinner is the only branch that is not a small control")
        # The slot's width is a constant of the row, so an update cannot nudge the line.
        self.assertIn(".frame(width: Self.hostActionWidth, alignment: .trailing)", SECTION)
        self.assertEqual(SECTION.count("hostActionWidth"), 1)

    def test_the_update_button_keeps_its_behaviour_and_its_identifier(self) -> None:
        self.assertIn("Button(title)", ACTION)
        self.assertIn("beginHostUpdate()", ACTION)
        self.assertIn('accessibilityIdentifier("aboutHostUpdate")', ACTION)
        self.assertIn(".disabled(!update.canStartPress)", ACTION)

    def test_the_version_line_is_not_inside_the_action(self) -> None:
        self.assertNotIn("Text(hostLine)", ACTION,
                         "the status line must not be redrawn per state, or the row would shift")
        self.assertIn('accessibilityIdentifier("aboutHostVersion")', SECTION)

    def test_a_running_press_reports_its_stage_on_its_own_line(self) -> None:
        self.assertIn("store.model.hostUpdate?.stateText", SECTION)
        self.assertIn('accessibilityIdentifier("aboutHostState")', SECTION)
        self.assertIn("ProgressView()", ACTION)
        self.assertIn('accessibilityIdentifier("aboutHostBusy")', ACTION)


class ACheckInFlightSaysSo(unittest.TestCase):

    def test_the_button_says_checking_and_is_disabled(self) -> None:
        self.assertIn('Button("Checking…")', ACTION)
        self.assertIn(".disabled(true)", ACTION)
        self.assertIn(".disabled(store.model.hostCheckRunning)", ACTION)

    def test_the_model_refuses_the_second_press_too(self) -> None:
        self.assertIn("@Published public private(set) var hostCheckRunning = false", MODEL)
        self.assertIn("guard !hostCheckRunning else { return }", CHECK)
        self.assertIn("hostCheckRunning = true", CHECK)
        # The reset has to leave on every exit, including a thrown request.
        self.assertIn("defer { if refresh { hostCheckRunning = false } }", CHECK)
        self.assertLess(CHECK.index("defer { if refresh { hostCheckRunning = false } }"),
                        CHECK.index("do {"),
                        "a defer inside the `if` above would run the moment that block ended")

    def test_only_a_manual_check_is_a_press(self) -> None:
        # Launch, reconnect and the install poll call `checkHostUpdate()`; none of them may light up
        # the button as if somebody had pressed it.
        self.assertIn("if refresh {", CHECK)
        # A press with no client is answered, not swallowed: the row gets a reason and the log a
        # line (this used to be `guard let client = hostUpdateClient else { return }`).
        self.assertIn("guard let client = hostUpdateClient else {", CHECK)
        self.assertIn("hostCheckFailure = why", CHECK)
        self.assertIn('ClientLog.note("host update check now: \\(why)"', CHECK)

    def test_the_press_always_writes_one_log_line_with_the_url_it_used(self) -> None:
        # The trace lives in the client, where the URL is actually built, and names the URL, whether
        # a bearer went with it, and the status that came back.
        self.assertIn('"host update \\(word): GET \\(url.absoluteString) (\\(bearer)) → \\(outcome)"', KIT)
        self.assertIn('category: "update"', KIT)
        # A press is never quiet, even when the host answers 404.
        self.assertIn("if refresh || !Self.isMissingUpdateRoute(error) {", CHECK)
        self.assertIn('ClientLog.note("host update check\\(refresh ? " now" : "") failed: \\(reason)"',
                      CHECK)

    def test_the_press_url_is_a_query_not_an_escaped_path(self) -> None:
        """The bug behind "Check now does nothing": `?refresh=1` appended as a path component.

        `URL.appendingPathComponent("v1/update?refresh=1")` percent-encodes the question mark to
        `%3F`, so the press sent `GET /v1/update%3Frefresh=1`, and the host answered 404 — which the
        model read as "no updater here" and swallowed. Verified on the deployed host: that URL is a
        404, and its audit log records the path as unparseable rather than `/v1/update`.
        """
        self.assertNotIn('appendingPathComponent(path)', KIT)
        self.assertNotIn('path += "?refresh=1"', KIT)
        self.assertIn('let url = Self.statusURL(base: prepared.baseURL, refresh: refresh)', KIT)
        self.assertIn('components.queryItems = [URLQueryItem(name: "refresh", value: "1")]', KIT)


class ThePhoneHasNoSuchBlock(unittest.TestCase):
    """Mirrored where it exists, and it does not exist there."""

    def test_the_phone_settings_never_drew_a_host_service_row(self) -> None:
        self.assertNotIn("HOST SERVICE", IOS_SETTINGS)
        self.assertNotIn("Check now", IOS_SETTINGS)
        # What it does have is the app's own version and build, which is a different question.
        self.assertIn('Text("Version")', IOS_SETTINGS)


if __name__ == "__main__":
    unittest.main()
