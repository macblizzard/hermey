"""Shared-store download links become cards in both apps' transcripts."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CARD = (ROOT / "Sources/HermeyUI/HermesFileLinkCard.swift").read_text(encoding="utf-8")
MAC = (ROOT / "Apps/HermesMac/Conversation/MarkdownTextView.swift").read_text(encoding="utf-8")
IOS_MD = (ROOT / "Apps/HermesMobile/Views/MobileMarkdown.swift").read_text(encoding="utf-8")
IOS_ROW = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text(encoding="utf-8")


class BothFileStoreHostsAreRecognised(unittest.TestCase):
    def test_the_card_knows_the_tailnet_and_dns_free_origins(self) -> None:
        self.assertIn("hermes.corvus-vibes.ts.net", CARD)
        self.assertIn("100.86.19.1", CARD)
        self.assertIn(":9446", CARD)
        self.assertIn(":8099", CARD)

    def test_it_does_not_turn_every_link_into_a_card(self) -> None:
        self.assertIn('host == "hermes.corvus-vibes.ts.net" || host == "100.86.19.1"', CARD)
        self.assertIn("parts.count >= 2", CARD)

    def test_names_and_owner_come_from_the_path(self) -> None:
        self.assertIn("removingPercentEncoding", CARD)
        self.assertIn("Text(link.filename)", CARD)
        self.assertIn("From \\(link.owner)", CARD)

    def test_markdown_wrappers_are_stripped_too(self) -> None:
        self.assertIn(r'\[[^\]\n]*\]\(', CARD)

    def test_the_card_offers_open_copy_and_share(self) -> None:
        for token in ("openURL(link.url)", "ShareLink(item: link.url)", "UIPasteboard", "NSPasteboard"):
            with self.subTest(token=token):
                self.assertIn(token, CARD)


class BothAppsRenderIt(unittest.TestCase):
    def test_mac_renders_cards_from_the_raw_message(self) -> None:
        self.assertIn("HermesFileLinks.removingLinks(from: text)", MAC)
        self.assertIn("ForEach(fileLinks)", MAC)
        self.assertIn("HermesFileLinkCard(link: link)", MAC)
        self.assertIn("synchronise(cleanText)", MAC)
        self.assertIn("@State private var cachedSource: String?", MAC)

    def test_ios_renders_cards_and_takes_the_url_out_of_the_prose(self) -> None:
        self.assertIn("rawText: String? = nil", IOS_MD)
        self.assertIn("ForEach(fileLinks)", IOS_MD)
        self.assertIn("HermesFileLinkCard(link: link)", IOS_MD)
        self.assertIn("markdownCache.sanitized(label.body)", IOS_ROW)
        self.assertIn("markdownCache.sanitized(entry.text)", IOS_ROW)

    def test_room_messages_get_cards_too(self) -> None:
        self.assertIn("IncrementalMarkdown.parse(HermesFileLinks.removingLinks(from: text))", IOS_MD)


class LongMessagesDoNotFreezeScrolling(unittest.TestCase):
    def test_uikits_own_link_detector_is_off(self) -> None:
        # It rescans a multi-kilobyte message during layout, on top of our markdown link pass.
        selector = (ROOT / "Apps/HermesMobile/Views/MobileSelectableText.swift").read_text(encoding="utf-8")
        self.assertIn("view.dataDetectorTypes = []", selector)
        self.assertNotIn("view.dataDetectorTypes = [.link]", selector)

    def test_url_extraction_is_cached_per_message(self) -> None:
        self.assertIn("@State private var cachedLinkSource: String?", IOS_MD)
        self.assertIn("if cachedLinkSource == rawText { return cachedLinks }", IOS_MD)
        self.assertIn("func sanitized(_ raw: String) -> String", IOS_MD)
        self.assertIn("if rawSource == raw { return cleanSource }", IOS_MD)


class LinksStayTappableWithoutTheDetector(unittest.TestCase):
    def test_markdown_links_are_linkified_into_text(self) -> None:
        selector = (ROOT / "Apps/HermesMobile/Views/MobileSelectableText.swift").read_text(encoding="utf-8")
        self.assertIn("InlineMarkdown.linkified(InlineMarkdown.spans(source))", selector)
        self.assertIn("InlineMarkdown.bareLinkRanges(in: text)", selector)
        render = (ROOT / "Sources/HermesRender/InlineMarkdown.swift").read_text(encoding="utf-8")
        self.assertIn("public static func linkified", render)
        self.assertIn("public static func bareLinkRanges", render)


class ProcessNoticesAreHidden(unittest.TestCase):
    def test_the_decoder_drops_the_runtimes_banner(self) -> None:
        decoder = (ROOT / "Sources/HermesKit/GatewayEventDecoder.swift").read_text(encoding="utf-8")
        self.assertIn('text.hasPrefix("[IMPORTANT: Background process ")', decoder)
        self.assertIn("if Self.isProcessNotice(text) { return nil }", decoder)
        self.assertIn("compactMap { index, message in", decoder)


class SaveToFilesNeedsAFile(unittest.TestCase):
    def test_ios_shares_a_downloaded_file_not_a_url(self) -> None:
        share = (ROOT / "Sources/HermeyUI/HermesFileShareSheet.swift").read_text(encoding="utf-8")
        self.assertIn("UIActivityViewController(activityItems: [url]", share)
        self.assertIn("Save to Files", share)
        card = (ROOT / "Sources/HermeyUI/HermesFileLinkCard.swift").read_text(encoding="utf-8")
        self.assertIn("URLSession.shared.download(from: downloadURL())", card)
        self.assertIn("HermesFileShareSheet(url: file.url)", card)
        self.assertIn("appendingPathComponent(link.filename)", card)
        self.assertIn("components.host = \"hermes.corvus-vibes.ts.net\"", card)

