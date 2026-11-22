"""The app's half of the share sheet: the roster it publishes, when it drains, and what "accepted" means.

The extension writes bytes into an App Group container and opens ``hermey://share``; everything
after that is the app's, and none of it is visible to a compiler. These tests pin the three
decisions that are easy to get subtly wrong and impossible to see in a green build:

* the picker is fed from the *model's* roster, written off the main thread, and not rewritten when
  nothing changed (a file the extension may be reading at that moment);
* draining happens at the three moments the container can gain something — launch, becoming
  active, the deep link — and never twice at once;
* ``accept`` answers true only when a message actually reached the host, so a refusal leaves the
  share queued instead of deleting it.

Written as ``unittest.TestCase``: CI runs ``unittest discover``, which collects only TestCase
subclasses, so bare classes with ``assert`` would enforce nothing there.
"""

import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "Apps" / "HermesMobile"
WIRING_FILE = APP / "Views" / "ShareWiring.swift"
SHELL_FILE = APP / "HermesMobileApp.swift"
RECEIVER_FILE = APP / "Views" / "ShareInboxReceiver.swift"
PROJECT = ROOT / "project.yml"

WIRING = WIRING_FILE.read_text(encoding="utf-8")
SHELL = SHELL_FILE.read_text(encoding="utf-8")
RECEIVER = RECEIVER_FILE.read_text(encoding="utf-8")


def swift_block(source: str, marker: str) -> str:
    """The balanced ``{ … }`` that follows ``marker``, with string literals and comments skipped.

    If ``marker`` itself contains the opening brace (a declaration signature, or a modifier written
    out in full), that brace is the block's; otherwise the first ``{`` after the marker is.
    Enough for SwiftUI modifier bodies, which nest closures several deep, and for interpolated
    strings — a ``{`` inside ``"\\(x)"`` must not be counted as a brace.
    """
    start = source.index(marker)
    if "{" in marker:
        open_at = start + marker.rindex("{")
    else:
        open_at = source.index("{", start + len(marker))
    depth = 0
    index = open_at
    in_string = False
    escaped = False
    in_comment = False
    while index < len(source):
        char = source[index]
        if in_comment:
            if char == "\n":
                in_comment = False
        elif in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif source.startswith("//", index):
            in_comment = True
            index += 1
        elif char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[open_at:index + 1]
        index += 1
    raise AssertionError(f"unbalanced braces after {marker!r}")


def function_body(source: str, signature: str) -> str:
    """The body of the declaration that starts at ``signature``."""
    block = swift_block(source, signature)
    return block


class TestThePickerGetsTheRosterTheAppHolds(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.publish = function_body(WIRING, "static func publishBots(from model: AppModel) async {")

    def test_the_list_comes_from_the_model_not_from_a_second_fetch(self) -> None:
        self.assertIn("model.bots.map { (id: $0.id, displayName: $0.displayName) }", WIRING)
        # The extension has no host connection, so the app may not delegate the question back to it.
        self.assertNotIn("URLSession", WIRING)
        self.assertNotIn("client.submit", WIRING)

    def test_the_snapshot_is_written_through_the_store_that_owns_the_schema(self) -> None:
        self.assertIn("ShareBotSnapshotStore.publish(bots, defaultBotID: defaultBotID)", self.publish)
        # Versioning stays the type's job: a hand-built snapshot could be written with a version
        # this build does not implement.
        self.assertNotIn("ShareBotSnapshot(", WIRING)
        self.assertIn("let defaultBotID = model.selectedBotID", self.publish,
                      "the picker preselection is the bot the app last opened")

    def test_the_write_happens_off_the_main_thread(self) -> None:
        self.assertIn("Task.detached(priority: .utility)", self.publish)
        # The publish is awaited *inside* the detached task, so a failed write is still reported.
        self.assertIn("}.value", self.publish)
        self.assertIn("if !wrote { publishedSignature = nil }", self.publish,
                      "a write that failed (no container yet) must not be remembered as done")

    def test_an_unchanged_roster_is_not_rewritten(self) -> None:
        self.assertIn("private static var publishedSignature: String?", WIRING)
        self.assertIn("guard signature != publishedSignature else { return }", self.publish)
        # …and a relaunch has no memory, so the file itself is the second opinion.
        self.assertIn("if let existing = existingSnapshot(),", self.publish)
        self.assertIn("Self.matches(existing, bots: bots, defaultBotID: defaultBotID)", self.publish)
        # The comparison normalises the display name exactly as `ShareBot` writes it, or an empty
        # label would look changed on every launch.
        self.assertRegex(WIRING, r"ShareBot\(id: fresh\.id,\s*\n?\s*displayName: fresh\.displayName\)\.displayName")

    def test_an_empty_roster_does_not_blank_a_working_picker(self) -> None:
        self.assertIn("guard !bots.isEmpty else { return }", self.publish)

    def test_the_app_publishes_at_launch_and_on_every_roster_change(self) -> None:
        launch = swift_block(SHELL, ".task {\n                    ThemeRuntime.restoreFromDefaults()")
        self.assertIn("await ShareWiring.publishBots(from: app.model)", launch)
        self.assertIn("await app.start()", launch)
        roster_change = swift_block(SHELL, ".onChange(of: app.model.bots)")
        self.assertIn("ShareWiring.publishBots(from: app.model)", roster_change)


class TestDrainingHappensAtTheThreeMoments(unittest.TestCase):
    def test_a_pass_runs_at_launch_after_the_model_is_ready(self) -> None:
        launch = swift_block(SHELL, ".task {\n                    ThemeRuntime.restoreFromDefaults()")
        start = launch.index("await app.start()")
        published = launch.index("await ShareWiring.publishBots(from: app.model)")
        drained = launch.index("await ShareWiring.drain(app.model)")
        self.assertLess(start, published, "the roster must be published before the first drain")
        self.assertLess(published, drained)

    def test_a_pass_runs_when_the_scene_becomes_active(self) -> None:
        phase = swift_block(SHELL, ".onChange(of: scenePhase) { phase in")
        self.assertIn("if phase == .active {", phase)
        active = phase.index("if phase == .active {")
        self.assertIn("ShareWiring.drain(app.model)", phase[active:])

    def test_the_share_deep_link_drains_and_leaves_bot_links_alone(self) -> None:
        handler = swift_block(SHELL, ".onOpenURL { url in")
        self.assertIn("guard ShareInboxReceiver.isShareInboxURL(url) else { return }", handler)
        self.assertLess(handler.index("isShareInboxURL"), handler.index("ShareWiring.drain"))
        # `hermey://bot/<profile>` stays the list's business: this handler must not steal it.
        self.assertNotIn("hermey://bot", handler)
        self.assertNotIn("path.append", handler)

    def test_the_receiver_owns_the_url_the_extension_opens(self) -> None:
        self.assertIn('static let deepLink = URL(string: "hermey://share")!', RECEIVER)
        self.assertIn("url.scheme == \"hermey\" && url.host == \"share\"", RECEIVER)


class TestTwoDrainsCannotOverlap(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.drain = function_body(WIRING, "static func drain(_ model: AppModel) async {")

    def test_the_wiring_refuses_a_second_pass(self) -> None:
        self.assertIn("private static var isDraining = false", WIRING)
        self.assertIn("guard !isDraining else {", self.drain)
        entered = self.drain.index("isDraining = true")
        released = self.drain.index("defer { isDraining = false }")
        handoff = self.drain.index("ShareInboxReceiver.shared.drain")
        self.assertLess(entered, handoff, "the flag must be set before the pass is awaited")
        self.assertLess(released, handoff, "the flag must be released on every exit, including a throw")

    def test_a_caller_during_a_pass_is_served_by_that_pass(self) -> None:
        """Draining again is not the same as draining twice.

        The foreground drain may already have listed the inbox when the extension writes its file
        and opens `hermey://share`. Returning outright would leave that share for the next launch;
        the pass therefore repeats, and the claim-by-rename in the receiver is what keeps the second
        lap from delivering anything twice.
        """
        self.assertIn("private static var drainAgain = false", WIRING)
        self.assertIn("drainAgain = true", self.drain)
        self.assertIn("repeat {", self.drain)
        self.assertIn("} while drainAgain", self.drain)
        self.assertLess(self.drain.index("drainAgain = false"),
                        self.drain.index("ShareInboxReceiver.shared.drain"),
                        "the flag has to be cleared before the pass that will set it again")

    def test_the_receiver_guards_its_own_pass_as_well(self) -> None:
        body = function_body(RECEIVER, "func drain(accept: (SharePayload) async -> Bool) async {")
        self.assertIn("guard !isDraining else { return }", body)
        self.assertIn("isDraining = true", body)

    def test_the_flag_is_released_after_the_pass_not_before(self) -> None:
        # `defer` is the only exit path that covers `break`, `continue` and the awaited closure.
        self.assertNotIn("isDraining = false\n        await ShareInboxReceiver", self.drain)


class TestAcceptedMeansDelivered(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.deliver = function_body(WIRING, "private static func deliver(_ payload: SharePayload, to model: AppModel) async -> Bool {")

    def test_an_offline_app_refuses_and_leaves_the_share_queued(self) -> None:
        self.assertIn("guard model.connection.isLive else { return false }", self.deliver)

    def test_a_busy_composer_is_waited_out_rather_than_merged(self) -> None:
        # `send()` submits *every* staged attachment, so the person's file would ride along with the
        # share — or the share's bytes with their next message.
        self.assertIn("guard !model.sending, model.pendingAttachments.isEmpty else { return false }",
                      self.deliver)

    def test_the_payload_goes_to_its_own_bot(self) -> None:
        self.assertIn("model.endlessSession(for: payload.botID, select: true)", self.deliver)
        self.assertIn("model.selectedBotID == payload.botID", self.deliver)
        self.assertIn("model.selectedSessionID == session", self.deliver)

    def test_the_message_travels_the_ordinary_send_path(self) -> None:
        self.assertIn("model.draft = body", self.deliver)
        self.assertIn("await model.send()", self.deliver)
        # Not a second way to reach the host.
        self.assertNotIn("submit(", WIRING)
        self.assertNotIn("URLSession", WIRING)

    def test_true_requires_the_send_to_have_actually_landed(self) -> None:
        self.assertIn("let reached = model.lastSendError == nil", self.deliver)
        self.assertIn("&& model.pendingAttachments.isEmpty", self.deliver,
                      "a failed submit keeps the staged bytes — that is the tell")
        self.assertIn("count > matchesBefore", self.deliver)
        guard_at = self.deliver.index("guard reached else {")
        self.assertLess(guard_at, self.deliver.rindex("return true"),
                        "success may only be reported after the guard on `reached`")
        self.assertEqual(self.deliver.count("return true"), 2,
                         "one early accept for an empty payload, one after `reached`")

    def test_two_identical_shares_cannot_vouch_for_each_other(self) -> None:
        """The success test counts the bubble, it does not search for one.

        Two shares of the same text produce two identical user rows. Searching the transcript would
        let the second one's failed submit find the first one's bubble and be reported as delivered —
        and then the payload is deleted, which is the one outcome this protocol exists to prevent.
        """
        self.assertIn("let matchesBefore = model.transcript.filter", self.deliver)
        self.assertLess(self.deliver.index("matchesBefore"), self.deliver.index("await model.send()"))
        self.assertNotIn("model.transcript.contains", self.deliver)

    def test_a_failed_attempt_puts_the_composer_back(self) -> None:
        failure = self.deliver[self.deliver.index("guard reached else {"):]
        self.assertIn("for id in stagedIDs { model.removePendingAttachment(id) }", failure,
                      "the share's bytes must not ride along with the person's next message")
        self.assertIn("model.draft = priorDraft", failure)
        self.assertIn("return false", failure,
                      "false is what renames the payload back into Inbox/ for the next pass")

    def test_a_payload_with_nothing_readable_is_kept_rather_than_accepted(self) -> None:
        self.assertIn("guard !body.isEmpty || !stagedIDs.isEmpty else { return false }", self.deliver)

    def test_delivery_is_once_only_by_the_receivers_protocol(self) -> None:
        body = function_body(RECEIVER, "func drain(accept: (SharePayload) async -> Bool) async {")
        # Claimed by rename before the closure runs, so the deep link and the foreground pass cannot
        # both deliver the same share.
        self.assertLess(body.index("storage.claim(url)"), body.index("await accept(payload)"))
        # Already-delivered payloads are retired without being sent again.
        self.assertLess(body.index("storage.isDelivered(payload.id)"),
                        body.index("await accept(payload)"))
        self.assertIn("try? storage.finish(claimed, payloadID: payload.id)",
                      body[body.index("await accept(payload)"):])
        # The wiring never writes a payload of its own, so it cannot manufacture a second delivery.
        self.assertNotIn("storage.write", WIRING)
        self.assertNotIn("importAttachment", WIRING)


class TestImagesTravelTheComposersOwnPath(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.deliver = function_body(WIRING, "private static func deliver(_ payload: SharePayload, to model: AppModel) async -> Bool {")

    def test_the_bytes_are_read_before_the_descriptor_is_deleted(self) -> None:
        self.assertIn("ShareInboxReceiver.shared.data(for: attachment, payloadID: payload.id)",
                      self.deliver)
        self.assertLess(self.deliver.index("data(for: attachment"), self.deliver.index("await model.send()"),
                        "the receiver deletes the payload as soon as the closure returns true")

    def test_an_image_is_staged_exactly_as_a_picked_one(self) -> None:
        self.assertIn("model.addPendingAttachment(name: name, data: data, isImage: attachment.kind == .image)",
                      self.deliver)
        self.assertIn("attachment.originalName ?? attachment.fileName", self.deliver)

    def test_a_file_that_could_not_be_attached_is_named_in_the_message(self) -> None:
        self.assertIn("var unstaged: [String] = []", self.deliver)
        self.assertIn('let line = "Shared with this message but not attached: "', self.deliver)
        self.assertIn("body = body.isEmpty ? line : body + \"\\n\\n\" + line", self.deliver,
                      "nothing is silently dropped")
        # The composer's own refusals (over the size limit, the eight-file cap) count as unattached.
        self.assertIn("if added.isEmpty {", self.deliver)

    def test_the_container_copy_is_dropped_only_after_the_host_has_the_bytes(self) -> None:
        self.assertIn("try? ShareInboxStorage.live.removeAssets(payload.id)", self.deliver)
        self.assertLess(self.deliver.index("guard reached else {"),
                        self.deliver.index("removeAssets(payload.id)"))

    def test_the_persons_draft_survives_a_share(self) -> None:
        self.assertIn("let priorDraft = model.draft", self.deliver)
        self.assertIn("if model.draft.isEmpty, !priorDraft.isEmpty", self.deliver)


class TestNothingSharedWasTouched(unittest.TestCase):
    """The wiring is app-target-only, so it may not leak into HermesKit or the project file."""

    def test_no_source_in_the_shared_packages_knows_about_the_share_sheet(self) -> None:
        for path in sorted((ROOT / "Sources").rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            for symbol in ("ShareWiring", "ShareInboxStorage", "ShareBotSnapshot"):
                self.assertNotIn(symbol, text, f"{path.relative_to(ROOT)} reaches into the app's share wiring")

    def test_the_mac_app_does_not_compile_it(self) -> None:
        for path in sorted((ROOT / "Apps" / "HermesMac").rglob("*.swift")):
            self.assertNotIn("ShareWiring", path.read_text(encoding="utf-8"),
                             f"{path.relative_to(ROOT)} cannot see an iOS-only surface")
        # The file itself is gated, so even an accidental inclusion builds on the Mac unchanged.
        self.assertTrue(WIRING.lstrip().startswith("#if os(iOS)"), "the file must be iOS-gated")
        self.assertTrue(WIRING.rstrip().endswith("#endif"))

    def test_the_new_file_needs_no_project_change(self) -> None:
        project = PROJECT.read_text(encoding="utf-8")
        self.assertIn("- path: Apps/HermesMobile", project,
                      "the app's sources are directory-based, which is why Views/ needs no entry")
        self.assertNotIn("ShareWiring", project)
        self.assertIn("- path: Apps/HermesShare", project)

    def test_the_wiring_owns_no_shared_code(self) -> None:
        # Was `git status --porcelain -- Sources project.yml` must be empty — which failed the whole
        # suite the moment the parent (or another task) legitimately edited those files. Assert the
        # property that was actually meant: this file adds no shared-target code and no network path of
        # its own; it goes through the model's send/select API.
        source = (ROOT / "Apps" / "HermesMobile" / "Views" / "ShareWiring.swift").read_text()
        self.assertNotIn("URLSession", source, "delivery must not open a second network path")
        # `import HermesKit` is the app's own model layer (`SessionID`, the types `AppModel` speaks);
        # it was there before this feature and the file needs it. What must never appear is a
        # transport of its own — a second client or a hand-built request.
        self.assertNotIn("GatewayClient", source)
        self.assertNotIn("URLRequest", source)
        self.assertIn("#if os(iOS)", source, "the Mac target must compile nothing from this file")


if __name__ == "__main__":
    unittest.main()
