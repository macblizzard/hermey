"""Shared-store download links become cards in both apps' transcripts."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CARD = (ROOT / "Sources/HermeyUI/HermesFileLinkCard.swift").read_text(encoding="utf-8")
MAC = (ROOT / "Apps/HermesMac/Conversation/MarkdownTextView.swift").read_text(encoding="utf-8")
IOS_MD = (ROOT / "Apps/HermesMobile/Views/MobileMarkdown.swift").read_text(encoding="utf-8")
IOS_ROW = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text(encoding="utf-8")


class StorePortsAreRecognised(unittest.TestCase):
    def test_recognition_uses_the_store_ports_not_an_installation_address(self) -> None:
        for token in ("tlsPort = 9446", "directPort = 8099", "isStorePort(url.port)"):
            with self.subTest(token=token):
                self.assertIn(token, CARD)
        # A public repo must not compile in one install's host or IP: the store lives on
        # whichever machine the app is paired to. Patterns, not literals, keep this guard clean.
        for personal in (r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.",
                         r"[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.ts\.net"):
            with self.subTest(personal=personal):
                self.assertNotRegex(CARD, personal)
        self.assertIn("(?:9446|8099)", CARD)

    def test_it_does_not_turn_every_link_into_a_card(self) -> None:
        self.assertIn("isStorePort(_ port: Int?) -> Bool", CARD)
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
        # The cache exists and is seeded where writing state is legal; the exact optionality moved
        # when the getter stopped writing it from body (`test_render_state_writes` pins that rule).
        self.assertIn("@State private var cachedSource: String", MAC)
        self.assertIn("_cachedClean = State(initialValue:", MAC)

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
        self.assertIn("components.port = HermesFileLinks.tlsPort", card)


class FleetApprovalSettings(unittest.TestCase):
    def test_host_modes_keep_their_spelling(self) -> None:
        kit = (ROOT / "Sources/HermesKit/ApprovalSettings.swift").read_text(encoding="utf-8")
        for mode in ("manual", "smart", "off"):
            self.assertIn(f"case {mode}", kit)
        self.assertIn('case .manual: return "Ask always"', kit)
        self.assertIn('case .smart: return "Auto"', kit)
        self.assertIn('case .off: return "Allow always"', kit)

    def test_every_layer_forwards_the_setting(self) -> None:
        gateway = (ROOT / "Sources/HermesKit/GatewayClient.swift").read_text(encoding="utf-8")
        pointer = (ROOT / "Sources/HermesKit/EndlessSessionPointer.swift").read_text(encoding="utf-8")
        actor = (ROOT / "Sources/HermesKit/GatewayClientActor.swift").read_text(encoding="utf-8")
        model = (ROOT / "Sources/HermesAppKit/AppModel.swift").read_text(encoding="utf-8")
        for layer in (gateway, pointer, actor, model):
            self.assertIn("func approvalSettings()", layer)
            self.assertIn("func setApprovalMode(", layer)
        self.assertIn('bridgePUT("v1/bots/approvals", body: ["mode": mode.rawValue]', pointer)

    def test_both_settings_surfaces_exist(self) -> None:
        ios = (ROOT / "Apps/HermesMobile/Views/SettingsScreen.swift").read_text(encoding="utf-8")
        mac = (ROOT / "Apps/HermesMac/Views/MacSettingsView.swift").read_text(encoding="utf-8")
        tab = (ROOT / "Apps/HermesMac/Views/ApprovalSettingsTab.swift").read_text(encoding="utf-8")
        self.assertIn("approvalsSection", ios)
        self.assertIn("ApprovalSettingsTab(store: store)", mac)
        self.assertIn("ApprovalMode.allCases", tab)
        self.assertIn("role: .destructive", tab)

class ApprovalsDefaultAndLayout(unittest.TestCase):
    def test_auto_is_the_recommended_default_on_both_platforms(self) -> None:
        kit = (ROOT / "Sources/HermesKit/ApprovalSettings.swift").read_text(encoding="utf-8")
        self.assertIn("public static let recommended: ApprovalMode = .smart", kit)
        for name in ("Apps/HermesMac/Views/ApprovalSettingsTab.swift",
                     "Apps/HermesMobile/Views/SettingsScreen.swift"):
            view = (ROOT / name).read_text(encoding="utf-8")
            self.assertIn("?? .recommended", view)
            self.assertIn("answer.unset.count == answer.profiles.count", view)
            self.assertIn('mode == .smart', view)

    def test_mac_form_uses_the_house_grouped_style(self) -> None:
        tab = (ROOT / "Apps/HermesMac/Views/ApprovalSettingsTab.swift").read_text(encoding="utf-8")
        self.assertIn(".formStyle(.grouped)", tab)
        self.assertIn(".scrollContentBackground(.hidden)", tab)

    def test_bridge_skips_reserved_profile_names(self) -> None:
        admin = (ROOT / "Bridge/hermes_bridge/bot_admin.py").read_text(encoding="utf-8")
        self.assertIn('RESERVED_PROFILE_NAMES = frozenset({"hermes", "default", "test", "tmp", "root", "sudo"})',
                      admin)

class ApprovalsWriteFeedback(unittest.TestCase):
    def test_mac_rows_do_not_show_a_focus_ring_and_show_progress(self) -> None:
        tab = (ROOT / "Apps/HermesMac/Views/ApprovalSettingsTab.swift").read_text(encoding="utf-8")
        self.assertIn(".focusable(false)", tab)
        self.assertIn('@State private var applying: ApprovalMode?', tab)
        self.assertIn("Applying \\(applying.title) to every bot…", tab)

    def test_the_write_answer_is_in_the_get_shape(self) -> None:
        admin = (ROOT / "Bridge/hermes_bridge/bot_admin.py").read_text(encoding="utf-8")
        self.assertIn('"profiles": states,', admin)
        self.assertIn('"unset": unset,', admin)

