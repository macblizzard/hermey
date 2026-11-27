"""Attachments across devices: one parser, one route, one renderer.

The owner's report — "I upload an image from my phone and don't see it on my Mac in the same chat" —
is structural, not cosmetic: the bytes are on the *host*, and the message only carries a path
(`@image:/…/upload_1v5jm9lm.jpg`, or `@file:…` inside the engine's `📎 … — Attached Context —`
block). Nothing resolved that path, so the Mac drew prose where a picture belongs.

These guards pin the three halves that make it work, and they read *source*, because that is all
this suite can do:

  * the host route serves a reference and refuses everything outside the profile's `images/` and
    `attachments/` (the Rust is checked here; its own unit tests are the behavioural proof);
  * the shared parser turns both shapes into attachments and leaves the prose intact;
  * both shells draw the same view — thumbnail for a picture, chip for a file, a named
    "unavailable" chip when the host cannot answer — and cache the bytes by the reference.

A guard cannot see a compile. The Swift is compiled by CI's macOS job and by the Mac; this file's
job is to make the *rules* a tested fact rather than a comment.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

KIT = ROOT / "Sources" / "HermesKit"
ATTACHMENTS = KIT / "MessageAttachments.swift"
REFS = KIT / "MessageRefs.swift"
FILES = KIT / "AttachmentFiles.swift"
SENT = KIT / "SentAttachment.swift"
STORE = KIT / "AttachmentImageStore.swift"

UI = ROOT / "Sources" / "HermeyUI" / "ReferenceAttachmentsView.swift"
ROW = ROOT / "Sources" / "HermeyUI" / "AttachmentFileRow.swift"

MAC_ROW = ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift"
MAC_SCROLL = ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptScroll.swift"
MOBILE_ROW = ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift"

HOST_ROUTE = ROOT / "hermeyd" / "src" / "attachment_refs.rs"
HOST_MAIN = ROOT / "hermeyd" / "src" / "main.rs"
HOST_CARGO = ROOT / "hermeyd" / "Cargo.toml"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code(text: str) -> str:
    """Source with comments removed.

    A guard that greps raw text passes on a *comment* that mentions the thing it looks for — one
    did, once, while the real code had been deleted. Everything below matches code, not prose.
    """
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(?m)^\s*//.*$", "", text)
    return text


class BothReferenceShapesParse(unittest.TestCase):
    """`@image:`, `@file:` and the `📎` block all become the same struct."""

    def test_the_parser_knows_the_markers_and_the_block(self) -> None:
        source = code(read(ATTACHMENTS))
        self.assertIn('static let markers = ["@image:", "@file:"]', code(read(REFS)))
        self.assertIn('contextHeading = "--- Attached Context ---"', source)
        self.assertIn('pin = "📎"', source)
        self.assertIn("public static func attachments(in text: String) -> MessageAttachmentScan", source)

    def test_a_reference_must_start_its_line(self) -> None:
        # A `@file:` mentioned mid-sentence is the user's words, not an upload. The rule is what
        # keeps prose intact; it is asserted in Swift by `testAMentionMidSentenceStaysProse` too.
        source = code(read(ATTACHMENTS))
        self.assertIn("guard line.hasPrefix(marker) else { continue }", source)

    def test_the_block_is_merged_not_duplicated(self) -> None:
        source = code(read(ATTACHMENTS))
        self.assertIn("if let index = list.firstIndex(where: { $0.id == reference.id })", source)
        self.assertIn("mimeType: existing.mimeType ?? reference.mimeType", source)
        self.assertIn("size: existing.size ?? reference.size", source)

    def test_the_surrounding_prose_is_kept(self) -> None:
        source = code(read(ATTACHMENTS))
        self.assertIn("body.append(line)", source, "everything that is not a reference stays")
        self.assertIn("MessageAttachmentScan(body: joined, attachments: found)", source)

    def test_both_shapes_map_to_one_struct_with_a_name_a_type_and_a_size(self) -> None:
        source = code(read(ATTACHMENTS))
        for field in ("public let path: String", "public let name: String",
                      "public let mimeType: String?", "public let size: Int?"):
            self.assertIn(field, source)

    def test_the_one_parser_is_the_one_both_entry_points_use(self) -> None:
        self.assertIn("attachments(in: text)", code(read(REFS)),
                      "MessageRefs.split delegates rather than parsing a second time")
        self.assertIn("MessageRefs.attachments(in: text)", code(read(SENT)))


class TheHostRouteIsScoped(unittest.TestCase):
    """Every refusal rule, read off the Rust that owns it."""

    def setUp(self) -> None:
        self.source = code(read(HOST_ROUTE))

    def test_it_is_registered_as_the_get_half_of_the_attachments_route(self) -> None:
        main = code(read(HOST_MAIN))
        self.assertIn(".get(attachment_refs::attachment_by_reference)", main)
        self.assertIn('"/v1/attachments"', main)
        self.assertIn("mod attachment_refs;", main)

    def test_it_takes_the_profile_and_the_reference_as_query_parameters(self) -> None:
        self.assertIn("pub struct ReferenceQuery", self.source)
        self.assertIn("pub profile: Option<String>", self.source)
        self.assertIn("pub path: Option<String>", self.source)
        self.assertIn("Query(query): Query<ReferenceQuery>", self.source)

    def test_a_bearer_is_required(self) -> None:
        self.assertIn("require_device(&st, &headers)?", self.source)

    def test_traversal_is_refused_before_the_filesystem(self) -> None:
        self.assertIn('if *segment == ".." || *segment == "."', self.source)
        self.assertIn("Refusal::Traversal", self.source)
        self.assertIn('"invalid attachment reference: no traversal"', self.source)

    def test_an_absolute_path_outside_the_profile_is_refused(self) -> None:
        # Absolute and naming no profile home at all, and absolute naming a *different* profile.
        self.assertIn("None if path.starts_with('/') => return Err(Refusal::OutsideProfile)", self.source)
        self.assertIn("return Err(Refusal::OtherProfile)", self.source)
        self.assertIn('"invalid attachment reference: outside the profile"', self.source)
        self.assertIn('"invalid attachment reference: another profile"', self.source)

    def test_only_images_and_attachments_are_served(self) -> None:
        self.assertIn('const FOLDERS: [&str; 2] = ["images", "attachments"];', self.source)
        self.assertIn("FOLDERS.iter().copied().find(|f| *f == folder)", self.source)
        self.assertIn("Refusal::NotAnAttachmentFolder", self.source)

    def test_a_symlink_escape_is_refused_not_followed(self) -> None:
        # The file itself, and the folder it sits in: a symlinked folder agrees with itself once
        # canonicalised, so it has to be checked before it is trusted.
        self.assertIn("if meta.file_type().is_symlink() || !meta.is_file()", self.source)
        self.assertIn("if folder_meta.file_type().is_symlink() || !folder_meta.is_dir()", self.source)
        self.assertIn("if real.parent() != Some(folder.as_path()) || !real.starts_with(&profile_root)",
                      self.source)

    def test_the_size_ceiling_exists_and_is_thirty_two_mebibytes(self) -> None:
        self.assertIn("pub const MAX_REFERENCE_BYTES: u64 = 32 * 1024 * 1024;", self.source)
        self.assertIn("if meta.len() > MAX_REFERENCE_BYTES", self.source)
        self.assertIn("Refusal::TooLarge(meta.len())", self.source)
        self.assertIn("StatusCode::PAYLOAD_TOO_LARGE", self.source)

    def test_a_refusal_is_json_never_an_empty_200(self) -> None:
        self.assertIn('json!({ "detail": refusal.detail() })', self.source)
        self.assertIn('"attachment not found"', self.source)
        self.assertNotIn("StatusCode::OK", self.source)

    def test_the_answer_carries_its_type_and_may_not_be_cached(self) -> None:
        self.assertIn("pub fn media_type(name: &str) -> &'static str", self.source)
        self.assertIn('"no-store, no-cache, must-revalidate, private"', self.source)
        self.assertIn("header::CONTENT_TYPE", self.source)

    def test_the_rust_has_its_own_behavioural_tests(self) -> None:
        self.assertIn("fn traversal_is_refused_before_anything_is_opened", self.source)
        self.assertIn("fn an_absolute_path_outside_the_profile_is_refused", self.source)
        self.assertIn("fn a_symlink_that_escapes_is_refused_rather_than_followed", self.source)
        self.assertIn("fn the_size_ceiling_is_thirty_two_mebibytes_and_bites", self.source)
        self.assertIn("async fn a_picture_and_a_workbook_come_back_byte_for_byte", self.source)


class TheRouteIsInTheVersionStream(unittest.TestCase):
    def test_hermeyd_was_bumped_by_one_patch(self) -> None:
        manifest = read(HOST_CARGO)
        version = re.search(r'^version = "(\d+)\.(\d+)\.(\d+)"', manifest, re.M)
        self.assertIsNotNone(version)
        assert version is not None
        minor, patch = int(version.group(2)), int(version.group(3))
        self.assertGreaterEqual((minor, patch), (8, 26),
                                "the reference route is a new host capability: 0.8.26 or later")


class TheClientAsksTheRoute(unittest.TestCase):
    def test_the_location_builds_the_query_the_host_parses(self) -> None:
        source = code(read(FILES))
        self.assertIn("case reference(profile: String, path: String)", source)
        self.assertIn('appendingPathComponent("v1/attachments")', source)
        self.assertIn('URLQueryItem(name: "profile", value: profile)', source)
        self.assertIn('URLQueryItem(name: "path", value: path)', source)

    def test_every_request_presents_the_device_ticket(self) -> None:
        self.assertIn('request.setValue("Bearer \\(resolved.ticket)"', read(FILES))

    def test_a_missing_file_is_a_404_and_becomes_the_quiet_state(self) -> None:
        self.assertIn("if http.statusCode == 404 { throw AttachmentFetchError.notReady }",
                      code(read(FILES)))


class TheCacheIsKeyedByTheReference(unittest.TestCase):
    def test_the_lru_holds_sixty_four_references(self) -> None:
        source = code(read(ATTACHMENTS))
        self.assertIn("public static let capacity = 64", source)
        self.assertIn("while order.count > capacity", source)

    def test_it_is_keyed_by_the_reference_string(self) -> None:
        source = code(read(ATTACHMENTS))
        self.assertIn("public static func data(for reference: String) -> Data?", source)
        self.assertIn("public static func store(_ data: Data, for reference: String)", source)
        self.assertIn("entries[reference] = data", source)

    def test_the_disk_half_is_the_cache_that_already_existed(self) -> None:
        source = code(read(ATTACHMENTS))
        self.assertIn("AttachmentImageStore.data(named: key)", source)
        self.assertIn("AttachmentImageStore.save(data, as: key)", source)
        self.assertIn("private static let keep = 240", code(read(STORE)))

    def test_every_cache_key_is_the_reference_for_its_profile(self) -> None:
        # The 2026-11 audit: the caches were keyed by the bare file *name*, so profile A's
        # `notes.pdf` answered profile B's reference, and a re-attach with the same name served the
        # previous send's bytes. Reader, upload path and the two body passes all key by
        # `AttachmentLocation.cacheKey` — a fingerprint of profile + reference — through
        # `MessageAttachment.cacheKey(profile:)`.
        source = code(read(ATTACHMENTS))
        self.assertIn("public func cacheKey(profile: String) -> String", source)
        self.assertIn("AttachmentLocation.reference(profile: profile, path: path).cacheKey", source)
        reader = source[source.index("public enum AttachmentReferenceReader"):]
        self.assertIn("let key = attachment.cacheKey(profile: profile)", reader)
        files = code(read(FILES))
        # All three locations fingerprint profile + file; the uploaded branch goes through the
        # same key as the reference one, not a bare name.
        self.assertIn('Self.fingerprinted(profile, name, prefix: "upload")', files)
        self.assertIn('Self.fingerprinted(profile, path, prefix: "ref")', files)
        self.assertIn('fingerprint("\\(profile)\\u{0}\\(file)")', files)
        cache_key = files[files.index("public var cacheKey: String"):]
        cache_key = cache_key[:cache_key.index("private static func fingerprinted")]
        self.assertNotIn("lastPathComponent", cache_key,
                         "the cache key is a fingerprint, never the bare name")

    def test_the_send_writes_the_key_the_reader_looks_up(self) -> None:
        # The send path writes under the receipt's own path (what the row will quote as
        # `@image:<path>`) inside the profile that was messaged — so a relaunched device renders
        # what it sent with no host round trip, and never with another profile's bytes.
        source = code(read(ROOT / "Sources" / "HermesAppKit" / "AppModel.swift"))
        self.assertIn("AttachmentImageStore.save(attachment.data, as: cacheLocation.cacheKey)", source)
        self.assertIn("AttachmentLocation.reference(profile: sendProfile, path: $0)", source)
        self.assertIn("AttachmentLocation.uploaded(profile: sendProfile, name: attachment.name)", source)

    def test_the_body_pass_reads_memory_and_nothing_else(self) -> None:
        # `cachedBytes` runs inside the renderer's body. The disk (and the host) are the reader's
        # job, off the main actor; a body pass that read a file is the freeze of 2026-11-25. The
        # read is still memory-only — now keyed the same way the reader stores.
        for shell, profile in ((MAC_ROW, "bot"), (MOBILE_ROW, "attachmentProfile")):
            body = code(read(shell))
            self.assertIn("cachedBytes: { reference in", body)
            self.assertIn(f"AttachmentByteCache.data(for: reference.cacheKey(profile: {profile}))", body)
            self.assertNotIn("AttachmentImageStore", body)

    def test_a_cached_reference_never_asks_the_host(self) -> None:
        source = code(read(ATTACHMENTS))
        reader = source[source.index("public enum AttachmentReferenceReader"):]
        cache = reader.index("AttachmentByteCache.data(for: key)")
        fetch = reader.index("try await fetch(")
        self.assertLess(cache, fetch, "the memory cache is read before the request is built")


class BothShellsDrawTheOneView(unittest.TestCase):
    def test_the_view_is_shared_not_copied(self) -> None:
        source = code(read(UI))
        self.assertIn("public struct ReferenceAttachmentsView: View", source)
        for shell in (read(MAC_ROW), read(MOBILE_ROW)):
            body = code(shell)
            self.assertIn("ReferenceAttachmentsView(", body)
            self.assertIn("MessageRefs.attachments(in: entry.text).attachments", body)

    def test_the_mac_draws_it_for_a_row_it_did_not_send(self) -> None:
        body = code(read(MAC_ROW))
        self.assertIn("} else if !resolvedAttachments.isEmpty {", body)
        self.assertIn("MacAttachmentQuickLook.shared.show(url)", body)

    def test_the_phone_draws_it_for_a_row_it_did_not_send(self) -> None:
        body = code(read(MOBILE_ROW))
        self.assertIn("} else if !resolvedAttachments.isEmpty {", body)
        self.assertIn("MobileAttachmentShare.present(url)", body)

    def test_the_renderer_draws_a_thumbnail_for_a_picture(self) -> None:
        source = code(read(UI))
        self.assertIn("scaledToFill()", source)
        self.assertIn("clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))", source)
        self.assertIn("frame(width: thumbnailWidth, height: thumbnailHeight)", source)
        self.assertIn("onOpenImage(attachment, data)", source)

    def test_the_renderer_draws_a_chip_for_a_file(self) -> None:
        source = code(read(UI))
        self.assertIn("AttachmentFileRow(name: attachment.name", source)
        self.assertIn("kind: attachment.kindOfFile", source)
        self.assertIn("onOpenFile(attachment, url)", source)
        # The chip's glyph comes from the type, which is what makes it readable at a glance.
        self.assertIn("Image(systemName: kind.symbolName)", code(read(ROW)))


class FailureIsVisible(unittest.TestCase):
    """An unreachable host or a refused path draws a named chip, never a blank space."""

    def setUp(self) -> None:
        self.source = code(read(UI))

    def test_there_is_an_unavailable_chip_that_names_the_file(self) -> None:
        self.assertIn("public struct ReferenceUnavailableChip: View", self.source)
        self.assertIn('Text("Unavailable — \\(reason)")', self.source)
        self.assertIn("Text(name)", self.source)
        self.assertIn("onRetry", self.source)

    def test_every_failure_mode_lands_in_it(self) -> None:
        # A thrown fetch (unreachable host, refused path, too large)…
        self.assertIn("failures[attachment.id] = Self.reason(for: error)", self.source)
        # …the bytes arriving but not being storable…
        self.assertIn("AttachmentFetchError.cacheUnavailable.localizedDescription", self.source)
        # …a 404, which is the quiet state rather than an error…
        self.assertIn('if fetch.isNotReady { return "not on the host" }', self.source)
        # …and a picture still on its way is *named*, not blank.
        self.assertIn("status: attachment.isImage ? .loading : .ready", self.source)

    def test_the_chip_is_drawn_before_anything_else_can_be(self) -> None:
        row = self.source[self.source.index("private func row(for attachment"):]
        unavailable = row.index("ReferenceUnavailableChip(")
        thumbnail = row.index("thumbnail(picture)")
        self.assertLess(unavailable, thumbnail, "a failure is checked first")

    def test_no_raw_path_reaches_the_bubble(self) -> None:
        # The reference is a pointer, not prose: the parse removes it, and nothing re-prints it.
        self.assertNotIn("Text(attachment.path)", self.source)
        self.assertNotIn("Text(reference.path)", self.source)


class TheRestOfTheMessageIsUntouched(unittest.TestCase):
    def test_the_composer_still_sends_the_reference_it_always_did(self) -> None:
        # The send still appends the host's reference to the prompt; only the *cache write* changed
        # (pinned by `TheCacheIsKeyedByTheReference.test_the_send_writes_the_key_the_reader_looks_up`).
        source = code(read(ROOT / "Sources" / "HermesAppKit" / "AppModel.swift"))
        self.assertIn("if let ref = receipt.refText { refs.append(ref) }", source)

    def test_the_upload_path_did_not_grow_a_second_parse(self) -> None:
        # The send path writes the reference; the reader is the only thing that reads it.
        for path in (KIT / "GatewayClientActor.swift", ROOT / "Apps/HermesMobile" / "Networking" / "AttachmentPayload.swift"):
            self.assertNotIn("MessageRefs.attachments(in:", code(read(path)))


if __name__ == "__main__":
    unittest.main()
