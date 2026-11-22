"""One message, several pictures: the viewer pages through all of them.

The owner sends three photographs in one message and had to close and reopen the viewer for each one.
`ImageViewer` now opens on the picture that was tapped and pages to its neighbours — a swipe and a
counter on the phone, the arrow keys and chevrons on the Mac — while the one-picture form every other
call site uses stays exactly as it was.

These are source assertions: the CI here has no Swift toolchain. What they can prove is that the two
entry points exist, that both transcripts hand the viewer the whole list and the tapped index, and
that each platform has its own way to turn the page. What they cannot prove is that the pager behaves
— that needs a build and a device.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEWER = (ROOT / "Sources" / "HermeyUI" / "ImageViewer.swift").read_text(encoding="utf-8")
MAC_ROW = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift").read_text(encoding="utf-8")
IOS_ROW = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text(encoding="utf-8")


def section(text: str, opener: str, closer: str) -> str:
    """The slice from `opener` to the next `closer` — one property or function body."""
    start = text.index(opener)
    return text[start:text.index(closer, start)]


def guarded_by(text: str, condition: str, needle: str) -> bool:
    """True when `needle` sits inside the `#if <condition>` block that precedes it."""
    at = text.index(needle)
    opened = text.rindex(f"#if {condition}", 0, at)
    closed = text.index("#endif", opened)
    return at < closed


class CollectionEntry(unittest.TestCase):
    def test_the_viewer_takes_a_collection(self) -> None:
        self.assertIn("public struct Item: Identifiable", VIEWER)
        self.assertIn("public init(items: [Item], startIndex: Int = 0,", VIEWER)
        self.assertIn("public let items: [Item]", VIEWER)

    def test_an_item_is_the_bytes_and_their_name(self) -> None:
        item = section(VIEWER, "public struct Item: Identifiable", "// Every picture on offer")
        self.assertIn("public let data: Data", item)
        self.assertIn("public let name: String", item)
        self.assertIn("public init(data: Data, name: String)", item)

    def test_the_single_image_form_still_exists(self) -> None:
        # Backwards compatibility: a call site that knows one picture keeps compiling, and it
        # is one picture of a one-picture gallery, not a second code path.
        self.assertIn("public init(data: Data, title: String, canExport: Bool = true, onClose: @escaping () -> Void)", VIEWER)
        self.assertIn("self.init(items: [Item(data: data, name: title)], canExport: canExport, onClose: onClose)", VIEWER)

    def test_the_tapped_index_is_the_one_that_opens(self) -> None:
        init = section(VIEWER, "public init(items: [Item], startIndex: Int = 0,", "/// The bytes on screen")
        self.assertIn("min(max(startIndex, 0), items.count - 1)", init,
                      "an out-of-range index must open the nearest picture, not nothing")
        self.assertIn("_index = State(initialValue: opening)", init)

    def test_the_chrome_follows_the_page(self) -> None:
        # Name, size, Copy, Save and Share all read the current item, so a paged gallery never
        # captions the second picture with the first one's name.
        self.assertIn("public var data: Data { current?.data ?? Data() }", VIEWER)
        self.assertIn("public var title: String { current?.name ?? \"\" }", VIEWER)


class Paging(unittest.TestCase):
    def test_the_counter_is_visible(self) -> None:
        self.assertIn(r'private var counter: String { "\(index + 1) of \(items.count)" }', VIEWER)
        header = section(VIEWER, "private var header: some View", "private var subtitle: String")
        self.assertIn("Text(counter)", header, "the counter belongs in the chrome, on both platforms")
        self.assertIn("if canPage {", header)

    def test_the_phone_pages_by_swipe(self) -> None:
        self.assertIn("TabView(selection: $index)", VIEWER)
        self.assertIn(".tabViewStyle(.page(indexDisplayMode: .never))", VIEWER)
        self.assertTrue(guarded_by(VIEWER, "os(iOS)", ".tabViewStyle(.page(indexDisplayMode: .never))"),
                        "a page-style TabView is the phone's pager and exists only there")

    def test_the_phone_pager_does_not_fight_the_zoom(self) -> None:
        # The viewer zooms with a pinch and has no pan, so the page swipe is a different gesture
        # rather than a competitor. What must not happen is a page opening cropped by the last
        # page's zoom.
        page_change = section(VIEWER, ".onChange(of: index)", "#if os(macOS)")
        self.assertIn("zoom = 1", page_change)
        self.assertIn("pinchBase = nil", page_change)
        self.assertIn("MagnificationGesture", VIEWER)

    def test_the_mac_pages_with_the_arrow_keys(self) -> None:
        self.assertIn(".onKeyPress(.leftArrow, phases: .down)", VIEWER)
        self.assertIn(".onKeyPress(.rightArrow, phases: .down)", VIEWER)
        self.assertTrue(guarded_by(VIEWER, "os(macOS)", ".onKeyPress(.leftArrow"),
                        "arrow-key paging is a Mac affordance, not an iPad one")
        self.assertIn(".focusable()", VIEWER)
        self.assertIn(".focused($keyboardFocused)", VIEWER,
                      "keys must land on the viewer, not on the window behind it")

    def test_the_arrow_keys_do_not_steal_from_a_text_field(self) -> None:
        # A `keyboardShortcut(.leftArrow)` is a window-wide key equivalent: it would eat the arrow
        # in every text field of the app. Focus-scoped key presses are the way not to.
        self.assertNotIn("keyboardShortcut(.leftArrow", VIEWER)
        self.assertNotIn("keyboardShortcut(.rightArrow", VIEWER)

    def test_the_mac_has_visible_previous_and_next(self) -> None:
        controls = section(VIEWER, "private var pageControls: some View", "private var zoomControls")
        self.assertIn('iconButton("chevron.left"', controls)
        self.assertIn('iconButton("chevron.right"', controls)
        self.assertIn('label: "Previous image"', controls)
        self.assertIn('label: "Next image"', controls)
        footer = section(VIEWER, "private var footer: some View", "private var pageControls: some View")
        self.assertIn("pageControls", footer, "the buttons must be on screen, not only reachable by key")

    def test_pages_are_decoded_one_at_a_time(self) -> None:
        # Nothing decodes the whole set up front: the decode lives in the page builder, and the
        # phone hands the paging to a TabView, which keeps only the neighbours alive.
        page = section(VIEWER, "private func page(_ item: Item, size: CGSize)", "// MARK: Chrome")
        self.assertIn("Self.image(from: item.data)", page)
        self.assertIn("page(item, size: size)\n                        .tag(offset)", VIEWER)
        for eager in ("items.map { Self.image", "items.compactMap { Self.image", "decodedImages"):
            self.assertNotIn(eager, VIEWER, "the viewer must not decode every attachment to open one")

    def test_share_hands_over_the_page_on_screen(self) -> None:
        self.assertIn("sharedFile = nil", section(VIEWER, ".onChange(of: index)", "#if os(macOS)"),
                      "a stale temp file would share the previous picture's bytes")


class Transcripts(unittest.TestCase):
    def test_the_mac_passes_the_whole_message_and_the_tapped_index(self) -> None:
        self.assertIn("viewingImage = ViewedGallery(items: pictures", MAC_ROW)
        self.assertIn("startIndex: start", MAC_ROW)
        self.assertIn("firstIndex { $0.id == attachment.id }", MAC_ROW)
        self.assertIn("ImageViewer(items: gallery.items", MAC_ROW)
        self.assertIn("startIndex: gallery.startIndex", MAC_ROW)

    def test_the_phone_passes_the_whole_message_and_the_tapped_index(self) -> None:
        self.assertIn("viewingImage = ViewedGallery(items: pictures", IOS_ROW)
        self.assertIn("startIndex: start", IOS_ROW)
        self.assertIn("firstIndex { $0.attachment.id == attachment.id }", IOS_ROW)
        self.assertIn("ImageViewer(items: gallery.items", IOS_ROW)
        self.assertIn("startIndex: gallery.startIndex", IOS_ROW)

    def test_only_pictures_with_bytes_are_paged(self) -> None:
        # A picture still being fetched is a chip, not a thumbnail; it is not a page either.
        self.assertIn("bubbleAttachments\n            .filter { $0.isImage }", IOS_ROW)
        self.assertIn("bubbleAttachments.filter { $0.isImage && $0.imageData != nil }", MAC_ROW)
        self.assertIn("ImageViewer.Item(data:", MAC_ROW)
        self.assertIn("ImageViewer.Item(data:", IOS_ROW)

    def test_both_transcripts_keep_their_dismissal_and_export(self) -> None:
        for name, text in (("TranscriptRowView", MAC_ROW), ("MobileTranscript", IOS_ROW)):
            viewer_call = section(text, "ImageViewer(items: gallery.items", "hermesSheetChrome")
            self.assertIn("canExport: false", viewer_call, f"{name} shows a picture the person already owns")
            self.assertIn("{ viewingImage = nil }", viewer_call, f"{name} still closes the viewer on Done")

    def test_the_single_image_initialiser_is_still_the_compatibility_door(self) -> None:
        # Both transcripts had to move to the collection form; the single form is what other
        # call sites, tests and previews keep using, so it must not be deleted.
        self.assertNotIn("ImageViewer(data: item.data", MAC_ROW)
        self.assertNotIn("ImageViewer(data: item.data", IOS_ROW)
        self.assertIn("public init(data: Data, title: String", VIEWER)


if __name__ == "__main__":
    unittest.main()
