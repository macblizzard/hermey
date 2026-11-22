"""The share extension hands bytes over a container; it never holds a way to reach the host.

Two components meet at an App Group directory: an extension that lives for seconds inside another
app's process and cannot be trusted with a credential, and an app that already knows how to send.
These tests pin the contract between them — the payload shape, the copy-not-reference rule, the
delete-after-accept ordering, and the absence of any network surface in the extension — because none
of it can be exercised by the Python suite and none of it is visible in a build that merely compiles.

Written as ``unittest.TestCase``: CI runs ``unittest discover``, which collects only TestCase
subclasses, so bare classes with ``assert`` would enforce nothing there.
"""

import pathlib
import plistlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHARED = ROOT / "Apps" / "HermesShare"
EXTENSION = ROOT / "Apps" / "HermeyShareExtension"
APP = ROOT / "Apps" / "HermesMobile"

PAYLOAD_FILE = SHARED / "SharePayload.swift"
INBOX_FILE = SHARED / "ShareInbox.swift"
SNAPSHOT_FILE = SHARED / "ShareBotSnapshot.swift"
RECEIVER_FILE = APP / "Views" / "ShareInboxReceiver.swift"
EXTENSION_INFO = EXTENSION / "Info.plist"
EXTENSION_ENTITLEMENTS = EXTENSION / "HermeyShareExtension.entitlements"

PAYLOAD = PAYLOAD_FILE.read_text(encoding="utf-8")
INBOX = INBOX_FILE.read_text(encoding="utf-8")
SNAPSHOT = SNAPSHOT_FILE.read_text(encoding="utf-8")
RECEIVER = RECEIVER_FILE.read_text(encoding="utf-8")
EXTENSION_SWIFT = {path.name: path.read_text(encoding="utf-8")
                   for path in sorted(EXTENSION.glob("*.swift"))}
EXTENSION_TEXT = "\n".join(EXTENSION_SWIFT.values())


def function_body(source: str, signature: str) -> str:
    """The text from ``signature`` to the closing brace at its own indentation.

    Good enough for the ordered assertions below: these files have no nested braces at column 4.
    """
    start = source.index(signature)
    rest = source[start:]
    end = rest.find("\n    }")
    if end == -1:
        raise AssertionError(f"could not find the end of {signature!r}")
    return rest[:end]


class TestTheHandoffHasBothHalves(unittest.TestCase):
    def test_every_file_the_feature_needs_exists(self) -> None:
        for path in (PAYLOAD_FILE, INBOX_FILE, SNAPSHOT_FILE, RECEIVER_FILE,
                     EXTENSION_INFO, EXTENSION_ENTITLEMENTS):
            self.assertTrue(path.is_file(), f"missing {path.relative_to(ROOT)}")
        for name in ("ShareViewController.swift", "ShareComposer.swift",
                     "ShareItemImporter.swift", "ShareRootView.swift"):
            self.assertIn(name, EXTENSION_SWIFT, f"missing the extension's {name}")

    def test_the_readme_puts_the_shared_types_in_both_targets(self) -> None:
        """Neither target is in project.yml yet (the parent adds them).

        What this pins is that the instructions cannot go stale into "just add the extension": the
        payload types are compiled by the app *and* the extension, or the two sides drift.
        """
        readme = (EXTENSION / "README.md").read_text(encoding="utf-8")
        self.assertGreaterEqual(readme.count("Apps/HermesShare"), 2,
                                "the shared folder must be named for both targets")
        app_block = readme[readme.index("### 2. The app target"):]
        self.assertIn("Apps/HermesShare", app_block)


class TestEveryKindOfShareIsRepresentable(unittest.TestCase):
    def test_text_and_link_are_fields_of_the_payload(self) -> None:
        self.assertRegex(PAYLOAD, r"public var text: String\?")
        self.assertRegex(PAYLOAD, r"public var urlString: String\?")

    def test_an_image_is_an_attachment_with_a_relative_file_name(self) -> None:
        self.assertRegex(PAYLOAD, r"public var attachments: \[ShareAttachment\]")
        self.assertIn("case image", PAYLOAD)
        self.assertIn("case file", PAYLOAD)
        self.assertIn("public var fileName: String", PAYLOAD)
        # A reference, not a location: an absolute path or URL would be stale the moment it is written.
        self.assertNotIn("/Users/", PAYLOAD)
        self.assertNotIn("file://", PAYLOAD)

    def test_the_message_text_joins_a_caption_and_its_link(self) -> None:
        self.assertIn("var messageText: String", PAYLOAD)
        body = function_body(PAYLOAD, "public var messageText: String")
        self.assertIn("body.contains(link)", body,
                      "a caption that already contains the link must not repeat it")

    def test_an_empty_payload_is_recognised_rather_than_sent(self) -> None:
        self.assertIn("var isEmpty: Bool", PAYLOAD)
        self.assertIn("attachments.isEmpty", PAYLOAD)
        self.assertIn("!draft.isEmpty", EXTENSION_SWIFT["ShareComposer.swift"])


class TestTheSchemaCannotBeMisread(unittest.TestCase):
    def test_payloads_carry_a_version_written_by_the_type_not_the_caller(self) -> None:
        self.assertIn("public enum SharePayloadSchema", PAYLOAD)
        self.assertRegex(PAYLOAD, r"public static let version = \d+")
        self.assertIn("self.version = SharePayloadSchema.version", PAYLOAD)
        # No `version:` parameter: a caller can only ever write the version it implements.
        init = function_body(PAYLOAD, "    public init(id: UUID = UUID(),")
        self.assertNotIn("version:", init)

    def test_a_version_this_build_did_not_write_is_refused_before_any_field(self) -> None:
        self.assertIn("case unsupportedVersion", PAYLOAD)
        decode = function_body(PAYLOAD, "public init(from decoder: Decoder) throws {")
        self.assertIn("guard found == SharePayloadSchema.version", decode)
        self.assertIn("throw SharePayloadError.unsupportedVersion(found: found)", decode)
        # The refusal must come before the first field is read.
        self.assertLess(decode.index("unsupportedVersion"),
                        decode.index("self.id ="))

    def test_the_coding_keys_cover_every_field_the_app_reads(self) -> None:
        keys = function_body(PAYLOAD, "private enum CodingKeys: String, CodingKey {")
        for key in ("version", "id", "createdAt", "botID", "botName", "text", "urlString",
                    "attachments"):
            self.assertIn(key, keys, f"CodingKeys is missing {key}")

    def test_the_bot_snapshot_is_versioned_too(self) -> None:
        self.assertIn("ShareBotSnapshotVersion", SNAPSHOT)
        self.assertIn("probe.version == ShareBotSnapshotVersion.version", SNAPSHOT)


class TestImageBytesAreCopiedNotReferenced(unittest.TestCase):
    def test_the_extension_never_borrows_a_file_representation(self) -> None:
        """`loadFileRepresentation` hands back a URL that dies with the extension.

        The extension is torn down the instant Send is tapped, so a payload holding that URL would
        point at a deleted file by the time the app reads it.
        """
        for name, source in EXTENSION_SWIFT.items():
            # The name appears in a comment explaining why it is not used; a *call* is what dies.
            self.assertNotIn("loadFileRepresentation(", source, name)

    def test_nothing_is_stored_in_a_temporary_directory(self) -> None:
        for name, source in EXTENSION_SWIFT.items():
            self.assertNotIn("temporaryDirectory", source, name)
            self.assertNotIn("NSTemporaryDirectory", source, name)

    def test_bytes_are_written_under_the_group_containers_assets_directory(self) -> None:
        self.assertRegex(INBOX, r'assetsDirectory: URL\? \{.*?appendingPathComponent\("Assets"')
        body = function_body(INBOX, "public func importAttachment(")
        self.assertIn("data.write(to: destination, options: .atomic)", body)
        self.assertIn("payloadDirectory", body)
        self.assertIn("assetsDirectory", body)

    def test_every_branch_of_the_importer_copies_into_the_container(self) -> None:
        source = EXTENSION_SWIFT["ShareItemImporter.swift"]
        # image, file-url (a PDF from Files) and generic file all reach the same copy path.
        self.assertGreaterEqual(source.count("storage.importAttachment("), 3)
        self.assertIn("kind: .image", source)
        self.assertIn("Data(contentsOf: file, options: .mappedIfSafe)", source,
                      "a file URL must be read to bytes while it is still valid")
        self.assertNotIn("draft.attachments.append(file)", source,
                         "a file URL must never be kept as an attachment")

    def test_a_file_url_is_not_mistaken_for_a_web_link(self) -> None:
        source = EXTENSION_SWIFT["ShareItemImporter.swift"]
        kind = function_body(source, "private static func kind(of provider: NSItemProvider)")
        self.assertLess(kind.index("to: .fileURL"), kind.index("to: .url"),
                        "public.file-url conforms to public.url; it must be classified first")

    def test_the_payload_is_the_commit_after_the_bytes(self) -> None:
        body = function_body(INBOX, "public func write(_ payload: SharePayload) throws -> URL {")
        self.assertIn("data.write(to: destination, options: .atomic)", body)
        comment_start = INBOX.index("/// Writes the payload last")
        self.assertLess(comment_start, INBOX.index("public func write(_ payload: SharePayload)"))


class TestTheReceiverDeletesOnlyAfterAcceptance(unittest.TestCase):
    def test_a_payload_is_claimed_before_it_is_offered(self) -> None:
        drain = function_body(RECEIVER, "func drain(accept: (SharePayload) async -> Bool) async {")
        self.assertLess(drain.index("storage.claim(url)"), drain.index("await accept(payload)"),
                        "two readers must not be able to deliver the same share")

    def test_deletion_happens_after_the_app_says_yes(self) -> None:
        drain = function_body(RECEIVER, "func drain(accept: (SharePayload) async -> Bool) async {")
        accepted = drain[drain.index("await accept(payload)"):]
        self.assertIn("storage.finish(claimed", accepted,
                      "a file deleted before acceptance is a share that vanished")

    def test_acceptance_writes_the_marker_before_removing_the_file(self) -> None:
        finish = function_body(INBOX, "public func finish(_ claimed: URL, payloadID: UUID) throws {")
        self.assertLess(finish.index("markDelivered(payloadID)"), finish.index("removeItem"),
                        "a crash between the two must leave a marker, not a resend")

    def test_a_second_run_with_a_stale_file_does_not_send_again(self) -> None:
        drain = function_body(RECEIVER, "func drain(accept: (SharePayload) async -> Bool) async {")
        self.assertIn("if storage.isDelivered(payload.id)", drain)
        before_accept = drain[:drain.index("await accept(payload)")]
        self.assertIn("isDelivered", before_accept,
                      "the delivered marker must be checked before anything is handed over")
        self.assertIn("isDraining", RECEIVER, "two overlapping drains must not interleave")

    def test_a_refused_payload_goes_back_in_line(self) -> None:
        drain = function_body(RECEIVER, "func drain(accept: (SharePayload) async -> Bool) async {")
        self.assertIn("storage.restore(claimed)", drain)
        self.assertIn("break", drain, "a host that is down must not burn through the queue")

    def test_attachment_bytes_outlive_acceptance_until_the_upload_is_done(self) -> None:
        """Acceptance returns before the host has the file.

        Deleting the bytes in `finish` pulled the file out from under an upload that had been
        handed a path, so the payload goes and the bytes wait for `prune`.
        """
        finish = function_body(INBOX, "public func finish(_ claimed: URL, payloadID: UUID) throws {")
        self.assertNotIn("removeAssets", finish,
                         "bytes deleted at acceptance can vanish mid-upload")
        self.assertIn("public func removeAssets", INBOX,
                      "the app still needs a way to drop them once the upload is finished")
        self.assertIn("prune", function_body(INBOX, "public func prune(now: Date = Date()) {"))

    def test_an_unreadable_payload_is_parked_not_deleted(self) -> None:
        drain = function_body(RECEIVER, "func drain(accept: (SharePayload) async -> Bool) async {")
        self.assertIn("storage.reject(url)", drain)
        self.assertIn("lastError", drain)


class TestTheExtensionCannotReachTheHost(unittest.TestCase):
    """The extension is the one place a token must never be.

    It runs inside another app's process, for seconds, with no pairing. Anything it could do to the
    host would have to be created here — so the test is the absence of the machinery.
    """

    FORBIDDEN = (
        "URLSession",
        "URLRequest",
        "Authorization",
        "Bearer",
        "baseURL",
        "keychain",
        "SecItem",
        "kSecClass",
        "UserDefaults",
        "GatewayClient",
        "HermesKit",
        "hermesd",
        "/v1/",
        "http://",
        "https://",
    )

    def test_no_network_or_credential_surface_exists_in_the_extension(self) -> None:
        for name, source in EXTENSION_SWIFT.items():
            for needle in self.FORBIDDEN:
                self.assertNotIn(needle, source, f"{name} mentions {needle}")

    def test_the_only_storage_it_names_is_the_group_container(self) -> None:
        for name, source in EXTENSION_SWIFT.items():
            for other in ("cachesDirectory", "documentsDirectory", "applicationSupportDirectory"):
                self.assertNotIn(other, source, name)

    def test_it_reads_bots_only_from_the_published_snapshot(self) -> None:
        self.assertIn("ShareBotSnapshotStore.load", EXTENSION_SWIFT["ShareComposer.swift"])
        self.assertIn("ShareBotSnapshotStore", SNAPSHOT)
        self.assertIn("Called by the app whenever the bot list it holds changes",
                      SNAPSHOT)

    def test_a_missing_or_stale_snapshot_becomes_an_instruction_not_an_empty_list(self) -> None:
        composer = EXTENSION_SWIFT["ShareComposer.swift"]
        self.assertIn("Open Hermey once so it can list your bots here.", composer)
        self.assertIn("The bot list is out of date. Open Hermey to refresh it, then share again.",
                      composer)
        self.assertIn("No bots yet. Add one in Hermey, then share again.", composer)
        self.assertIn("case .missing", composer)
        self.assertIn("case .stale", composer)

    def test_the_picker_is_offered_before_send_is_enabled(self) -> None:
        composer = EXTENSION_SWIFT["ShareComposer.swift"]
        self.assertIn("selectedBotID != nil", composer)
        self.assertIn("!draft.isEmpty", composer)
        root = EXTENSION_SWIFT["ShareRootView.swift"]
        self.assertIn(".disabled(!composer.canSend)", root)


class TestTheHandoffIsDeepLinkThenClose(unittest.TestCase):
    def test_it_writes_opens_and_only_then_completes(self) -> None:
        composer = EXTENSION_SWIFT["ShareComposer.swift"]
        send = function_body(composer, "func send() async {")
        self.assertLess(send.index("storage.write(payload)"), send.index("openApp?()"),
                        "the app must be summoned after the payload exists")

        controller = EXTENSION_SWIFT["ShareViewController.swift"]
        self.assertIn('URL(string: "hermey://share")', controller)
        self.assertLess(controller.index("context.open("),
                        controller.index("extensionContext?.completeRequest"))

    def test_a_refused_open_still_closes_and_keeps_the_payload(self) -> None:
        controller = EXTENSION_SWIFT["ShareViewController.swift"]
        self.assertIn("hasCompleted", controller,
                      "the open callback and the fallback must not complete twice")
        self.assertIn("asyncAfter", controller)
        self.assertIn("completeRequest(returningItems: [], completionHandler: nil)", controller)

    def test_cancel_reports_a_cancellation_rather_than_a_completion(self) -> None:
        controller = EXTENSION_SWIFT["ShareViewController.swift"]
        self.assertIn("cancelRequest(withError:", controller)
        self.assertIn("NSUserCancelledError", controller)

    def test_the_receiver_recognises_the_same_url_the_extension_opens(self) -> None:
        self.assertRegex(RECEIVER, r'url\.scheme == "hermey" && url\.host == "share"')
        self.assertIn('URL(string: "hermey://share")!', RECEIVER)
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertGreaterEqual(project.count("- hermey"), 2,
                                "both apps must keep the hermey scheme registered")


class TestTheInfoPlistIsAShareExtension(unittest.TestCase):
    def test_the_extension_point_and_principal_class_are_right(self) -> None:
        info = plistlib.loads(EXTENSION_INFO.read_bytes())
        extension = info["NSExtension"]
        self.assertEqual(extension["NSExtensionPointIdentifier"], "com.apple.share-services")
        self.assertEqual(extension["NSExtensionPrincipalClass"],
                         "$(PRODUCT_MODULE_NAME).ShareViewController")
        self.assertIn("class ShareViewController",
                      EXTENSION_SWIFT["ShareViewController.swift"],
                      "the principal class must exist in the module the plist names")

    def test_the_activation_rule_offers_text_links_and_images(self) -> None:
        info = plistlib.loads(EXTENSION_INFO.read_bytes())
        rule = info["NSExtension"]["NSExtensionAttributes"]["NSExtensionActivationRule"]
        self.assertIs(rule.get("NSExtensionActivationSupportsText"), True)
        self.assertGreaterEqual(rule.get("NSExtensionActivationSupportsWebURLWithMaxCount", 0), 1)
        self.assertGreaterEqual(rule.get("NSExtensionActivationSupportsImageWithMaxCount", 0), 1)

    def test_the_display_name_is_the_apps_name(self) -> None:
        info = plistlib.loads(EXTENSION_INFO.read_bytes())
        self.assertEqual(info["CFBundleDisplayName"], "Hermey",
                         "the share sheet row is the app's name, not the target's")

    def test_the_bundle_identifier_is_under_the_app(self) -> None:
        info = plistlib.loads(EXTENSION_INFO.read_bytes())
        self.assertEqual(info["CFBundlePackageType"], "XPC!")
        # project.yml owns the identifier; the plist must defer to it rather than hard-code one.
        self.assertEqual(info["CFBundleIdentifier"], "$(PRODUCT_BUNDLE_IDENTIFIER)")


class TestTheAppGroupIsNamedOnce(unittest.TestCase):
    def test_the_entitlement_matches_the_code(self) -> None:
        match = re.search(r'public static let appGroupIdentifier = "([^"]+)"', INBOX)
        self.assertIsNotNone(match, "the group identifier must be a constant, not a literal in two files")
        identifier = match.group(1)
        entitlements = plistlib.loads(EXTENSION_ENTITLEMENTS.read_bytes())
        self.assertEqual(entitlements["com.apple.security.application-groups"], [identifier])
        self.assertEqual(identifier, "group.dev.hermey.app")

    def test_the_readme_tells_the_parent_to_add_it_to_both_targets(self) -> None:
        readme = (EXTENSION / "README.md").read_text(encoding="utf-8")
        self.assertIn("com.apple.security.application-groups", readme)
        self.assertGreaterEqual(readme.count("group.dev.hermey.app"), 2)


class TestEverythingIsIOSOnly(unittest.TestCase):
    def test_each_extension_source_is_guarded(self) -> None:
        for name, source in EXTENSION_SWIFT.items():
            self.assertTrue(source.lstrip().startswith("#if os(iOS)"),
                            f"{name} is not wrapped in #if os(iOS)")
            self.assertTrue(source.rstrip().endswith("#endif"),
                            f"{name} does not close its #if os(iOS)")

    def test_the_receiver_is_guarded_so_the_mac_target_compiles_untouched(self) -> None:
        self.assertTrue(RECEIVER.lstrip().startswith("#if os(iOS)"))
        self.assertTrue(RECEIVER.rstrip().endswith("#endif"))

    def test_no_mac_framework_is_imported_anywhere_near_this_feature(self) -> None:
        for name, source in EXTENSION_SWIFT.items():
            self.assertNotIn("import AppKit", source, name)
            self.assertNotIn("NSApplication", source, name)
        self.assertNotIn("import AppKit", RECEIVER)


if __name__ == "__main__":
    unittest.main()
