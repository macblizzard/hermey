"""Fast pet asks: a balloon question is answered in the bot's own bounded session.

What it fixes: `POST /v1/bots/tinker/ask` with `{"question":"hi","from":"desktop-pet"}` cost
12–15s, always against session `20260103_…`-style endless transcripts, because the route delivered
the greeting into the bot's *whole* conversation — full transcript, full prompt, every tool the
profile enables — for one word.

These are source-shape guards, the trade the rest of the host's tests make: the behaviour itself
is covered by the Rust tests beside the code (`cargo test` in `hermeyd/`), which pin the pet path
onto the bounded session and the normal path onto the bot's conversation. Two tests here pin the
trade-off this change had to resolve out loud — the pet's answer no longer lands in the
conversation the app opens — and two pin the levers the gateway wire does and does not carry.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MESSAGE = (ROOT / "hermeyd" / "src" / "bot_message.rs").read_text(encoding="utf-8")
STORE = (ROOT / "hermeyd" / "src" / "store.rs").read_text(encoding="utf-8")
DOCS = (ROOT / "docs" / "HERMEYD.md").read_text(encoding="utf-8")


def body_of(name: str, source: str = MESSAGE) -> str:
    """The text of one function, from its signature to the closing brace at column zero."""
    start = source.index(name)
    end = source.index("\n}\n", start)
    return source[start:end]


class ThePetTakesTheBoundedSession(unittest.TestCase):
    """Ask 1: a dedicated per-bot pet session, created once, reused, capped."""

    def test_the_pet_pointer_is_its_own_row_not_the_conversation(self) -> None:
        self.assertIn("CREATE TABLE IF NOT EXISTS pet_sessions", STORE)
        self.assertIn("SELECT stored_session_id FROM pet_sessions", STORE)
        # The conversation the app opens is a different table and must stay one.
        self.assertIn("CREATE TABLE IF NOT EXISTS bot_sessions", STORE)
        self.assertIn("SELECT stored_session_id FROM bot_sessions", STORE)

    def test_the_ask_route_reads_the_pet_pointer_for_a_balcony_question(self) -> None:
        run_ask = body_of("pub(crate) async fn run_ask")
        self.assertIn('st.store.get_bot_pet_session(profile).unwrap_or_default()', run_ask)
        # `unwrap_or_default` is the point: a first balloon needs no conversation at all.
        self.assertIn("A pet ask needs no conversation yet: it makes", run_ask)

    def test_the_window_is_capped_and_rotates_rather_than_grows(self) -> None:
        self.assertRegex(
            MESSAGE,
            re.compile(r"const PET_WINDOW: i64 = \d+;"),
            "the cap has to be a number somebody can read",
        )
        run_ask = body_of("pub(crate) async fn run_ask")
        self.assertIn(">= PET_WINDOW", run_ask, "a window at the cap must be noticed")
        self.assertIn("stored.clear();", run_ask, "…and cleared, so the delivery mints instead")
        self.assertIn("pet_message_count", run_ask, "the cap is measured, not assumed")

    def test_a_mint_is_recorded_so_the_next_ask_resumes_it(self) -> None:
        run_ask = body_of("pub(crate) async fn run_ask")
        self.assertIn("st.store.set_bot_pet_session(profile, &poll)", run_ask)
        # The minted key, not the runtime id, is what is polled against and reported.
        self.assertIn('delivered.stored_session_id.clone()', run_ask)
        self.assertIn("Ok(ask_body(profile, &plan, &poll, reply.as_deref()))", run_ask)


class TheNormalPathStillTakesTheBotsConversation(unittest.TestCase):
    """Everything that is not a balloon question, byte for byte as it was."""

    def test_a_normal_ask_still_requires_the_conversation_the_app_opens(self) -> None:
        run_ask = body_of("pub(crate) async fn run_ask")
        self.assertIn(
            'require_stored(st.store.get_bot_session(profile), profile, "ask")?',
            run_ask,
            "a non-pet ask must still be a 409 without a conversation",
        )

    def test_a_plain_message_is_never_marked_as_the_pets(self) -> None:
        run_message = body_of("pub(crate) async fn run_message")
        self.assertIn("pet: None", run_message)
        self.assertNotIn("pet_model", run_message)
        self.assertNotIn("PET_WINDOW", run_message)

    def test_the_sender_decides_the_route_not_a_field_the_caller_adds(self) -> None:
        plan = body_of("pub(crate) fn plan_ask")
        self.assertIn("pet: sender == PET_SENDER", plan)
        self.assertNotIn('"desktop-pet"', plan, "the literal lives in one constant, not here")


class TheFastModelComesOnlyFromTheProfilesOwnConfig(unittest.TestCase):
    """Ask 2: a per-session model — reachable, and never a name we invented."""

    def test_the_wire_lever_is_session_create_and_it_is_used(self) -> None:
        mint = body_of("async fn create_pet_session")
        self.assertIn('"method": "session.create"', mint)
        # The four keys the create contract carries for us: nothing else is sent.
        self.assertIn('json!({ "profile": req.profile, "title": mint.title })', mint)
        self.assertIn("params[\"model\"] = json!(model)", mint)
        self.assertIn("params[\"provider\"] = json!(mint.provider)", mint)

    def test_the_model_is_read_from_config_yaml_not_written_by_us(self) -> None:
        pet_model = body_of("fn pet_model")
        for token in ('join("config.yaml")', 'get("model")', 'get("default")',
                      'get("fallback_providers")'):
            self.assertIn(token, pet_model)
        # The pin travels as a field, so no literal model name can reach the wire by accident.
        self.assertIn("pub model: Option<&'a str>", MESSAGE)
        self.assertIn("if let Some(model) = mint.model", body_of("async fn create_pet_session"))

    def test_the_model_is_read_for_a_pet_ask_and_for_nothing_else(self) -> None:
        run_ask = body_of("pub(crate) async fn run_ask")
        self.assertIn("if plan.pet { pet_model(st, profile) } else { None }", run_ask)


class TheLeversTheWireDoesNotCarry(unittest.TestCase):
    """Asks 3 and 4, named honestly: not reachable per session, so not faked here."""

    def test_no_toolset_key_is_sent_because_create_has_none(self) -> None:
        # `session.create` accepts cols/source/cwd/messages/parent/title/model/provider/
        # reasoning_effort/fast/service_tier/close_on_disconnect/hidden/room_plumbing/
        # follow_profile_config/idempotency_key — no toolsets (contracts/sessions.py), and
        # `prompt.submit` has none either. `tools.configure` would rewrite the *profile's*
        # config.yaml, changing the bot's normal conversation too, so it is not used.
        for absent in ("toolset", "enabled_toolsets", "disabled_toolsets"):
            self.assertNotIn(absent, MESSAGE, f"hermeyd must not claim a {absent} lever it lacks")

    def test_no_system_prompt_key_is_sent_because_create_has_none(self) -> None:
        # The gateway builds the agent's system prompt from profile config and env only
        # (tui_gateway/agent_factory.py `_startup_system_prompt`); there is no per-session prompt
        # parameter to send, so none is sent.
        for absent in ("system_prompt", "ephemeral_system_prompt", '"prompt"'):
            self.assertNotIn(absent, MESSAGE, f"hermeyd must not claim a {absent} lever it lacks")


class TheTranscriptTradeOffIsResolvedOutLoud(unittest.TestCase):
    """Ask 5, the one the brief refused to let us drop silently."""

    def test_the_docs_say_where_the_pet_answer_lands_now(self) -> None:
        self.assertIn("pet", DOCS.lower())
        for phrase in ("bounded", "session.create", "transcript"):
            self.assertIn(phrase, DOCS, f"the report to the owner must mention {phrase}")

    def test_the_route_module_says_the_conversation_is_no_longer_the_pets(self) -> None:
        self.assertIn("separate, bounded session", MESSAGE)
        self.assertIn("Every other `from` keeps the old route byte for byte", MESSAGE)


if __name__ == "__main__":
    unittest.main()
