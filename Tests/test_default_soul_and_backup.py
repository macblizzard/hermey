"""The soul a new bot starts from, and a JSON copy of the roster.

Asked for 2026-11-15: "an option to set the default bot soul instructions" and "a custom backup
which saves all bot infos like bot name, description, memory, soul, routines as json files".

The host behaviour lives in `hermeyd/src/bridge_routes.rs` (defaults) and `hermeyd/src/backup.rs`
(export/restore), with its own Rust tests; this pins what the apps do with it.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# The host service is the Rust crate in `hermeyd/` now.
DEFAULTS = (ROOT / "hermeyd" / "src" / "bridge_routes.rs").read_text(encoding="utf-8")
BACKUP = (ROOT / "hermeyd" / "src" / "backup.rs").read_text(encoding="utf-8")
APP_PY = (ROOT / "hermeyd" / "src" / "main.rs").read_text(encoding="utf-8")

KIT = (ROOT / "Sources" / "HermesKit" / "BotDefaults.swift").read_text(encoding="utf-8")
POINTER = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text(encoding="utf-8")
CLIENT = (ROOT / "Sources" / "HermesKit" / "GatewayClient.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
PANES = (ROOT / "Sources" / "HermeyUI" / "BotSettingsPanes.swift").read_text(encoding="utf-8")
IOS = (ROOT / "Apps" / "HermesMobile" / "Views" / "SettingsScreen.swift").read_text(encoding="utf-8")
MAC = (ROOT / "Apps" / "HermesMac" / "Views" / "MacSettingsView.swift").read_text(encoding="utf-8")


class TheDefaultSoulLivesOnTheHost(unittest.TestCase):
    def test_both_verbs_exist_and_are_mounted(self) -> None:
        # Retargeted from `hermes_bridge/bot_defaults.py` (deleted with the Python bridge).
        self.assertIn("pub async fn get_defaults(", DEFAULTS)
        self.assertIn("pub async fn put_defaults_soul(", DEFAULTS)
        self.assertIn('"/v1/bot-defaults"', APP_PY)
        self.assertIn('"/v1/bot-defaults/soul"', APP_PY)

    def test_an_empty_text_is_the_reset(self) -> None:
        # The bridge unlinked the file; hermeyd keeps the document and marks it absent, which the
        # app reads as "no default soul" just the same.
        self.assertIn('"present": !text.trim().is_empty()', DEFAULTS)

    def test_it_does_not_guess_hermess_wording(self) -> None:
        """The built-in default is read from the install, not copied into this repo."""
        self.assertIn('"built_in": null', DEFAULTS)

    # Removed with the Python bridge: `test_a_soul_has_a_ceiling` guarded
    # `bot_defaults.py::MAX_SOUL_CHARS = 64_000`. hermeyd's defaults document has no length ceiling
    # (the engine's own profiles.configure is the only writer), so there is no constant to assert;
    # the missing cap is reported with this change.


class TheBackupIsConfigOnly(unittest.TestCase):
    def test_the_two_routes_exist_and_are_mounted(self) -> None:
        self.assertIn("pub async fn export(", BACKUP)
        self.assertIn("pub async fn restore(", BACKUP)
        self.assertIn('"/v1/backup"', APP_PY)
        self.assertIn('"/v1/backup/restore"', APP_PY)

    def test_it_reads_every_document_a_bot_is(self) -> None:
        for name in ("SOUL.md", "memories/MEMORY.md", "memories/USER.md", "cron/jobs.json"):
            self.assertIn(name, BACKUP)
        self.assertIn('"NOTES.md"', BACKUP)
        self.assertIn('"description": description,', BACKUP)

    def test_it_carries_no_conversations(self) -> None:
        self.assertNotIn("state.db", BACKUP)
        self.assertNotIn("sessions", BACKUP)

    def test_a_restore_never_overwrites_a_live_bot(self) -> None:
        # The default path still refuses to write over a live bot's own words; only the explicit
        # "overwrite" mode may, and it has to be named in the code to exist.
        self.assertIn('if !here.trim().is_empty() && mode != "overwrite"', BACKUP)
        self.assertIn('matches!(mode, "merge" | "overwrite" | "copy")', BACKUP)

    def test_restoring_twice_does_not_double_a_schedule(self) -> None:
        # The engine mints its own job ids, so hermeyd compares name + schedule against what the
        # bot already has instead of the backup's own id.
        self.assertIn("if known.contains(&(name.to_string(), schedule.to_string()))", BACKUP)

    def test_a_newer_backup_is_refused(self) -> None:
        self.assertIn("const IMPORT_VERSION: i64 = 2", BACKUP)
        self.assertIn("StatusCode::CONFLICT", BACKUP)

    def test_a_profile_name_is_checked_before_a_directory_is_made(self) -> None:
        # The name is validated before any directory is made, whatever the entry is called here.
        self.assertIn("fn valid_profile(name: &str) -> bool", BACKUP)
        body = BACKUP.split("if !valid_profile(&wanted)", 1)
        self.assertEqual(len(body), 2, "the import validates the name it is about to create")


class BothAppsEditTheSameThing(unittest.TestCase):
    def test_the_client_carries_the_four_verbs(self) -> None:
        for token in ("func botDefaults", "func setDefaultSoul", "func exportBackup",
                      "func restoreBackup"):
            self.assertIn(token, POINTER)
            self.assertIn(token, CLIENT)
            self.assertIn(token, (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift")
                          .read_text(encoding="utf-8"))

    def test_the_hosts_answers_are_typed(self) -> None:
        self.assertIn("public struct BotDefaults", KIT)
        self.assertIn("public struct BackupRestoreResult", KIT)
        self.assertIn('case builtIn = "built_in"', KIT)

    def test_a_restore_rereads_the_roster(self) -> None:
        self.assertIn("await loadBots()", MODEL)
        self.assertIn("await loadBotCategories()", MODEL)

    def test_a_failed_save_says_so_instead_of_going_quiet(self) -> None:
        self.assertIn("The host refused the change", MODEL)
        self.assertIn("The host refused the file", MODEL)

    def test_both_screens_draw_both_panes(self) -> None:
        self.assertIn("public struct DefaultSoulPane", PANES)
        self.assertIn("public struct BackupPane", PANES)
        self.assertIn("rosterSection", IOS)
        self.assertIn("DefaultSoulPane(current: model.botDefaults.soul.text", IOS)
        self.assertIn("DefaultSoulPane(current: model.botDefaults.soul.text", MAC)
        self.assertIn("BackupPane(botCount: model.bots.count", MAC)

    def test_the_routine_restart_is_not_hidden(self) -> None:
        self.assertIn("restartRequired", KIT)
        self.assertIn("restart the host for the restored routines to run", PANES)


if __name__ == "__main__":
    unittest.main()
