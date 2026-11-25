"""The Mac composer's plus reaches both the Photos library and the disk in one click.

The bug these pin: a single `NSOpenPanel` browses *paths*, and a picture in Photos has no path, so
the one panel that replaced the old two-item menu could not offer the library at all. The fix keeps
one click and one panel and puts the library behind a button in the panel's own accessory chrome.

What is asserted here is structural, because the behaviour is AppKit's and only a Mac can run it:
one presentation per click, a Photos route reachable from that presentation, one staging call for
both routes, the panel's `.item` freedom intact, and the phone's picker untouched.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PICKER_PATH = ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerPicker.swift"
BAR_PATH = ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerBar.swift"
PHONE_PATH = ROOT / "Apps" / "HermesMobile" / "Views" / "AttachmentPicker.swift"
PHONE_SCREEN_PATH = ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift"
APP_MODEL_PATH = ROOT / "Sources" / "HermesAppKit" / "AppModel.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


PICKER = read(PICKER_PATH)
BAR = read(BAR_PATH)
PHONE = read(PHONE_PATH)


def decl(marker: str, source: str) -> str:
    """One declaration, from `marker` to the brace that closes it.

    Brace counting is enough for these files: the Swift members scanned here hold no unbalanced
    brace inside a string literal, and every marker is unique in its file.
    """
    start = source.index(marker)
    depth = 0
    seen = False
    for index in range(start, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
            seen = True
        elif char == "}":
            depth -= 1
            if seen and depth == 0:
                return source[start:index + 1]
    return source[start:]


class OneClickIsOnePresentation(unittest.TestCase):
    def test_the_plus_calls_the_picker_once_and_presents_nothing_else(self) -> None:
        self.assertEqual(BAR.count("onAttach:"), 1, "the plus must wire exactly one action")
        self.assertIn("onAttach: { startAttach() }", BAR)
        # No popover of two items at the top level: the panel *is* the presentation.
        self.assertIn("attachPopoverPresented: nil", BAR)
        self.assertIn("attachPopoverContent: nil", BAR)
        self.assertNotIn(".popover(", BAR)

    def test_the_old_two_item_menu_is_gone(self) -> None:
        self.assertFalse((ROOT / "Apps" / "HermesMac" / "Conversation"
                          / "MacAttachmentMenu.swift").exists(),
                         "the menu whose Photos half was unreachable must not linger")
        mac_sources = "\n".join(path.read_text(encoding="utf-8")
                                for path in (ROOT / "Apps" / "HermesMac").rglob("*.swift"))
        self.assertNotIn("MacAttachmentMenu", mac_sources)

    def test_one_panel_is_built_per_click(self) -> None:
        self.assertEqual(PICKER.count("NSOpenPanel()"), 1)
        self.assertEqual(PICKER.count("panel.runModal()"), 1,
                         "a second panel.runModal would be a second presentation")

    def test_the_photos_button_ends_the_panel_instead_of_stacking_on_it(self) -> None:
        self.assertIn("panel?.orderOut(nil)", PICKER)
        self.assertIn("NSApp.stopModal(withCode: .cancel)", PICKER)
        # A sheet from inside the modal, or a second panel on top of it, would be the two-click
        # shape again wearing a button.
        self.assertNotIn("beginSheetModal", PICKER)
        self.assertNotIn("NSAlert()", PICKER.split("static func stage")[0])


class PhotosIsOneVisibleButtonInsideThePanel(unittest.TestCase):
    def test_the_panel_carries_the_accessory_from_the_moment_it_opens(self) -> None:
        # Assigned before runModal, not after: an accessory added later would not be visible at
        # the moment Mohammad looked for it.
        before_modal = PICKER.split("panel.runModal()")[0]
        self.assertIn("panel.accessoryView = photosAccessoryView(target)", before_modal)

    def test_the_accessory_is_a_normal_button_in_the_panels_own_chrome(self) -> None:
        accessory = decl("private static func photosAccessoryView", PICKER)
        self.assertIn('NSButton(title: "Photos…"', accessory)
        self.assertIn("button.bezelStyle = .rounded", accessory)
        self.assertIn("boxType = .separator", accessory, "an accessory bar, not a loose control")
        self.assertIn("NSStackView", accessory)

    def test_the_button_route_is_the_one_the_caller_presents(self) -> None:
        before_modal = PICKER.split("panel.runModal()")[0]
        self.assertIn("wantsPhotos = true", before_modal)
        self.assertIn("guard !wantsPhotos else { return .photos }", PICKER)
        self.assertIn("if MacComposerPicker.chooseAttachments(for: model) == .photos", BAR)
        self.assertIn("showingPhotos = true", BAR)

    def test_the_library_opens_the_system_photo_picker_not_a_folder(self) -> None:
        self.assertIn("import PhotosUI", BAR)
        self.assertIn(".photosPicker(isPresented: $showingPhotos", BAR)
        self.assertIn("matching: .images", BAR)
        # The same encoding choice the phone's PHPicker makes: original bytes in, one transcode.
        self.assertIn("preferredItemEncoding: .current", BAR)
        self.assertIn("await item.loadTransferable(type: Data.self)", BAR)

    def test_the_mac_declares_the_photo_library_purpose_string(self) -> None:
        project = read(ROOT / "project.yml")
        mac_target = project.split("targets:\n  HermesMac:")[1].split("targets:\n  HermesMobile:")[0]
        self.assertIn("NSPhotoLibraryUsageDescription:", mac_target)


class BothRoutesStageTheSameWay(unittest.TestCase):
    def test_the_bytes_reach_the_model_once_and_from_one_place(self) -> None:
        self.assertEqual(PICKER.count("addPendingAttachment("), 1,
                         "the panel and the library must share one staging call")
        self.assertIn("model.addPendingAttachment(name: file.name, data: file.data, "
                      "isImage: file.isImage)", PICKER)
        # The library's half never touches the model's attachment list itself: it hands validated
        # files to the same `stage`.
        library = decl("private func attachLibraryPhotos", BAR)
        self.assertIn("MacComposerPicker.stage(files, in: model, failure: firstFailure)", library)
        self.assertNotIn("addPendingAttachment", library)

    def test_both_routes_go_through_the_panels_stage_call(self) -> None:
        self.assertIn("stage(files, in: model, failure: firstFailure)", PICKER)
        self.assertEqual(PICKER.count("static func stage("), 1)

    def test_the_library_picture_clears_the_same_bars_as_a_file(self) -> None:
        self.assertIn("init(name: String, data: Data, isImage: Bool) throws", PICKER)
        validating = decl("init(name: String, data: Data, isImage: Bool) throws", PICKER)
        self.assertIn("guard !data.isEmpty else { throw Failure.empty }", validating)
        self.assertIn("guard data.count <= AppModel.maxAttachmentBytes else { throw Failure.tooLarge }",
                      validating)
        # The disk read goes through the same initialiser rather than duplicating its checks.
        self.assertIn("return try MacAttachmentFile(name: url.lastPathComponent", PICKER)
        self.assertIn("isImage: true", decl("private func attachLibraryPhotos", BAR))

    def test_the_extension_comes_from_the_bytes_so_heic_still_transcodes(self) -> None:
        # `ImageTranscoding` decides on the *name*, and a library photo has none: deriving the
        # extension from the picker's advertised types can say `.jpeg` for HEIC bytes, which would
        # skip the transcode and hand the host an extension it refuses.
        naming = decl("static func photoName", PICKER)
        self.assertIn("CGImageSourceGetType(source)", naming)
        self.assertIn("UTType(raw as String).preferredFilenameExtension", naming)
        self.assertIn("MacAttachmentFile.photoName(data, index: index)", BAR)

    def test_the_transcode_itself_stays_in_the_model(self) -> None:
        model = read(APP_MODEL_PATH)
        attach = decl("public func addPendingAttachment", model)
        self.assertIn("ImageTranscoding.jpegIfNeeded(name: name, data: data)", attach)
        self.assertIn("guard data.count <= Self.maxAttachmentBytes", attach)

    def test_one_alert_serves_both_routes(self) -> None:
        self.assertEqual(PICKER.count('"Could not attach that file"'), 1)
        stage = decl("static func stage(", PICKER)
        self.assertIn("NSAlert()", stage)
        self.assertIn("notice.localizedDescription", stage)


class ThePanelStaysOpenToEverything(unittest.TestCase):
    def test_the_panel_takes_any_file(self) -> None:
        self.assertIn("panel.allowedContentTypes = [.item]", PICKER)
        self.assertNotIn("allowedFileTypes", PICKER)
        # No second, narrower list anywhere in the panel's configuration.
        self.assertEqual(PICKER.count("allowedContentTypes ="), 1)

    def test_multi_select_and_files_only_are_unchanged(self) -> None:
        self.assertIn("panel.allowsMultipleSelection = true", PICKER)
        self.assertIn("panel.canChooseFiles = true", PICKER)
        self.assertIn("panel.canChooseDirectories = false", PICKER)

    def test_the_last_folder_is_the_panels_own_memory(self) -> None:
        # Setting `directoryURL` would overwrite the folder the panel remembers; a new store (a
        # UserDefaults key, an @AppStorage) would be a second place to keep it.
        self.assertNotIn("panel.directoryURL", PICKER)
        self.assertNotIn("UserDefaults", PICKER)
        self.assertNotIn("AppStorage", PICKER)


class ThePhoneIsUntouched(unittest.TestCase):
    def test_the_phone_still_uses_the_system_photo_picker(self) -> None:
        for marker in ("struct AttachmentPhotos: UIViewControllerRepresentable",
                       "PHPickerViewController(configuration: config)",
                       "config.selectionLimit = 0",
                       "config.preferredAssetRepresentationMode = .current"):
            self.assertIn(marker, PHONE)

    def test_the_phone_still_stages_through_the_model(self) -> None:
        screen = read(PHONE_SCREEN_PATH)
        self.assertIn("model.addPendingAttachment(name: payload.name, data: payload.data, "
                      "isImage: payload.isImage)", screen)

    def test_nothing_mac_only_leaked_into_the_phone_sources(self) -> None:
        for path in (ROOT / "Apps" / "HermesMobile").rglob("*.swift"):
            source = path.read_text(encoding="utf-8")
            self.assertNotIn("MacComposerPicker", source, str(path))
            self.assertNotIn("NSOpenPanel", source, str(path))


if __name__ == "__main__":
    unittest.main()
