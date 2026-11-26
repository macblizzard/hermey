"""The one-press host update, pinned where a compiler cannot see the whole of it.

Three things have to be true at once and none of them is checkable from either side alone:

* the **host** reports its own next version, verifies what it downloads, installs it beside the
  running binary, and can put the previous build back **without the network**;
* the **apps** draw that as one row above the waiting bots, never apply anything without a press,
  and keep the words for each stage the host reports;
* the two agree on the names: `/v1/update`, `pending` / `healthy` / `rolled-back`,
  `downloading` / `verifying` / `installing`.

The Swift and Rust sources are read as text. The behaviour itself is tested where it runs: the Rust
suite (`hermeyd/src/update.rs`, including a fake release server on a loopback port) covers the state
machine, the checksum and the install; these assertions cover the wiring between the two languages,
which neither suite can see.
"""

from __future__ import annotations

import os
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

UPDATE_RS = (ROOT / "hermeyd" / "src" / "update.rs").read_text(encoding="utf-8")
MAIN_RS = (ROOT / "hermeyd" / "src" / "main.rs").read_text(encoding="utf-8")
AUDIT_RS = (ROOT / "hermeyd" / "src" / "audit.rs").read_text(encoding="utf-8")
CARGO = (ROOT / "hermeyd" / "Cargo.toml").read_text(encoding="utf-8")
DOCS = (ROOT / "docs" / "HERMEYD.md").read_text(encoding="utf-8")

KIT = (ROOT / "Sources" / "HermesKit" / "HostUpdate.swift").read_text(encoding="utf-8")
STATE = (ROOT / "Sources" / "HermesAppKit" / "HostUpdate.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
ROW = (ROOT / "Sources" / "HermeyUI" / "HostUpdateRow.swift").read_text(encoding="utf-8")
INBOX = (ROOT / "Sources" / "HermeyUI" / "WaitingBotsInbox.swift").read_text(encoding="utf-8")
MAC_SIDEBAR = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
MAC_ABOUT = (ROOT / "Apps" / "HermesMac" / "Views" / "AboutSettingsTab.swift").read_text(encoding="utf-8")
IOS_LIST = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")


def block(source: str, opening: str, closing: str) -> str:
    """The text between one marker and the next, both exclusive."""
    assert opening in source, f"{opening!r} is gone"
    tail = source.split(opening, 1)[1]
    assert closing in tail, f"{closing!r} did not follow {opening!r}"
    return tail.split(closing, 1)[0]


def from_marker(source: str, opening: str) -> str:
    """Everything from a marker to the end of the file (for the last declaration)."""
    assert opening in source, f"{opening!r} is gone"
    return source.split(opening, 1)[1]


# The two declarations the app side owns, each grabbed once.
ROW_TYPE = from_marker(KIT, "public struct HostUpdate: Equatable, Sendable {")
TRACKER = from_marker(STATE, "public struct HostUpdateTracker:")
CHECKED = block(STATE, "public mutating func checked(", "public mutating func pressed(")
SILENT = block(STATE, "public mutating func silent() {", "/// The owner dismissed")


class TheHostReportsItsOwnNextVersion(unittest.TestCase):
    """`GET /v1/update` is a report, and a report that cannot be read says so."""

    def setUp(self) -> None:
        self.get = block(UPDATE_RS, "pub async fn get_update(", "/// `POST /v1/update`")

    def test_the_route_exists_behind_the_device_bearer(self) -> None:
        self.assertIn('"/v1/update"', MAIN_RS)
        self.assertIn("get(update::get_update).post(update::post_update)", MAIN_RS)
        self.assertIn("require_device(&st, &headers)", self.get)

    def test_the_shape_is_the_contract_the_apps_decode(self) -> None:
        body = block(UPDATE_RS, "pub fn status_body(", "/// `GET /v1/update`")
        for key in ('"current"', '"latest"', '"available"', '"notes_url"', '"checked_at"',
                    '"can_self_update"', '"arch"'):
            self.assertIn(key, body, f"{key} is missing from the report")
        wire = block(KIT, "private struct Wire: Decodable {", "private struct WireRecord")
        for field in ("current", "latest", "available", "notesUrl", "checkedAt",
                      "canSelfUpdate", "arch"):
            self.assertIn(field, wire, f"the client stopped decoding {field}")

    def test_a_failed_check_is_unknown_and_never_a_version(self) -> None:
        body = block(UPDATE_RS, "pub fn status_body(", "/// `GET /v1/update`")
        unknown = body.split("Err(why) => json!({", 1)[1]
        self.assertIn('"latest": Value::Null', unknown,
                      "a check that failed must not report a version it does not have")
        self.assertIn('"available": false', unknown)
        self.assertIn('"error": why', unknown)
        # And a client that cannot answer draws nothing rather than "up to date".
        self.assertIn("available: wire.available ?? false", KIT)

    def test_the_feed_is_cached_and_refreshes_on_demand(self) -> None:
        self.assertIn("CACHE_SECONDS", UPDATE_RS)
        usable = block(UPDATE_RS, "pub fn usable(", "fn cache()")
        self.assertIn("if force {", usable)
        self.assertIn("pub refresh: Option<String>", UPDATE_RS)
        self.assertIn("wants_refresh", self.get)

    def test_only_published_host_releases_are_candidates(self) -> None:
        parse = block(UPDATE_RS, "pub fn parse_releases(", "/// Ask the feed.")
        self.assertIn("TAG_PREFIX", parse)
        self.assertIn('"draft"', parse)
        self.assertIn('"prerelease"', parse, "an automatic updater must not walk onto an rc")
        self.assertIn("compare_versions(&candidate.version, &current.version)", parse,
                      "the newest is compared, not taken from the feed's order")


class TheInstallIsVerifiedAndReversible(unittest.TestCase):
    """What `POST /v1/update` does, and what it refuses to do."""

    def setUp(self) -> None:
        self.post = block(UPDATE_RS, "pub async fn post_update(", "// ---- tests")
        self.stage = block(UPDATE_RS, "async fn stage_and_install(", "/// The whole background half")
        self.install = block(UPDATE_RS, "fn install(cfg: &Config) -> Result<(), StepError> {",
                             "async fn fetch_bytes")

    def test_the_press_is_answered_before_the_download_starts(self) -> None:
        self.assertIn("StatusCode::ACCEPTED", self.post)
        self.assertIn('json!({ "target": target, "state": "started" })', self.post)
        self.assertIn("tokio::spawn(apply(", self.post, "the 202 must not wait for 15 MB")

    def test_a_host_that_cannot_update_itself_answers_403(self) -> None:
        self.assertIn("if !cfg.can_self_update() {", self.post)
        self.assertIn("StatusCode::FORBIDDEN", self.post)
        self.assertIn('reason: Some("not_permitted")', self.post)
        self.assertIn('"can_self_update": can_self_update', UPDATE_RS,
                      "the report has to say so, or an app draws a button that cannot work")

    def test_a_second_press_is_refused_while_one_runs(self) -> None:
        self.assertIn("APPLYING.swap(true", self.post)
        self.assertIn("StatusCode::CONFLICT", self.post)

    def test_the_download_is_checked_against_the_published_digest(self) -> None:
        self.assertIn("SHA256SUMS", self.stage)
        self.assertIn("checksum_for(&sums, &cfg.asset)", self.stage)
        self.assertIn("if actual != expected {", self.stage)
        mismatch = self.stage.split("if actual != expected {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("remove_file(&staged)", mismatch,
                      "a mismatched download must not be left on disk")
        self.assertIn('"checksum_mismatch"', self.stage)
        self.assertLess(self.stage.index("if actual != expected {"),
                        self.stage.index("std::fs::write(&staged, &bytes)"),
                        "the file is written only after the digest matches")

    def test_the_previous_build_is_kept_and_the_new_one_renamed_in(self) -> None:
        self.assertIn('pub const PREV_FILE: &str = "hermeyd.prev";', UPDATE_RS)
        self.assertIn("std::fs::copy(&cfg.bin, cfg.prev())", self.install,
                      "the previous bytes are kept before anything is replaced")
        self.assertLess(self.install.index("std::fs::copy(&cfg.bin, cfg.prev())"),
                        self.install.index("std::fs::rename(cfg.staged(), &cfg.bin)"),
                        "a failure between the two must leave the running binary in place")
        self.assertIn("std::fs::rename(cfg.staged(), &cfg.bin)", self.install,
                      "one atomic step, or a half-written binary is a host that does not boot")
        # Staged beside the binary, so the rename cannot cross a filesystem.
        self.assertIn('pub const STAGED_FILE: &str = "hermeyd.new";', UPDATE_RS)
        self.assertIn("self.bin.with_file_name(STAGED_FILE)", UPDATE_RS)

    def test_the_service_leaves_so_systemd_starts_the_new_build(self) -> None:
        self.assertIn("std::process::exit(0)", UPDATE_RS)
        self.assertIn("Restart=always",
                      (ROOT / "deploy" / "hermeyd.service").read_text(encoding="utf-8"))

    def test_it_never_runs_anything_and_never_touches_the_engine(self) -> None:
        for forbidden in ("std::process::Command", "Command::new", "\"systemctl\"", "engine_home",
                          "hermes gateway"):
            self.assertFalse(forbidden in UPDATE_RS, f"the updater must not reach {forbidden}")
        # The only two places it writes: the binary's own directory and the state dir.
        self.assertIn("self.state_dir.join(STATE_FILE)", UPDATE_RS)
        self.assertIn("self.bin.with_file_name(PREV_FILE)", UPDATE_RS)


class TheRollbackNeedsNoNetwork(unittest.TestCase):
    """The state file, the two attempts, and the step that puts the old binary back."""

    def setUp(self) -> None:
        self.boot = block(UPDATE_RS, "pub fn on_boot(", "/// `pending` → `healthy`")

    def test_the_record_is_the_three_states_the_apps_switch_on(self) -> None:
        for line in ('pub const PENDING: &str = "pending";',
                     'pub const HEALTHY: &str = "healthy";',
                     'pub const ROLLED_BACK: &str = "rolled-back";'):
            self.assertIn(line, UPDATE_RS)
        # And the app side reads the same words.
        self.assertIn('state == "rolled-back"', KIT)
        self.assertIn('state == "pending"', KIT)

    def test_the_record_holds_what_the_rollback_needs(self) -> None:
        record = block(UPDATE_RS, "pub struct UpdateState {", "\n}\n")
        for field in ("pub target", "pub previous", "pub state", "pub attempts", "pub started_at"):
            self.assertIn(field, record)
        self.assertIn('pub const STATE_FILE: &str = "update-state.json";', UPDATE_RS)
        self.assertIn("write_atomically", UPDATE_RS,
                      "a boot that reads half a record cannot decide anything")

    def test_two_boots_onto_a_build_put_the_previous_one_back(self) -> None:
        self.assertIn("pub const MAX_ATTEMPTS: u32 = 2;", UPDATE_RS)
        self.assertIn("record.attempts += 1;", self.boot)
        self.assertIn("if record.attempts < MAX_ATTEMPTS {", self.boot)
        self.assertIn("restore_binary(bin)", self.boot)
        self.assertIn("record.state = ROLLED_BACK.to_string();", self.boot)
        # And main exits, so systemd starts the binary that was just restored.
        self.assertIn("update::Boot::RolledBack { target, to }", MAIN_RS)
        self.assertIn("std::process::exit(0);", MAIN_RS)

    def test_the_rollback_is_file_operations_only(self) -> None:
        for forbidden in ("reqwest", "http_client", "fetch_bytes", "latest_release", "Release"):
            self.assertFalse(forbidden in self.boot,
                             f"the rollback path must not need the network ({forbidden})")
        restore = block(UPDATE_RS, "fn replace_file(", "/// Keep the running build beside")
        for forbidden in ("reqwest", "http", "url", "Release"):
            self.assertFalse(forbidden in restore)

    def test_a_failed_rollback_says_so_and_stays_pending(self) -> None:
        self.assertIn("Boot::RollbackStuck(why)", self.boot)
        stuck = self.boot.split("Err(why) => {", 1)[1]
        self.assertFalse("record.state = ROLLED_BACK" in stuck,
                         "a rollback that did not happen must not be recorded as done")

    def test_the_build_is_settled_once_it_has_served(self) -> None:
        self.assertIn("pub const HEALTHY_SECONDS: u64 = 60;", UPDATE_RS)
        healthy = block(UPDATE_RS, "pub fn mark_healthy(", "// ---- the routes")
        self.assertIn("record.state = HEALTHY.to_string();", healthy)
        self.assertIn("record.target != running", healthy, "only the build on trial is settled")
        self.assertIn("update::mark_healthy(", MAIN_RS, "boot must start the timer")

    def test_rollback_happens_before_anything_is_served(self) -> None:
        self.assertLess(MAIN_RS.index("update::on_boot("), MAIN_RS.index("axum::serve(listener"),
                        "a build that is going to be replaced must not answer a request first")


class TheAppsDrawItOnlyWhenTheHostSaysSo(unittest.TestCase):
    """One row, in the bell's list, with words for every stage — and a button, only a button."""

    def test_there_is_a_row_for_every_stage_the_host_reports(self) -> None:
        for stage in ("case downloading", "case verifying", "case restarting",
                      "case updated", "case rolledBack", "case failed"):
            self.assertIn(stage, ROW_TYPE)
        words = block(KIT, "public var stateText: String? {", "/// A press is in flight")
        self.assertIn('"Downloading…"', words)
        self.assertIn('"Verifying…"', words)
        self.assertIn('"Restarting…"', words)
        self.assertIn('"Updated to \\(version)"', words)
        self.assertIn('"Rolled back to \\(version)"', words)
        self.assertIn('"Update failed: \\(reason)"', words)

    def test_the_stage_words_are_the_hosts_own(self) -> None:
        for constant in ('pub const DOWNLOADING: &str = "downloading";',
                         'pub const VERIFYING: &str = "verifying";',
                         'pub const INSTALLING: &str = "installing";'):
            self.assertIn(constant, UPDATE_RS)
        self.assertIn('case "downloading"', CHECKED)
        self.assertIn('case "verifying"', CHECKED)
        self.assertIn('case "installing"', CHECKED)

    def test_a_dropped_socket_is_the_restart_and_not_an_error(self) -> None:
        self.assertIn("socketDropped", CHECKED)
        self.assertIn("socketDropped ? .restarting : nil", CHECKED)
        # Nothing on the check path turns a transport failure into the row's failure text.
        check = block(MODEL, "public func checkHostUpdate(", "/// Press: ask the host")
        self.assertIn("updateTracker.silent()", check)
        self.assertFalse(".failed(" in check, "a failed request is not a failed update")

    def test_nothing_updates_without_a_press(self) -> None:
        # `beginHostUpdate` is reachable from a button and from nowhere else.
        for source, where in ((MAC_SIDEBAR, "the Mac's bell"), (MAC_ABOUT, "Settings ▸ About"),
                              (IOS_LIST, "the phone's bell")):
            self.assertIn("beginHostUpdate()", source, f"{where} cannot press")
            self.assertIn("Button(title)", source if source is MAC_ABOUT else ROW,
                          f"{where} presses from something other than a button")
        # And no lifecycle path reaches it: not launch, not reconnect, not the poll.
        start = block(MODEL, "public func start() async {", "public func stop() async {")
        self.assertFalse("beginHostUpdate" in start, "launch must never update the host")
        connect = block(MODEL, "public func connectNow(", "/// A host timestamp as a `Date`")
        self.assertFalse("beginHostUpdate" in connect, "a reconnect must never update the host")
        poll = block(MODEL, "private func startUpdatePoll() {", "// MARK: Lifecycle")
        self.assertFalse("beginHostUpdate" in poll, "the poll only reads")

    def test_the_row_is_first_in_the_waiting_list_on_both_apps(self) -> None:
        self.assertIn("HostUpdateRow(update: hostUpdate,", INBOX)
        self.assertLess(INBOX.index("HostUpdateRow(update: hostUpdate,"),
                        INBOX.index("ForEach(bots)"),
                        "the host update is the first row, above the bots")
        self.assertIn("hostUpdate: store.model.hostUpdate", MAC_SIDEBAR)
        self.assertIn("hostUpdate: model.hostUpdate", IOS_LIST)

    def test_the_bell_wears_a_dot_for_it(self) -> None:
        self.assertIn("waitingDot(!waitingBots.isEmpty || store.model.hostUpdate?.wantsAttention == true",
                      MAC_SIDEBAR)
        self.assertIn("waitingDot(!waitingBots.isEmpty || model.hostUpdate?.wantsAttention == true",
                      IOS_LIST)
        self.assertIn("public var wantsAttention: Bool { phase == .available }", ROW_TYPE)

    def test_an_old_host_or_an_unpaired_app_draws_nothing(self) -> None:
        self.assertIn("guard let client = hostUpdateClient else { return }", MODEL)
        self.assertIn("updateTracker.silent()",
                      block(MODEL, "public func checkHostUpdate(", "/// Press: ask the host"))
        self.assertIn("update = nil", SILENT)
        # Silence only before a press: a press in flight keeps the row it has.
        self.assertIn("guard pressedAt == nil, !settled else { return }", SILENT)

    def test_a_row_needs_both_an_answer_and_permission(self) -> None:
        self.assertIn("guard status.available, status.canSelfUpdate, let latest = status.latest else {",
                      CHECKED)
        self.assertIn("update = nil", CHECKED)

    def test_about_shows_the_host_version_and_the_same_button(self) -> None:
        self.assertIn('SectionCaption("HOST SERVICE")', MAC_ABOUT)
        self.assertIn("store.model.hostStatus", MAC_ABOUT)
        self.assertIn("aboutHostUpdate", MAC_ABOUT)
        self.assertIn("aboutHostVersion", MAC_ABOUT)
        # The version is derived from the last answer, so the row, the bell and About agree.
        self.assertIn("@Published public private(set) var hostStatus: HostUpdateStatus?", MODEL)
        self.assertIn("public var hostVersion: String? { hostStatus?.current }", MODEL)
        # And "up to date" is never said about a host that could not be asked.
        self.assertIn('return "\(status.current) · could not check"', MAC_ABOUT)

    def test_the_link_to_the_notes_is_quiet_and_optional(self) -> None:
        self.assertIn("public var showsNotes: Bool { notesURL != nil && !isBusy }", ROW_TYPE)
        self.assertIn("Link(\"What's new\", destination: notes)", ROW)

    def test_the_row_is_not_a_bot_row(self) -> None:
        # A different glyph and a button: a host update must never look like one more bot waiting.
        self.assertIn('"arrow.triangle.2.circlepath" : "arrow.down.circle"', ROW)
        self.assertFalse("BotAvatarView" in ROW, "the host row must not borrow a bot's face")
        self.assertIn("hostUpdate.row", ROW)


class TheNamesAgreeAcrossTheTwoLanguages(unittest.TestCase):
    def test_the_route_and_the_client_path_are_the_same_string(self) -> None:
        self.assertIn('"/v1/update"', MAIN_RS)
        self.assertIn('"v1/update"', KIT)

    def test_the_apps_and_the_host_agree_on_the_record(self) -> None:
        self.assertIn('"last_update": state', UPDATE_RS)
        self.assertIn("lastUpdate",
                      block(KIT, "private struct Wire: Decodable {", "private struct WireRecord"))
        self.assertIn("public let lastUpdate: HostUpdateRecord?", KIT)

    def test_the_audit_names_are_registered(self) -> None:
        for event in ("update.check", "update.started", "update.installed", "update.failed",
                      "update.blocked", "update.healthy", "update.rolled_back"):
            self.assertIn(f'"{event}"', AUDIT_RS, f"{event} is not in the audit's closed set")

    def test_the_smoke_script_is_a_runnable_proof(self) -> None:
        script = ROOT / "scripts" / "smoke-self-update.sh"
        self.assertTrue(script.is_file(), "the end-to-end smoke is gone")
        self.assertTrue(os.access(script, os.X_OK), "the smoke is not executable")
        body = script.read_text(encoding="utf-8")
        for check in ("SELF-UPDATE SMOKE OK", "hermeyd.prev", "rolled-back", "SHA256SUMS",
                      "/v1/update"):
            self.assertIn(check, body)

    def test_the_version_was_bumped_and_the_docs_say_so(self) -> None:
        self.assertIn('version = "0.8.14"', CARGO)
        self.assertIn("## Self-update — `GET/POST /v1/update`", DOCS)
        for phrase in ("checksum", "rolled-back", "pending", "healthy",
                       "HERMEYD_SELF_UPDATE", "SHA256SUMS"):
            self.assertIn(phrase, DOCS)


if __name__ == "__main__":
    unittest.main()
