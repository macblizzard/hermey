"""Two ways out of the log sheet: a portion on the clipboard, or a file on the host.

The owner asked for both in one message: "on view log copy shown and copy all both copies the full
log. would be better if i could just copy a portion of the log like last 100 lines and so on instead
of copying the whole thing and paste here on chat. also wouldn't it better if u save the log on
server side as well so that i wont have to paste the whole log for u to investigate?"

These guards read the Swift and the Rust together, because the promises are split across them:

* the four copy labels exist, and all four are narrowed by the active filter;
* the upload posts the copy's own bytes over a bearer HTTP POST, not the relay socket;
* the route is device-authenticated and capped at 2 MiB on both ends;
* the file lands at /var/log/hermey, 0640, named for the device and the minute, and is never
  overwritten;
* nothing new can reach the log — no card or credential value is added by this change;
* the sheet shows the path the host answered with, and keeps itself open on a failure.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / "Sources" / "HermeyUI" / "ClientLogView.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesKit" / "ClientLog.swift").read_text(encoding="utf-8")
UPLOAD = (ROOT / "Sources" / "HermesKit" / "ClientLogUpload.swift").read_text(encoding="utf-8")
MAIN = (ROOT / "hermeyd" / "src" / "main.rs").read_text(encoding="utf-8")
ROUTE = (ROOT / "hermeyd" / "src" / "client_logs.rs").read_text(encoding="utf-8")
APP_MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
PHONE = (ROOT / "Apps" / "HermesMobile" / "Views" / "SettingsScreen.swift").read_text(encoding="utf-8")
PHONE_ENV = (ROOT / "Apps" / "HermesMobile" / "App" / "AppEnvironment.swift").read_text(encoding="utf-8")
MAC_ABOUT = (ROOT / "Apps" / "HermesMac" / "Views" / "AboutSettingsTab.swift").read_text(encoding="utf-8")
MAC_ROOT = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
MAC_STORE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")


def block(source: str, start: str, end: str) -> str:
    """The text between two markers, failing with the name of the marker that is missing."""
    if start not in source:
        raise AssertionError(f"expected to find {start!r}")
    return source.split(start, 1)[1].split(end, 1)[0]


class TheMenuOffersFourCopies(unittest.TestCase):
    """Copy is a menu of four, and every one of them is a portion of what is filtered."""

    def setUp(self) -> None:
        self.scopes = block(MODEL, "public enum ClientLogCopyScope", "/// One recorded fact")
        self.menu = block(VIEW, "private var copyMenu: some View", "/// The sentence under each menu item")

    def test_the_four_labels_exist(self) -> None:
        for title in ('"Copy last 100 lines"', '"Copy last 500 lines"',
                      '"Copy shown"', '"Copy all"'):
            self.assertIn(title, self.scopes, f"the menu lost the {title} item")

    def test_the_limits_are_100_and_500_and_only_the_tails(self) -> None:
        self.assertIn("case .last100: return 100", self.scopes)
        self.assertIn("case .last500: return 500", self.scopes)
        self.assertIn("case .shown, .all: return nil", self.scopes)

    def test_the_labels_carry_a_count(self) -> None:
        # "Copy last 100 lines (of 812)" — the number is the size of the pool the press would take.
        self.assertIn('base = "Copy last 100 lines"', self.scopes)
        self.assertIn('return lineLimit == nil ? "\\(base) (\\(available))" : "\\(base) (of \\(available))"',
                      self.scopes)
        # The menu offers the counted title, not the bare one.
        self.assertIn("Button(scope.title(available: availableCount(scope)))", self.menu)

    def test_the_menu_is_drawn_in_the_sheets_body(self) -> None:
        # Build 0.1.611 lost the copy controls into a toolbar the Mac sheet did not draw.
        body = VIEW.split("// MARK: Toolbar", 1)[0]
        toolbar = VIEW.split("private var toolbar", 1)[1].split("// MARK: Behaviour", 1)[0]
        self.assertIn("copyMenu", block(body, "private var handoffControls", "private var copyMenu"))
        self.assertNotIn("copyMenu", toolbar)

    def test_every_scope_is_narrowed_by_the_active_filter(self) -> None:
        # One query — the one the list is drawn from — is what the tails and "all" read.
        self.assertIn("private var query: ClientLogQuery {", VIEW)
        self.assertIn("ClientLogQuery(order: order, level: levelFilter, category: categoryFilter, search: search)",
                      VIEW)
        entries = block(VIEW, "private func logEntries(limit: Int?)", "/// How many lines the log would hand")
        self.assertIn("ClientLog.shared.snapshot()", entries)
        self.assertIn("query.apply(to: buffer, limit: limit)", entries)
        # And the tail itself drops everything but the newest N *of the filtered set*.
        apply = block(MODEL, "public func apply(to entries: [ClientLogEntry], limit: Int?)", "/// Which of the four")
        self.assertIn("let matched = entries.filter(matches)", apply)
        self.assertIn("matched.suffix(limit)", apply)

    def test_shown_is_the_feed_and_the_others_read_the_log(self) -> None:
        copy = block(VIEW, "private func copy(_ scope: ClientLogCopyScope)", "private func copy(_ entries:")
        self.assertIn("copy(shown, scope: .shown)", copy)
        self.assertIn("copy(logEntries(limit: scope.lineLimit), scope: scope)", copy)
        counts = block(VIEW, "private func availableCount(", "private func copy(_ scope:")
        self.assertIn("scope == .shown ? shown.count : logAdmittedCount", counts)

    def test_one_formatter_still_writes_every_copy(self) -> None:
        self.assertEqual(VIEW.count("ClientLog.text(of:"), 1)
        self.assertIn("private func exportText(_ entries: [ClientLogEntry]) -> String", VIEW)
        self.assertEqual(VIEW.count("write(exportText(entries))"), 1)


class TheUploadIsOneTapOneFile(unittest.TestCase):
    """The host save: a bearer POST, the copy's bytes, and never on its own."""

    def setUp(self) -> None:
        self.send = block(VIEW, "private var sendButton: some View", "/// What the press did")
        self.log = block(VIEW, "private func sendLog()", "/// This device's own name")
        self.client = block(UPLOAD, "public func send(_ payload: ClientLogUploadPayload)",
                           "// MARK: The wire")

    def test_the_sheet_has_a_send_button(self) -> None:
        self.assertIn('handoffLabel("Send log to host", "arrow.up.doc")', self.send)
        self.assertIn("sendLog()", self.send)
        self.assertIn("sendButton", block(VIEW, "private var handoffControls", "private var copyMenu"))

    def test_the_upload_is_a_plain_bearer_post_not_the_socket(self) -> None:
        # The whole point of the route: a busy relay cannot delay it, and it cannot take a slot.
        self.assertIn('request.httpMethod = "POST"', self.client)
        self.assertIn("v1/client-logs", self.client)
        self.assertIn('request.setValue("Bearer \\(prepared.ticket)", forHTTPHeaderField: "Authorization")',
                      self.client)
        self.assertIn("session.data(for: request)", self.client)
        # The relay's own vocabulary: a socket, a frame, a send over the gateway transport.
        for socket in ("GatewayTransport", "URLSessionWebSocketTask", "webSocketTask",
                       "URLSessionWebSocketDelegate", "send(.string"):
            self.assertNotIn(socket, UPLOAD, f"the upload must not ride the relay ({socket})")
        self.assertIn("request.httpBody = try Self.encodedBody(of: payload)", self.client)

    def test_the_body_is_the_copy_verbatim_plus_the_header_facts(self) -> None:
        # The same formatter the copy uses, so the file and the clipboard cannot disagree.
        self.assertIn("text: exportText(entries))", self.log)
        for field in ("device:", "appVersion:", "appBuild:", "osVersion:",
                      "capturedAt:", "level:", "category:", "search:", "scope: .all"):
            self.assertIn(field, self.log, f"the upload header lost {field}")
        wire = block(UPLOAD, "private struct Wire: Encodable", "/// The bytes this upload puts")
        for field in ("device", "appVersion", "appBuild", "osVersion", "scope",
                      "level", "category", "search", "capturedAt", "text"):
            self.assertIn(f"let {field}:", wire, f"the wire lost {field}")

    def test_nothing_is_uploaded_without_a_press(self) -> None:
        # One tap, one file: no timer, no retry, no send on appear.
        self.assertIn("sendLog()", block(VIEW, "private var sendButton", "/// What the press did"))
        self.assertEqual(VIEW.count("sendLog()"), 2, "sendLog is defined once and pressed once")
        for trigger in (".task {\n            sendLog", ".onAppear {\n            sendLog", "Timer"):
            self.assertNotIn(trigger, VIEW)
        self.assertNotIn("retry", self.client.lower())

    def test_a_failure_is_shown_and_keeps_the_sheet_open(self) -> None:
        self.assertIn("sendOutcome = .failed(error.localizedDescription)", self.log)
        status = block(VIEW, "private var sendStatus: some View", "private var clearButton")
        self.assertIn("case let .failed(reason):", status)
        self.assertIn('Text("Not sent — \\(reason)")', status)
        # No dismiss anywhere in the send path: a refusal that closes the sheet takes the log with it.
        for path in (self.send, self.log, status):
            self.assertNotIn("dismiss()", path)

    def test_the_app_shows_the_path_the_host_answered_with(self) -> None:
        self.assertIn("public let path: String", UPLOAD)
        status = block(VIEW, "private var sendStatus: some View", "private var clearButton")
        self.assertIn('Text("Saved on the host: \\(receipt.path)")', status)
        self.assertIn(".textSelection(.enabled)", status)

    def test_every_refusal_has_its_own_sentence(self) -> None:
        for sentence in ("This device is not paired with a host",
                         "is over the", "Copy a portion of it instead",
                         "would not take a log from this device (403)",
                         "already has a log with that name"):
            self.assertIn(sentence, UPLOAD, f"a refusal lost its words: {sentence}")


class TheRouteIsGuarded(unittest.TestCase):
    """`POST /v1/client-logs` on hermeyd: authenticated, capped, and writing one private file."""

    def test_the_route_is_registered_and_device_authenticated(self) -> None:
        self.assertIn('mod client_logs;', MAIN)
        route = block(MAIN, '"/v1/client-logs"', ".layer(axum::extract::DefaultBodyLimit")
        self.assertIn("post(client_logs::post_log)", route)
        self.assertIn("require_device(&st, &headers)?", ROUTE)
        # The very first thing the handler does: an unauthenticated body is never parsed.
        handler = block(ROUTE, "pub async fn post_log(", "let upload: Upload")
        self.assertIn("require_device", handler)

    def test_the_ceiling_is_two_mebibytes_on_both_ends(self) -> None:
        self.assertIn("pub const MAX_LOG_BYTES: usize = 2 * 1024 * 1024;", ROUTE)
        self.assertIn("public static let maximumBytes = 2 * 1024 * 1024", UPLOAD)
        self.assertIn("if upload.text.len() > MAX_LOG_BYTES {", ROUTE)
        self.assertIn("StatusCode::PAYLOAD_TOO_LARGE", ROUTE)
        self.assertIn("ClientLogUploadError.tooLarge", UPLOAD)
        # The framework ceiling sits above the handler's, so the client reads a sentence not a blank.
        self.assertIn("pub const MAX_BODY_BYTES: usize = 8 * 1024 * 1024;", ROUTE)
        self.assertIn("DefaultBodyLimit::max(client_logs::MAX_BODY_BYTES)", MAIN)

    def test_the_file_is_named_for_the_device_and_the_minute(self) -> None:
        self.assertIn('format!("client-{device}-{stamp}.log")', ROUTE)
        self.assertIn("fn slug(name: &str) -> String", ROUTE)
        # The stamp is UTC to the minute, as the owner asked: 20261125T2130Z.
        self.assertIn('format!("{y:04}{m:02}{d:02}T{:02}{:02}Z"', ROUTE)
        # A device name cannot become a path: everything but [a-z0-9-] collapses to a dash.
        self.assertIn("if ch.is_ascii_alphanumeric() {", ROUTE)
        self.assertIn('"device".to_string()', ROUTE)

    def test_the_file_is_private_and_never_overwritten(self) -> None:
        self.assertIn("const FILE_MODE: u32 = 0o640;", ROUTE)
        self.assertIn("const DIR_MODE: u32 = 0o750;", ROUTE)
        self.assertIn("std::fs::Permissions::from_mode(FILE_MODE)", ROUTE)
        self.assertIn(".create_new(true)", ROUTE)
        self.assertIn("ErrorKind::AlreadyExists", ROUTE)
        self.assertIn("StatusCode::CONFLICT", ROUTE)
        # No path that truncates: the only writer opens with create_new.
        self.assertNotIn("std::fs::write(", ROUTE)

    def test_the_log_directory_is_the_services_convention(self) -> None:
        self.assertIn('const DEFAULT_LOG_DIR: &str = "/var/log/hermey";', ROUTE)

    def test_the_header_carries_what_a_reader_needs(self) -> None:
        head = ROUTE.split("fn header_block(", 1)[1].split("fn filter_summary", 1)[0]
        for line in ("# device:", "# device-id:", "# app: Hermey", "# os:",
                     "# captured:", "# saved:", "# copy:", "# filters:", "# lines:"):
            self.assertIn(f'"{line}', head, f"the file header lost {line}")


class TheChangeAddsNoSecretToTheLog(unittest.TestCase):
    """The log holds no credential today, and this change must not be the way one gets in."""

    def test_the_upload_has_no_field_that_could_hold_a_value(self) -> None:
        payload = block(UPLOAD, "public struct ClientLogUploadPayload", "/// `POST /v1/client-logs`'s 201")
        fields = set(re.findall(r"public var (\w+)", payload))
        self.assertEqual(fields, {"device", "appVersion", "appBuild", "osVersion", "scope",
                                  "level", "category", "search", "capturedAt", "text"})
        for forbidden in ("value", "secret", "password", "card", "cvc", "token", "cookie"):
            self.assertNotIn(f"var {forbidden}", payload)
            self.assertNotIn(f"{forbidden}:", block(ROUTE, "struct Upload {", "}"))

    def test_the_route_cannot_see_the_secret_store(self) -> None:
        # No import, no call: a route that cannot reach `secrets::get` cannot write a value into a log.
        for forbidden in ("crate::secrets", "crate::credentials", "crate::vault", "secrets::get"):
            self.assertNotIn(forbidden, ROUTE, f"the log route must not touch {forbidden}")

    def test_the_text_is_the_line_the_app_already_shows(self) -> None:
        # The upload serialises `ClientLogEntry.line` — clock, level, category, message — through the
        # one formatter, so the file cannot carry anything the sheet did not draw.
        self.assertIn("entries.map(\\.line).joined(separator: \"\\n\")", MODEL)
        self.assertIn("private func exportText(_ entries: [ClientLogEntry]) -> String", VIEW)


class TheUploaderIsWiredToBothApps(unittest.TestCase):
    """A saved log needs a host address and a ticket, and neither is invented in a view."""

    def test_the_model_carries_the_uploader(self) -> None:
        self.assertIn("public var clientLogUploader: ClientLogUploadClient?", APP_MODEL)

    def test_both_shells_build_it_from_their_own_pairing(self) -> None:
        self.assertIn("self.model.clientLogUploader = ClientLogUploadClient(endpoint:", PHONE_ENV)
        self.assertIn("model.clientLogUploader = ClientLogUploadClient(endpoint:", MAC_STORE)

    def test_all_three_sheets_are_handed_it(self) -> None:
        for host, argument in ((PHONE, "uploader: model.clientLogUploader"),
                               (MAC_ABOUT, "uploader: store.model.clientLogUploader"),
                               (MAC_ROOT, "uploader: store.model.clientLogUploader")):
            self.assertIn('ClientLogView(title: "Log", header: logHeader', host)
            self.assertIn(argument, host)


if __name__ == "__main__":
    unittest.main()
