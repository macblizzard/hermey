"""A pairing must survive quitting the Mac app.

The app ships unsigned, so a data-protection Keychain item — the only storage the old
`PairingStore` used — is refused with `errSecMissingEntitlement` (-34018) and every relaunch asked
for a new code from `hermey pair`. These guards keep the three-tier store honest: Keychain first,
then the login Keychain, then a `0600` file that an unsigned build can always write.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

MAC = Path(__file__).resolve().parents[1] / "Apps" / "HermesMac"


class PairingPersistenceGuards(unittest.TestCase):
    def setUp(self) -> None:
        self.store = (MAC / "Pairing" / "PairingStore.swift").read_text(encoding="utf-8")
        self.workspace = (MAC / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")

    def test_all_three_storages_exist(self) -> None:
        for case in ("dataProtectionKeychain", "loginKeychain", "file"):
            self.assertIn(f"case {case}", self.store, f"storage tier {case} is declared")

    def test_save_writes_the_file_even_when_the_keychain_refuses(self) -> None:
        save = self.store.split("func save(", 1)[1].split("func clear(", 1)[0]
        self.assertIn("addKeychain(data, to: variant)", save)
        self.assertIn("if writeFile(data)", save,
                      "the file is the tier an unsigned build can always write")
        self.assertIn("persisted = !written.isEmpty", save)

    def test_read_tries_the_keychain_before_the_file(self) -> None:
        read = self.store.split("private func read()", 1)[1].split("private func query(", 1)[0]
        self.assertLess(read.index("dataProtectionKeychain"), read.index("readFile()"),
                        "the encrypted copy is read before the file")
        self.assertIn("for variant in [Storage.dataProtectionKeychain, .loginKeychain]", read)

    def test_the_file_is_private_and_not_backed_up(self) -> None:
        self.assertIn("0o600", self.store)
        self.assertIn("0o700", self.store)
        self.assertIn("isExcludedFromBackup = true", self.store)

    def test_clear_removes_every_tier(self) -> None:
        clear = self.store.split("func clear()", 1)[1].split("// MARK: Keychain", 1)[0]
        self.assertIn("deleteKeychain()", clear)
        self.assertIn("removeFile()", clear)

    def test_launch_restores_the_saved_address(self) -> None:
        init = self.workspace.split("init() {", 1)[1].split("restorePreferences()", 1)[0]
        self.assertIn("savedAddress()", init, "a relaunch must resume the stored pairing")
        self.assertIn("pairingStorage = store.storage", init)

    def test_pairing_does_not_auto_unpair_on_a_refused_token(self) -> None:
        # A 401 must surface as a notice, never as a silent unpair that costs a code.
        for path in MAC.rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("store.unpair()", text.replace("await store.unpair()", ""),
                             f"{path.name} calls unpair outside the explicit verb")

    def test_settings_say_where_the_pairing_is_kept(self) -> None:
        settings = (MAC / "Views" / "MacSettingsView.swift").read_text(encoding="utf-8")
        self.assertIn("pairingStorageDescription", settings)


if __name__ == "__main__":
    unittest.main()
