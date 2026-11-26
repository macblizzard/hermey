"""The pet's callout is a small persistent chat.

The owner's ask, in one sentence: tap the pet to open the chat and type, the bot's reply shows
below, clicking away hides it but the thread survives, a new bot message reopens it, answers stay
short, and one conversation caps at twenty messages with a `New` button.

These are source guards, in the style of `test_desktop_pets.py` and `test_pets_polish.py`: CI is the
only Swift compiler and the only cargo the host gets, so the assertions are about what the code says.
The behaviour itself is covered by XCTest in `Tests/HermesKitTests` (the conversation value) and by
`cargo test` beside the ask route (the brevity line). What is pinned here is the part no compiler can
check: that the right rule lives in the right place, and that the old single-exchange behaviour is
really gone rather than sitting beside the new one.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PETS = ROOT / "Apps" / "HermesMac" / "Pets"

BALLOON = (PETS / "PetBalloonView.swift").read_text(encoding="utf-8")
CONTROLLER = (PETS / "DesktopPetController.swift").read_text(encoding="utf-8")
PLACEMENT_SOURCE = (PETS / "PetCalloutPlacement.swift").read_text(encoding="utf-8")
CHAT = (ROOT / "Sources" / "HermesKit" / "PetChat.swift").read_text(encoding="utf-8")
STORE = (ROOT / "Sources" / "HermesKit" / "PetConversationStore.swift").read_text(encoding="utf-8")
MESSAGE = (ROOT / "hermeyd" / "src" / "bot_message.rs").read_text(encoding="utf-8")


def body_of(name: str, source: str) -> str:
    """One Swift function's body, from its signature to the closing brace at four spaces."""
    start = source.index(name)
    return source[start:].split("\n    }", 1)[0]


class TheBalloonIsAConversation(unittest.TestCase):
    """Both roles, in order, drawn as two sides of one thread."""

    def test_the_model_holds_messages_not_one_answer(self):
        self.assertIn("@Published private(set) var conversation: PetConversation", BALLOON)
        self.assertNotIn("@Published private(set) var state: PetBalloonState", BALLOON,
                         "the single-exchange state machine is gone, not kept beside the thread")
        self.assertNotIn("hasExchange", BALLOON, "no half-thread, half-exchange model")

    def test_a_question_and_an_answer_are_both_appended(self):
        self.assertIn("conversation.append(PetMessage(role: .owner, text: question))", BALLOON)
        self.assertIn("conversation.append(PetMessage(role: .bot, text: reply))", BALLOON)

    def test_the_view_draws_every_message_on_its_own_side(self):
        self.assertIn("ForEach(model.conversation.messages)", BALLOON)
        bubble = body_of("private func bubble(_ message: PetMessage) -> some View {", BALLOON)
        self.assertIn("let mine = message.role == .owner", bubble)
        self.assertIn("if mine { Spacer(minLength: 24) }", bubble)
        self.assertIn("if !mine { Spacer(minLength: 24) }", bubble)
        self.assertIn("alignment: mine ? .trailing : .leading", bubble,
                      "yours on the right, the bot's on the left")

    def test_the_transcript_is_bounded_and_scrolls_to_the_newest_line(self):
        self.assertIn(".frame(height: PetCalloutMetrics.transcriptHeight(", BALLOON)
        self.assertIn("ScrollViewReader { proxy in", BALLOON)
        self.assertIn("proxy.scrollTo(last.id, anchor: .bottom)", BALLOON)


class ClosingIsNotAReset(unittest.TestCase):

    def test_dismiss_only_asks_the_controller_to_close_the_window(self):
        dismiss = body_of("func dismiss() {", BALLOON)
        self.assertEqual("onDismiss?()", dismiss.split("\n", 1)[1].strip(),
                         "the model keeps everything; the window is what closes")
        self.assertNotIn("conversation.reset()", dismiss)
        self.assertNotIn("cancel()", dismiss,
                         "the turn keeps running so its answer can reopen the balloon")

    def test_the_store_round_trips_a_thread(self):
        self.assertIn("self.conversation = store.load()", BALLOON,
                      "the thread the pet opens with is what was on disk")
        self.assertIn("store.save(conversation)", BALLOON)
        self.assertIn("public func load() -> PetConversation", STORE)
        self.assertIn("public func save(_ conversation: PetConversation)", STORE)
        save = body_of("public func save(_ conversation: PetConversation) {", STORE)
        self.assertIn("try encoder.encode(document).write(to: fileURL, options: .atomic)", save)
        self.assertIn("clear()", save, "an empty thread removes the file rather than storing []")

    def test_the_file_is_keyed_by_bot_id_and_bounded(self):
        self.assertIn('static let folderName = "PetChat"', STORE)
        self.assertIn("Self.fileName(for: botID) + \".json\"", STORE)
        self.assertIn("public static func fileName(for botID: String) -> String", STORE)
        self.assertIn(".applicationSupportDirectory", STORE,
                      "not Caches: the system may purge those whenever it likes")
        self.assertIn("document.version == Self.version", STORE,
                      "a shape from another version is a miss, never half-read")
        self.assertIn("Array(messages.suffix(Self.maxMessages))", CHAT,
                      "a hand-edited file cannot widen the cap")


class ABotMessageReopensIt(unittest.TestCase):
    """Closed balloon + a bot message = the balloon, with no keyboard.

    The owner asked for the message to arrive by itself; he did not ask to lose the cursor in the
    middle of whatever he was typing, so an auto-open never becomes key and never focuses the field.
    """

    def test_a_reply_landing_while_closed_is_the_controller_s_cue(self):
        self.assertIn("chat.onBotMessage = { [weak self] in self?.botWrote(botID: bot.id) }", CONTROLLER)
        wrote = body_of("private func botWrote(botID: String) {", CONTROLLER)
        self.assertIn("guard pet.balloon == nil else { return }", wrote,
                      "a balloon already showing the answer is not re-presented")
        self.assertIn("openBalloon(botID: botID, focus: false)", wrote)

    def test_an_auto_open_does_not_become_key_or_focus_the_field(self):
        present = body_of("func present(focus: Bool? = nil) {", BALLOON)
        self.assertIn("if focus ?? autoFocus {", present,
                      "the click takes the keyboard; the auto-open does not")
        self.assertIn("panel.makeKey()", present.split("if focus ?? autoFocus {", 1)[1],
                      "makeKey is inside the branch, so an auto-open never takes it")
        appear = BALLOON.split(".onAppear {", 1)[1].split(".onChange", 1)[0]
        self.assertIn("if autoFocus { fieldFocused = true }", appear,
                      "no `fieldFocused = true` on an auto-open, at the first frame")
        self.assertIn("guard autoFocus else { return }", BALLOON,
                      "nor when the turn ends")

    def test_the_auto_open_does_not_clear_the_bot_chat_s_badge(self):
        open_balloon = body_of("private func openBalloon(botID: String, focus: Bool = true) {", CONTROLLER)
        self.assertIn("if focus { clearUnread(for: botID) }", open_balloon,
                      "the pet's thread and the bot's own chat are two conversations: an auto-open "
                      "is not a read of the second one")


class TwentyMessagesThenNew(unittest.TestCase):

    def test_the_cap_is_one_constant(self):
        self.assertIn("public static let maxMessages = 20", CHAT)
        self.assertEqual(len(re.findall(r"maxMessages\s*=\s*\d+", CHAT + BALLOON + CONTROLLER)), 1,
                         "one number, spelled once")
        self.assertNotIn("= 20\n", BALLOON.replace("maxMessages = 20", ""),
                         "the balloon must not keep its own copy of the cap")

    def test_the_cap_counts_both_roles_and_leaves_room_for_the_answer(self):
        self.assertIn("public var canAddExchange: Bool { messages.count + 2 <= Self.maxMessages }",
                      CHAT, "a question only fits when its answer fits too")
        self.assertIn("public var isFull: Bool { !canAddExchange }", CHAT)
        append = body_of("public mutating func append(_ message: PetMessage) -> Bool {", CHAT)
        self.assertIn("guard messages.count < Self.maxMessages else { return false }", append)

    def test_a_full_chat_disables_and_greys_the_field_with_a_reason(self):
        self.assertIn("var acceptsInput: Bool { !isAsking && !conversation.isFull }", BALLOON)
        self.assertIn(".disabled(!model.acceptsInput)", BALLOON)
        self.assertIn(".opacity(model.acceptsInput ? 1 : 0.45)", BALLOON, "visibly greyed")
        self.assertIn("static let fullText = \"This chat is full — start a new one.\"", BALLOON)
        self.assertIn("if model.isFull {", BALLOON)
        self.assertIn("Text(PetBalloonModel.fullText)", BALLOON)

    def test_new_starts_a_clean_conversation(self):
        clear = body_of("func clear() {", BALLOON)
        self.assertIn("conversation.reset()", clear)
        self.assertIn("store.clear()", clear)
        self.assertIn("phase = .idle", clear)
        self.assertIn('draft = ""', clear)

    def test_the_new_button_is_only_there_when_there_is_something_to_clear(self):
        self.assertIn("var canClear: Bool { !conversation.isEmpty }", BALLOON)
        header = BALLOON.split("private var header: some View {", 1)[1].split("private var transcript", 1)[0]
        self.assertIn("if model.canClear {", header)
        self.assertIn('CalloutButton("New") { model.clear() }', header)
        self.assertEqual(BALLOON.count('CalloutButton("New")'), 1)

    def test_the_count_is_shown_where_the_cap_is(self):
        self.assertIn('Text("\\(model.conversation.count)/\\(PetConversation.maxMessages)")', BALLOON,
                      "eighteen of twenty explains a field that closed two messages early")


class AnswersStayShort(unittest.TestCase):
    """The rule reaches the model; the clamp keeps a model that ignores it from winning."""

    def test_the_rule_lives_in_the_ask_the_host_assembles(self):
        self.assertIn("const PET_BREVITY: &str =", MESSAGE)
        rule = MESSAGE.split("const PET_BREVITY: &str =", 1)[1].split(";", 1)[0]
        for phrase in ("two sentences", "plain text", "no preamble", "no lists"):
            self.assertIn(phrase, rule, f"the brevity rule never says {phrase}")
        # Appended by the ask route, for the pet's sender only.
        plan = MESSAGE.split("pub(crate) fn plan_ask", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("if sender == PET_SENDER {", plan)
        self.assertIn("pet_message(sender, profile, question, sender_profile.as_deref())", plan)
        self.assertIn("label(sender, profile, question, sender_profile.as_deref())", plan,
                      "every other sender keeps the label byte for byte")

    def test_the_rule_is_not_in_the_view(self):
        for word in ("two sentences", "no preamble", "no lists"):
            self.assertNotIn(word, BALLOON,
                             "a prompt written in the view never reaches the model")

    def test_the_client_clamps_what_it_displays(self):
        self.assertIn("public enum PetBrevity", CHAT)
        self.assertIn("public static let sentenceLimit = 2", CHAT)
        self.assertIn("public static let characterLimit", CHAT)
        clamp = body_of("public static func clamp(_ text: String) -> String {", CHAT)
        self.assertIn("sentencePrefix(of: flattened, limit: sentenceLimit)", clamp)
        self.assertIn('truncated ? shown + "…" : shown', clamp)
        self.assertIn("Text(PetBrevity.clamp(message.text))", BALLOON)
        self.assertIn(".lineLimit(PetBrevity.lineLimit)", BALLOON)
        self.assertIn(".help(message.text)", BALLOON,
                      "the clamp is display-only; the whole answer is on hover and in Copy")


class NothingTheOwnerHadIsLost(unittest.TestCase):

    def test_the_balloon_is_still_beside_the_pet(self):
        self.assertIn("PetCalloutPlacement.place(", BALLOON)
        self.assertIn("PetCalloutMetrics.tailHeight", BALLOON)
        self.assertIn("PetBalloonShape(tailCentre: anchor.petCentre)", BALLOON)
        self.assertIn("static let gap: Double = 8", PLACEMENT_SOURCE,
                      "the bubble never sits on the pet")

    def test_the_ink_and_the_shape_are_untouched(self):
        self.assertIn("static let body = Color(red: 0.043, green: 0.043, blue: 0.047).opacity(0.97)",
                      BALLOON)
        self.assertIn("static let primary = Color.white", BALLOON)
        self.assertIn(".environment(\\.colorScheme, .dark)", BALLOON)

    def test_the_pet_keeps_its_click_and_its_drag(self):
        self.assertIn("panel.onClick = { [weak self] in self?.clicked(botID: bot.id) }", CONTROLLER)
        self.assertIn("panel.onDragBegan = { [weak self] in self?.dragBegan(botID: bot.id) }",
                      CONTROLLER)
        self.assertIn("ignoresMouseEvents", CONTROLLER,
                      "the click-through watch still runs while the chat is open")

    def test_no_message_text_is_ever_logged(self):
        self.assertNotIn("ClientLog.note(\"pet \\(botID): question sent: ", BALLOON)
        for line in re.findall(r"ClientLog\.note\((.*?)\)\n", BALLOON, re.S):
            for field in ("question", "message.text", "reply"):
                self.assertNotRegex(line, rf"\\\\({field}\\)",
                                    f"a log line interpolates {field}: {line}")
        self.assertIn("answer arrived (\\(reply.count) characters)", BALLOON,
                      "the log records the size, never the words")

    def test_the_bot_chat_is_not_touched(self):
        # The pet's conversation is the host's bounded session; the real chat's documents, cards
        # and transcript are not reachable from here.
        for path in (PETS).rglob("*.swift"):
            text = path.read_text(encoding="utf-8", errors="ignore")
            for banned in ("ConversationDocument", "CardsView", "TranscriptView", "LiveActivity"):
                self.assertNotIn(banned, text, f"{path.name} reaches into {banned}")


if __name__ == "__main__":
    unittest.main()
