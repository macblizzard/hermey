"""Office files in the apps: attach them, draw them as rows, open them.

The host is the other half: it sniffs the upload, extracts the text, and serves the bytes. These
checks pin what the *apps* owe — that both pickers offer PDF/Word/Excel, that a file that is not a
picture is a row (type symbol, name, size, a press) rather than a generic blob, that a bot-made
workspace link in a reply body becomes that same row, that the bytes come back over the device
bearer, and that the Mac opens them with Quick Look. A source scan cannot run Quick Look; it can
pin that the app asks for it and that the fetch route is the one the host serves.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "Sources" / "HermesKit"
ROW = (ROOT / "Sources" / "HermeyUI" / "AttachmentFileRow.swift").read_text(encoding="utf-8")
FILES = (KIT / "AttachmentFiles.swift").read_text(encoding="utf-8")
STORE = (KIT / "AttachmentImageStore.swift").read_text(encoding="utf-8")
SENT = (KIT / "SentAttachment.swift").read_text(encoding="utf-8")
ATTACH_RPC = (KIT / "GatewayClientActor.swift").read_text(encoding="utf-8")

MAC_MENU = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MacAttachmentMenu.swift").read_text(encoding="utf-8")
MAC_ROW = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift").read_text(encoding="utf-8")
MAC_QUICKLOOK = ROOT / "Apps" / "HermesMac" / "Conversation" / "MacAttachmentQuickLook.swift"
MAC_STORE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")

PICKER = (ROOT / "Apps" / "HermesMobile" / "Views" / "AttachmentPicker.swift").read_text(encoding="utf-8")
PAYLOAD = (ROOT / "Apps" / "HermesMobile" / "Networking" / "AttachmentPayload.swift").read_text(encoding="utf-8")
MOBILE_ROW = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text(encoding="utf-8")
MOBILE_SHARE = ROOT / "Apps" / "HermesMobile" / "Views" / "MobileAttachmentShare.swift"
MOBILE_SCREEN = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
APP_ENV = (ROOT / "Apps" / "HermesMobile" / "App" / "AppEnvironment.swift").read_text(encoding="utf-8")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class TheOfficeTypesAreKnown(unittest.TestCase):
    def test_the_three_extensions_are_declared_once(self) -> None:
        self.assertIn('officeExtensions: [String] = ["pdf", "docx", "xlsx"]', FILES)

    def test_each_type_has_its_own_symbol_and_word(self) -> None:
        kind = FILES[FILES.index("public enum AttachmentKind"):FILES.index("public enum AttachmentLocation")]
        for symbol in ("doc.richtext", "doc.text", "tablecells"):
            self.assertIn(f'return "{symbol}"', kind)
        self.assertIn("case .pdf:", kind)
        self.assertIn("case .spreadsheet:", kind)


class BothPickersOfferThem(unittest.TestCase):
    def test_the_mac_files_panel_takes_pdf_word_excel_and_images(self) -> None:
        self.assertIn("AttachmentKind.officeExtensions", MAC_MENU)
        self.assertIn("var types: [UTType] = [.pdf, .image]", MAC_MENU)
        self.assertIn("UTType(filenameExtension: ext)", MAC_MENU)
        self.assertIn("pick(contentTypes: Self.fileTypes", MAC_MENU)

    def test_the_phone_file_picker_takes_the_same_three(self) -> None:
        self.assertIn("AttachmentKind.officeExtensions", PICKER)
        self.assertIn("[.pdf, .image]", PICKER)
        self.assertIn("UIDocumentPickerViewController(forOpeningContentTypes: AttachmentFileTypes.accepted", PICKER)

    def test_both_composers_wear_the_types_symbol_before_sending(self) -> None:
        mac_bar = read(ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerBar.swift")
        self.assertIn("AttachmentKind(name: attachment.name).symbolName", mac_bar)
        self.assertIn("AttachmentKind(name: attachment.name).symbolName", MOBILE_SCREEN)


class TheRowIsARow(unittest.TestCase):
    def test_it_shows_a_symbol_a_name_and_a_size(self) -> None:
        self.assertIn("Image(systemName: kind.symbolName)", ROW)
        self.assertIn("Text(name)", ROW)
        self.assertIn("ByteCountFormatter.string(fromByteCount: Int64(size)", ROW)
        self.assertIn("kind.displayName", ROW, "no invented size: the type's word when bytes are unknown")

    def test_a_press_opens_it_and_the_row_says_so(self) -> None:
        self.assertIn("public let onOpen: () -> Void", ROW)
        self.assertIn(".onTapGesture(perform: onOpen)", ROW)
        self.assertIn('accessibilityLabel("Attached file \\(name)")', ROW)
        self.assertIn("accessibilityHint", ROW)

    def test_the_not_there_yet_state_is_quiet_and_offers_a_retry(self) -> None:
        self.assertIn("case notReady", ROW)
        self.assertIn("Not there yet", ROW)
        self.assertIn("Button(action: onRetry)", ROW)
        self.assertIn('Text("Retry")', ROW)

    def test_the_fetch_is_one_per_transcript_and_survives_a_recycled_row(self) -> None:
        self.assertIn("public final class AttachmentOpenCoordinator", ROW)
        self.assertIn("@Published public private(set) var states", ROW)
        self.assertIn("AttachmentFileStatus.forError(error)", ROW)

    def test_a_404_is_not_an_error_message(self) -> None:
        self.assertIn("if let fetch = error as? AttachmentFetchError, fetch.isNotReady { return .notReady }", ROW)


class TheTranscriptsDrawTheRows(unittest.TestCase):
    def test_the_mac_user_bubble_draws_a_file_row(self) -> None:
        self.assertIn("AttachmentFileRow(name: attachment.name", MAC_ROW)
        self.assertIn("sentFileRow(attachment)", MAC_ROW)
        # The picture path is untouched.
        self.assertIn("imageThumbnail(attachment, image: image)", MAC_ROW)

    def test_the_phone_user_bubble_draws_a_file_row(self) -> None:
        self.assertIn("AttachmentFileRow(name: attachment.name", MOBILE_ROW)
        self.assertIn("sentFileRow(attachment)", MOBILE_ROW)
        self.assertIn("AttachmentThumbnail(data: data, size: 132)", MOBILE_ROW)

    def test_a_sent_file_is_remembered_with_its_size(self) -> None:
        self.assertIn("public let size: Int?", SENT)
        self.assertIn("size: attachment.size", SENT)


class AWorkspaceLinkIsARow(unittest.TestCase):
    def test_the_link_is_recognised_by_the_route_the_host_serves(self) -> None:
        self.assertIn('routeMarker = "/v1/workspace/"', FILES)
        self.assertIn('segments[0] == "v1", segments[1] == "workspace", segments[3] == "file"', FILES)
        self.assertIn('URLQueryItem(name: "path"', FILES)

    def test_a_bot_made_file_becomes_the_same_row_in_both_apps(self) -> None:
        for source in (MAC_ROW, MOBILE_ROW):
            self.assertIn("WorkspaceLinkScan.scan(entry.text)", source)
            self.assertIn("replyFileRows(files.links)", source)
            self.assertIn("AttachmentFileRow(name: link.name", source)

    def test_the_link_does_not_stay_as_a_url_in_the_prose(self) -> None:
        self.assertIn("WorkspaceLinkScan.scan(entry.text)", MAC_ROW)
        self.assertIn("MarkdownTextView(text: files.prose)", MAC_ROW)
        self.assertIn("rawText: files.prose", MOBILE_ROW)

    def test_no_refresh_dance_means_the_row_fetches_at_press_time(self) -> None:
        self.assertIn("public func open(_ location: AttachmentLocation)", ROW)
        self.assertIn("let url = try await loader(location)", ROW)


class TheBytesComeOverTheBearer(unittest.TestCase):
    def test_an_upload_is_read_from_the_route_the_pictures_use(self) -> None:
        self.assertIn('appendingPathComponent("v1/attachments/\\(encodedProfile)/\\(encodedName)")', FILES)

    def test_a_workspace_file_is_read_from_the_file_route(self) -> None:
        self.assertIn('appendingPathComponent("v1/workspace/\\(encodedProfile)/file")', FILES)
        self.assertIn('URLQueryItem(name: "path", value: path)', FILES)

    def test_every_request_presents_the_device_ticket(self) -> None:
        self.assertIn('request.setValue("Bearer \\(resolved.ticket)", forHTTPHeaderField: "Authorization")', FILES)

    def test_a_missing_file_is_a_404_not_an_empty_200(self) -> None:
        self.assertIn("if http.statusCode == 404 { throw AttachmentFetchError.notReady }", FILES)

    def test_both_apps_inject_the_client(self) -> None:
        self.assertIn("model.attachmentClient = AttachmentFileClient(endpoint:", MAC_STORE)
        self.assertIn("self.model.attachmentClient = AttachmentFileClient(endpoint:", APP_ENV)

    def test_the_bytes_land_in_the_existing_attachment_cache(self) -> None:
        self.assertIn("public enum AttachmentFileCache", FILES)
        self.assertIn("AttachmentImageStore.save(data, as: location.cacheKey)", FILES)
        self.assertIn("public static func url(named name: String) -> URL?", STORE)


class QuickLookOnTheMac(unittest.TestCase):
    def test_the_mac_opens_a_file_in_quick_look(self) -> None:
        source = read(MAC_QUICKLOOK)
        self.assertIn("import Quartz", source)
        self.assertIn("QLPreviewView", source)
        self.assertIn("preview.previewItem = url as NSURL", source)

    def test_the_transcript_hands_the_file_to_it(self) -> None:
        self.assertIn("MacAttachmentQuickLook.shared.show(url)", MAC_ROW)

    def test_the_phone_hands_the_file_to_the_system_sheet(self) -> None:
        source = read(MOBILE_SHARE)
        self.assertIn("UIActivityViewController(activityItems: [url]", source)
        self.assertIn("MobileAttachmentShare.present(url)", MOBILE_ROW)


class NothingWasRegressed(unittest.TestCase):
    def test_images_still_travel_the_way_they_did(self) -> None:
        self.assertIn('"image.attach_bytes"', ATTACH_RPC)
        self.assertIn('"file.attach"', ATTACH_RPC)
        self.assertIn('AttachmentImageStore.save(attachment.data, as: receipt.path ?? attachment.name)',
                      read(KIT / ".." / "HermesAppKit" / "AppModel.swift"))

    def test_the_phone_still_sends_a_file_as_a_data_url_over_the_same_rpc(self) -> None:
        self.assertIn('return ("file.attach"', PAYLOAD)
        self.assertIn('"data:application/octet-stream;base64,"', PAYLOAD)

    def test_nothing_writes_a_selected_file_into_the_repository(self) -> None:
        # The only write paths added are the cache and the existing ones; a security-scoped file is
        # read, never copied into the source tree.
        for source in (MAC_MENU, PICKER, MAC_QUICKLOOK.read_text(encoding="utf-8")):
            self.assertNotRegex(source, re.compile(r"write\(to:.*ROOT|/Users/.*/Projects"))


if __name__ == "__main__":
    unittest.main()


class TheBubbleShowsOnlyWhatWasTyped(unittest.TestCase):
    """The host appends an attachment's extracted text to the stored user row; the bubble must not."""

    def test_the_host_block_never_reaches_the_bubble(self) -> None:
        src = (ROOT / "Sources" / "HermesKit" / "MessageRefs.swift").read_text(encoding="utf-8")
        body = src[src.index("public static func display"):]
        self.assertIn('body.range(of: "--- attachment:")', body,
                      "the labelled block the host appends has to be cut before the bubble draws")
        self.assertIn("String(body[..<marker.lowerBound])", body)

    def test_the_typed_words_are_kept(self) -> None:
        src = (ROOT / "Sources" / "HermesKit" / "MessageRefs.swift").read_text(encoding="utf-8")
        display = src[src.index("public static func display"):src.index("public static func names")]
        self.assertIn("trimmingCharacters(in: .whitespacesAndNewlines)", display,
                      "cutting the block must not leave the typed words ending in blank lines")
