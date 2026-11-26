"""The Vault pane: names on screen, values nowhere.

The host learned to keep secrets in 0.8.2/0.8.3 (`hermeyd/src/secrets.rs`), and the owner asked to see
them — add, list, delete — from the Mac's and the phone's Settings. The whole point of a vault is that a
value goes in once and never comes out, so the pane is the easiest place in the app to break that
promise: one `value` in a response, one "reveal" button, one local decoder that "just needs the text".

These are static checks over the Rust and Swift sources. They are cheap, and each one fails at the moment
the mistake is made rather than after an app build and a manual look at a pane nobody screenshots. The
Rust tests in `hermeyd/src/vault.rs` prove the routes behave; these prove the shape that makes the
behaviour possible.

Comment stripping matters here more than usual: this feature is *about* not showing values, so a file is
full of sentences containing the word "value", and a guard a comment can satisfy is not a guard.
"""

from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HERMEYD = ROOT / "hermeyd" / "src"
VAULT_RS = (HERMEYD / "vault.rs").read_text(encoding="utf-8")
SECRETS_RS = (HERMEYD / "secrets.rs").read_text(encoding="utf-8")
CREDENTIALS_RS = (HERMEYD / "credentials.rs").read_text(encoding="utf-8")
MAIN_RS = (HERMEYD / "main.rs").read_text(encoding="utf-8")
SHARED = (ROOT / "Sources" / "HermesKit" / "VaultItems.swift").read_text(encoding="utf-8")
POINTER = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text(encoding="utf-8")
APP_MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
MAC_PANE = (ROOT / "Apps" / "HermesMac" / "Credentials" / "VaultPane.swift").read_text(encoding="utf-8")
MAC_SETTINGS = (ROOT / "Apps" / "HermesMac" / "Views" / "MacSettingsView.swift").read_text(encoding="utf-8")
MAC_SHEET = (ROOT / "Apps" / "HermesMac" / "Credentials" / "CredentialCards.swift").read_text(encoding="utf-8")
PHONE_PANE = (ROOT / "Apps" / "HermesMobile" / "Views" / "VaultScreen.swift").read_text(encoding="utf-8")
PHONE_SETTINGS = (ROOT / "Apps" / "HermesMobile" / "Views" / "SettingsScreen.swift").read_text(encoding="utf-8")
PHONE_SHEET = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileCredentialCard.swift").read_text(encoding="utf-8")

# What a stored value might be called if somebody added it to a response. The item the host serves is
# built from a type that has none of these members, which is the check below.
VALUE_NAMES = ("value", "secret", "password", "token", "key_material", "contents", "text")


def code(text: str) -> str:
    """The source with comments removed, string literals left alone.

    A naive `line.split("//")` would eat `contains("//")` — the very token the name-pattern guard looks
    for — so the scanner tracks double-quoted strings, line comments and block comments.
    """
    out: list[str] = []
    index, length = 0, len(text)
    in_line = in_block = in_string = False
    while index < length:
        char = text[index]
        if in_line:
            if char == "\n":
                in_line = False
                out.append(char)
            index += 1
            continue
        if in_block:
            if text.startswith("*/", index):
                in_block = False
                index += 2
            else:
                if char == "\n":
                    out.append(char)
                index += 1
            continue
        if in_string:
            out.append(char)
            if char == "\\" and index + 1 < length:
                out.append(text[index + 1])
                index += 2
                continue
            if char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            out.append(char)
            index += 1
            continue
        if text.startswith("//", index):
            in_line = True
            index += 2
            continue
        if text.startswith("/*", index):
            in_block = True
            index += 2
            continue
        out.append(char)
        index += 1
    return "".join(out)


def module_code(text: str) -> str:
    """A Rust file's non-test half.

    The tests in `vault.rs` use `secrets::has` to check that a delete removed something — that is not the
    module reading a value, and a guard that could not tell the two apart would have to be weakened.
    """
    return code(text.split("#[cfg(test)]")[0])


def block(text: str, opener: str) -> str:
    """The brace-balanced body that follows `opener`, so a check covers one type or function."""
    start = text.index(opener)
    depth, index = 0, text.index("{", start)
    for position in range(index, len(text)):
        if text[position] == "{":
            depth += 1
        elif text[position] == "}":
            depth -= 1
            if depth == 0:
                return text[index : position + 1]
    raise AssertionError(f"unbalanced braces after {opener!r}")


class TheHostServesNamesAndNothingElse(unittest.TestCase):
    def test_the_served_item_has_no_member_a_value_could_travel_in(self) -> None:
        item = block(code(VAULT_RS), "struct VaultItem")
        members = re.findall(r"^\s{4}(\w+):", item, flags=re.M)
        self.assertEqual(
            members,
            ["name", "kind", "added_at", "site", "note"],
            "the vault row the host serialises must be names and labels only — a `value` member here "
            "would be served by GET /v1/vault no matter what the handler intended",
        )
        for forbidden in VALUE_NAMES:
            self.assertNotRegex(
                item,
                rf"^\s{{4}}{forbidden}\s*:",
                f"VaultItem declares `{forbidden}`",
            )

    def test_the_vault_module_never_reads_a_value(self) -> None:
        # `secrets::get` is the one function that returns a value. A module that cannot call it cannot
        # print one, which is a stronger statement than "the handler does not".
        shipped = module_code(VAULT_RS)
        self.assertNotIn("secrets::get", shipped)
        self.assertNotIn("secrets::has", shipped)
        # Nor may an answer be assembled with a `value` key.
        self.assertNotRegex(shipped, r'"value"\s*:')

    def test_the_list_route_is_names_plus_labels_and_the_delete_is_by_name(self) -> None:
        listing = block(code(VAULT_RS), "pub async fn list(")
        self.assertIn("secrets::names(", listing, "the list must be built from names")
        self.assertIn("require_device(", listing, "the vault is the owner's, like every other route")
        for label in ("kind", "added_at", "site", "note"):
            self.assertIn(label, listing, f"the row should carry {label}")

        deleting = block(code(VAULT_RS), "pub async fn delete_item(")
        self.assertIn("require_device(", deleting)
        self.assertIn("secrets::valid_name(", deleting, "the name pattern is checked before a lookup")
        self.assertIn("secrets::remove(", deleting, "deleting removes the name from the one store")
        self.assertIn("NOT_FOUND", deleting, "a name the vault does not have is a 404, not a quiet 200")

    def test_the_routes_are_mounted_the_way_the_panes_call_them(self) -> None:
        router = code(MAIN_RS)
        self.assertIn('"/v1/vault"', router)
        # A name may hold one `/` (`doctolib.de/password`), so the delete path is a wildcard.
        self.assertIn('"/v1/vault/{*name}"', router)
        self.assertIn("vault::list", router)
        self.assertIn("vault::delete_item", router)
        self.assertIn("mod vault;", router)

    def test_adding_a_value_still_only_happens_through_a_stored_card(self) -> None:
        # One door into the store: the credential card. The Vault pane creates one; it does not post a
        # value anywhere.
        self.assertNotIn("post", block(code(VAULT_RS), "pub async fn list("))
        self.assertNotRegex(
            code(MAIN_RS),
            r"/v1/vault[^\n]*post\(",
            "a POST on /v1/vault would be a second way for a value to enter the store",
        )
        self.assertIn("crate::secrets::put(", code(CREDENTIALS_RS), "the card is the path that writes")
        self.assertIn("crate::vault::note_stored(", code(CREDENTIALS_RS))


class ThePanesShowNamesOnly(unittest.TestCase):
    def test_neither_pane_offers_a_way_to_see_a_value(self) -> None:
        forbidden = (
            "reveal", "Show value", "showValue", "eye", "Pasteboard", "pasteboard",
            "copyToPasteboard", "UIPasteboard", "NSPasteboard", ".copy(", "isRevealed",
            "showSecret", "unmask",
        )
        for name, source in (("Mac VaultPane", MAC_PANE), ("phone VaultScreen", PHONE_PANE)):
            text = code(source)
            for token in forbidden:
                self.assertNotIn(token, text, f"{name} has a reveal affordance: {token!r}")

    def test_neither_pane_draws_a_value_even_as_a_row(self) -> None:
        # The rows read a name, a site, a note and a date. Nothing else is on the wire for them to draw.
        for name, source, row in (
            ("Mac VaultPane", MAC_PANE, "private func row(_ item: VaultItem)"),
            ("phone VaultScreen", PHONE_PANE, "private func row(_ item: VaultItem)"),
        ):
            body = block(code(source), row)
            shown = set(re.findall(r"item\.(\w+)", body))
            self.assertLessEqual(
                shown,
                {"name", "site", "note", "addedAt", "addedOn"},
                f"{name} draws something other than a label: {sorted(shown)}",
            )

    def test_both_apps_decode_one_shared_model(self) -> None:
        # No per-app copy, no per-app parsing: the two screens cannot drift because there is one type.
        for path in sorted((ROOT / "Apps").rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            self.assertNotRegex(
                text,
                r"struct\s+VaultItem\b",
                f"{path.name} declares its own VaultItem — the shared one is in Sources/HermesKit",
            )
        self.assertIn("public struct VaultItem", SHARED)
        for name, source in (("Mac VaultPane", MAC_PANE), ("phone VaultScreen", PHONE_PANE)):
            text = code(source)
            self.assertIn("VaultItem", text, f"{name} must use the shared row type")
            self.assertIn("model.vaultItems()", text, f"{name} must read through the shared client")
            self.assertNotIn("JSONDecoder", text, f"{name} decodes JSON itself")
            self.assertNotIn("JSONSerialization", text, f"{name} parses JSON itself")

    def test_the_shared_client_is_the_only_place_the_wire_shape_is_known(self) -> None:
        self.assertIn("func vaultItems()", POINTER)
        self.assertIn('bridgeGET("v1/vault"', POINTER)
        self.assertIn('bridgeDELETE("v1/vault/', POINTER)
        self.assertIn("public static func list(from data: Data)", SHARED)
        self.assertIn('root["items"]', SHARED)


class AddingGoesThroughTheOneMaskedSheet(unittest.TestCase):
    def test_the_panes_reuse_the_credential_sheets_rather_than_a_second_form(self) -> None:
        mac = code(MAC_PANE)
        phone = code(PHONE_PANE)
        self.assertIn("CredentialCardSheet(card:", mac)
        self.assertIn("MobileCredentialCardSheet(card:", phone)
        for name, text in (("Mac VaultPane", mac), ("phone VaultScreen", phone)):
            # A SecureField here would be a second masked form, which is the thing to avoid.
            self.assertNotIn("SecureField", text, f"{name} has its own masked field")
            self.assertIn("model.createVaultEntryCard(", text, f"{name} must ask the host for a card")

    def test_the_card_the_pane_asks_for_stores_into_the_vault(self) -> None:
        factory = block(code(APP_MODEL), "public func createVaultEntryCard(")
        self.assertIn("store: true", factory, "the pane's card must write to the vault, not to a page")
        self.assertIn("saveAs: name", factory, "the name is the label the pane lists")
        self.assertIn('fields: ["secret"]', factory, "one masked field: the value")
        # …and the host validates that name when the card is made, before anything is typed into it.
        self.assertIn("valid_name", code(CREDENTIALS_RS))

    def test_the_sheet_still_clears_what_was_typed(self) -> None:
        for name, sheet in (("Mac", MAC_SHEET), ("phone", PHONE_SHEET)):
            self.assertIn("values = [:]", sheet, f"the {name} sheet must not keep the value")


class DeletingIsTheHostSDelete(unittest.TestCase):
    def test_delete_hits_the_delete_route_and_surfaces_a_refusal(self) -> None:
        app_model = code(APP_MODEL)
        self.assertIn("public func deleteVaultItem(name: String)", app_model)
        self.assertIn("client.deleteVaultItem(name: name)", app_model)

        pointer = code(POINTER)
        self.assertIn('bridgeDELETE("v1/vault/\\(item)"', pointer,
                      "delete must be a DELETE on the vault's own route, not a POST that hides a name")

        for name, source in (("Mac VaultPane", MAC_PANE), ("phone VaultScreen", PHONE_PANE)):
            text = code(source)
            self.assertIn("model.deleteVaultItem(name: item.name)", text, f"{name} must delete by name")
            # A refusal (404/409) is shown, and the list is re-read rather than assuming success.
            self.assertIn("actionError = VaultFailure.sentence(error)", text,
                          f"{name} swallows a refused delete")

    def test_deletion_follows_a_confirmation_on_both_screens(self) -> None:
        for name, source in (("Mac VaultPane", MAC_PANE), ("phone VaultScreen", PHONE_PANE)):
            text = code(source)
            self.assertIn("confirmationDialog(", text, f"{name} deletes without asking")
            self.assertIn('role: .destructive', text)


class AnEmptyVaultIsNotABrokenHost(unittest.TestCase):
    def test_the_panes_tell_an_unreachable_host_from_an_empty_vault(self) -> None:
        for name, source in (("Mac VaultPane", MAC_PANE), ("phone VaultScreen", PHONE_PANE)):
            text = code(source)
            # `nil` is "unknown"; `[]` is "nothing saved". A catch that leaves `[]` behind would make a
            # dead connection look like a tidy vault, which is the one thing this pane must never do.
            self.assertIn("items = nil", text, f"{name} keeps a stale/empty list after a failure")
            self.assertIn("failure = VaultFailure.sentence(error)", text,
                          f"{name} does not say why the vault is missing")
            self.assertIn("items.isEmpty", text, f"{name} has no distinct empty state")
            self.assertNotIn("items = (try? ", text)
            self.assertNotIn("try? await model.vaultItems()", text,
                             f"{name} turns a failure into an empty list")

    def test_the_shared_reader_throws_instead_of_reading_a_broken_answer_as_empty(self) -> None:
        listing = block(code(SHARED), "public static func list(from data: Data)")
        self.assertIn("throw VaultReadError.notTheVault", listing)
        self.assertIn("error is URLError", SHARED, "an unreachable host needs its own sentence")
        self.assertIn("VaultFailure", SHARED)

    def test_refreshing_is_a_re_read_not_a_local_edit(self) -> None:
        for name, text in (("Mac VaultPane", code(MAC_PANE)), ("phone VaultScreen", code(PHONE_PANE))):
            self.assertIn("await load()", text, f"{name} must re-read after add/delete")
        mac = code(MAC_PANE)
        phone = code(PHONE_PANE)
        self.assertIn("await onSaved()", mac, "the Mac pane re-reads after the sheet saves")
        self.assertIn("await onSaved()", phone, "the phone pane re-reads after the sheet saves")


class TheNamePatternIsCheckedOnBothEnds(unittest.TestCase):
    def test_the_host_and_the_apps_agree_on_what_a_name_is(self) -> None:
        valid = block(SECRETS_RS, "pub fn valid_name")
        for fragment in ('starts_with(\'/\')', "ends_with('/')", 'contains("//")', 'contains("..")',
                         "MAX_NAME_BYTES"):
            self.assertIn(fragment, valid, f"the host's pattern lost {fragment}")
        self.assertIn("pub const MAX_NAME_BYTES: usize = 96", SECRETS_RS)

        swift = block(code(SHARED), "public static func isValid(_ name: String)")
        for fragment in ('hasPrefix("/")', 'hasSuffix("/")', 'contains("//")', 'contains("..")',
                         "maxLength"):
            self.assertIn(fragment, swift, f"the app's copy of the pattern lost {fragment}")
        self.assertIn("public static let maxLength = 96", SHARED)

        # …and a form will not let a name that could never be stored reach the value field.
        for name, source in (("Mac VaultPane", MAC_PANE), ("phone VaultScreen", PHONE_PANE)):
            text = code(source)
            self.assertIn("VaultName.isValid(trimmedName)", text,
                          f"{name} does not check the name before asking for a value")
            self.assertIn("disabled(!nameIsValid", text, f"{name} offers Continue for an invalid name")

    def test_the_delete_route_validates_before_it_looks_anything_up(self) -> None:
        deleting = block(code(VAULT_RS), "pub async fn delete_item(")
        check = deleting.index("secrets::valid_name(")
        lookup = deleting.index("secrets::remove(")
        self.assertLess(check, lookup, "a name the store would not hold must be refused, not looked up")


if __name__ == "__main__":
    unittest.main()
