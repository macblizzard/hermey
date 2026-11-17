"""A bot's message to another bot is drawn as prose, not as its markdown source.

The transport writes markdown verbatim (`tools/bot_mode_dm.py` only prepends the "Message from 🤖"
signature), so anything that renders bot-to-bot rows with a plain `Text` shows `**bold**` and `- item`
exactly as typed. Both shells did that until 2026-11-16.
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MOBILE = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text()
MAC = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift").read_text()


class BothShellsRenderBotMessages(unittest.TestCase):
    def test_the_mobile_row_parses_markdown(self) -> None:
        self.assertIn("MobileMarkdownText(blocks: IncrementalMarkdown.parse(HermesFileLinks.removingLinks(from: label.body)), rawText: label.body)", MOBILE)

    def test_the_mac_row_renders_markdown(self) -> None:
        self.assertIn("MarkdownTextView(text: label.body", MAC)

    def test_neither_row_falls_back_to_plain_text(self) -> None:
        for name, source in (("mobile", MOBILE), ("mac", MAC)):
            self.assertNotIn("Text(label.body)", source,
                             f"the {name} bot-to-bot row would show the markdown source")

    def test_the_sender_attribution_survives(self) -> None:
        # Rendering the body as markdown must not cost the row its face, its name or the door into
        # the exchange: those are the reason the row is not a plain bubble.
        for name, source in (("mobile", MOBILE), ("mac", MAC)):
            row = source.split("private func botMessageRow", 1)[1]
            self.assertIn("label.headerTitle", row, name)
            self.assertIn("BotAvatarView(", row, name)
            self.assertIn("senderProfile", row, name)
