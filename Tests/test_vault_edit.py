"""Editing a vault item: a rename and a replacement, and still no way to read a value.

The vault shipped as names-only, and `test_vault_pane.py` pins that. The owner then asked to be able to
*edit* an item — a login whose password changed, a key that was rotated — which means a request that
carries a value for something that already exists. That is the first time anything in this feature
accepts a secret, so these guards are about the three ways it can go wrong:

* an answer that repeats what it was given (there must be no shape for a value in a response);
* a second write path that stores, publishes or masks differently from an add (there must be none);
* a sheet that pretends it already knows what is stored (it must start empty and say so).

They are static checks over the Rust and the Swift, in the style the pane's own guards use: they fail at
the moment the mistake is written, and comments are stripped first so a sentence *about* values cannot
satisfy a check that values are absent.
"""

from __future__ import annotations

import pathlib
import re
import unittest

from test_vault_pane import ROOT, block, code, module_code

HERMEYD = ROOT / "hermeyd" / "src"
VAULT_RS = (HERMEYD / "vault.rs").read_text(encoding="utf-8")
SECRETS_RS = (HERMEYD / "secrets.rs").read_text(encoding="utf-8")
CREDENTIALS_RS = (HERMEYD / "credentials.rs").read_text(encoding="utf-8")
MAIN_RS = (HERMEYD / "main.rs").read_text(encoding="utf-8")
POINTER = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text(encoding="utf-8")
GATEWAY = (ROOT / "Sources" / "HermesKit" / "GatewayClient.swift").read_text(encoding="utf-8")
ACTOR = (ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift").read_text(encoding="utf-8")
SHARED = (ROOT / "Sources" / "HermesKit" / "VaultItems.swift").read_text(encoding="utf-8")
APP_MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
MAC_PANE = (ROOT / "Apps" / "HermesMac" / "Credentials" / "VaultPane.swift").read_text(encoding="utf-8")
MAC_SHEET = (ROOT / "Apps" / "HermesMac" / "Credentials" / "VaultEditSheet.swift").read_text(
    encoding="utf-8"
)
PHONE_PANE = (ROOT / "Apps" / "HermesMobile" / "Views" / "VaultScreen.swift").read_text(encoding="utf-8")
PHONE_SHEET = (ROOT / "Apps" / "HermesMobile" / "Views" / "VaultEditSheet.swift").read_text(
    encoding="utf-8"
)

# What a stored value would be called if somebody put one in a response.
VALUE_NAMES = ("value", "secret", "password", "token", "contents", "text")

# The one sentence that makes a rename-only edit expressible. Both sheets say it, word for word.
KEEP_CURRENT = "Leave blank to keep the current value."


class TheEditRouteIsAPlainDeviceRoute(unittest.TestCase):
    def test_the_route_exists_and_is_the_owner_s(self) -> None:
        self.assertIn("pub async fn edit_item(", code(VAULT_RS))

    def test_it_checks_the_device_before_it_touches_the_store(self) -> None:
        body = block(code(VAULT_RS), "pub async fn edit_item(")
        self.assertIn("require_device(", body, "an edit that skipped the device check is an open door")
        # Nothing may be read, validated against the store or written before the owner is established:
        # the first statement is the check, and it precedes both the store call and the first refusal.
        self.assertLess(body.index("require_device("), body.index("crate::secrets::edit("))
        self.assertLess(body.index("require_device("), body.index("return Err("))

    def test_it_is_mounted_as_a_patch_on_the_same_wildcard_as_the_delete(self) -> None:
        router = code(MAIN_RS)
        self.assertIn('"/v1/vault/{*name}"', router)
        self.assertIn(".patch(vault::edit_item)", router, "the edit must be a PATCH on the item's path")
        # A POST on /v1/vault would be a way to *create* an item from a value; creating is still the
        # stored credential card, and an edit only ever changes a name that already exists.
        self.assertNotRegex(
            router,
            r"/v1/vault[^\n]*post\(",
            "a POST on /v1/vault would let a value create an item, which is the card's job",
        )

    def test_neither_name_can_be_a_path(self) -> None:
        body = block(code(VAULT_RS), "pub async fn edit_item(")
        # The name in the path and the rename target are both held to the store's own pattern, and the
        # target is checked before the store is asked to move anything.
        self.assertIn("crate::secrets::valid_name(&name)", body)
        self.assertIn("crate::secrets::valid_name(next)", body)
        self.assertLess(
            body.index("crate::secrets::valid_name(next)"),
            body.index("crate::secrets::edit("),
            "a rename target that could be a path must be refused, not passed to the store",
        )
        for token in ("Path::new", "std::fs", "File::open", "canonicalize"):
            self.assertNotIn(token, body, f"the edit handler touches the filesystem: {token!r}")

    def test_the_store_checks_the_pattern_too(self) -> None:
        body = block(code(SECRETS_RS), "pub fn edit(")
        self.assertIn("valid_name(from) || !valid_name(to)", body)


class NoRouteReturnsAStoredValue(unittest.TestCase):
    def test_the_edit_answer_is_a_name_and_two_booleans(self) -> None:
        body = block(code(VAULT_RS), "pub async fn edit_item(")
        keys = set(re.findall(r'"([a-z_]+)"\s*:', body))
        self.assertEqual(
            keys,
            {"name", "renamed", "replaced"},
            "the edit's answer grew a key — a value in a response is the one thing this route must not do",
        )
        for forbidden in VALUE_NAMES:
            self.assertNotIn(forbidden, keys, f"the edit answer carries `{forbidden}`")

    def test_the_edit_handler_never_reads_a_value(self) -> None:
        body = block(code(VAULT_RS), "pub async fn edit_item(")
        for reader in ("secrets::get", "secrets::has", "secrets::names"):
            self.assertNotIn(reader, body, f"an edit needs no reader, and {reader} is one")

    def test_the_module_still_serves_no_value(self) -> None:
        shipped = module_code(VAULT_RS)
        self.assertNotIn("secrets::get", shipped)
        self.assertNotIn("secrets::has", shipped)
        # A value cannot be assembled into an answer either: no literal key named for one.
        self.assertNotRegex(shipped, r'"value"\s*:')

    def test_the_served_row_did_not_grow_a_member(self) -> None:
        item = block(code(VAULT_RS), "struct VaultItem")
        members = re.findall(r"^\s{4}(\w+):", item, flags=re.M)
        self.assertEqual(members, ["name", "kind", "added_at", "site", "note"])

    def test_the_edit_store_hands_back_an_outcome_and_never_a_value(self) -> None:
        signature = re.search(r"pub fn edit\([^)]*\)[^{]*->[^{]*", code(SECRETS_RS))
        self.assertIsNotNone(signature, "secrets::edit must exist")
        self.assertIn("Result<EditOutcome, String>", signature.group(0), "an edit returns no value")
        outcome = block(code(SECRETS_RS), "pub enum EditOutcome")
        self.assertEqual(
            set(re.findall(r"^\s{4}(\w+),", outcome, flags=re.M)),
            {"Changed", "Missing", "Taken"},
            "an outcome with a field would be a value coming back out of the store",
        )
        self.assertNotRegex(outcome, r"^\s{4}\w+\(", "no variant of EditOutcome carries data")

    def test_the_client_shape_cannot_carry_a_value_back(self) -> None:
        # Every layer's edit returns nothing at all, so no caller has a value to hold or draw: the
        # protocol's requirement, the refusing default, and the bridge that speaks to the host.
        declared = re.findall(
            r"func editVaultItem\(name: String, rename: String, value: String\?\) async throws[^\n]*",
            code(POINTER),
        )
        self.assertEqual(
            len(declared),
            3,
            "the protocol, its no-bridge default and the bridge must all declare the edit",
        )
        for line in declared:
            self.assertNotIn("->", line, f"an edit must return nothing, got: {line!r}")
        self.assertIn(
            "public func editVaultItem(name: String, rename: String, value: String?) async throws",
            code(ACTOR),
        )
        self.assertIn(
            "public func editVaultItem(name: String, rename: String, value: String?) async throws",
            code(APP_MODEL),
        )

    def test_a_refusal_quotes_neither_value(self) -> None:
        body = block(code(SECRETS_RS), "pub fn edit(")
        # The value arrives as `text`; formatting it into any message is how a secret reaches a log.
        self.assertNotIn("{text}", body)
        for logger in ("println!", "eprintln!", "dbg!", "log::", "tracing::"):
            self.assertNotIn(logger, module_code(SECRETS_RS), f"the store logs: {logger}")
            self.assertNotIn(logger, module_code(VAULT_RS), f"the vault route logs: {logger}")

    def test_no_sheet_reads_a_value_out_of_the_row(self) -> None:
        for name, source in (("Mac VaultEditSheet", MAC_SHEET), ("phone VaultEditSheet", PHONE_SHEET)):
            text = code(source)
            self.assertNotIn("item.value", text, f"{name} reads a value from the row")
            for forbidden in ("reveal", "showValue", "eye", "Pasteboard", "pasteboard", "unmask"):
                self.assertNotIn(forbidden, text, f"{name} has a reveal affordance: {forbidden!r}")


class EditingUsesTheSameWritePathAsAnAdd(unittest.TestCase):
    def test_one_map_and_exactly_one_write(self) -> None:
        body = block(code(SECRETS_RS), "pub fn edit(")
        self.assertIn("let mut map = load(st)?", body, "an edit reads the store the way an add does")
        self.assertEqual(body.count("save(st, &map)"), 1, "a rename and a value are one write, not two")
        self.assertLess(body.index("map.remove(from)"), body.index("save(st, &map)"))
        self.assertLess(body.index("map.insert(to"), body.index("save(st, &map)"))

    def test_there_is_no_second_publish_path(self) -> None:
        shipped = module_code(SECRETS_RS)
        # One loader, one saver, one publisher: a store function that wrote its own file — encrypted or
        # not — would be the second path this feature must not have.
        self.assertEqual(shipped.count("fn load("), 1)
        self.assertEqual(shipped.count("fn save("), 1)
        self.assertEqual(shipped.count("fs::rename"), 1, "the atomic publish must happen once")
        self.assertEqual(shipped.count("fn edit("), 1)

    def test_only_the_store_module_writes_the_store(self) -> None:
        for path in sorted(HERMEYD.glob("*.rs")):
            if path.name == "secrets.rs":
                continue
            text = module_code(path.read_text(encoding="utf-8"))
            self.assertNotIn("secrets.json", text, f"{path.name} writes the store file itself")
            self.assertNotRegex(
                text,
                r"fs::write\([^)]*secrets::path",
                f"{path.name} writes straight to the store",
            )

    def test_the_route_makes_one_call_and_keeps_no_copy(self) -> None:
        body = block(code(VAULT_RS), "pub async fn edit_item(")
        self.assertEqual(body.count("crate::secrets::edit("), 1, "two calls would be two transactions")
        self.assertIn("value.as_deref()", body, "the value goes straight through, unformatted")
        # The handler must not stash the value anywhere of its own: the only thing it may pass on is the
        # request's own field, and the reply is built from names.
        self.assertNotRegex(body, r"let\s+\w*value\w*\s*=\s*body\.value\.clone")


class TheSheetStartsBlankAndSaysSo(unittest.TestCase):
    def test_both_sheets_start_with_an_empty_value(self) -> None:
        for name, source in (("Mac VaultEditSheet", MAC_SHEET), ("phone VaultEditSheet", PHONE_SHEET)):
            text = code(source)
            self.assertIn('@State private var value = ""', text, f"{name} must start empty")
            init = block(text, "init(item: VaultItem")
            self.assertNotIn("value", init, f"{name} seeds the field from something — there is nothing")
            self.assertIn("SecureField(", text, f"{name} must mask the field it accepts")

    def test_both_sheets_say_leave_blank_to_keep_the_current_value(self) -> None:
        for name, source in (("Mac VaultEditSheet", MAC_SHEET), ("phone VaultEditSheet", PHONE_SHEET)):
            self.assertIn(KEEP_CURRENT, code(source), f"{name} does not say what a blank field means")

    def test_a_blank_field_is_sent_as_no_value_at_all(self) -> None:
        for name, source in (("Mac VaultEditSheet", MAC_SHEET), ("phone VaultEditSheet", PHONE_SHEET)):
            text = code(source)
            self.assertIn(
                "value: value.isEmpty ? nil : value",
                text,
                f"{name} sends a blank value instead of no value, which the host would refuse",
            )
            self.assertIn("await onSaved()", text, f"{name} leaves the pane showing a stale row")

    def test_the_value_does_not_outlive_the_request(self) -> None:
        for name, source in (("Mac VaultEditSheet", MAC_SHEET), ("phone VaultEditSheet", PHONE_SHEET)):
            text = code(source)
            save = block(text, "private func save() async")
            self.assertIn('value = ""', save, f"{name} keeps the value after the host took it")
            self.assertIn("await model.editVaultItem(", save)

    def test_a_blank_value_is_kept_on_an_edit_and_refused_on_a_create(self) -> None:
        # The two rules that must not be confused: an edit with no value means "keep what is stored"…
        edit = block(code(SECRETS_RS), "pub fn edit(")
        self.assertIn("None => current", edit, "an edit with no value must keep the stored one")
        self.assertIn("if let Some(text) = value", edit, "a replacement is optional, not required")
        self.assertIn("text.is_empty()", edit, "an empty replacement is not a value")
        # …while a create still refuses to store nothing, at the store and at the card.
        put = block(code(SECRETS_RS), "pub fn put(")
        self.assertIn("value.is_empty()", put)
        self.assertIn("nothing to store", put)
        answer = block(code(CREDENTIALS_RS), "pub async fn answer_card(")
        self.assertIn("values.is_empty()", answer)
        self.assertIn("no answers for that request", answer)

    def test_the_edit_only_renames_and_replaces_and_says_which(self) -> None:
        body = block(code(SECRETS_RS), "pub fn edit(")
        self.assertIn("EditOutcome::Missing", body, "an edit of a name nobody saved is its own answer")
        self.assertIn("EditOutcome::Taken", body, "a name already used by another item is refused")
        self.assertIn("if map.contains_key(to)", body, "a rename must not swallow another item")


class BothPlatformsReachTheSameRoute(unittest.TestCase):
    def test_the_mac_pane_offers_an_edit_and_presents_the_sheet(self) -> None:
        text = code(MAC_PANE)
        self.assertIn("pendingEdit", text)
        self.assertIn("VaultEditSheet(item: item", text)
        self.assertIn('Image(systemName: "pencil")', text)
        self.assertIn('.sheet(item: $pendingEdit)', text, "the Mac must present the sheet for one row")
        # Still no masked field in the pane itself: adding is the credential card's sheet, not this one.
        self.assertNotIn("SecureField", text)

    def test_the_phone_pane_offers_an_edit_from_the_row(self) -> None:
        text = code(PHONE_PANE)
        self.assertIn("pendingEdit", text)
        self.assertIn("VaultEditSheet(item: item", text)
        self.assertIn('Label("Edit"', text)
        self.assertIn('.sheet(item: $pendingEdit)', text, "the phone must present the sheet for one row")
        self.assertNotIn("SecureField", text)

    def test_the_shared_client_is_where_the_wire_shape_is_written(self) -> None:
        pointer = code(POINTER)
        self.assertIn('bridgePATCH("v1/vault/\\(item)"', pointer, "the edit must be a PATCH on the item")
        self.assertIn('"rename": rename', pointer)
        self.assertIn("if let value, !value.isEmpty", pointer, "a blank value must not be sent at all")
        self.assertIn("Self.pathComponent(name)", pointer, "the name is percent-encoded like a delete's")

        self.assertIn("func editVaultItem(name: String, rename: String, value: String?)", code(GATEWAY))
        self.assertIn("try await sessionPointer.editVaultItem(", code(ACTOR))
        self.assertIn("try await client.editVaultItem(", code(APP_MODEL))

    def test_a_client_with_no_bridge_refuses_rather_than_pretending(self) -> None:
        # The stubs on both protocols throw: an edit that silently succeeded would leave the pane saying
        # something was changed when nothing was.
        for name, source in (("BotSessionPointerStore", POINTER), ("GatewayClientProtocol", GATEWAY)):
            stub = re.search(
                r"func editVaultItem\(name: String, rename: String, value: String\?\) async throws \{"
                r"\s*throw BotAdminUnavailable\(\)",
                source,
            )
            self.assertIsNotNone(stub, f"{name} has no refusing default for an edit")

    def test_the_refusal_sentence_is_shared(self) -> None:
        self.assertIn("public static func refused(_ error: Error) -> String", code(SHARED))
        for name, source in (("Mac VaultEditSheet", MAC_SHEET), ("phone VaultEditSheet", PHONE_SHEET)):
            self.assertIn("VaultFailure.refused(", code(source), f"{name} invents its own words")


if __name__ == "__main__":
    unittest.main()
