"""The secure-entry card: one mechanism for a login and an API key, and the value has one destination.

The card itself shipped earlier (`docs/CREDENTIALS.md`, `hermeyd/src/credentials.rs`): a bot asks, both
apps draw it, the owner answers, the bot is told one thing. What this file pins is the part that was
missing and that Mohammad asked for by name — *"any sensitive entries it needs from me like an api ...
should come to me as a secure entry card"*:

* a card can be **stored**, and a stored answer goes into the host's vault (`hermeyd/src/secrets.rs`),
  never back to the caller;
* the fields the host calls secret are **masked in both apps**, so `api key` is as private as
  `password` without either app knowing the word;
* the sheet says where the value is going, and the bot gets an acknowledgement that names an item;
* and the value is written to exactly one place in the source — no card file, no transcript, no log,
  no `UserDefaults`, no `bridge.db` document.

These are source-level guards because this box has no Swift compiler and no running app: the XCTest
targets on CI cover what the views do, and the Rust unit tests cover what the routes return. This file
covers the sentence a refactor would quietly break.
"""
from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HERMEYD = ROOT / "hermeyd" / "src"

CREDENTIALS = (HERMEYD / "credentials.rs").read_text(encoding="utf-8")
SECRETS = (HERMEYD / "secrets.rs").read_text(encoding="utf-8")
BROWSER = (HERMEYD / "browser.rs").read_text(encoding="utf-8")
ROUTES = (HERMEYD / "main.rs").read_text(encoding="utf-8")
AUDIT = (HERMEYD / "audit.rs").read_text(encoding="utf-8")

MODEL = (ROOT / "Sources/HermesKit/CredentialCards.swift").read_text(encoding="utf-8")
MAC = (ROOT / "Apps/HermesMac/Credentials/CredentialCards.swift").read_text(encoding="utf-8")
IOS = (ROOT / "Apps/HermesMobile/Views/MobileCredentialCard.swift").read_text(encoding="utf-8")
CLI = (ROOT / "hermeyd/assets/agent-skills/bin/hermey_signin.py").read_text(encoding="utf-8")
SKILL = (ROOT / "hermeyd/assets/agent-skills/signin/SKILL.md").read_text(encoding="utf-8")
DOC = (ROOT / "docs/CREDENTIALS.md").read_text(encoding="utf-8")


def body(source: str, start: str, end: str | None = None) -> str:
    """The slice of a source from `start` to `end` (or EOF), for per-function assertions."""
    at = source.index(start)
    return source[at:source.index(end)] if end and end in source[at:] else source[at:]


class TheHostStoresWhatTheOwnerTypes(unittest.TestCase):
    """`answer` writes to the vault; `consume` answers with a name."""

    def test_a_card_can_ask_for_a_stored_answer(self) -> None:
        create = body(CREDENTIALS, "pub struct CreateCard", "pub async fn create_card")
        self.assertIn("pub store: bool", create)
        self.assertIn("pub save_as: Option<String>", create)
        # Both optional on the wire: an older caller keeps the card it already knew.
        for field in ("pub store: bool", "pub save_as: Option<String>"):
            self.assertIn(f"#[serde(default)]\n    {field}", create, field)

    def test_the_saved_name_is_checked_before_the_owner_types_anything(self) -> None:
        create = body(CREDENTIALS, "pub async fn create_card", "let mut cards = load(&st);")
        # A name the store cannot hold is refused at create time, not after a password was typed.
        self.assertIn("crate::secrets::valid_name(name)", create)
        self.assertIn("save_as needs store: true", create)
        self.assertIn("save_as names one value, so the card asks for one field", create)

    def test_an_answered_store_card_keeps_a_name_and_no_value(self) -> None:
        answer = body(CREDENTIALS, "pub async fn answer_card", "pub async fn cancel_card")
        self.assertIn('let store = card.get("store").and_then(Value::as_bool).unwrap_or(false);', answer)
        self.assertIn("crate::secrets::put(&st, &name, text)", answer)
        self.assertIn('stored.push(json!({ "field": field, "name": name }));', answer)
        # The value is dropped from the card document the moment it is in the vault.
        self.assertIn('card["values"] = Value::Null;', answer)
        self.assertIn('card["stored"] = json!(stored);', answer)
        # …and the acknowledgement is a state, never a value.
        self.assertIn('Ok(Json(json!({ "id": card_id, "state": "answered" })))', answer)

    def test_a_value_is_bounded_and_the_refusal_does_not_quote_it(self) -> None:
        answer = body(CREDENTIALS, "pub async fn answer_card", "pub async fn cancel_card")
        self.assertIn("crate::secrets::MAX_VALUE_BYTES", answer)
        self.assertIn("StatusCode::PAYLOAD_TOO_LARGE", answer)
        # The detail names the limit. It is built from the constant, so it cannot carry the text.
        self.assertNotIn('detail: text', answer)
        self.assertNotIn("println!", answer)
        self.assertNotIn("eprintln!", answer)

    def test_consume_hands_over_a_value_once_or_a_name_forever(self) -> None:
        consume = body(CREDENTIALS, "pub async fn consume_card", "#[cfg(test)]")
        self.assertIn('let stored = card.get("stored").cloned().filter(|s| !s.is_null());', consume)
        self.assertIn('"ok": true', consume)
        self.assertIn('"stored": stored', consume)
        # The values path is untouched for a card that was not stored.
        self.assertIn('Ok(Json(json!({ "id": card_id, "values": values })))', consume)
        # A stored card cannot fall through to the values branch.
        stored_branch = consume[consume.index('if let Some(stored) = stored {'):consume.index('"values": values')]
        self.assertIn("return Ok(", stored_branch)
        # A stored card cannot reach the values branch: it returns before it.
        self.assertNotIn("\"values\"", stored_branch)

    def test_the_app_is_told_which_fields_are_secrets(self) -> None:
        view = body(CREDENTIALS, "fn view(card: &Value) -> Value", "/// Drop cards that stopped")
        self.assertIn('"masked": crate::secrets::masked_fields(&fields),', view)
        self.assertIn('"store": store,', view)
        # The button's words are the host's, so a bot cannot relabel a vault save as a page fill.
        self.assertIn('"submit": if store { "Save to the vault" } else { "Fill it in" },', view)

    def test_every_step_is_audited_and_a_stored_step_has_its_own_event(self) -> None:
        self.assertIn('"credentials.stored"', CREDENTIALS)
        # `audit::Event` is scalar-only and `emit` drops an event outside the list, so the name has to
        # be registered or the record is silently lost (it was, in the first cut of this change).
        self.assertIn('"credentials.stored",', AUDIT)


class TheVaultIsOneFileNobodyServes(unittest.TestCase):
    def test_the_store_sits_beside_the_other_owner_only_state(self) -> None:
        self.assertIn('st.home.join("secrets.json")', SECRETS)
        self.assertIn("std::fs::Permissions::from_mode(0o600)", SECRETS)
        # Written to a temp file and renamed: a reader never sees half a vault.
        self.assertIn("std::fs::rename(&tmp, &file)", SECRETS)
        self.assertIn('.secrets.{}.tmp', SECRETS)

    def test_a_name_cannot_be_a_path(self) -> None:
        self.assertIn("pub fn valid_name(name: &str) -> bool", SECRETS)
        for guard in ('name.contains("..")', 'name.contains("//")', 'name.starts_with(\'/\')'):
            self.assertIn(guard, SECRETS, guard)
        self.assertIn("MAX_NAME_BYTES", SECRETS)
        self.assertIn("MAX_VALUE_BYTES: usize = 4096", SECRETS)

    def test_a_masked_field_is_the_default(self) -> None:
        # The rule is a list of the *ordinary* names, so a new secret-shaped field is hidden by default.
        self.assertIn('pub const PLAIN_FIELDS: &[&str] = &["username", "user", "email", "site", "host", "account", "login"];', SECRETS)
        self.assertIn("pub fn is_masked(field: &str) -> bool", SECRETS)
        self.assertIn("!PLAIN_FIELDS.contains(", SECRETS)

    def test_a_corrupt_vault_is_refused_instead_of_overwritten(self) -> None:
        load = body(SECRETS, "fn load(st: &AppState)", "/// Publish the store in one step")
        self.assertIn("the secret store is not readable JSON; nothing was written", load)
        self.assertNotIn("unwrap_or_default()", load)

    def test_nothing_serves_the_vault(self) -> None:
        # No route mentions it: the only reader is a fill, and a fill's reply is the extension's.
        self.assertNotIn("secrets::", ROUTES)
        self.assertNotIn("/v1/secrets", ROUTES)
        # The module that owns it is mounted, so the routes can reach it.
        self.assertIn("mod secrets;", ROUTES)

    def test_the_only_reader_is_a_fill_by_name(self) -> None:
        fill = body(BROWSER, "fn fill_fields", "#[cfg(test)]")
        self.assertIn("crate::secrets::get(st, &name)", fill)
        self.assertIn('item.insert("value".to_string(), json!(value));', fill)
        # A name that is not stored says so and names nothing else.
        self.assertIn("no stored secret named {name}", fill)
        # A caller cannot smuggle a value alongside the name it is replacing.
        self.assertIn("a field carries a value or a secret name, not both", fill)


class BothAppsMaskAndSayWhereItGoes(unittest.TestCase):
    def test_neither_app_recognises_a_password_by_name(self) -> None:
        for source, name in ((MAC, "Mac"), (IOS, "iPhone")):
            self.assertNotIn('field == "password"', source, name)
            self.assertIn("card.isMasked(field)", source, name)
            self.assertIn("SecureField(field.capitalized, text: binding(field))", source, name)

    def test_the_sheet_says_the_destination_and_the_hosts_button_words(self) -> None:
        for source, name in ((MAC, "Mac"), (IOS, "iPhone")):
            self.assertIn("Text(card.destinationNote)", source, name)
            self.assertIn("card.submit", source, name)
            self.assertNotIn('"Fill it in"', source, name)

    def test_the_two_destinations_read_differently(self) -> None:
        self.assertIn("Saved to the vault on this host — the bot gets its name, never the value.", MODEL)
        self.assertIn("Typed straight into the page — it never enters the chat.", MODEL)
        self.assertIn('card.store ? "Save a credential for', MAC)
        self.assertIn('card.store ? "Save a credential for', IOS)

    def test_the_model_has_no_place_to_keep_a_value(self) -> None:
        # The type carries what the card asks for, never an answer — the cheapest guarantee there is.
        for forbidden in ("var values", "let values", "var secret:", "let secret:", "var password"):
            self.assertNotIn(forbidden, MODEL, forbidden)
        self.assertIn("public let masked: [String]", MODEL)
        self.assertIn("public let store: Bool", MODEL)
        self.assertIn("public static let plainFields: Set<String>", MODEL)
        # An older host that names no masked fields still gets everything but the plain ones hidden.
        self.assertIn("?? CredentialCard.defaultMasked(fields)", MODEL)
        self.assertIn("?? (store ? \"Save to the vault\" : \"Fill it in\")", MODEL)

    def test_nothing_typed_is_persisted_and_nothing_is_sent_as_a_message(self) -> None:
        for source, name in ((MAC, "Mac"), (IOS, "iPhone")):
            for word in ("UserDefaults", "AppStorage", "SceneStorage", "FileManager", "print(", "NSLog"):
                self.assertNotIn(word, source, f"{name}: {word}")
            # Cleared the moment it is sent, and never routed through the composer.
            self.assertIn("values = [:]", source, name)
            self.assertIn("answerCredentialCard", source, name)
            self.assertNotIn("model.send(", source, name)
            self.assertNotIn("model.draft", source, name)


class TheBotIsToldToAskRatherThanGiveUp(unittest.TestCase):
    def test_the_cli_can_store_and_reuse_a_name(self) -> None:
        self.assertIn('"--store"', CLI)
        self.assertIn('"--save-as"', CLI)
        self.assertIn('"--use"', CLI)
        self.assertIn('body["store"] = True', CLI)
        self.assertIn('print("stored " + ", ".join(', CLI)
        # A stored answer is a name: the CLI must not fall through to filling a page with nothing.
        after = CLI[CLI.index('stored = outcome.get("stored") or []'):]
        self.assertIn("return 0", after[:after.index("values = outcome.get")])

    def test_a_host_without_a_vault_says_so_instead_of_filling(self) -> None:
        # The CLI can reach a host older than this feature (0.8.0 ignores `store`). It must not go on to
        # fill a page and report `filled` for a card that asked to be stored.
        self.assertIn('if store and not created.get("store"):', CLI)
        self.assertIn("this host has no vault yet", CLI)
        self.assertIn("nothing was asked of the owner", CLI)

    def test_a_fill_by_name_sends_a_name_not_a_value(self) -> None:
        fill = body(CLI, "def _fill(", "def _await_browser")
        self.assertIn('fields.append({"name": name, "secret": handle})', fill)
        # The DevTools fallback can only type a value it was handed, so it is skipped for a name.
        self.assertIn("a stored credential is filled through the sign-in extension", CLI)

    def test_nothing_the_cli_prints_is_a_value(self) -> None:
        # `values` exists only to be handed to a fill; no print statement formats it.
        for line in CLI.splitlines():
            if "print(" not in line:
                continue
            self.assertNotIn("{values", line, line)
            self.assertNotIn("values[", line, line)
            self.assertNotIn("+ values", line, line)
            self.assertNotIn("outcome", line, line)
            if "values" in line:
                self.assertIn("_deliver(", line, f"a value reached a print statement: {line}")

    def test_the_skill_tells_a_bot_what_to_do_on_a_login_wall(self) -> None:
        self.assertIn("Never answer", SKILL)
        self.assertIn('"I can\'t, it needs a login"', SKILL)
        self.assertIn("--store", SKILL)
        self.assertIn("--use", SKILL)

    def test_the_contract_document_matches_what_the_code_does(self) -> None:
        # It used to promise "never stored after the fill"; a stored card is the opposite of that.
        self.assertIn("store", DOC)
        self.assertIn("vault", DOC.lower())


class TheRustTestsThatProveItExist(unittest.TestCase):
    def test_the_store_and_fill_cases_are_pinned(self) -> None:
        for name in (
            "a_stored_answer_goes_to_the_vault_and_never_comes_back",
            "a_saved_name_is_validated_when_the_card_is_asked_for",
            "an_oversized_value_is_refused_and_nothing_is_stored",
            "an_ordinary_card_still_hands_its_value_over_exactly_once",
            "the_view_names_the_masked_fields_and_the_buttons_words",
        ):
            self.assertIn(name, CREDENTIALS, name)
        for name in (
            "a_fill_by_name_resolves_the_value_the_caller_never_saw",
            "a_fill_by_name_refuses_what_it_cannot_resolve",
        ):
            self.assertIn(name, BROWSER, name)
        for name in (
            "the_store_is_owner_only_and_written_in_one_step",
            "a_corrupt_store_refuses_a_write_instead_of_replacing_it",
            "the_guards_refuse_what_could_be_a_path_or_a_flood",
            "a_value_never_appears_in_any_answer",
        ):
            self.assertIn(name, SECRETS, name)


if __name__ == "__main__":
    unittest.main()