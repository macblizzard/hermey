"""The soul a new bot starts from, and a JSON copy of the roster.

Asked for 2026-11-15: "an option to set the default bot soul instructions" and "a custom backup
which saves all bot infos like bot name, description, memory, soul, routines as json files".

The bridge behaviour is covered by `Bridge/tests/test_bot_defaults.py` and
`Bridge/tests/test_bot_backup.py`; this pins what the apps do with it.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULTS = (ROOT / "Bridge" / "hermes_bridge" / "bot_defaults.py").read_text(encoding="utf-8")
BACKUP = (ROOT / "Bridge" / "hermes_bridge" / "bot_backup.py").read_text(encoding="utf-8")
APP_PY = (ROOT / "Bridge" / "hermes_bridge" / "app.py").read_text(encoding="utf-8")

KIT = (ROOT / "Sources" / "HermesKit" / "BotDefaults.swift").read_text(encoding="utf-8")
POINTER = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text(encoding="utf-8")
CLIENT = (ROOT / "Sources" / "HermesKit" / "GatewayClient.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
PANES = (ROOT / "Sources" / "HermeyUI" / "BotSettingsPanes.swift").read_text(encoding="utf-8")
IOS = (ROOT / "Apps" / "HermesMobile" / "Views" / "SettingsScreen.swift").read_text(encoding="utf-8")
MAC = (ROOT / "Apps" / "HermesMac" / "Views" / "MacSettingsView.swift").read_text(encoding="utf-8")


class TheDefaultSoulLivesOnTheHost(unittest.TestCase):
    def test_both_verbs_exist_and_are_mounted(self) -> None:
        self.assertIn('@router.get("/bot-defaults")', DEFAULTS)
        self.assertIn('@router.put("/bot-defaults/soul")', DEFAULTS)
        self.assertIn("create_bot_defaults_router(runtime)", APP_PY)

    def test_an_empty_text_is_the_reset(self) -> None:
        self.assertIn("if not body.text.strip():", DEFAULTS)
        self.assertIn("path.unlink(missing_ok=True)", DEFAULTS)

    def test_it_does_not_guess_hermess_wording(self) -> None:
        """The built-in default is read from the install, not copied into this repo."""
        self.assertIn("def built_in_soul()", DEFAULTS)
        self.assertIn("return None", DEFAULTS)

    def test_a_soul_has_a_ceiling(self) -> None:
        self.assertIn("MAX_SOUL_CHARS = 64_000", DEFAULTS)


class TheBackupIsConfigOnly(unittest.TestCase):
    def test_the_two_routes_exist_and_are_mounted(self) -> None:
        self.assertIn('@router.get("/backup")', BACKUP)
        self.assertIn('@router.post("/backup/restore")', BACKUP)
        self.assertIn("create_backup_router(runtime)", APP_PY)

    def test_it_reads_every_document_a_bot_is(self) -> None:
        for name in ("SOUL.md", "memories/MEMORY.md", "memories/USER.md", "cron/jobs.json"):
            self.assertIn(name, BACKUP)
        self.assertIn("NOTES_NAME", BACKUP)
        self.assertIn('"description": fields.get("description")', BACKUP)

    def test_it_carries_no_conversations(self) -> None:
        self.assertNotIn("state.db", BACKUP)
        self.assertNotIn("sessions", BACKUP)

    def test_a_restore_never_overwrites_a_live_bot(self) -> None:
        self.assertIn("if _read(directory, relative).strip():", BACKUP)

    def test_restoring_twice_does_not_double_a_schedule(self) -> None:
        self.assertIn("if job_id and job_id in known:", BACKUP)

    def test_a_newer_backup_is_refused(self) -> None:
        self.assertIn("BACKUP_VERSION", BACKUP)
        self.assertIn("status_code=409", BACKUP)

    def test_a_profile_name_is_checked_before_a_directory_is_made(self) -> None:
        self.assertIn("PROFILE_RE.match(profile)", BACKUP)


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
