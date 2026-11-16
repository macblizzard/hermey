"""Allow-always on the approval card, and one dismissal gesture for every sheet.

Two asks from 2026-11-16: "allow always for approval cards" and "on mobile all modal sheets should be
able to close with swipe down, at the moment some closes with swipe down some doesn't".

Both are properties of a surface, not of a screenshot, so both are pinned here: the approval answer
carries a `choice` and `always` is a real token the host records; and no sheet in either app may refuse
the drag while the rest accept it.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
CARD = (ROOT / "Sources" / "HermeyUI" / "ApprovalCard.swift").read_text(encoding="utf-8")
MOBILE_APPROVAL = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileApproval.swift").read_text(encoding="utf-8")
MAC_APPROVAL = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ApprovalRequestView.swift").read_text(encoding="utf-8")
MAC_STORE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
LANGUAGE = (ROOT / "Sources" / "HermeyUI" / "SheetLanguage.swift").read_text(encoding="utf-8")


class AllowAlwaysIsARealAnswer(unittest.TestCase):
    def test_the_answer_carries_the_choice_and_always_is_one_of_them(self) -> None:
        # The host records `always` in its own allow-list (tools/approval.py honours it in later
        # sessions); the client's job is to send it, not to keep one.
        self.assertIn('"choice": .string(choice)', MODEL)
        self.assertIn('let wanted = remembering ? "always" : "once"', MODEL)

    def test_a_permanent_choice_is_only_sent_when_the_host_offered_it(self) -> None:
        approve = MODEL.split("public func approve(", 1)[1].split("public func deny(", 1)[0]
        self.assertIn("offered.contains(wanted)", approve,
                      "inventing `always` for a request that did not offer it is the client deciding "
                      "a security question on the host's behalf")

    def test_both_apps_offer_the_button_from_the_hosts_choices(self) -> None:
        self.assertIn("allowsAlways: presentation.hostOffersAlways", MOBILE_APPROVAL)
        self.assertNotIn("allowsAlways: false", MOBILE_APPROVAL,
                         "the card supports Always; a hardcoded false hid a real answer")
        self.assertIn("var hostOffersAlways: Bool { choices.contains { $0.id == \"always\" } }",
                      MOBILE_APPROVAL)
        self.assertIn("allowsAlways: offersAlways", MAC_APPROVAL)
        self.assertIn('items.contains { $0.stringValue == "always" }', MAC_APPROVAL)
        self.assertNotIn("allowsAlways: false", MAC_APPROVAL)

    def test_always_takes_the_remembering_path_on_both_platforms(self) -> None:
        # The phone draws the card twice (the approval sheet and the inline transcript row); the Mac
        # has one panel for it. Both must send the remembering answer.
        self.assertEqual(MOBILE_APPROVAL.count("model.approve(request, remembering: true)"), 2)
        self.assertEqual(MAC_APPROVAL.count("store.approve(request, remembering: true)"), 1)
        self.assertIn("func approve(_ request: ServerRequest, remembering: Bool = false)",
                      MAC_STORE)

    def test_the_card_still_shows_the_scope_it_will_remember(self) -> None:
        self.assertIn('answerButton(.always, kind: .ghost, title: "Always for \\(scope)")', CARD)


class EverySheetCanBeSwipedAway(unittest.TestCase):
    def test_the_house_chrome_carries_the_grabber(self) -> None:
        # One place, applied at every presentation site — the same reason the chrome exists at all.
        self.assertIn(".presentationDragIndicator(.visible)", LANGUAGE)

    def test_no_sheet_refuses_the_gesture(self) -> None:
        offenders = []
        for app in ("HermesMobile", "HermesMac"):
            for path in (ROOT / "Apps" / app).rglob("*.swift"):
                if "interactiveDismissDisabled" in path.read_text(encoding="utf-8"):
                    offenders.append(f"{app}/{path.name}")
        for path in (ROOT / "Sources" / "HermeyUI").rglob("*.swift"):
            if "interactiveDismissDisabled" in path.read_text(encoding="utf-8"):
                offenders.append(f"HermeyUI/{path.name}")
        self.assertEqual(offenders, [], "a sheet that refuses the drag is the report: some close, some do not")

    def test_the_two_full_screen_surfaces_are_covers_not_sheets(self) -> None:
        # Named so a future reader knows they are deliberate: the bot's computer (a live VNC surface)
        # and a group chat. They have their own way back; they are not modal sheets.
        mobile = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
        listing = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
        self.assertIn(".fullScreenCover(isPresented: $showComputer)", mobile)
        self.assertIn(".fullScreenCover(item: $openRoom)", listing)
